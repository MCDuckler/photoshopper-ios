import Foundation
import Photos
import ImageIO

enum PhotosError: LocalizedError {
    case noAccess, noAlbum, failed(String)
    var errorDescription: String? {
        switch self {
        case .noAccess: return "No Photos access"
        case .noAlbum: return "Album could not be created"
        case .failed(let m): return m
        }
    }
}

/// All PhotoKit work. Assets land in the user's library (→ iCloud Photos) and
/// in one album.
struct PhotosWriter {
    func authorize() async -> Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if s == .authorized || s == .limited { return true }
        if s == .notDetermined {
            let n = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return n == .authorized || n == .limited
        }
        return false
    }

    func albumID(named name: String) async throws -> String {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title = %@", name)
        if let c = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject {
            return c.localIdentifier
        }
        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            id = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name).placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id else { throw PhotosError.noAlbum }
        return id
    }

    func add(_ data: Data, created: Date?, filename: String, toAlbum albumID: String) async throws -> String {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { throw PhotosError.noAlbum }
        var newID: String?
        let stem = (filename as NSString).deletingPathExtension
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let o = PHAssetResourceCreationOptions()
            o.originalFilename = stem + "-edit.jpg"
            req.addResource(with: .photo, data: data, options: o)
            if let created { req.creationDate = created }
            if let ph = req.placeholderForCreatedAsset {
                newID = ph.localIdentifier
                PHAssetCollectionChangeRequest(for: album)?.addAssets([ph] as NSArray)
            }
        }
        guard let newID else { throw PhotosError.failed("asset not created") }
        return newID
    }

    func existing(_ ids: Set<String>) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let r = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        var out = Set<String>()
        r.enumerateObjects { a, _, _ in out.insert(a.localIdentifier) }
        return out
    }

    /// iOS asks the user once for the whole batch.
    func delete(_ ids: [String]) async -> Bool {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return true }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            return true
        } catch { return false }
    }

    /// Rebuild the index from the album: every Photoshopper export carries an
    /// XMP packet with its photo id and recipe hash.
    func rescan(albumID: String, into store: SyncStore, progress: @escaping (Int, Int) -> Void) async -> Int {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return 0 }
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        var list: [PHAsset] = []
        assets.enumerateObjects { a, _, _ in list.append(a) }
        var found = 0
        for (i, a) in list.enumerated() {
            progress(i + 1, list.count)
            guard let data = await imageData(a), let tag = XMPTag.read(data) else { continue }
            store.upsert(SyncedRow(photoID: tag.id, recipeHash: tag.hash, variant: tag.variant,
                                   assetID: a.localIdentifier, bytes: data.count, syncedAt: a.creationDate ?? Date()))
            found += 1
        }
        return found
    }

    private func imageData(_ a: PHAsset) async -> Data? {
        await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.version = .original
            o.isNetworkAccessAllowed = true
            o.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: a, options: o) { d, _, _, _ in cont.resume(returning: d) }
        }
    }
}

struct XMPTag {
    let id: String, hash: String, variant: String

    /// Pulls photoshopper:id / :hash / :variant out of the embedded XMP packet
    /// (first 64 KB of the JPEG is enough — the server writes it right after SOI).
    static func read(_ data: Data) -> XMPTag? {
        let head = data.prefix(65536)
        guard let s = String(data: head, encoding: .isoLatin1), s.contains("photoshopper:id=") else { return nil }
        func attr(_ name: String) -> String? {
            guard let r = s.range(of: "photoshopper:\(name)=\"") else { return nil }
            let rest = s[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        guard let id = attr("id"), let hash = attr("hash") else { return nil }
        return XMPTag(id: id, hash: hash, variant: attr("variant") ?? "full")
    }
}
