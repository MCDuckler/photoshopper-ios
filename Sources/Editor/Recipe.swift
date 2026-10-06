import Foundation
import CoreGraphics

/// The server's EditRecipe, kept as JSON so fields the phone has no control for
/// (export settings, anything added later) survive a round trip untouched.
struct Recipe: Equatable {
    var raw: [String: JSONValue]

    static let identityCurve: [Double] = [0, 0.25, 0.5, 0.75, 1]

    static let defaults: [String: JSONValue] = [
        "exposure": 0, "brightness": 0, "contrast": 0, "wb_temp": 5500, "wb_tint": 0,
        "highlights": 0, "shadows": 0, "whites": 0, "blacks": 0,
        "saturation": 0, "vibrance": 0, "sharpening": 0,
        "grain_amount": 0, "grain_size": 1, "grain_roughness": 0,
        "rotation": 0,
        "tone_curve": [0, 0.25, 0.5, 0.75, 1],
        "hsl": .array(Array(repeating: .number(0), count: 24)),
        "crop": ["x": 0, "y": 0, "w": 1, "h": 1],
        "dehaze": 0,
        "bw_amount": 0,
        "bw_mixer": .array(Array(repeating: .number(0), count: 8)),
        "vignette_amount": 0, "vignette_feather": 0.5, "vignette_midpoint": 0.5, "vignette_roundness": 0.5,
        "matte": 0,
        "split_shadow_hex": "#1f3a7a", "split_shadow_sat": 0,
        "split_highlight_hex": "#f0c878", "split_highlight_sat": 0,
        "split_balance": 0,
        "halation_amount": 0, "halation_radius": 0.5,
        "bloom_amount": 0, "bloom_threshold": 0.7, "bloom_radius": 0.5,
        "light_leak": .null, "light_leak_amount": 0.5,
        "film_border": .null,
        "date_stamp": false, "date_stamp_text": .null,
        "lut": .null,
    ]

    /// Integer fields on the server model.
    static let intKeys: Set<String> = ["wb_temp", "rotation"]

    static var fresh: Recipe { Recipe(raw: defaults) }

    init(raw: [String: JSONValue]) { self.raw = raw }

    /// Server recipe over the defaults.
    init(server: JSONValue?) {
        var r = Self.defaults
        for (k, v) in server?.object ?? [:] { r[k] = v }
        raw = r
    }

    var json: JSONValue { .object(raw) }

    // MARK: numbers

    func num(_ k: String) -> Double { raw[k]?.double ?? Self.defaults[k]?.double ?? 0 }

    mutating func set(_ k: String, _ v: Double) {
        raw[k] = .number(Self.intKeys.contains(k) ? v.rounded() : v)
    }

    func nums(_ k: String) -> [Double] {
        let def = Self.defaults[k]?.array?.compactMap(\.double) ?? []
        guard let a = raw[k]?.array else { return def }
        let v = a.map { $0.double ?? 0 }
        return v.count == def.count || def.isEmpty ? v : def
    }

    mutating func setNums(_ k: String, _ v: [Double]) { raw[k] = .array(v.map { .number($0) }) }

    func isDefault(_ k: String) -> Bool {
        guard let d = Self.defaults[k] else { return true }
        if let dv = d.double { return abs(num(k) - dv) < 1e-9 }
        if d.array != nil {
            let def = d.array!.compactMap(\.double)
            return zip(nums(k), def).allSatisfy { abs($0 - $1) < 1e-6 }
        }
        if k == "crop" { return !cropActive }
        return (raw[k] ?? .null) == d
    }

    // MARK: typed fields

    var crop: CGRect {
        get {
            guard let o = raw["crop"]?.object else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
            return CGRect(x: o["x"]?.double ?? 0, y: o["y"]?.double ?? 0, width: o["w"]?.double ?? 1, height: o["h"]?.double ?? 1)
        }
        set {
            raw["crop"] = .object(["x": .number(newValue.minX), "y": .number(newValue.minY), "w": .number(newValue.width), "h": .number(newValue.height)])
        }
    }

    var cropActive: Bool {
        let c = crop
        return c.minX > 1e-4 || c.minY > 1e-4 || c.width < 0.9999 || c.height < 0.9999
    }

    var rotation: Int {
        get { Int(num("rotation")) }
        set { raw["rotation"] = .number(Double(((newValue % 360) + 360) % 360)) }
    }

    var lutName: String? {
        get { raw["lut"]?["name"]?.string }
        set {
            if let n = newValue { raw["lut"] = .object(["name": .string(n), "amount": .number(lutAmount)]) }
            else { raw["lut"] = .null }
        }
    }

    var lutAmount: Double {
        get { raw["lut"]?["amount"]?.double ?? 1 }
        set { if let n = lutName { raw["lut"] = .object(["name": .string(n), "amount": .number(newValue)]) } }
    }

    func string(_ k: String) -> String? { raw[k]?.string }
    mutating func setString(_ k: String, _ v: String?) { raw[k] = v.map { .string($0) } ?? .null }
    func bool(_ k: String) -> Bool { raw[k]?.bool ?? false }
    mutating func setBool(_ k: String, _ v: Bool) { raw[k] = .bool(v) }

