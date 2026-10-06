import Foundation
import UIKit

struct LutInfo: Decodable, Identifiable, Hashable {
    let name: String
    let folder: String?
    var id: String { name }
    var label: String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        return last.replacingOccurrences(of: ".png", with: "", options: [.caseInsensitive, .anchored, .backwards])
    }
}

struct OverlayInfo: Decodable, Identifiable, Hashable {
    let name: String
    var id: String { name }
    var label: String { name.replacingOccurrences(of: ".png", with: "", options: [.caseInsensitive, .backwards]) }
}

struct Preset: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let shape: String?
    let color: String?
    let recipe: JSONValue
    let linked_count: Int?
}

struct Histogram: Decodable, Equatable {
    let bins: Int
    let r: [Double]
    let g: [Double]
    let b: [Double]
    let luma: [Double]
    let clipped_high_pct: Double?
    let clipped_low_pct: Double?
}

struct Exif: Decodable {
    let filename: String?
    let exif: [String: String?]
}

private struct Items<T: Decodable>: Decodable { let items: [T] }

extension API {
    private func body(_ obj: Any) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8) }

    /// Saved recipe + preset link, or nil when the photo has never been edited.
    func edit(_ id: String) async throws -> (recipe: JSONValue, presetID: Int?)? {
        do {
            let (d, _) = try await send(request("/api/photos/\(id)/edit"))
            struct R: Decodable { let recipe: JSONValue; let preset_id: Int? }
            let r = try JSONDecoder().decode(R.self, from: d)
            return (r.recipe, r.preset_id)
        } catch APIError.status(404, _) { return nil }
    }

    func putEdit(_ id: String, recipe: JSONValue, presetID: Int?) async throws -> Double {
        let q = presetID.map { "?preset_id=\($0)" } ?? ""
        let (d, _) = try await send(request("/api/photos/\(id)/edit\(q)", method: "PUT", body: recipe.data, timeout: 20))
        struct R: Decodable { let updated_at: Double? }
        return (try? JSONDecoder().decode(R.self, from: d))?.updated_at ?? Date().timeIntervalSince1970
    }

    func deleteEdit(_ id: String) async throws {
        _ = try await send(request("/api/photos/\(id)/edit", method: "DELETE", timeout: 20))
    }

    func previewEdit(_ id: String, recipe: JSONValue, longEdge: Int) async throws -> UIImage {
        let (d, _) = try await send(request("/api/photos/\(id)/preview_edit?long_edge=\(longEdge)", method: "POST", body: recipe.data, timeout: 60))
        guard let img = UIImage(data: d) else { throw APIError.status(0, "bad image") }
        return await img.byPreparingForDisplay() ?? img
    }

    func prepare(_ id: String) async {
        _ = try? await send(request("/api/photos/\(id)/prepare", method: "POST", body: Data("{}".utf8)))
    }

    /// `/auto` (everything) or `/auto_tone` (exposure + brightness).
    func auto(_ id: String, toneOnly: Bool) async throws -> [String: JSONValue] {
        let (d, _) = try await send(request("/api/photos/\(id)/\(toneOnly ? "auto_tone" : "auto")", timeout: 40))
        struct R: Decodable { let suggestion: [String: JSONValue]? }
        return try JSONDecoder().decode(R.self, from: d).suggestion ?? [:]
    }

    func histogram(_ id: String, recipe: JSONValue) async throws -> Histogram {
        let b64 = recipe.data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let (d, _) = try await send(request("/api/photos/\(id)/histogram?bins=64&recipe=\(b64)", timeout: 30))
        return try JSONDecoder().decode(Histogram.self, from: d)
    }

    func exif(_ id: String) async throws -> Exif {
        let (d, _) = try await send(request("/api/photos/\(id)/exif"))
        return try JSONDecoder().decode(Exif.self, from: d)
    }

    func luts() async throws -> [LutInfo] {
        let (d, _) = try await send(request("/api/luts", timeout: 30))
        return try JSONDecoder().decode(Items<LutInfo>.self, from: d).items
    }

    func favoriteLuts() async throws -> Set<String> {
        let (d, _) = try await send(request("/api/collections"))
        struct C: Decodable { let kind: String?; let members: [String]? }
        let cs = try JSONDecoder().decode(Items<C>.self, from: d).items
        return Set(cs.first { $0.kind == "favorites" }?.members ?? [])
    }

    func setFavorite(_ lut: String, _ on: Bool) async throws {
        if on {
            _ = try await send(request("/api/favorites", method: "POST", body: body(["lut_name": lut])))
        } else {
            let q = lut.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+/"))) ?? lut
            _ = try await send(request("/api/favorites?lut_name=\(q)", method: "DELETE"))
        }
    }

    func overlays(_ kind: String) async throws -> [OverlayInfo] {
        let (d, _) = try await send(request("/api/overlays/\(kind)"))
        return try JSONDecoder().decode(Items<OverlayInfo>.self, from: d).items
    }

    func presets() async throws -> [Preset] {
        let (d, _) = try await send(request("/api/presets"))
        return try JSONDecoder().decode(Items<Preset>.self, from: d).items
    }

    func createPreset(name: String, recipe: JSONValue) async throws -> Preset {
        let payload: JSONValue = ["name": .string(name), "recipe": recipe]
        let (d, _) = try await send(request("/api/presets", method: "POST", body: payload.data))
        return try JSONDecoder().decode(Preset.self, from: d)
    }

    func updatePreset(_ id: Int, name: String? = nil, recipe: JSONValue? = nil) async throws {
        var o: [String: JSONValue] = [:]
        if let name { o["name"] = .string(name) }
        if let recipe { o["recipe"] = recipe }
        _ = try await send(request("/api/presets/\(id)", method: "PATCH", body: JSONValue.object(o).data))
    }

    func deletePreset(_ id: Int) async throws {
        _ = try await send(request("/api/presets/\(id)", method: "DELETE"))
    }

    /// Full render of `recipe` (web = 2048 px). Returns the JPEG and the server's file name.
    func render(_ id: String, recipe: JSONValue, web: Bool) async throws -> (Data, String) {
        var r = recipe
        if web {
            var ex = r["export"]?.object ?? [:]
            ex["long_edge"] = 2048
            ex["quality"] = 92
            r["export"] = .object(ex)
        }
        let (d, http) = try await send(request("/api/photos/\(id)/render", method: "POST", body: r.data, timeout: 300))
        var name = "photo.jpg"
        if let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           let a = cd.range(of: "filename=\""), let b = cd[a.upperBound...].firstIndex(of: "\"") {
            name = String(cd[a.upperBound..<b])
        }
        return (d, name)
    }

    /// One request for a whole selection: preset / merge (paste) / clear.
    func batchEdits(_ ids: [String], mode: String, presetID: Int? = nil, recipe: JSONValue? = nil, fields: [String]? = nil) async throws {
        var o: [String: JSONValue] = ["photo_ids": .array(ids.map { .string($0) }), "mode": .string(mode)]
        if let presetID { o["preset_id"] = .number(Double(presetID)) }
        if let recipe { o["recipe"] = recipe }
        if let fields { o["fields"] = .array(fields.map { .string($0) }) }
        _ = try await send(request("/api/edits/batch", method: "POST", body: JSONValue.object(o).data, timeout: 120))
    }

    func lutSwatch(_ photoID: String, lut: String) -> URLRequest {
        let q = lut.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? lut
        return imageRequest("/api/photos/\(photoID)/lut_preview?lut=\(q)&size=128")
    }

    func overlayImage(_ kind: String, _ name: String) -> URLRequest {
        let q = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        return imageRequest("/api/overlays/\(kind)/\(q)")
    }

    func lutImage(_ name: String) -> URLRequest {
        let q = name.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String($0) }.joined(separator: "/")
        return imageRequest("/api/luts/\(q)")
    }

    func basePreview(_ id: String) -> URLRequest { imageRequest("/api/photos/\(id)/preview") }
}

/// The copy / paste clipboard for edits (a subset of a recipe), kept across launches.
enum EditClipboard {
    private static let key = "editClipboard"
    static var value: [String: JSONValue]? {
        get { UserDefaults.standard.data(forKey: key).flatMap(JSONValue.decode)?.object }
        set { UserDefaults.standard.set(newValue.map { JSONValue.object($0).data }, forKey: key) }
    }
}
