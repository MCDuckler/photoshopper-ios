import Foundation
import Combine

/// One write as the server's `POST /api/ops` takes it. Last writer wins on `ts`,
/// so an offline rating from yesterday never beats one made elsewhere since.
struct Op: Codable, Equatable {
    var op: String
    var ts: Double
    var photo_id: String?
    var photo_ids: [String]?
    var rating: Int?
    var recipe: JSONValue?
    var preset_id: Int?
    var album_id: Int?
    var client_op_id: String

    init(_ op: String, photoID: String? = nil, photoIDs: [String]? = nil, rating: Int? = nil,
         recipe: JSONValue? = nil, presetID: Int? = nil, albumID: Int? = nil) {
        self.op = op
        self.ts = Date().timeIntervalSince1970
        self.photo_id = photoID
        self.photo_ids = photoIDs
        self.rating = rating
        self.recipe = recipe
        self.preset_id = presetID
        self.album_id = albumID
        self.client_op_id = String(Int(ts * 1000), radix: 36) + String(UInt32.random(in: 0...UInt32.max), radix: 36)
    }
}

/// What changed on this phone, so every screen holding the photo can patch itself
/// before the server has even heard about it.
enum LocalChange {
    case rating([String], Int)
    case edited(String, Bool, Double)          // photo, has edit, edited_at
    case album(Int, [String], added: Bool)
}

struct OpsResult: Decodable {
    struct One: Decodable { let client_op_id: String?; let applied: Bool?; let error: String? }
    let results: [One]
    let head: Int?
}

/// Writes are applied locally first, queued on disk, and sent when the server is
/// reachable — the review deck never waits on Wi-Fi.
@MainActor
final class Outbox: ObservableObject {
    static let shared = Outbox()

    @Published private(set) var pending = 0
    @Published private(set) var lastError: String?
    let changes = PassthroughSubject<LocalChange, Never>()

    private var ops: [Op]
    private var flushing = false

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("outbox.json")
    }

    private init() {
        ops = (try? JSONDecoder().decode([Op].self, from: Data(contentsOf: Self.url))) ?? []
        pending = ops.count
    }

    // MARK: writes

    func rate(_ ids: [String], _ rating: Int) {
        guard !ids.isEmpty else { return }
        enqueue(ids.count == 1 ? Op("rating", photoID: ids[0], rating: rating) : Op("rating", photoIDs: ids, rating: rating),
                .rating(ids, rating))
    }

    func albumAdd(_ albumID: Int, _ ids: [String]) {
        enqueue(Op("album_add", photoIDs: ids, albumID: albumID), .album(albumID, ids, added: true))
    }

    func albumRemove(_ albumID: Int, _ ids: [String]) {
        enqueue(Op("album_remove", photoIDs: ids, albumID: albumID), .album(albumID, ids, added: false))
    }

    func edit(_ id: String, recipe: JSONValue, presetID: Int?) {
        let op = Op("edit", photoID: id, recipe: recipe, presetID: presetID)
        // A newer edit of the same photo supersedes a queued one.
        ops.removeAll { $0.op == "edit" && $0.photo_id == id }
        enqueue(op, .edited(id, true, op.ts))
    }

    func editDelete(_ id: String) {
        ops.removeAll { $0.op == "edit" && $0.photo_id == id }
        let op = Op("edit_delete", photoID: id)
        enqueue(op, .edited(id, false, op.ts))
    }

    private func enqueue(_ op: Op, _ change: LocalChange) {
        ops.append(op)
        save()
        changes.send(change)
        Task { await flush() }
    }

    // MARK: send

    func flush() async {
        guard !flushing, !ops.isEmpty, let api = AppModel.shared.api else { return }
        flushing = true
        defer { flushing = false }
        // Ops queued while a batch is in flight are picked up by the next turn.
        while !ops.isEmpty {
            let before = ops.count
            let batch = Array(ops.prefix(500))
            do {
                let r = try await api.ops(batch)
                let done = Set(r.results.compactMap(\.client_op_id))
                ops.removeAll { done.contains($0.client_op_id) }
                lastError = nil
                save()
            } catch APIError.status(let code, let msg) where code == 422 || code == 400 {
                // The server will never take this batch; keep the queue moving.
                let ids = Set(batch.map(\.client_op_id))
                ops.removeAll { ids.contains($0.client_op_id) }
                lastError = "Dropped \(batch.count) change(s): \(msg.prefix(120))"
                save()
            } catch {
                lastError = error.localizedDescription
                return
            }
            if ops.count >= before { break }
        }
    }

    private func save() {
        pending = ops.count
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(ops).write(to: Self.url, options: .atomic)
    }
}

extension API {
    func ops(_ ops: [Op]) async throws -> OpsResult {
        let body = try JSONEncoder().encode(["ops": ops])
        let (d, _) = try await send(request("/api/ops", method: "POST", body: body, timeout: 40))
        return try JSONDecoder().decode(OpsResult.self, from: d)
    }
}
