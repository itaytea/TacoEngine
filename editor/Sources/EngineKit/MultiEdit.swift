import Foundation

/// Editing several entities at once: the Inspector shows what they have in common and copies each change
/// to all of them, leaving values that weren't touched as they were on each entity.
extension EntityDef {
    /// The components every def has, with the values of the first one. Scripts are matched by name.
    public static func shared(_ defs: [EntityDef]) -> EntityDef {
        guard var out = defs.first else { return EntityDef() }
        let rest = defs.dropFirst()
        if rest.contains(where: { $0.sprite == nil }) { out.sprite = nil }
        if rest.contains(where: { $0.collider == nil }) { out.collider = nil }
        if rest.contains(where: { $0.platformer == nil }) { out.platformer = nil }
        out.scripts = out.scripts.filter { s in rest.allSatisfy { d in d.scripts.contains { $0.script == s.script } } }
        return out
    }

    /// Key paths (in prefab-override form: "sprite.animation", "scripts.@Name.fields.speed") whose values
    /// differ between the defs, among the components they share. `defaults` gives a script field's value
    /// when an entity doesn't store one.
    public static func mixed(_ defs: [EntityDef], defaults: (String, String) -> JSON? = { _, _ in nil }) -> JSON? {
        guard defs.count > 1 else { return nil }
        let shared = shared(defs)
        var out: [String: JSON] = [:]
        func mark(_ path: [String]) {
            func put(_ o: inout [String: JSON], _ p: ArraySlice<String>) {
                guard let k = p.first else { return }
                if p.count == 1 { o[k] = .bool(true); return }
                var child = o[k]?.object ?? [:]
                put(&child, p.dropFirst())
                o[k] = .object(child)
            }
            put(&out, path[...])
        }
        func component<T: Encodable>(_ name: String, _ get: (EntityDef) -> T?) {
            let objects = defs.compactMap { get($0).map { JSON.from($0).object ?? [:] } }
            guard objects.count == defs.count else { return }
            for k in Set(objects.flatMap(\.keys)) where Set(objects.map { $0[k] ?? .null }).count > 1 { mark([name, k]) }
        }
        if Set(defs.map(\.tag)).count > 1 { mark(["tag"]) }
        component("sprite", \.sprite)
        component("collider", \.collider)
        component("platformer", \.platformer)
        for s in shared.scripts {
            let fields = defs.compactMap { d in d.scripts.first { $0.script == s.script }?.fields }
            for k in Set(fields.flatMap(\.keys)) where Set(fields.map { $0[k] ?? defaults(s.script, k) ?? .null }).count > 1 {
                mark(["scripts", "@" + s.script, "fields", k])
            }
        }
        return out.isEmpty ? nil : .object(out)
    }

    /// This def with the change from `old` to `new` (both `shared` views) applied: added components are
    /// added where missing, removed ones removed, and only the values that changed are copied.
    public func applyingEdit(from old: EntityDef, to new: EntityDef) -> EntityDef {
        var d = self
        if new.tag != old.tag { d.tag = new.tag }
        d.sprite = Self.patch(d.sprite, old.sprite, new.sprite)
        d.collider = Self.patch(d.collider, old.collider, new.collider)
        d.platformer = Self.patch(d.platformer, old.platformer, new.platformer)
        for s in old.scripts where !new.scripts.contains(where: { $0.script == s.script }) {
            d.scripts.removeAll { $0.script == s.script }
        }
        for s in new.scripts {
            guard let before = old.scripts.first(where: { $0.script == s.script }) else {
                if !d.scripts.contains(where: { $0.script == s.script }) { d.scripts.append(s) }
                continue
            }
            guard let i = d.scripts.firstIndex(where: { $0.script == s.script }) else { continue }
            for k in Set(before.fields.keys).union(s.fields.keys) where before.fields[k] != s.fields[k] {
                d.scripts[i].fields[k] = s.fields[k]
            }
        }
        return d
    }

    /// One component: added, removed, or the fields that changed copied over
    static func patch<T: Codable>(_ mine: T?, _ old: T?, _ new: T?) -> T? {
        guard let new else { return old == nil ? mine : nil }
        guard let old, let mine else { return mine ?? new }
        let o = JSON.from(old).object ?? [:], n = JSON.from(new).object ?? [:]
        var m = JSON.from(mine).object ?? [:]
        for k in Set(o.keys).union(n.keys) where o[k] != n[k] { m[k] = n[k] }
        return JSON.object(m).decode(T.self) ?? mine
    }
}