    /// Crop and rotation decide the frame shape.
    func outputAspect(source: CGFloat) -> CGFloat {
        let a = rotation % 180 == 0 ? source : 1 / max(source, 0.01)
        let c = crop
        return a * max(c.width, 0.01) / max(c.height, 0.01)
    }

    /// Everything that changes the picture, for "is anything set" and badges.
    var isIdentity: Bool { Recipe.copiable.allSatisfy { isDefault($0.key) } && lutName == nil }

    /// Fields for copy / paste, in the web app's order.
    static let copiable: [(key: String, label: String)] = [
        ("exposure", "Exposure"), ("brightness", "Brightness"), ("contrast", "Contrast"),
        ("wb_temp", "Temp"), ("wb_tint", "Tint"), ("highlights", "Highlights"), ("shadows", "Shadows"),
        ("whites", "Whites"), ("blacks", "Blacks"), ("saturation", "Saturation"), ("vibrance", "Vibrance"),
        ("sharpening", "Sharpening"), ("dehaze", "Dehaze"), ("bw_amount", "B&W"), ("bw_mixer", "B&W mixer"),
        ("grain_amount", "Grain"), ("grain_size", "Grain size"), ("grain_roughness", "Grain color"),
        ("tone_curve", "Tone curve"), ("hsl", "Color mix"),
        ("vignette_amount", "Vignette"), ("vignette_feather", "Vignette feather"), ("vignette_midpoint", "Vignette midpoint"), ("vignette_roundness", "Vignette roundness"),
        ("matte", "Matte"), ("split_shadow_hex", "Split shadow color"), ("split_shadow_sat", "Split shadow"),
        ("split_highlight_hex", "Split highlight color"), ("split_highlight_sat", "Split highlight"), ("split_balance", "Split balance"),
        ("halation_amount", "Halation"), ("halation_radius", "Halation size"), ("bloom_amount", "Bloom"),
        ("bloom_threshold", "Bloom threshold"), ("bloom_radius", "Bloom size"),
        ("light_leak", "Light leak"), ("light_leak_amount", "Leak amount"), ("film_border", "Film border"), ("date_stamp", "Date stamp"),
        ("rotation", "Rotation"), ("crop", "Crop"), ("lut", "Look (LUT)"),
    ]

    /// Fields that are set on this recipe (what "Copy" offers ticked).
    var activeFields: [String] {
        Recipe.copiable.map { $0.key }.filter { k in
            switch k {
            case "lut": return lutName != nil
            case "split_shadow_hex": return num("split_shadow_sat") > 0
            case "split_highlight_hex": return num("split_highlight_sat") > 0
            case "light_leak_amount": return string("light_leak") != nil
            case "grain_size", "grain_roughness": return num("grain_amount") > 0
            case "vignette_feather", "vignette_midpoint", "vignette_roundness": return num("vignette_amount") != 0
            case "halation_radius": return num("halation_amount") > 0
            case "bloom_threshold", "bloom_radius": return num("bloom_amount") > 0
            default: return !isDefault(k)
            }
        }
    }
}

// MARK: - Slider fields

struct SliderSpec {
    let key: String
    let label: String
    let icon: String
    let min: Double
    let max: Double
    let dp: Int
    var unit = ""
    /// Taper: >1 gives finer control near zero (the web app's `curve`).
    var taper: Double = 1
    var isInt = false

    var def: Double { Recipe.defaults[key]?.double ?? 0 }

    func value(at pos: Double) -> Double {
        let v: Double
        if taper == 1 { v = pos } else {
            let a = Swift.max(abs(min), abs(max))
            let t = pos / a
            v = (t < 0 ? -1 : 1) * pow(abs(t), taper) * a
        }
        let p = pow(10, Double(dp))
        return isInt ? (v / 50).rounded() * 50 : (v * p).rounded() / p
    }

    func pos(of v: Double) -> Double {
        if taper == 1 { return v }
        let a = Swift.max(abs(min), abs(max))
        let t = v / a
        return (t < 0 ? -1 : 1) * pow(abs(t), 1 / taper) * a
    }

    func text(_ v: Double) -> String {
        if isInt { return "\(Int(v))\(unit)" }
        let s = String(format: "%.\(dp)f", v)
        let signed = min < 0 && v > 0 ? "+" + s : s
        return signed + unit
    }

    /// 0…1 for the ring on the tool button.
    func magnitude(_ v: Double) -> Double {
        let span = v >= def ? max - def : def - min
        return span > 0 ? Swift.min(1, abs(v - def) / span) : 0
    }

