import Foundation

/// Untyped JSON, used for prefab overrides (deep merge / deep diff) and script field values.
public enum JSON: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var number: Double? { if case .number(let n) = self { return n }; if case .bool(let b) = self { return b ? 1 : 0 }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; if case .number(let n) = self { return n != 0 }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }

    /// Names of an array of script components ({"script": name, ...}), if every element has a distinct one.
    /// Such arrays are patched by name ("@Name"), so reordering or removing scripts in a prefab can't move
    /// an instance's values onto a different script.
    static func scriptNames(_ a: [JSON]) -> [String]? {
        let names = a.compactMap { $0.object?["script"]?.string }
        guard !names.isEmpty, names.count == a.count, Set(names).count == names.count else { return nil }
        return names
    }

    /// Apply `patch` on top of self. Objects merge recursively; an object patch on an array patches by
    /// script name ("@Name") or by index (numeric keys, from older projects).
    public func merged(with patch: JSON) -> JSON {
        switch (self, patch) {
        case (.object(var base), .object(let p)):
            for (k, v) in p { base[k] = (base[k] ?? .null).merged(with: v) }
            return .object(base)
        case (.array(var base), .object(let p)):
            let names = JSON.scriptNames(base)
            for (k, v) in p {
                if k.hasPrefix("@") {
                    if let i = names?.firstIndex(of: String(k.dropFirst())) { base[i] = base[i].merged(with: v) }
                } else if let i = Int(k), i >= 0, i < base.count {
                    base[i] = base[i].merged(with: v)
                }
            }
            return .array(base)
        default:
            return patch
        }
    }

    /// The smallest patch that turns `base` into self (nil = identical).
    public func diff(from base: JSON) -> JSON? {
        if self == base { return nil }
        switch (self, base) {
        case (.object(let mine), .object(let theirs)):
            var out: [String: JSON] = [:]
            for (k, v) in mine {
                if let b = theirs[k] { if let d = v.diff(from: b) { out[k] = d } } else { out[k] = v }
            }
            return out.isEmpty ? nil : .object(out)
        case (.array(let mine), .array(let theirs)):
            if let a = JSON.scriptNames(mine), let b = JSON.scriptNames(theirs), Set(a) == Set(b) {
                var out: [String: JSON] = [:]
                for (i, name) in a.enumerated() {
                    if let d = mine[i].diff(from: theirs[b.firstIndex(of: name)!]) { out["@" + name] = d }
                }
                // Same scripts in a different order: the instance's order has to be kept as a whole
                if a != b { return self }
                return out.isEmpty ? nil : .object(out)
            }
            guard mine.count == theirs.count else { return self }
            var out: [String: JSON] = [:]
            for i in mine.indices { if let d = mine[i].diff(from: theirs[i]) { out[String(i)] = d } }
            return out.isEmpty ? nil : .object(out)
        default:
            return self
        }
    }

    /// Whether a dotted key path (e.g. "components.collider.w") is present in this patch.
    public func contains(path: [String]) -> Bool {
        guard let first = path.first else { return true }
        switch self {
        case .object(let o): return o[first]?.contains(path: Array(path.dropFirst())) ?? false
        default: return false
        }
    }

    /// Remove a key path from this patch (used by "Revert").
    public func removing(path: [String]) -> JSON? {
        guard let first = path.first, case .object(var o) = self else { return nil }
        if path.count == 1 { o[first] = nil }
        else if let child = o[first] { o[first] = child.removing(path: Array(path.dropFirst())) }
        return o.isEmpty ? nil : .object(o)
    }
}

extension JSON {
    /// Encode any Codable value to JSON
    public static func from<T: Encodable>(_ value: T) -> JSON {
        let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
        return (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
