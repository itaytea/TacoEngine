import AppKit
import EngineKit
import SwiftUI

enum Selection: Equatable {
    case none
    case file(String)          // a loose file (e.g. an image not yet used as a sprite), relative path
    case entity(UUID)
    case asset(UUID)
    case script(String)
    case projectSettings
}

enum CenterTab: Equatable {
    case scene
    case asset(UUID)       // sprite / tileset / platformer editor
}

enum SceneTool: String, CaseIterable {
    case select = "Move"
    case paint = "Paint"
    case rect = "Rectangle"
    case fill = "Fill"
    case erase = "Erase"
    var icon: String {
        switch self {
        case .select: "arrow.up.and.down.and.arrow.left.and.right"
        case .paint: "paintbrush.pointed"
        case .rect: "rectangle.inset.filled"
        case .fill: "drop.fill"
        case .erase: "eraser"
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var project: GameProject? {
        didSet {
            defCache.removeAll()
            if !loading { scheduleSave() }
        }
    }
    @Published var openScene: UUID?
    @Published var selection: Selection = .none {
        didSet {   // keep the multi-selection in step when something selects one entity (or something else)
            if case .entity(let id) = selection { if !entitySelection.contains(id) { entitySelection = [id] } }
            else if !entitySelection.isEmpty { entitySelection = [] }
        }
    }
    /// Multi-selection: entities in the open scene (the Inspector shows `selection`, the last one picked)
    @Published var entitySelection: Set<UUID> = []
    /// Multi-selection in the Project panel (item ids: asset UUIDs, "script:Name", "file:path", "folder:path")
    @Published var projectSelection: Set<String> = []
    var projectAnchor: String?
    var entityAnchor: UUID?
    /// Where the last click was, so Delete / Copy / Paste know what they act on
    enum FocusArea { case hierarchy, scene, project, other }
    var focusArea: FocusArea = .other
    @Published var center: CenterTab = .scene
    @Published var tool: SceneTool = .select
    @Published var paintTile = 1
    @Published var tilesetSelection: [UUID: Int] = [:]   // selected tile in each tileset's editor (survives view rebuilds)
    @Published var showGrid = true
    @Published var showColliders = true
    @Published var snap = true
    @Published var diagnostics: [Diagnostic] = []
    @Published var buildLog = ""
    @Published var building = false
    @Published var buildStatus = ""
    @Published var bottomTab = 0              // 0 = Project, 1 = Console
    @Published var errorMessage: String?
    @Published var artVersion = 0
    @Published var currentFolder = "assets"   // Project panel folder (relative to the project root)
    @Published var folderVersion = 0          // bumped when folders change on disk
    @Published private(set) var folders: [String] = ["assets", "scripts"]   // cached; scanning the disk per redraw was slow

    @Published private(set) var looseImages: [String] = []

    func refreshFolders() {
        let f = project?.folders() ?? ["assets", "scripts"]
        if f != folders { folders = f }
        let l = project?.looseImages() ?? []
        if l != looseImages { looseImages = l }
    }

    // MARK: Watching the project folder

    private var watcher: FolderWatcher?
    private var syncTask: Task<Void, Never>?

    private func startWatching(_ root: URL) {
        let rootPath = root.standardizedFileURL.path
        watcher = FolderWatcher(path: rootPath) { [weak self] paths in
            // Ignore build output; everything else (assets, images, scripts, folders) may have changed
            let relevant = paths.filter { !$0.hasPrefix(rootPath + "/build/") && !$0.hasSuffix("/.DS_Store") }
            guard !relevant.isEmpty else { return }
            let images = relevant.contains { GameProject.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            MainActor.assumeIsolated { self?.diskChanged(imagesChanged: images) }
        }
    }

    private func diskChanged(imagesChanged: Bool) {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.syncFromDisk(imagesChanged: imagesChanged)
        }
    }

    /// Pick up files added, removed or edited outside Taco Engine (Finder, Aseprite, a text editor…)
    func syncFromDisk(imagesChanged: Bool) {
        guard let project else { return }
        if imagesChanged {
            art.invalidate()
            artVersion += 1
        }
        checkScripts()
        refreshFolders()
        // Only reload assets if the files differ from what we last saved ourselves
        guard saveTask == nil || saveTask!.isCancelled, let disk = try? GameProject.load(project.root) else { return }
        var mine = lastSaved ?? project
        mine.scripts = disk.scripts
        // Every asset kind counts (a git pull can change dialogues, speakers, text boxes or fonts too)
        if disk != mine { reload() }
    }

    // MARK: Loose files

    /// Make a sprite or tileset out of an image that's already in the project (no copying)
    func useImage(_ rel: String, asTileset: Bool) {
        guard let project else { return }
        let url = project.url(rel)
        let dir = (rel as NSString).deletingLastPathComponent
        let base = url.deletingPathExtension().lastPathComponent
        let suffix = asTileset ? ".tileset.json" : ".sprite.json"
        var jsonPath = dir + "/" + base + suffix
        if FileManager.default.fileExists(atPath: project.url(jsonPath).path) { jsonPath = project.uniquePath(dir, base, suffix) }
        var created: UUID?
        edit { p in
            if asTileset {
                let t = TilesetAsset(guid: UUID(), image: url.lastPathComponent, tiles: [:])
                p.tilesets[t.guid] = Stored(path: jsonPath, value: t)
                created = t.guid
            } else {
                let b = try? Bitmap.load(url)
                let h = b?.height ?? 16, w = b?.width ?? 16
                // A row of square frames if it looks like a strip, otherwise one frame
                let size = (w > h && w % h == 0) ? min(64, h) : min(64, max(w, h))
                let frames = max(1, (w / max(1, size)) * (h / max(1, size)))
                let s = SpriteAsset(guid: UUID(), image: url.lastPathComponent, frameWidth: size, frameHeight: size,
                                    pivotX: size / 2, pivotY: size,
                                    animations: [SpriteAnimation(name: "idle", frames: Array(0..<min(frames, 16)), fps: frames > 1 ? 8 : 0)])
                p.sprites[s.guid] = Stored(path: jsonPath, value: s)
                created = s.guid
            }
        }
        saveNow()
        refreshFolders()
        if let created { selection = .asset(created); center = .asset(created) }
    }

    /// Copy files dragged in from Finder into a project folder
    func importFiles(_ urls: [URL], to folder: String) {
        guard let project else { return }
        let fm = FileManager.default
        var copied = 0
        for src in urls {
            let srcPath = src.standardizedFileURL.path
            if srcPath.hasPrefix(project.root.standardizedFileURL.path + "/") {
                // already inside the project: treat as a move
                _ = move("file:" + project.relative(src), to: folder)
                continue
            }
            var dest = project.url(folder).appendingPathComponent(src.lastPathComponent)
            var n = 1
            while fm.fileExists(atPath: dest.path) {
                dest = project.url(folder).appendingPathComponent("\(src.deletingPathExtension().lastPathComponent) \(n).\(src.pathExtension)")
                n += 1
            }
            if (try? fm.copyItem(at: src, to: dest)) != nil { copied += 1 }
        }
        if copied > 0 { syncFromDisk(imagesChanged: true) }
    }

    func trashFile(_ rel: String) {
        guard let project else { return }
        try? FileManager.default.trashItem(at: project.url(rel), resultingItemURL: nil)
        if selection == .file(rel) { selection = .none }
        syncFromDisk(imagesChanged: true)
    }


    let art = ArtCache()
    private var lastSaved: GameProject?
    private var loading = false
    private var saveTask: Task<Void, Never>?
    /// The window's undo manager (set by MainView): Edit ▸ Undo / Redo, ⌘Z / ⇧⌘Z, shared with text fields
    weak var undoManager: UndoManager?
    private var scriptStamp: [String: Date] = [:]
    private var timer: Timer?

    static let lastProjectKey = "lastGBAProject"

    init() {
        // Projects opened before (most recent first); the launcher shows them
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshFromDisk() }
        }
        // Scripts are edited in an external editor: re-parse them when they change
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkScripts() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return MainActor.assumeIsolated { self.handleKey(e) } ? nil : e
        }
    }

    private var keyMonitor: Any?
    @Published var savedFlash = false

    /// Save now and show "Saved" in the toolbar for a moment
    func saveFromKeyboard() {
        saveNow()
        savedFlash = true
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); savedFlash = false }
    }

    /// Editor shortcuts that act on the selection. Typing in a text field keeps its normal keys.
    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .control && key == "s" { saveFromKeyboard(); return true }
        let typing = NSApp.keyWindow?.firstResponder is NSText
        guard project != nil, !typing else { return false }
        switch (e.keyCode, mods) {
        case (51, []), (117, []):                                   // Delete / forward delete
            if focusArea == .project, !projectSelection.isEmpty { deleteProjectSelection(); return true }
            if focusArea != .project, !entitySelection.isEmpty { deleteSelection(); return true }
        case (123...126, let m) where focusArea == .scene && (m.isEmpty || m == .shift) && !entitySelection.isEmpty:   // arrows nudge
            let step = m == .shift ? 8 : 1
            let (dx, dy) = [123: (-step, 0), 124: (step, 0), 125: (0, step), 126: (0, -step)][Int(e.keyCode)]!
            nudgeSelection(dx, dy, mergeUndo: e.isARepeat)
            return true
        default: break
        }
        if mods == .command {
            switch key {
            case "c" where focusArea != .project && !entitySelection.isEmpty: copySelection(); return true
            case "v" where focusArea != .project && NSPasteboard.general.data(forType: Self.pasteboardType) != nil: pasteFromClipboard(); return true
            case "d" where focusArea != .project && !entitySelection.isEmpty: duplicateSelection(); return true
            default: break
            }
        }
        return false
    }

    /// Move the selected entities (not ones whose parent is selected too: they come along)
    func nudgeSelection(_ dx: Int, _ dy: Int, mergeUndo: Bool) {
        guard let sc = scene else { return }
        let sel = entitySelection
        func underSelected(_ e: SceneEntity) -> Bool {
            var p = e.parent, n = 0
            while let pid = p, n < 32 { if sel.contains(pid) { return true }; p = sc.entities.first { $0.guid == pid }?.parent; n += 1 }
            return false
        }
        if !mergeUndo { checkpoint() }
        for e in sc.entities where sel.contains(e.guid) && !underSelected(e) { updateEntity(e.guid) { $0.x += dx; $0.y += dy } }
    }

    // MARK: Project

    func open(_ url: URL) {
        do {
            let p = try GameProject.load(url)
            loading = true
            project = p
            loading = false
            lastSaved = p
            undoManager?.removeAllActions(withTarget: self)
            art.invalidate()
            openScene = p.settings.startScene.flatMap { p.scenes[$0] != nil ? $0 : nil } ?? p.settings.scenes.first
            selection = .none
            center = .scene
            stampScripts()
            refreshFolders()
            showLoadIssues(p)
            UserDefaults.standard.set(url.path, forKey: Self.lastProjectKey)
            addRecent(url)
            startWatching(url)
        } catch {
            errorMessage = "Couldn't open project: \(error.localizedDescription)"
        }
    }

    // MARK: Recent projects (the launcher)

    static let recentKey = "recentProjects"

    struct RecentProject: Identifiable, Hashable {
        let path: String
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
        var exists: Bool { GameProject.isProject(url) }
        var name: String {
            guard let d = try? Data(contentsOf: url.appendingPathComponent(GameProject.settingsFile)),
                  let s = try? JSONDecoder().decode(ProjectSettings.self, from: d) else { return url.lastPathComponent }
            return s.name
        }
        var modified: Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
    }

    @Published var recents: [RecentProject] = (UserDefaults.standard.stringArray(forKey: EditorModel.recentKey)
        ?? UserDefaults(suiteName: "local.tacomaker")?.stringArray(forKey: EditorModel.recentKey)   // before the app was renamed
        ?? [UserDefaults.standard.string(forKey: EditorModel.lastProjectKey)].compactMap { $0 }).map { RecentProject(path: $0) }

    private func addRecent(_ url: URL) {
        var paths = recents.map(\.path).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        paths = Array(paths.prefix(15))
        UserDefaults.standard.set(paths, forKey: Self.recentKey)
        recents = paths.map { RecentProject(path: $0) }
    }

    func removeRecent(_ r: RecentProject) {
        let paths = recents.map(\.path).filter { $0 != r.path }
        UserDefaults.standard.set(paths, forKey: Self.recentKey)
        recents = paths.map { RecentProject(path: $0) }
    }

    /// Back to the launcher
    func closeProject() {
        saveNow()
        watcher = nil
        loading = true
        project = nil
        loading = false
        lastSaved = nil
        openScene = nil
        selection = .none
        center = .scene
        undoManager?.removeAllActions(withTarget: self)
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a project folder (one containing project.json)"
        if panel.runModal() == .OK, let url = panel.url {
            if GameProject.isProject(url) { open(url) } else { errorMessage = "That folder isn't a Taco Engine project. Choose the folder that contains project.json." }
        }
    }

    func newProject() {
        let panel = NSSavePanel()
        panel.message = "Choose where to create the new project folder"
        panel.nameFieldStringValue = "My GBA Game"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try Templates.emptyProject(at: url, scriptTemplates: Templates.scriptLibrary(engine: Builder.findEngine(for: url)))
            open(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let project else { return }
        do {
            try project.saveChanges(since: lastSaved)
            lastSaved = project
        } catch {
            errorMessage = "Couldn't save the project: \(error.localizedDescription)"
        }
    }

    func refreshFromDisk() {
        art.invalidate()
        artVersion += 1
        checkScripts()
        refreshFolders()
    }

    private func stampScripts() {
        // Every script the project reads: scripts/ and assets/, at any folder depth
        let files = project?.scriptFiles() ?? []
        scriptStamp = Dictionary(uniqueKeysWithValues: files.map {
            ($0.path, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        })
    }

    func checkScripts() {
        guard project != nil else { return }
        let before = scriptStamp
        stampScripts()
        if before != scriptStamp {
            loading = true
            project!.reloadScripts()
            loading = false
        }
    }

    // MARK: Undo

    /// Call before changing the project: records the current state as one undo step
    func checkpoint() {
        guard let project, let um = undoManager else { return }
        let snapshot = project
        um.registerUndo(withTarget: self) { model in model.restore(snapshot) }
    }

    /// Undo/redo: swap in a saved state, registering the current one so the step can be reversed
    private func restore(_ snapshot: GameProject) {
        guard let current = project else { return }
        undoManager?.registerUndo(withTarget: self) { model in model.restore(current) }
        project = snapshot
    }

    func edit(_ change: (inout GameProject) -> Void) {
        guard var p = project else { return }
        checkpoint()
        change(&p)
        project = p
    }

    // MARK: Scene helpers

    var scene: SceneAsset? { openScene.flatMap { project?.scenes[$0]?.value } }

    /// Mutate the open scene (callers decide when to checkpoint)
    func updateScene(_ change: (inout SceneAsset) -> Void) {
        guard let id = openScene, project?.scenes[id] != nil else { return }
        change(&project!.scenes[id]!.value)
    }

    func entity(_ id: UUID) -> SceneEntity? { scene?.entities.first { $0.guid == id } }

    func updateEntity(_ id: UUID, _ change: (inout SceneEntity) -> Void) {
        updateScene { s in
            if let i = s.entities.firstIndex(where: { $0.guid == id }) { change(&s.entities[i]) }
        }
    }

    var selectedEntity: SceneEntity? {
        if case .entity(let id) = selection { return entity(id) }
        return nil
    }

    func openSceneAsset(_ id: UUID) {
        saveNow()
        openScene = id
        center = .scene
        selection = .none
    }

    // MARK: Entities

    func addEntity(_ e: SceneEntity) {
        checkpoint()
        updateScene { $0.entities.append(e) }
        selection = .entity(e.guid)
    }

    func instantiate(prefab id: UUID, at point: CGPoint? = nil) {
        guard let project, let pf = project.prefabs[id] else { return }
        let p = point ?? defaultSpawnPoint()
        var e = SceneEntity(name: pf.name, x: Int(p.x), y: Int(p.y), prefab: id)
        if snap { e.x = (e.x / 8) * 8; e.y = (e.y / 8) * 8 }
        addEntity(e)
    }

    func createEmpty(withSprite sprite: UUID? = nil) {
        var def = EntityDef()
        var name = "Entity"
        if let sprite, let s = project?.sprites[sprite] {
            def.sprite = SpriteComponent(sprite: sprite, animation: s.value.animations.first?.name ?? "")
            name = s.name
        }
        let p = defaultSpawnPoint()
        addEntity(SceneEntity(name: name, x: Int(p.x), y: Int(p.y), def: def))
    }

    func defaultSpawnPoint() -> CGPoint {
        guard let s = scene else { return .zero }
        return CGPoint(x: min(120, s.width * 8), y: min(80, s.height * 8))
    }

    func duplicate(_ id: UUID) {
        selectEntities([id])
        duplicateSelection()
    }

    func deleteEntity(_ id: UUID) {
        selectEntities([id])
        deleteSelection()
    }

    // MARK: Multi-selection, copy & paste, parenting

    /// Selected entities in scene order
    func orderedSelection() -> [UUID] {
        guard let sc = scene else { return [] }
        return sc.entities.map(\.guid).filter { entitySelection.contains($0) }
    }

    func selectEntities(_ ids: [UUID]) {
        entitySelection = Set(ids)
        if let last = ids.last { selection = .entity(last) } else if case .entity = selection { selection = .none }
        entityAnchor = ids.last
    }

    /// Cmd/Shift-click in the Scene view: add or remove one
    func toggleEntity(_ id: UUID) {
        var sel = entitySelection
        if sel.contains(id) { sel.remove(id) } else { sel.insert(id) }
        entitySelection = sel
        if sel.contains(id) { selection = .entity(id) }
        else if let other = orderedSelection().last { selection = .entity(other) }
        else { selection = .none }
    }

    /// Delete the selected entities and everything under them
    func deleteSelection() {
        guard let sc = scene, !entitySelection.isEmpty else { return }
        let gone = Set(entitySelection.flatMap { sc.subtree($0) })
        checkpoint()
        updateScene { s in
            s.entities.removeAll { gone.contains($0.guid) }
            if let t = s.cameraTarget, gone.contains(t) { s.cameraTarget = nil }
        }
        entitySelection = []
        selection = .none
    }

    func duplicateSelection() {
        guard let data = encodeSelection() else { return }
        pasteEntities(data, offset: 16)
    }

    static let pasteboardType = NSPasteboard.PasteboardType("local.tacoengine.entities")

    /// The selected entities plus their children, as JSON (positions of top-level ones made absolute)
    func encodeSelection() -> Data? {
        guard let sc = scene, !entitySelection.isEmpty else { return nil }
        let ids = Set(entitySelection.flatMap { sc.subtree($0) })
        var list = sc.entities.filter { ids.contains($0.guid) }
        for i in list.indices where list[i].parent.map({ !ids.contains($0) }) ?? false {
            let w = sc.worldPosition(of: list[i])
            list[i].x = w.x; list[i].y = w.y; list[i].parent = nil       // copied without its parent: top-level
        }
        return try? JSONEncoder().encode(list)
    }

    func copySelection() {
        guard let data = encodeSelection() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
    }

    func pasteFromClipboard() {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType) else { return }
        pasteEntities(data, offset: 16)
    }

    /// Add copied entities with fresh ids; links between them (parents, EntityRef fields like a switch's door) follow the copies
    func pasteEntities(_ data: Data, offset: Int) {
        guard scene != nil, let list = try? JSONDecoder().decode([SceneEntity].self, from: data), !list.isEmpty else { return }
        var mapping: [String: String] = [:]
        for e in list { mapping[e.guid.uuidString] = UUID().uuidString }
        guard var text = String(data: data, encoding: .utf8) else { return }
        for (old, new) in mapping { text = text.replacingOccurrences(of: old, with: new) }
        guard var copies = try? JSONDecoder().decode([SceneEntity].self, from: Data(text.utf8)) else { return }
        let existing = Set(scene!.entities.map(\.guid.uuidString))
        let overlapping = list.contains { existing.contains($0.guid.uuidString) }
        for i in copies.indices where copies[i].parent == nil {
            if overlapping { copies[i].x += offset; copies[i].y += offset }
        }
        checkpoint()
        updateScene { $0.entities.append(contentsOf: copies) }
        let top = copies.filter { c in c.parent.map { p in !copies.contains { $0.guid == p } } ?? true }.map(\.guid)
        selectEntities(top)
    }

    /// Make `child` a child of `parent` (nil = top level), keeping where it is in the world
    func setParent(_ child: UUID, to parent: UUID?) {
        guard let sc = scene, let e = sc.entities.first(where: { $0.guid == child }), child != parent else { return }
        if let parent, sc.subtree(child).contains(parent) { return }   // can't go under its own child
        let w = sc.worldPosition(of: e)
        let pw = parent.flatMap { pid in sc.entities.first { $0.guid == pid } }.map { sc.worldPosition(of: $0) } ?? (0, 0)
        checkpoint()
        updateScene { s in
            guard let i = s.entities.firstIndex(where: { $0.guid == child }) else { return }
            s.entities[i].parent = parent
            s.entities[i].x = w.x - pw.0
            s.entities[i].y = w.y - pw.1
            // keep children right after their parent in the list
            if let parent, let pi = s.entities.firstIndex(where: { $0.guid == parent }), i < pi {
                let moved = s.entities.remove(at: i)
                s.entities.insert(moved, at: pi)
            }
        }
    }

    /// Project panel: delete everything selected (assets, scripts, files, folders), after one confirmation
    func deleteProjectSelection() {
        guard let project, !projectSelection.isEmpty else { return }
        let ids = projectSelection
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "Delete the selected item?" : "Delete \(ids.count) items?"
        alert.informativeText = "Assets are removed from the project; scripts, sounds, images and folders go to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        saveNow()
        let fm = FileManager.default
        var assets: [UUID] = []
        for id in ids {
            if let u = UUID(uuidString: id) { assets.append(u) }
            else if id.hasPrefix("script:"), let info = project.script(String(id.dropFirst(7))) { try? fm.trashItem(at: info.file, resultingItemURL: nil) }
            else if id.hasPrefix("file:") { try? fm.trashItem(at: project.url(String(id.dropFirst(5))), resultingItemURL: nil) }
            else if id.hasPrefix("folder:") { try? fm.trashItem(at: project.url(String(id.dropFirst(7))), resultingItemURL: nil) }
        }
        if !assets.isEmpty {
            edit { p in
                for id in assets {
                    p.sprites[id] = nil; p.tilesets[id] = nil; p.prefabs[id] = nil; p.platformers[id] = nil
                    p.dialogues[id] = nil; p.speakers[id] = nil; p.textboxes[id] = nil; p.fonts[id] = nil
                    if p.scenes[id] != nil {
                        p.scenes[id] = nil
                        p.settings.scenes.removeAll { $0 == id }
                        if p.settings.startScene == id { p.settings.startScene = p.settings.scenes.first }
                    }
                }
            }
            saveNow()
            if let o = openScene, assets.contains(o) { openScene = self.project?.settings.scenes.first }
            if case .asset(let a) = center, assets.contains(a) { center = .scene }
        }
        projectSelection = []
        selection = .none
        checkScripts()
        reload()
    }

    /// Effective components of an entity (cached until the project changes: merging prefab overrides is not cheap)
    private var defCache: [UUID: (SceneEntity, EntityDef)] = [:]

    func def(_ e: SceneEntity) -> EntityDef {
        if let (cachedFor, d) = defCache[e.guid], cachedFor == e { return d }
        let d = project?.effectiveDef(e) ?? EntityDef()
        defCache[e.guid] = (e, d)
        return d
    }

    /// Change an entity's components (stored as prefab overrides for instances)
    func setDef(_ id: UUID, _ def: EntityDef) {
        guard let project, let e = entity(id) else { return }
        let updated = project.applying(def, to: e)
        updateEntity(id) { $0 = updated }
    }

    func makePrefab(from id: UUID) {
        guard let e = entity(id), let project else { return }
        let path = project.uniquePath(assetFolder, e.name, ".prefab.json")
        let prefab = PrefabAsset(guid: UUID(), def: def(e))
        edit { p in
            p.prefabs[prefab.guid] = Stored(path: path, value: prefab)
            if let sid = openScene, let i = p.scenes[sid]?.value.entities.firstIndex(where: { $0.guid == id }) {
                p.scenes[sid]!.value.entities[i].prefab = prefab.guid
                p.scenes[sid]!.value.entities[i].def = nil
                p.scenes[sid]!.value.entities[i].overrides = nil
            }
        }
    }

    func unpack(_ id: UUID) {
        guard let e = entity(id) else { return }
        let d = def(e)
        checkpoint()
        updateEntity(id) { $0.prefab = nil; $0.overrides = nil; $0.def = d }
    }

    func applyOverridesToPrefab(_ id: UUID) {
        guard let e = entity(id), let pid = e.prefab else { return }
        let d = def(e)
        edit { p in
            p.prefabs[pid]?.value.def = d
            if let sid = openScene, let i = p.scenes[sid]?.value.entities.firstIndex(where: { $0.guid == id }) {
                p.scenes[sid]!.value.entities[i].overrides = nil
            }
        }
    }

    func revertOverrides(_ id: UUID) {
        checkpoint()
        updateEntity(id) { $0.overrides = nil }
    }

    // MARK: Assets

    func createScene() {
        guard let project else { return }
        let path = project.uniquePath(assetFolder, "New Scene", ".scene.json")
        var s = SceneAsset(width: 30, height: 10)
        s.tileset = project.tilesets.keys.first
        edit { p in
            p.scenes[s.guid] = Stored(path: path, value: s)
            p.settings.scenes.append(s.guid)
        }
        openSceneAsset(s.guid)
    }

    func createPrefab() {
        guard let project else { return }
        let path = project.uniquePath(assetFolder, "New Prefab", ".prefab.json")
        let pf = PrefabAsset(guid: UUID(), def: EntityDef())
        edit { $0.prefabs[pf.guid] = Stored(path: path, value: pf) }
        selection = .asset(pf.guid)
    }

    func createPlatformer() {
        guard let project else { return }
        let path = project.uniquePath(assetFolder, "New Platformer", ".platformer.json")
        let ps = PlatformerSettings()
        edit { $0.platformers[ps.guid] = Stored(path: path, value: ps) }
        selection = .asset(ps.guid)
        center = .asset(ps.guid)
    }

    /// Import a PNG as a sprite sheet or tileset (copied into assets/)
    func importImage(asTileset: Bool) {
        guard let project else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = true
        panel.message = asTileset ? "Choose a tileset image (a grid of 16x16 tiles)" : "Choose sprite sheet images (a grid of equal-size frames)"
        guard panel.runModal() == .OK else { return }
        var created: UUID?
        edit { p in
            for src in panel.urls {
                let base = src.deletingPathExtension().lastPathComponent
                let dir = assetFolder
                let jsonPath = project.uniquePath(dir, base, asTileset ? ".tileset.json" : ".sprite.json")
                let imageName = assetName(URL(fileURLWithPath: jsonPath)) + ".png"
                let dest = p.url(dir).appendingPathComponent(imageName)
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: src, to: dest)
                if asTileset {
                    let t = TilesetAsset(guid: UUID(), image: imageName, tiles: [:])
                    p.tilesets[t.guid] = Stored(path: jsonPath, value: t)
                    created = t.guid
                } else {
                    let h = (try? Bitmap.load(dest).height) ?? 16
                    let size = min(64, max(8, h))
                    let s = SpriteAsset(guid: UUID(), image: imageName, frameWidth: size, frameHeight: size,
                                        pivotX: size / 2, pivotY: size, animations: [SpriteAnimation(name: "default", frames: [0], fps: 0)])
                    p.sprites[s.guid] = Stored(path: jsonPath, value: s)
                    created = s.guid
                }
            }
        }
        if let created { selection = .asset(created); center = .asset(created) }
    }

    func createScript() {
        guard let project else { return }
        let alert = NSAlert()
        alert.messageText = "New Script"
        alert.informativeText = "Name (letters and numbers, e.g. EnemyAI):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = "NewScript"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = cIdentifier(field.stringValue.trimmingCharacters(in: .whitespaces))
        let file = project.url(currentFolder).appendingPathComponent("\(name.lowercased()).c")
        guard !FileManager.default.fileExists(atPath: file.path) else { errorMessage = "\(file.lastPathComponent) already exists."; return }
        let template = """
        // \(name): describe what this script does.
        #include "engine.h"

        SCRIPT(\(name)) {
            int speed;      // = 1 Fields show up in the Inspector. "// = value" sets the default.
            int timer;      // @hide  (internal state, not shown)
        };

        void \(name)_Start(\(name) *self, Entity *e) {
            // Runs once, before the first Update.
        }

        void \(name)_Update(\(name) *self, Entity *e) {
            // Runs every frame (60 times a second). Example: move right while holding A.
            if (key_held(KEY_A)) e->x += FX(self->speed);
        }

        // Other callbacks you can add:
        // void \(name)_OnTrigger(\(name) *self, Entity *e, Entity *other)      touched a trigger collider
        // void \(name)_OnTriggerExit(\(name) *self, Entity *e, Entity *other)
        // void \(name)_OnMessage(\(name) *self, Entity *e, int msg, int arg)   MSG_JUMPED, MSG_LANDED, send_message()...
        // void \(name)_OnDestroy(\(name) *self, Entity *e)

        """
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try template.write(to: file, atomically: true, encoding: .utf8)
            checkScripts()
            selection = .script(name)
            ExternalEditor.open(file, line: 5, workspace: project.root)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAsset(_ id: UUID) {
        guard let project, let name = project.name(of: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(name)?"
        alert.informativeText = "The asset file is removed from the project folder (its image stays)."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        edit { p in
            p.sprites[id] = nil; p.tilesets[id] = nil; p.prefabs[id] = nil; p.platformers[id] = nil
            p.dialogues[id] = nil; p.speakers[id] = nil; p.textboxes[id] = nil; p.fonts[id] = nil
            if p.scenes[id] != nil {
                p.scenes[id] = nil
                p.settings.scenes.removeAll { $0 == id }
                if p.settings.startScene == id { p.settings.startScene = p.settings.scenes.first }
            }
        }
        if openScene == id { openScene = self.project?.settings.scenes.first }
        if center == .asset(id) { center = .scene }
        selection = .none
    }

    func renameAsset(_ id: UUID, to newName: String) {
        guard let project else { return }
        let clean = newName.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.contains("/") else { return }
        func renamed(_ path: String, _ kind: AssetKind) -> String {
            (path as NSString).deletingLastPathComponent + "/" + clean + kind.fileSuffix
        }
        edit { p in
            if let s = p.sprites[id] { p.sprites[id]!.path = renamed(s.path, .sprite) }
            if let s = p.tilesets[id] { p.tilesets[id]!.path = renamed(s.path, .tileset) }
            if let s = p.prefabs[id] { p.prefabs[id]!.path = renamed(s.path, .prefab) }
            if let s = p.scenes[id] { p.scenes[id]!.path = renamed(s.path, .scene) }
            if let s = p.platformers[id] { p.platformers[id]!.path = renamed(s.path, .platformer) }
            if let s = p.dialogues[id] { p.dialogues[id]!.path = renamed(s.path, .dialogue) }
            if let s = p.speakers[id] { p.speakers[id]!.path = renamed(s.path, .speaker) }
            if let s = p.textboxes[id] { p.textboxes[id]!.path = renamed(s.path, .textbox) }
            if let s = p.fonts[id] { p.fonts[id]!.path = renamed(s.path, .font) }
        }
        _ = project
    }

    // MARK: Dialogue assets

    func createDialogue() {
        guard let project else { return }
        let path = project.uniquePath(assetFolder, "New Dialogue", ".dialogue.json")
        let d = DialogueAsset(lines: [DialogueLine(speaker: project.speakers.keys.first, text: "Hello! [wave]Nice to meet you.[/wave]")])
        edit { $0.dialogues[d.guid] = Stored(path: path, value: d) }
        selection = .asset(d.guid)
        center = .asset(d.guid)
    }

    func createSpeaker() {
        guard let project else { return }
        let path = project.uniquePath(assetFolder, "New Speaker", ".speaker.json")
        let sp = SpeakerAsset(displayName: "Someone")
        edit { $0.speakers[sp.guid] = Stored(path: path, value: sp) }
        selection = .asset(sp.guid)
    }

    func createTextBox() {
        guard let project else { return }
        let path = project.uniquePath(assetFolder, "Text Box", ".textbox.json")
        var style = TextBoxStyleAsset()
        let frameName = assetName(URL(fileURLWithPath: path)) + " frame.png"
        try? Templates.defaultFrame().savePNG(project.url(assetFolder).appendingPathComponent(frameName))
        style.frameImage = frameName
        edit { $0.textboxes[style.guid] = Stored(path: path, value: style) }
        selection = .asset(style.guid)
        center = .asset(style.guid)
    }

    /// Save the built-in font as an editable PNG + font asset, and use it in a text box style
    func exportBuiltInFont(for styleID: UUID?) {
        guard let project else { return }
        let path = project.uniquePath(assetFolder, "Font", ".font.json")
        let image = assetName(URL(fileURLWithPath: path)) + ".png"
        try? FontData.standard.bitmap().savePNG(project.url(assetFolder).appendingPathComponent(image))
        let f = FontAsset(image: image)
        edit { p in
            p.fonts[f.guid] = Stored(path: path, value: f)
            if let styleID { p.textboxes[styleID]?.value.font = f.guid }
        }
        refreshFolders()
    }

    /// docs/ next to the engine (or next to the app)
    func openDocumentation() {
        // The copy inside TacoEngine.app, else the docs folder of the repository the engine comes from
        let candidates = [Bundle.main.resourceURL,
                          project.flatMap { Builder.findEngine(for: $0.root)?.deletingLastPathComponent() },
                          Bundle.main.bundleURL.deletingLastPathComponent()].compactMap { $0 }
        guard let docs = candidates.map({ $0.appendingPathComponent("docs") })
            .first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("README.md").path) }) else {
            errorMessage = "Couldn't find the documentation. Rebuild TacoEngine.app with build_editor.sh, which copies it into the app."
            return
        }
        NSWorkspace.shared.open(docs.appendingPathComponent("README.md"))
    }

    // MARK: Presets

    /// The project's square sprite (created if missing)
    func ensureSquareSprite() -> UUID? {
        guard project != nil else { return nil }
        if let id = project!.sprites.first(where: { $0.value.name == "square" })?.key { return id }
        var id: UUID?
        edit { p in id = try? Templates.addSquareSprite(to: &p, folder: assetFolder) }
        return id
    }

    /// First platformer settings asset (a Celeste Classic 2 style one is created if there are none)
    func ensurePlatformerSettings() -> UUID? {
        guard let project else { return nil }
        if let id = project.platformers.keys.sorted(by: { project.platformers[$0]!.name < project.platformers[$1]!.name }).first { return id }
        var id: UUID?
        edit { p in id = Templates.addPlatformerSettings(to: &p, folder: "assets") }
        return id
    }

    /// Turn a def into a ready-to-play platformer character
    func withPlatformerController(_ def: EntityDef) -> EntityDef {
        var d = def
        if d.collider == nil || d.collider?.trigger == true {
            // fit inside the sprite if there is one: a bit narrower than 16x16, standing on the pivot
            var w = 12, h = 14
            if let sid = d.sprite?.sprite, let s = project?.sprites[sid]?.value {
                w = max(4, s.frameWidth - 4); h = max(4, s.frameHeight - 2)
                d.collider = ColliderComponent(x: -w / 2, y: -h - (s.frameHeight - s.pivotY), w: w, h: h)
            } else {
                d.collider = ColliderComponent(x: -w / 2, y: -h, w: w, h: h)
            }
        }
        d.platformer = PlatformerComponent(settings: ensurePlatformerSettings(), joypad: true)
        if d.tag.isEmpty, project?.settings.tags.contains("Player") == true { d.tag = "Player" }
        return d
    }

    /// Make sure the project has a ready-made script (copied from engine/templates/scripts)
    func ensureLibraryScript(_ file: String) {
        guard let project else { return }
        if Templates.ensureScript(file, in: project, library: Templates.scriptLibrary(engine: Builder.findEngine(for: project.root))) {
            checkScripts()
        }
    }

    func ensureTalkScript() { ensureLibraryScript("talk.c") }

    /// Talk preset: a trigger area plus the Talk script, pointing at the first dialogue
    func withTalk(_ def: EntityDef) -> EntityDef {
        ensureTalkScript()
        var d = def
        if d.collider == nil { d.collider = ColliderComponent(x: -12, y: -20, w: 24, h: 20, trigger: true) }
        else { d.collider?.trigger = true }
        if !d.scripts.contains(where: { $0.script == "Talk" }) {
            var fields: [String: JSON] = [:]
            if let first = project?.dialogues.keys.sorted(by: { project!.dialogues[$0]!.name < project!.dialogues[$1]!.name }).first {
                fields["dialogue"] = .string(first.uuidString)
            }
            d.scripts.append(ScriptComponent(script: "Talk", fields: fields))
        }
        return d
    }

    /// Hierarchy ▸ + ▸ Talking NPC
    func createTalkingNPC() {
        guard scene != nil else { return }
        var def = EntityDef()
        def.sprite = SpriteComponent(sprite: ensureSquareSprite(), animation: "idle")
        def = withTalk(def)
        let p = defaultSpawnPoint()
        addEntity(SceneEntity(name: "NPC", x: Int(p.x), y: Int(p.y), def: def))
    }

    // MARK: Ready-made prefabs

    enum Premade: String, CaseIterable {
        case levelEnd = "Level End", enemy = "Enemy", spikes = "Spikes"
    }

    /// The prefab for a ready-made kind: reuses one with that name, otherwise creates it (art, scripts and prefab)
    @discardableResult
    func premadePrefab(_ kind: Premade) -> UUID? {
        guard let project else { return nil }
        if let id = project.prefabs.first(where: { $0.value.name == kind.rawValue })?.key { return id }
        let files: [String]
        switch kind {
        case .levelEnd: files = ["level_end.c"]
        case .enemy: files = ["patroller.c", "hazard.c"]
        case .spikes: files = ["hazard.c"]
        }
        files.forEach(ensureLibraryScript)
        // Respawn is what reacts to getting hurt
        if kind == .enemy || kind == .spikes { ensureLibraryScript("respawn.c") }
        guard let p = self.project else { return nil }
        func script(_ name: String, _ extra: [String: JSON] = [:]) -> ScriptComponent {
            ScriptComponent(script: name, fields: (p.script(name)?.defaultFields() ?? [:]).merging(extra) { $1 })
        }
        let folder = "assets/premade"
        let art: (String, Bitmap, [SpriteAnimation])
        var def = EntityDef()
        switch kind {
        case .levelEnd:
            art = ("flag", Placeholders.flagSheet(), [SpriteAnimation(name: "wave", frames: [0, 1], fps: 3)])
            def.collider = ColliderComponent(x: -5, y: -16, w: 10, h: 16, trigger: true)
            def.scripts = [script("LevelEnd")]
        case .enemy:
            art = ("enemy", Placeholders.slimeSheet(), [SpriteAnimation(name: "walk", frames: [0, 1], fps: 4)])
            def.tag = p.settings.tags.contains("Enemy") ? "Enemy" : ""
            def.collider = ColliderComponent(x: -6, y: -9, w: 12, h: 9, trigger: true)
            def.scripts = [script("Patroller"), script("Hazard")]
        case .spikes:
            art = ("spikes", Placeholders.spikeSprite(), [SpriteAnimation(name: "idle", frames: [0], fps: 0)])
            def.collider = ColliderComponent(x: -5, y: -6, w: 10, h: 6, trigger: true)
            def.scripts = [script("Hazard")]
        }
        var prefabID: UUID?
        edit { pr in
            // sprite (reused if a sprite with that name already exists)
            var spriteID = pr.sprites.first { $0.value.name == art.0 }?.key
            if spriteID == nil {
                try? art.1.savePNG(pr.url(folder).appendingPathComponent(art.0 + ".png"))
                let s = SpriteAsset(guid: UUID(), image: art.0 + ".png", frameWidth: 16, frameHeight: 16, pivotX: 8, pivotY: 16, animations: art.2)
                pr.sprites[s.guid] = Stored(path: pr.uniquePath(folder, art.0, ".sprite.json"), value: s)
                spriteID = s.guid
            }
            def.sprite = SpriteComponent(sprite: spriteID, animation: art.2.first?.name ?? "")
            let prefab = PrefabAsset(guid: UUID(), def: def)
            pr.prefabs[prefab.guid] = Stored(path: pr.uniquePath(folder, kind.rawValue, ".prefab.json"), value: prefab)
            prefabID = prefab.guid
        }
        refreshFolders()
        return prefabID
    }

    /// Place a ready-made prefab in the open scene (and make sure the player can get hurt by it)
    func placePremade(_ kind: Premade) {
        guard scene != nil, let id = premadePrefab(kind) else { return }
        if kind == .enemy || kind == .spikes { giveRespawnToPlayer() }
        instantiate(prefab: id)
    }

    /// Players made with the Platformer Player preset get the Respawn script so hazards do something
    private func giveRespawnToPlayer() {
        guard let sc = scene, project?.script("Respawn") != nil else { return }
        for e in sc.entities {
            let d = def(e)
            guard d.tag == "Player", d.platformer != nil, d.scripts.isEmpty else { continue }
            var nd = d
            nd.scripts.append(ScriptComponent(script: "Respawn", fields: project?.script("Respawn")?.defaultFields() ?? [:]))
            setDef(e.guid, nd)
        }
    }

    /// Hierarchy ▸ + ▸ Platformer Player: square sprite + collider + movement, followed by the camera
    func createPlatformerPlayer() {
        guard scene != nil else { return }
        let sprite = ensureSquareSprite()
        var def = EntityDef()
        def.sprite = SpriteComponent(sprite: sprite, animation: "idle")
        def = withPlatformerController(def)
        ensureLibraryScript("respawn.c")
        def.scripts.append(ScriptComponent(script: "Respawn", fields: project?.script("Respawn")?.defaultFields() ?? [:]))
        let p = defaultSpawnPoint()
        let e = SceneEntity(name: "Player", x: Int(p.x), y: Int(p.y), def: def)
        addEntity(e)
        if scene?.cameraTarget == nil { updateScene { $0.cameraTarget = e.guid } }
    }

    // MARK: Folders

    /// Where new assets go: the open Project folder if it's inside assets/, otherwise assets/
    var assetFolder: String { currentFolder == "assets" || currentFolder.hasPrefix("assets/") ? currentFolder : "assets" }

    /// Re-read the project from disk after files were moved, keeping what's open
    func reload() {
        guard let root = project?.root, let p = try? GameProject.load(root) else { return }
        let scene = openScene, sel = selection, ctr = center, folder = currentFolder
        loading = true
        project = p
        loading = false
        lastSaved = p
        undoManager?.removeAllActions(withTarget: self)
        art.invalidate()
        openScene = scene.flatMap { p.scenes[$0] != nil ? $0 : nil } ?? p.settings.scenes.first
        selection = sel
        center = ctr
        currentFolder = FileManager.default.fileExists(atPath: p.url(folder).path) ? folder : "assets"
        folderVersion += 1
        artVersion += 1
        stampScripts()
        refreshFolders()
        showLoadIssues(p)
    }

    /// Files that couldn't be read go to the Console as errors (builds refuse to run until they're fixed)
    func showLoadIssues(_ p: GameProject) {
        diagnostics.removeAll { $0.file == nil && $0.message.hasPrefix("Project: ") }
        guard !p.loadIssues.isEmpty else { return }
        diagnostics.insert(contentsOf: p.loadIssues.map { Diagnostic(severity: .error, message: "Project: " + $0) }, at: 0)
        bottomTab = 1
    }

    private func ask(_ title: String, _ message: String, _ initial: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty || v.contains("/") || v.hasPrefix(".") ? nil : v
    }

    func createFolder(in parent: String? = nil) {
        guard let project, let name = ask("New Folder", "Folder name:", "New Folder", button: "Create") else { return }
        let path = (parent ?? currentFolder) + "/" + name
        do {
            try FileManager.default.createDirectory(at: project.url(path), withIntermediateDirectories: true)
            currentFolder = path
            folderVersion += 1
            refreshFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameFolder(_ path: String) {
        guard let project, path != "assets", path != "scripts" else { return }
        let old = (path as NSString).lastPathComponent
        guard let name = ask("Rename Folder", "New name for \(old):", old, button: "Rename"), name != old else { return }
        let dest = (path as NSString).deletingLastPathComponent + "/" + name
        saveNow()
        do {
            try FileManager.default.moveItem(at: project.url(path), to: project.url(dest))
            if currentFolder == path || currentFolder.hasPrefix(path + "/") { currentFolder = dest + currentFolder.dropFirst(path.count) }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func trashFolder(_ path: String) {
        guard let project, path != "assets", path != "scripts" else { return }
        let alert = NSAlert()
        alert.messageText = "Move \((path as NSString).lastPathComponent) to the Trash?"
        alert.informativeText = "Everything inside it (assets, images, scripts) goes to the Trash too."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        saveNow()
        do {
            try FileManager.default.trashItem(at: project.url(path), resultingItemURL: nil)
            if currentFolder == path || currentFolder.hasPrefix(path + "/") { currentFolder = (path as NSString).deletingLastPathComponent }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Move something dragged in the Project panel into a folder.
    /// Payload: an asset UUID, "script:<relative path>" or "folder:<relative path>".
    @discardableResult
    func move(_ payload: String, to folder: String) -> Bool {
        guard let project else { return false }
        let fm = FileManager.default
        saveNow()
        do {
            if payload.hasPrefix("folder:") {
                let src = String(payload.dropFirst(7))
                guard src != folder, !folder.hasPrefix(src + "/"), (src as NSString).deletingLastPathComponent != folder,
                      src != "assets", src != "scripts" else { return false }
                try fm.moveItem(at: project.url(src), to: project.url(folder + "/" + (src as NSString).lastPathComponent))
            } else if payload.hasPrefix("file:") {
                let src = String(payload.dropFirst(5))
                guard (src as NSString).deletingLastPathComponent != folder else { return false }
                let dest = folder + "/" + (src as NSString).lastPathComponent
                guard !fm.fileExists(atPath: project.url(dest).path) else {
                    errorMessage = "\((dest as NSString).lastPathComponent) already exists in that folder."
                    return false
                }
                try fm.moveItem(at: project.url(src), to: project.url(dest))
                if selection == .file(src) { selection = .file(dest) }
            } else if payload.hasPrefix("script:") {
                let src = String(payload.dropFirst(7))
                guard (src as NSString).deletingLastPathComponent != folder else { return false }
                try fm.moveItem(at: project.url(src), to: project.url(folder + "/" + (src as NSString).lastPathComponent))
            } else if let id = UUID(uuidString: payload), let path = assetPath(id) {
                guard folder == "assets" || folder.hasPrefix("assets/") else {
                    errorMessage = "Assets have to stay inside the assets folder."
                    return false
                }
                let oldDir = (path as NSString).deletingLastPathComponent
                guard oldDir != folder else { return false }
                let newPath = folder + "/" + (path as NSString).lastPathComponent
                guard !fm.fileExists(atPath: project.url(newPath).path) else {
                    errorMessage = "\((newPath as NSString).lastPathComponent) already exists in that folder."
                    return false
                }
                try fm.moveItem(at: project.url(path), to: project.url(newPath))
                // Bring the image along (copy it if another asset in the old folder still uses it)
                if let image = assetImage(id), !image.contains("/") {
                    let oldImg = project.url(oldDir + "/" + image), newImg = project.url(folder + "/" + image)
                    if fm.fileExists(atPath: oldImg.path) && !fm.fileExists(atPath: newImg.path) {
                        let shared = (project.sprites.values.map { ($0.path, $0.value.image) } + project.tilesets.values.map { ($0.path, $0.value.image) })
                            .contains { $0.0 != path && ($0.0 as NSString).deletingLastPathComponent == oldDir && $0.1 == image }
                        if shared { try fm.copyItem(at: oldImg, to: newImg) } else { try fm.moveItem(at: oldImg, to: newImg) }
                    }
                }
            } else {
                return false
            }
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func assetPath(_ id: UUID) -> String? { project?.path(of: id) }

    func assetImage(_ id: UUID) -> String? {
        project?.sprites[id]?.value.image ?? project?.tilesets[id]?.value.image ?? project?.fonts[id]?.value.image ?? project?.textboxes[id]?.value.frameImage
    }

    // MARK: Sounds

    private var previewPlayer: NSSound?

    /// Play a sound (by name, or a project-relative file path) in the editor
    func previewSound(_ nameOrPath: String?) {
        guard let project, let key = nameOrPath else { return }
        let path = project.sounds().first { $0.name == key }?.path ?? key
        previewPlayer?.stop()
        previewPlayer = NSSound(contentsOf: project.url(path), byReference: true)
        previewPlayer?.play()
    }

    // MARK: Export

    /// Game ▸ Export for Web…: build from the start and write index.html + game.gba into a folder
    func exportWeb() {
        guard let project, !building else { return }
        let panel = NSSavePanel()
        panel.message = "Choose where to put the web version (a folder with index.html and the game)"
        panel.nameFieldStringValue = project.settings.name + " (web)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        saveNow()
        building = true
        buildStatus = "Exporting…"
        Task.detached {
            let result = WebExport.export(project, to: folder) { msg in Task { @MainActor in self.buildStatus = msg } }
            await MainActor.run {
                self.building = false
                self.buildLog = result.log
                self.diagnostics = result.diagnostics
                if result.success {
                    self.buildStatus = "Exported for web"
                    NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("index.html")])
                } else {
                    self.buildStatus = "Export failed"
                    self.bottomTab = 1
                }
            }
        }
    }

    // MARK: Build & play

    /// Scene ▸ right-click ▸ Play From Here: run the open scene with the player starting at `point`
    func playFromHere(_ point: CGPoint) {
        guard let sc = scene, let id = openScene else { return }
        guard sc.entities.contains(where: { def($0).tag == "Player" }) else {
            errorMessage = "Play From Here moves the entity tagged Player, and this scene has none. Give your player the Player tag in the Inspector."
            return
        }
        play(boot: .sceneAt(id, x: Int(point.x), y: Int(point.y)))
    }

    func play(fromStart: Bool = false) {
        play(boot: fromStart ? .start : (openScene.map { .scene($0) } ?? .start))
    }

    private func play(boot: Codegen.Boot) {
        guard let project, !building else { return }
        saveNow()
        building = true
        buildStatus = "Building…"
        Task.detached {
            let result = Builder.build(project, boot: boot) { msg in
                Task { @MainActor in self.buildStatus = msg }
            }
            await MainActor.run {
                self.building = false
                self.buildLog = result.log
                self.diagnostics = result.diagnostics
                if result.success, let rom = result.rom {
                    if Builder.mgbaApp == nil {
                        self.buildStatus = "Built"
                        NSWorkspace.shared.activateFileViewerSelecting([rom])
                        self.errorMessage = "The game built, but mGBA isn't installed, so it can't be opened. Get mGBA from https://mgba.io and put it in Applications, or open game.gba (now shown in Finder) in another emulator."
                        return
                    }
                    self.buildStatus = "Running in mGBA"
                    Builder.launch(rom)
                    if result.diagnostics.contains(where: { $0.severity == .warning }) { self.bottomTab = 1 }
                } else {
                    self.buildStatus = "Build failed"
                    self.bottomTab = 1
                }
            }
        }
    }
}
