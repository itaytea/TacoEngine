import Foundation

/// A field of a script's SCRIPT(...) block, as shown in the Inspector.
public struct ScriptField: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case int, fixed, bool, entity, scene, prefab, sprite, dialogue, sound
        case hidden          // internal state: pointers, arrays, unknown types, or marked @hide
    }
    public var name: String
    public var ctype: String
    public var kind: Kind
    public var defaultValue: JSON?
    public var help: String
    public var id: String { name }
}

public struct ScriptInfo: Equatable, Sendable, Identifiable {
    public var name: String           // C identifier used in SCRIPT(Name)
    public var file: URL
    public var line: Int              // line of SCRIPT(...)
    public var body: String           // raw field declarations
    public var fields: [ScriptField]
    public var callbacks: Set<String> // Start, Update, OnTrigger, OnTriggerExit, OnMessage, OnDestroy
    public var id: String { name }

    public static let callbackNames = ["Start", "Update", "OnTrigger", "OnTriggerExit", "OnMessage", "OnDestroy"]

    /// Default value for a field when a script is first attached
    public func defaultFields() -> [String: JSON] {
        var out: [String: JSON] = [:]
        for f in fields where f.kind != .hidden { if let d = f.defaultValue { out[f.name] = d } }
        return out
    }
}

public enum ScriptParser {
    public static func parse(file: URL) -> [ScriptInfo] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return parse(text, file: file)
    }

    /// The text with comments blanked out (same length, so offsets still line up)
    static func withoutComments(_ text: String) -> String {
        var out = Array(text.utf16)
        var i = 0
        while i < out.count {
            if out[i] == 47, i + 1 < out.count, out[i + 1] == 47 {          // //
                while i < out.count && out[i] != 10 { out[i] = 32; i += 1 }
            } else if out[i] == 47, i + 1 < out.count, out[i + 1] == 42 {   // /* */
                while i < out.count && !(out[i] == 42 && i + 1 < out.count && out[i + 1] == 47) { if out[i] != 10 { out[i] = 32 }; i += 1 }
                if i + 1 < out.count { out[i] = 32; out[i + 1] = 32; i += 2 }
            } else if out[i] == 34 {                                         // "string" (may contain //)
                i += 1
                while i < out.count && out[i] != 34 && out[i] != 10 { if out[i] == 92 { i += 1 }; i += 1 }
                i += 1
            } else {
                i += 1
            }
        }
        return String(utf16CodeUnits: out, count: out.count)
    }

    public static func parse(_ text: String, file: URL) -> [ScriptInfo] {
        var result: [ScriptInfo] = []
        let ns = text as NSString
        let code = withoutComments(text)    // so commented-out SCRIPT(...) or callbacks don't count
        let decl = try! NSRegularExpression(pattern: #"SCRIPT\s*\(\s*([A-Za-z_]\w*)\s*\)\s*\{"#)
        for m in decl.matches(in: code, range: NSRange(location: 0, length: (code as NSString).length)) {
            let name = ns.substring(with: m.range(at: 1))
            let open = m.range.location + m.range.length   // just after '{'
            guard let close = matchingBrace(ns, from: open) else { continue }
            let body = ns.substring(with: NSRange(location: open, length: close - open))
            let line = ns.substring(to: m.range.location).components(separatedBy: "\n").count
            result.append(ScriptInfo(name: name, file: file, line: line, body: body,
                                     fields: parseFields(body), callbacks: callbacks(in: code, name: name)))
        }
        return result
    }

    static func matchingBrace(_ s: NSString, from start: Int) -> Int? {
        var depth = 1, i = start
        var inLineComment = false, inBlockComment = false
        while i < s.length {
            let c = s.character(at: i)
            let next: unichar = i + 1 < s.length ? s.character(at: i + 1) : 0
            if inLineComment { if c == 10 { inLineComment = false } }
            else if inBlockComment { if c == 42 && next == 47 { inBlockComment = false; i += 1 } }
            else if c == 47 && next == 47 { inLineComment = true; i += 1 }
            else if c == 47 && next == 42 { inBlockComment = true; i += 1 }
            else if c == 123 { depth += 1 }
            else if c == 125 { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    static func callbacks(in text: String, name: String) -> Set<String> {
        var found: Set<String> = []
        for cb in ScriptInfo.callbackNames {
            let pattern = #"\bvoid\s+"# + NSRegularExpression.escapedPattern(for: "\(name)_\(cb)") + #"\s*\("#
            if text.range(of: pattern, options: .regularExpression) != nil { found.insert(cb) }
        }
        return found
    }

    static let fieldRegex = try! NSRegularExpression(
        pattern: #"^\s*((?:const\s+)?[A-Za-z_][\w]*(?:\s+[A-Za-z_]\w*)*?)\s*(\*+)?\s*([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*;\s*(?://(.*))?$"#)

    static func parseFields(_ body: String) -> [ScriptField] {
        var fields: [ScriptField] = []
        for raw in body.components(separatedBy: "\n") {
            let ns = raw as NSString
            guard let m = fieldRegex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }
            let ctype = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let pointer = m.range(at: 2).location != NSNotFound
            let name = ns.substring(with: m.range(at: 3))
            let array = m.range(at: 4).location != NSNotFound
            var comment = m.range(at: 5).location != NSNotFound ? ns.substring(with: m.range(at: 5)).trimmingCharacters(in: .whitespaces) : ""
            var kind = (pointer || array) ? .hidden : kindOf(ctype)
            if comment.contains("@hide") {
                kind = .hidden
                comment = comment.replacingOccurrences(of: "@hide", with: "").trimmingCharacters(in: .whitespaces)
            }
            // "// = 5  Help text" sets the default value; quote names with spaces: // = "Cloud Icon"
            var def: JSON?
            if comment.hasPrefix("=") {
                let rest = comment.dropFirst().trimmingCharacters(in: .whitespaces)
                var token = String(rest.prefix { !$0.isWhitespace })
                var used = token.count
                if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") {
                    token = String(rest[rest.index(after: rest.startIndex)..<end])
                    used = rest.distance(from: rest.startIndex, to: end) + 1
                }
                comment = String(rest.dropFirst(used)).trimmingCharacters(in: .whitespaces)
                switch kind {
                case .int, .fixed: if let d = Double(token) { def = .number(d) }
                case .bool: def = .bool(token == "true" || token == "1")
                case .scene, .prefab, .sprite, .dialogue, .sound: def = .string(token)   // resolved by name
                default: break
                }
            }
            fields.append(ScriptField(name: name, ctype: ctype, kind: kind, defaultValue: def, help: comment))
        }
        return fields
    }

    static func kindOf(_ ctype: String) -> ScriptField.Kind {
        let t = ctype.replacingOccurrences(of: "const ", with: "")
        switch t {
        case "fixed": return .fixed
        case "bool": return .bool
        case "EntityRef": return .entity
        case "SceneRef": return .scene
        case "PrefabRef": return .prefab
        case "SpriteRef": return .sprite
        case "DialogueRef": return .dialogue
        case "SoundRef": return .sound
        case "int", "s8", "s16", "s32", "u8", "u16", "u32", "short", "long", "char", "unsigned", "unsigned int",
             "signed int", "unsigned char", "unsigned short", "signed char":
            return .int
        default: return .hidden
        }
    }
}
