import Foundation

struct SyncResult {
    var counts = SyncCounts()
    var reachedServer = false
    var log: [(level: LogLine.Level, text: String)] = []
    var summary = ""
}

/// One pass: fetch the selected set, add what is new, replace what was re-edited,
/// take out what was deselected. Idempotent — a row is written only after the
/// asset exists, so an interrupted run just continues next time.
struct SyncEngine {
    let api: API
    let store: SyncStore
    let writer: PhotosWriter

    static let maxFailures = 3

    func run(deadline: Date?, progress: @escaping (Double, String) -> Void) async -> SyncResult {
        var res = SyncResult()
        guard await writer.authorize() else {
            res.log.append((.error, "No Photos access — allow it in iOS Settings › Photoshopper3000 › Photos (Full Access)."))
            res.summary = "Needs Photos access"
            return res
        }
        progress(0, "Asking the server…")
        let set: SyncSet
        do { set = try await api.syncSet() } catch {
            res.summary = "Server not reachable"
            res.log.append((.error, "Server not reachable: \(error.localizedDescription)"))
            return res
        }
        res.reachedServer = true
        await api.prepare()   // renders the rest ahead of us

        let album: String
        do { album = try await writer.albumID(named: Settings.albumName) } catch {
            res.summary = "Could not create the album"
            res.log.append((.error, "Album: \(error.localizedDescription)"))
            return res
        }

        let have = store.all()
        let wanted = Dictionary(uniqueKeysWithValues: set.items.map { ($0.id, $0) })
        // Assets the user deleted in Photos count as missing, so they come back.
        let alive = await writer.existing(Set(have.values.map(\.assetID)))

        var todo: [SyncItem] = []
        for item in set.items where item.available {
            if let row = have[item.id], alive.contains(row.assetID), row.recipeHash == item.recipe_hash,
               row.variant == item.variant || !item.full_available {
                continue
            }
            if store.failureCount(item.id) >= Self.maxFailures { res.counts.failed += 1; continue }
            todo.append(item)
        }
        // Rendered ones first: those are instant.
        todo.sort { ($0.rendered ? 0 : 1, $0.capture_dt ?? "") < ($1.rendered ? 0 : 1, $1.capture_dt ?? "") }
        let dropped = have.values.filter { wanted[$0.photoID] == nil }

        res.counts.selected = set.count
        var replacedOld: [String] = []
        var done = 0
        for item in todo {
            if let deadline, Date() > deadline { break }
            let name = item.filename ?? item.id
            progress(Double(done) / Double(max(todo.count, 1)), "\(done + 1) of \(todo.count) · \(name)")
            do {
                let ex = try await api.export(item)
                let assetID = try await writer.add(ex.data, created: item.captureDate, filename: name, toAlbum: album)
                let old = have[item.id]
                store.upsert(SyncedRow(photoID: item.id, recipeHash: ex.recipeHash, variant: ex.variant,
                                       assetID: assetID, bytes: ex.data.count, syncedAt: Date()))
                if let old, alive.contains(old.assetID) {
                    replacedOld.append(old.assetID)
                    res.log.append((.replaced, "Replaced \(name) (re-edited)"))
                } else {
                    res.log.append((.added, "Added \(name)"))
                }
            } catch APIError.stale {
                // Edited again while we were at it; the next run picks up the new hash.
                continue
            } catch {
                store.noteFailure(item.id, error.localizedDescription)
                res.counts.failed += 1
                res.log.append((.error, "\(name): \(error.localizedDescription)"))
            }
            done += 1
        }

        // Deselected on the server → take the asset out of Photos.
        let removeIDs = dropped.map(\.assetID).filter { alive.contains($0) }
        let toDelete = replacedOld + removeIDs
        if !toDelete.isEmpty {
            progress(1, "Tidying up \(toDelete.count) old version\(toDelete.count == 1 ? "" : "s")…")
            // One system confirmation for the whole batch; if declined, the rows stay
            // correct (the new assets are already recorded) and nothing is lost.
            let ok = await writer.delete(toDelete)
            if ok {
                for r in dropped { store.remove(r.photoID); res.log.append((.removed, "Removed \(r.photoID) (deselected)")) }
            } else {
                res.log.append((.info, "Kept \(toDelete.count) old version\(toDelete.count == 1 ? "" : "s") (deletion not confirmed)"))
            }
        } else {
            for r in dropped where !alive.contains(r.assetID) { store.remove(r.photoID) }
        }

        let after = store.all()
        res.counts.inPhotos = set.items.filter { after[$0.id]?.recipeHash == $0.recipe_hash }.count
        res.counts.pending = max(0, set.items.filter(\.available).count - res.counts.inPhotos - res.counts.failed)
        res.summary = res.counts.pending == 0
            ? "Up to date · \(res.counts.inPhotos) in Photos"
            : "\(res.counts.inPhotos) in Photos · \(res.counts.pending) to go"
        progress(1, res.summary)
        return res
    }
}
