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

    private func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 20) -> URLRequest {
        var r = URLRequest(url: URL(string: base.absoluteString + path)!)
        r.httpMethod = method
        r.timeoutInterval = timeout
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue(ClientID.value, forHTTPHeaderField: "X-Client-Id")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
