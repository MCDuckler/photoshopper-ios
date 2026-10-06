import Foundation

struct Health: Decodable { let ok: Bool; let service: String; let version: String? }

struct SyncItem: Decodable, Identifiable, Hashable {
    let id: String
    let variant: String
    let filename: String?
    let capture_dt: String?
    let rating: Int
    let w: Int?
    let h: Int?
    let recipe_hash: String
    let rendered: Bool
    let available: Bool
    let full_available: Bool

    /// EXIF "YYYY:MM:DD HH:MM:SS" → Date, so the asset sorts at the shoot.
    var captureDate: Date? {
        guard let s = capture_dt, s.count >= 19 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: String(s.prefix(19)))
    }
}

struct SyncSet: Decodable { let head: Int; let count: Int; let items: [SyncItem] }

struct Export {
    let data: Data
    let recipeHash: String
    let variant: String
}

enum APIError: LocalizedError {
    case status(Int, String)
    case stale(String)
    var errorDescription: String? {
        switch self {
        case .status(let c, let m): return "HTTP \(c): \(m)"
        case .stale: return "Edit changed on the server"
        }
    }
}

struct API {
    let base: URL
    let token: String?

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 600
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 20) -> URLRequest {
        var r = URLRequest(url: URL(string: base.absoluteString + path)!)
        r.httpMethod = method
        r.timeoutInterval = timeout
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue(ClientID.value, forHTTPHeaderField: "X-Client-Id")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (d, resp) = try await Self.session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.status(0, "no response") }
        if http.statusCode == 409 { throw APIError.stale(String(data: d, encoding: .utf8) ?? "") }
        guard (200..<300).contains(http.statusCode) else { throw APIError.status(http.statusCode, String(data: d, encoding: .utf8) ?? "") }
        return (d, http)
    }

    func health() async throws -> Health {
        let (d, _) = try await send(request("/api/health", timeout: 6))
        return try JSONDecoder().decode(Health.self, from: d)
    }

    func syncSet() async throws -> SyncSet {
        let (d, _) = try await send(request("/api/sync/set"))
        return try JSONDecoder().decode(SyncSet.self, from: d)
    }

    func prepare() async {
        _ = try? await send(request("/api/sync/prepare", method: "POST", body: Data("{}".utf8)))
    }

    /// Rendered JPEG. Renders on the server if not cached, so this can take a while.
    func export(_ item: SyncItem) async throws -> Export {
        let v = item.full_available ? item.variant : "web"
        let path = "/api/photos/\(item.id)/export?variant=\(v)&hash=\(item.recipe_hash)"
        let (d, http) = try await send(request(path, timeout: 180))
        return Export(data: d,
                      recipeHash: http.value(forHTTPHeaderField: "X-Recipe-Hash") ?? item.recipe_hash,
                      variant: http.value(forHTTPHeaderField: "X-Variant") ?? v)
    }
}

enum ClientID {
    static let value: String = {
        let k = "clientID"
        if let v = UserDefaults.standard.string(forKey: k) { return v }
        let v = "ios-" + UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(v, forKey: k)
        return v
    }()
}

// MARK: - Browsing

struct PhotoItem: Decodable, Identifiable, Hashable {
    let id: String
    let filename: String?
    let w: Int?
    let h: Int?
    let capture_dt: String?
    var rating: Int
    var has_edit: Bool
    var edited_at: Double?
    let camera: String?

    var aspect: CGFloat {
        guard let w, let h, w > 0, h > 0 else { return 1.5 }
        return CGFloat(w) / CGFloat(h)
    }
    var monthKey: String { capture_dt.map { String($0.prefix(7)) } ?? "" }
    var captureDate: Date? {
        guard let s = capture_dt, s.count >= 19 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: String(s.prefix(19)))
    }
}

struct PhotoPage: Decodable { let next_cursor: String?; let items: [PhotoItem] }
struct Album: Decodable, Identifiable, Hashable { let id: Int; let name: String; let count: Int; let published: Int? }
struct Folder: Decodable, Identifiable, Hashable { let path: String; let count: Int; var id: String { path } }
private struct Items<T: Decodable>: Decodable { let items: [T] }
private struct IDs: Decodable { let ids: [String]; let total: Int }

extension API {
    private func json(_ obj: Any) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8) }

    func photos(query: String, cursor: String?) async throws -> PhotoPage {
        var q = "limit=500"
        if !query.isEmpty { q += "&" + query }
        if let cursor { q += "&cursor=" + cursor }
        let (d, _) = try await send(request("/api/photos?" + q, timeout: 40))
        return try JSONDecoder().decode(PhotoPage.self, from: d)
    }

    func albums() async throws -> [Album] {
        let (d, _) = try await send(request("/api/albums"))
        return try JSONDecoder().decode(Items<Album>.self, from: d).items
    }

    func folders() async throws -> [Folder] {
        let (d, _) = try await send(request("/api/folders"))
        return try JSONDecoder().decode(Items<Folder>.self, from: d).items
    }

    func phoneIDs() async throws -> Set<String> {
        let (d, _) = try await send(request("/api/photos/ids?phone=true"))
        return Set(try JSONDecoder().decode(IDs.self, from: d).ids)
    }

    func addToPhone(_ ids: [String], variant: String) async throws {
        _ = try await send(request("/api/sync/set", method: "POST", body: json(["photo_ids": ids, "variant": variant])))
    }

    func removeFromPhone(_ ids: [String]) async throws {
        _ = try await send(request("/api/sync/set", method: "DELETE", body: json(["photo_ids": ids, "variant": "full"])))
    }

    func rate(_ id: String, _ rating: Int) async throws {
        _ = try await send(request("/api/photos/\(id)", method: "PATCH", body: json(["rating": rating])))
    }

    /// Authenticated request for an image; the server sends immutable cache headers,
    /// so URLCache keeps them across launches.
    func imageRequest(_ path: String) -> URLRequest {
        var r = request(path, timeout: 60)
        r.cachePolicy = .returnCacheDataElseLoad
        return r
    }

    func thumb(_ p: PhotoItem) -> URLRequest {
        p.has_edit
            ? imageRequest("/api/photos/\(p.id)/edited_thumb?size=512&v=\(Int(p.edited_at ?? 0))")
            : imageRequest("/api/photos/\(p.id)/thumb?size=512")
    }

    func preview(_ p: PhotoItem) -> URLRequest {
        p.has_edit
            ? imageRequest("/api/photos/\(p.id)/edited_preview?long_edge=1600&v=\(Int(p.edited_at ?? 0))")
            : imageRequest("/api/photos/\(p.id)/preview")
    }

    /// Sharper than `preview` for zooming in. Unedited photos only have the 2048 px
    /// RAW preview, which `preview` already is.
    func hq(_ p: PhotoItem) -> URLRequest? {
        p.has_edit ? imageRequest("/api/photos/\(p.id)/edited_preview?long_edge=4096&v=\(Int(p.edited_at ?? 0))") : nil
    }
}
