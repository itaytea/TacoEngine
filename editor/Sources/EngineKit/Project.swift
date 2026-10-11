import Foundation

/// An asset together with where it lives (path relative to the project root).
public struct Stored<T: Equatable & Sendable>: Equatable, Sendable {
    public var path: String
    public var value: T
    public var name: String { assetName(URL(fileURLWithPath: path)) }
    public init(path: String, value: T) { self.path = path; self.value = value }
}

/// The whole project in memory. A value type, so undo is just keeping old copies.
public struct GameProject: Equatable, Sendable {
    public var root: URL
    public var settings: ProjectSettings
    public var sprites: [UUID: Stored<SpriteAsset>] = [:]
    public var tilesets: [UUID: Stored<TilesetAsset>] = [:]
    public var prefabs: [UUID: Stored<PrefabAsset>] = [:]
    public var scenes: [UUID: Stored<SceneAsset>] = [:]
    public var platformers: [UUID: Stored<PlatformerSettings>] = [:]
    public var dialogues: [UUID: Stored<DialogueAsset>] = [:]
    public var speakers: [UUID: Stored<SpeakerAsset>] = [:]
    public var textboxes: [UUID: Stored<TextBoxStyleAsset>] = [:]
    public var fonts: [UUID: Stored<FontAsset>] = [:]
    public var scripts: [ScriptInfo] = []

    public static let settingsFile = "project.json"
    public var assetsDir: URL { root.appendingPathComponent("assets") }
    public var scriptsDir: URL { root.appendingPathComponent("scripts") }
    public var buildDir: URL { root.appendingPathComponent("build") }

    public init(root: URL, settings: ProjectSettings) {
        self.root = root
        self.settings = settings
    }

    // MARK: Loading