    static let all: [String: SliderSpec] = Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0) })

    static let list: [SliderSpec] = [
        SliderSpec(key: "exposure", label: "Exposure", icon: "plusminus.circle", min: -5, max: 5, dp: 2, unit: " EV", taper: 2),
        SliderSpec(key: "brightness", label: "Brightness", icon: "sun.max", min: -1, max: 1, dp: 2, taper: 1.5),
        SliderSpec(key: "highlights", label: "Highlights", icon: "circle.tophalf.filled", min: -1, max: 1, dp: 2, taper: 1.5),
        SliderSpec(key: "shadows", label: "Shadows", icon: "circle.bottomhalf.filled", min: -1, max: 1, dp: 2, taper: 1.5),
        SliderSpec(key: "whites", label: "Whites", icon: "circle", min: -1, max: 1, dp: 2, taper: 1.5),
        SliderSpec(key: "blacks", label: "Blacks", icon: "circle.fill", min: -1, max: 1, dp: 2, taper: 1.5),
        SliderSpec(key: "contrast", label: "Contrast", icon: "circle.lefthalf.filled", min: -1, max: 1, dp: 2, taper: 1.5),
        SliderSpec(key: "wb_temp", label: "Warmth", icon: "thermometer.medium", min: 2500, max: 9500, dp: 0, unit: " K", isInt: true),
        SliderSpec(key: "wb_tint", label: "Tint", icon: "eyedropper.halffull", min: -1, max: 1, dp: 2, taper: 1.5),
        SliderSpec(key: "saturation", label: "Saturation", icon: "drop.fill", min: -1, max: 1, dp: 2, taper: 1.5),
        SliderSpec(key: "vibrance", label: "Vibrance", icon: "sparkles", min: -1, max: 1, dp: 2, taper: 1.5),
        SliderSpec(key: "bw_amount", label: "Black & white", icon: "circle.righthalf.filled", min: 0, max: 1, dp: 2),
        SliderSpec(key: "dehaze", label: "Dehaze", icon: "aqi.medium", min: -1, max: 1, dp: 2, taper: 1.5),
        SliderSpec(key: "sharpening", label: "Sharpen", icon: "triangle", min: 0, max: 1, dp: 2),
        SliderSpec(key: "vignette_amount", label: "Vignette", icon: "circle.dashed", min: -1, max: 1, dp: 2),
        SliderSpec(key: "vignette_feather", label: "Vignette feather", icon: "circle.dotted", min: 0, max: 1, dp: 2),
        SliderSpec(key: "vignette_midpoint", label: "Vignette size", icon: "smallcircle.filled.circle", min: 0, max: 1, dp: 2),
        SliderSpec(key: "vignette_roundness", label: "Vignette roundness", icon: "oval", min: 0, max: 1, dp: 2),
        SliderSpec(key: "matte", label: "Matte", icon: "square.on.square", min: 0, max: 1, dp: 2),
        SliderSpec(key: "split_shadow_sat", label: "Split shadows", icon: "moon", min: 0, max: 1, dp: 2),
        SliderSpec(key: "split_highlight_sat", label: "Split highlights", icon: "sun.min", min: 0, max: 1, dp: 2),
        SliderSpec(key: "split_balance", label: "Split balance", icon: "scalemass", min: -1, max: 1, dp: 2),
        SliderSpec(key: "halation_amount", label: "Halation", icon: "light.max", min: 0, max: 1, dp: 2),
        SliderSpec(key: "halation_radius", label: "Halation size", icon: "circle.circle", min: 0, max: 1, dp: 2),
        SliderSpec(key: "bloom_amount", label: "Bloom", icon: "sun.dust", min: 0, max: 1, dp: 2),
        SliderSpec(key: "bloom_threshold", label: "Bloom threshold", icon: "sun.horizon", min: 0, max: 1, dp: 2),
        SliderSpec(key: "bloom_radius", label: "Bloom size", icon: "circle.hexagongrid", min: 0, max: 1, dp: 2),
        SliderSpec(key: "grain_amount", label: "Grain", icon: "circle.grid.3x3", min: 0, max: 1, dp: 2),
        SliderSpec(key: "grain_size", label: "Grain size", icon: "circle.grid.2x2", min: 0.5, max: 4, dp: 1, unit: " px"),
        SliderSpec(key: "grain_roughness", label: "Grain color", icon: "circle.grid.3x3.fill", min: 0, max: 1, dp: 2),
        SliderSpec(key: "light_leak_amount", label: "Leak amount", icon: "flame", min: 0, max: 1, dp: 2),
    ]
}

/// The eight hue bands the server's colour mix and B&W mixer use.
enum HueBand: Int, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: Int { rawValue }
    var name: String { ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"][rawValue] }
    var rgb: (Double, Double, Double) {
        [(0.80, 0.20, 0.20), (0.88, 0.55, 0.10), (0.90, 0.81, 0.16), (0.24, 0.62, 0.24),
         (0.15, 0.66, 0.63), (0.18, 0.42, 0.69), (0.49, 0.31, 0.72), (0.77, 0.24, 0.54)][rawValue]
    }
}

/// Hex "#rrggbb" ↔ components, for split toning.
enum Hex {
    static func rgb(_ s: String?) -> (Double, Double, Double) {
        var h = (s ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return (0.5, 0.5, 0.5) }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }

    static func string(_ r: Double, _ g: Double, _ b: Double) -> String {
        func c(_ x: Double) -> Int { Int((Swift.max(0, Swift.min(1, x)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
    }
}
