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
    public var warnings: [String] = [] // body lines that look like field declarations but did not parse
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
            guard let close = matchingBrace(code as NSString, from: open) else { continue }
            let body = ns.substring(with: NSRange(location: open, length: close - open))
            let line = ns.substring(to: m.range.location).components(separatedBy: "\n").count
            let parsed = parseFieldsWithWarnings(body)
            result.append(ScriptInfo(name: name, file: file, line: line, body: body,
                                     fields: parsed.fields, callbacks: callbacks(in: code, name: name),
                                     warnings: parsed.warnings))
        }
        return result
    }

    /// `s` must already have comments blanked out (see withoutComments)
    static func matchingBrace(_ s: NSString, from start: Int) -> Int? {
        var depth = 1, i = start
        while i < s.length {
            let c = s.character(at: i)
            if c == 123 { depth += 1 }
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

    /// First declarator of a line: shared type, optional pointer stars, name, optional array suffix, optional initializer
    static let firstDeclRegex = try! NSRegularExpression(
        pattern: #"^\s*((?:const\s+)?[A-Za-z_]\w*(?:\s+[A-Za-z_]\w*)*?)\s*(\*+)?\s*([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*(?:=.*)?$"#)
    /// Further declarators after a top-level comma: `*p`, `b`, `arr[4]`, `c = 3`
    static let nextDeclRegex = try! NSRegularExpression(
        pattern: #"^\s*(\*+)?\s*([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*(?:=.*)?$"#)
    /// Something that looks like `type name ...;` (used to warn when it does not parse)
    static let declLikeRegex = try! NSRegularExpression(pattern: #"^\s*[A-Za-z_]\w*[\s*].*;\s*$"#)

    /// Splits on commas that are not inside (), {} or []
    static func splitTopLevel(_ s: String) -> [String] {
        var parts: [String] = [], cur = "", depth = 0
        for ch in s {
            if "({[".contains(ch) { depth += 1 }
            else if ")}]".contains(ch) { depth -= 1 }
            if ch == "," && depth == 0 { parts.append(cur); cur = "" } else { cur.append(ch) }
        }
        parts.append(cur)
        return parts
    }

    static func parseFields(_ body: String) -> [ScriptField] {
        parseFieldsWithWarnings(body).fields
    }

    static func parseFieldsWithWarnings(_ body: String) -> (fields: [ScriptField], warnings: [String]) {
        var fields: [ScriptField] = []
        var warnings: [String] = []
        for raw in body.components(separatedBy: "\n") {
            var codePart = raw
            var rawComment: String?
            if let r = raw.range(of: "//") {
                codePart = String(raw[..<r.lowerBound])
                rawComment = String(raw[r.upperBound...])
            }
            codePart = codePart.trimmingCharacters(in: .whitespaces)
            guard !codePart.isEmpty else { continue }
            let lineText = raw.trimmingCharacters(in: .whitespaces)
            guard codePart.hasSuffix(";") else { continue }
            let declarators = splitTopLevel(String(codePart.dropLast()))
            func whole(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

            // (name, pointer, array) for every declarator, or nil if the line does not parse
            var parsed: [(name: String, pointer: Bool, array: Bool)] = []
            var ctype = ""
            if let m = firstDeclRegex.firstMatch(in: declarators[0], range: whole(declarators[0])) {
                let ns = declarators[0] as NSString
                ctype = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                parsed.append((ns.substring(with: m.range(at: 3)), m.range(at: 2).location != NSNotFound, m.range(at: 4).location != NSNotFound))
                for d in declarators.dropFirst() {
                    guard let n = nextDeclRegex.firstMatch(in: d, range: whole(d)) else { parsed = []; break }
                    let nns = d as NSString
                    parsed.append((nns.substring(with: n.range(at: 2)), n.range(at: 1).location != NSNotFound, n.range(at: 3).location != NSNotFound))
                }
            }
            if parsed.isEmpty {
                if declLikeRegex.firstMatch(in: codePart, range: whole(codePart)) != nil {
                    warnings.append("Could not parse field declaration: \(lineText)")
                }
                continue
            }
            for (name, pointer, array) in parsed {
                var comment = rawComment?.trimmingCharacters(in: .whitespaces) ?? ""
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
        }
        return (fields, warnings)
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