    public static func isProject(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(settingsFile).path)
    }

    public static func load(_ root: URL) throws -> GameProject {
        let data = try Data(contentsOf: root.appendingPathComponent(settingsFile))
        var p = GameProject(root: root, settings: try JSONDecoder().decode(ProjectSettings.self, from: data))
        let dec = JSONDecoder()
        for url in p.assetFiles() {
            guard let kind = AssetKind.of(url), let d = try? Data(contentsOf: url) else { continue }
            let rel = p.relative(url)
            switch kind {
            case .sprite: if let a = try? dec.decode(SpriteAsset.self, from: d) { p.sprites[a.guid] = Stored(path: rel, value: a) }
            case .tileset: if let a = try? dec.decode(TilesetAsset.self, from: d) { p.tilesets[a.guid] = Stored(path: rel, value: a) }
            case .prefab: if let a = try? dec.decode(PrefabAsset.self, from: d) { p.prefabs[a.guid] = Stored(path: rel, value: a) }
            case .scene: if let a = try? dec.decode(SceneAsset.self, from: d) { p.scenes[a.guid] = Stored(path: rel, value: a) }
            case .platformer: if let a = try? dec.decode(PlatformerSettings.self, from: d) { p.platformers[a.guid] = Stored(path: rel, value: a) }
            case .dialogue: if let a = try? dec.decode(DialogueAsset.self, from: d) { p.dialogues[a.guid] = Stored(path: rel, value: a) }
            case .speaker: if let a = try? dec.decode(SpeakerAsset.self, from: d) { p.speakers[a.guid] = Stored(path: rel, value: a) }
            case .textbox: if let a = try? dec.decode(TextBoxStyleAsset.self, from: d) { p.textboxes[a.guid] = Stored(path: rel, value: a) }
            case .font: if let a = try? dec.decode(FontAsset.self, from: d) { p.fonts[a.guid] = Stored(path: rel, value: a) }
            }
        }
        p.reloadScripts()
        // Keep the build order in sync with the scenes on disk
        p.settings.scenes = p.settings.scenes.filter { p.scenes[$0] != nil }
        for id in p.scenes.keys.sorted(by: { p.scenes[$0]!.path < p.scenes[$1]!.path }) where !p.settings.scenes.contains(id) {
            p.settings.scenes.append(id)
        }
        return p
    }

    public mutating func reloadScripts() {
        scripts = scriptFiles().flatMap { ScriptParser.parse(file: $0) }
    }

    /// All .c files under scripts/ and assets/ (any folder depth), sorted
    public func scriptFiles() -> [URL] {
        [scriptsDir, assetsDir].flatMap { GameProject.files(in: $0, ext: "c") }.sorted { $0.path < $1.path }
    }

    public static func files(in dir: URL, ext: String) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == ext }
    }

    public static let imageExtensions: Set<String> = ["png", "gif", "jpg", "jpeg", "bmp"]
    public static let audioExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "mp3", "m4a", "aac", "caf", "flac"]

    /// Every audio file under assets/ is a sound, named after its file (the first one wins if two share a name)
    public func sounds() -> [(name: String, path: String)] {
        guard let e = FileManager.default.enumerator(at: assetsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var seen = Set<String>(), out: [(name: String, path: String)] = []
        for case let u as URL in e where GameProject.audioExtensions.contains(u.pathExtension.lowercased()) {
            let rel = relative(u)
            let name = u.deletingPathExtension().lastPathComponent
            out.append((name, rel))
        }
        out.sort { $0.path < $1.path }
        return out.filter { seen.insert($0.name).inserted }
    }

    /// Images under assets/ that no sprite or tileset uses yet (relative paths) — e.g. files dropped in from Finder
    public func looseImages() -> [String] {
        let used = Set((sprites.values.map { imageURL(assetPath: $0.path, image: $0.value.image) }
                        + tilesets.values.map { imageURL(assetPath: $0.path, image: $0.value.image) }
                        + fonts.values.map { imageURL(assetPath: $0.path, image: $0.value.image) }
                        + textboxes.values.compactMap { s in s.value.frameImage.map { imageURL(assetPath: s.path, image: $0) } })
                        .map { $0.standardizedFileURL.path })
        guard let e = FileManager.default.enumerator(at: assetsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { GameProject.imageExtensions.contains($0.pathExtension.lowercased()) && !used.contains($0.standardizedFileURL.path) }
            .map { relative($0) }
            .sorted()
    }

    /// Folders under assets/ and scripts/ (relative paths, including the two roots), sorted
    public func folders() -> [String] {
        var out = ["assets", "scripts"]
        for dir in [assetsDir, scriptsDir] {
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                out.append(relative(u))
            }
        }
        return out.sorted()
    }

    func assetFiles() -> [URL] {
        guard let e = FileManager.default.enumerator(at: assetsDir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { AssetKind.of($0) != nil }
    }

    public func relative(_ url: URL) -> String {
        let r = root.standardizedFileURL.path, p = url.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    public func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    /// Image path of an asset (stored relative to the asset's JSON file)
    public func imageURL(assetPath: String, image: String) -> URL {
        url(assetPath).deletingLastPathComponent().appendingPathComponent(image)
    }

    // MARK: Saving

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public func saveSettings() throws {
        try GameProject.encoder.encode(settings).write(to: root.appendingPathComponent(GameProject.settingsFile), options: .atomic)
    }

    public func save<T: Encodable>(_ value: T, path: String) throws {
        let u = url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try GameProject.encoder.encode(value).write(to: u, options: .atomic)
    }

    /// Write every asset that differs from `old` (or everything when old is nil). Deletes removed assets.
    public func saveChanges(since old: GameProject?) throws {
        if old?.settings != settings { try saveSettings() }
        func sync<T: Codable & Equatable & Sendable>(_ mine: [UUID: Stored<T>], _ theirs: [UUID: Stored<T>]?) throws {
            for (id, s) in mine where theirs?[id] != s {
                if let prev = theirs?[id], prev.path != s.path { try? FileManager.default.removeItem(at: url(prev.path)) }
                try save(s.value, path: s.path)
            }
            for (id, s) in theirs ?? [:] where mine[id] == nil { try? FileManager.default.removeItem(at: url(s.path)) }
        }
        try sync(sprites, old?.sprites)
        try sync(tilesets, old?.tilesets)
        try sync(prefabs, old?.prefabs)
        try sync(scenes, old?.scenes)
        try sync(platformers, old?.platformers)
        try sync(dialogues, old?.dialogues)
        try sync(speakers, old?.speakers)
        try sync(textboxes, old?.textboxes)
        try sync(fonts, old?.fonts)
    }

    // MARK: Lookups

    public func name(of id: UUID?) -> String? {
        guard let id else { return nil }
        return path(of: id).map { assetName(URL(fileURLWithPath: $0)) }
    }

    /// Path (relative) of any asset by id
    public func path(of id: UUID) -> String? {
        let candidates: [String?] = [sprites[id]?.path, tilesets[id]?.path, prefabs[id]?.path, scenes[id]?.path, platformers[id]?.path,
                                     dialogues[id]?.path, speakers[id]?.path, textboxes[id]?.path, fonts[id]?.path]
        return candidates.compactMap { $0 }.first
    }

    public func script(_ name: String) -> ScriptInfo? { scripts.first { $0.name == name } }

    public func sceneIndex(_ id: UUID?) -> Int? { id.flatMap { settings.scenes.firstIndex(of: $0) } }

    /// Finds an asset by name, for script default values like `// = Bullet`
    public func asset(named name: String) -> UUID? {
        for (id, s) in prefabs where s.name == name { return id }
        for (id, s) in scenes where s.name == name { return id }
        for (id, s) in sprites where s.name == name { return id }
        for (id, s) in dialogues where s.name == name { return id }
        return nil
    }

    /// The entity's components after applying prefab overrides
    public func effectiveDef(_ e: SceneEntity) -> EntityDef {
        if let pid = e.prefab, let prefab = prefabs[pid]?.value.def {
            guard let o = e.overrides else { return prefab }
            return JSON.from(prefab).merged(with: o).decode(EntityDef.self) ?? prefab
        }
        return e.def ?? EntityDef()
    }

    /// Store a new effective def on an entity (as overrides when it's a prefab instance)
    public func applying(_ def: EntityDef, to e: SceneEntity) -> SceneEntity {
        var e = e
        if let pid = e.prefab, let prefab = prefabs[pid]?.value.def {
            e.overrides = JSON.from(def).diff(from: JSON.from(prefab))
        } else {
            e.def = def
        }
        return e
    }

    public func uniquePath(_ dir: String, _ base: String, _ suffix: String) -> String {
        var n = 0
        while true {
            let candidate = "\(dir)/\(base)\(n == 0 ? "" : " \(n)")\(suffix)"
            if !FileManager.default.fileExists(atPath: url(candidate).path) &&
                !allPaths.contains(candidate) { return candidate }
            n += 1
        }
    }

    var allPaths: Set<String> {
        Set(sprites.values.map(\.path) + tilesets.values.map(\.path) + prefabs.values.map(\.path)
            + scenes.values.map(\.path) + platformers.values.map(\.path) + dialogues.values.map(\.path)
            + speakers.values.map(\.path) + textboxes.values.map(\.path) + fonts.values.map(\.path))
    }
}
