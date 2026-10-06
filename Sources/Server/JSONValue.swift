import Foundation

/// Lossless JSON for things the app only partly understands (edit recipes):
/// fields the phone has no control for travel back to the server untouched.
enum JSONValue: Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Whole numbers go out as integers so pydantic `int` fields accept them.
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var double: Double? { if case .number(let n) = self { return n }; if case .bool(let b) = self { return b ? 1 : 0 }; return nil }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    subscript(key: String) -> JSONValue? {
        get { object?[key] }
        set {
            var o = object ?? [:]
            o[key] = newValue
            self = .object(o)
        }
    }
}

extension JSONValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(integerLiteral v: Int) { self = .number(Double(v)) }
    init(floatLiteral v: Double) { self = .number(v) }
    init(stringLiteral v: String) { self = .string(v) }
    init(booleanLiteral v: Bool) { self = .bool(v) }
    init(arrayLiteral v: JSONValue...) { self = .array(v) }
    init(dictionaryLiteral v: (String, JSONValue)...) { self = .object(Dictionary(v, uniquingKeysWith: { _, b in b })) }
}

extension JSONValue {
    /// Compact JSON text (for clipboard storage and query parameters).
    var data: Data { (try? JSONEncoder().encode(self)) ?? Data("null".utf8) }
    static func decode(_ d: Data) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: d) }
}
