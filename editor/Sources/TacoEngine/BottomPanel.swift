import AppKit
import EngineKit
import SwiftUI
import UniformTypeIdentifiers

struct BottomPanel: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            PanelTabBar {
                PanelTab(title: "Project", icon: "folder", active: model.bottomTab == 0) { model.bottomTab = 0 }
                PanelTab(title: consoleTitle, icon: "terminal", active: model.bottomTab == 1) { model.bottomTab = 1 }
            }
            if model.bottomTab == 0 { ProjectBrowser() } else { ConsoleView() }
        }
    }

    var consoleTitle: String {
        let errors = model.diagnostics.filter { $0.severity == .error }.count
        let warnings = model.diagnostics.filter { $0.severity == .warning }.count
        if errors > 0 { return "Console (\(errors) error\(errors == 1 ? "" : "s"))" }
        if warnings > 0 { return "Console (\(warnings) warning\(warnings == 1 ? "" : "s"))" }
        return "Console"
    }

}

/// A folder in the Project panel's tree
struct FolderNode: Identifiable, Hashable {
    let path: String
    var children: [FolderNode]?
    var id: String { path }
    var name: String { path == "assets" ? "Assets" : path == "scripts" ? "Scripts" : (path as NSString).lastPathComponent }

    static func tree(_ paths: [String]) -> [FolderNode] {
        func build(_ parent: String) -> FolderNode {
            let kids = paths.filter { ($0 as NSString).deletingLastPathComponent == parent }.sorted().map { build($0) }
            return FolderNode(path: parent, children: kids.isEmpty ? nil : kids)
        }
        return ["assets", "scripts"].map { build($0) }
    }
}

struct ProjectBrowser: View {
    @EnvironmentObject var model: EditorModel
    @State private var filter = ""
    @State private var dropTarget: String?

    struct Item: Identifiable {
        let id: String
        let name: String
        let icon: String
        let kind: String
        var asset: UUID? = nil
        var script: String? = nil      // script name (for selection)
        var file: String? = nil        // relative path (scripts)
        var loose: String? = nil       // relative path of an image that isn't an asset yet
        var folder: String? = nil
        var thumb: Bitmap? = nil

        /// What gets dragged: asset UUID, script:<path> or folder:<path>
        var payload: String? {
            if let asset { return asset.uuidString }
            if let folder { return "folder:" + folder }
            if let loose { return "file:" + loose }
            if let file { return "script:" + file }
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            folderTree
                .frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 96), spacing: Space.sm)], alignment: .leading, spacing: Space.sm) {
                        ForEach(items) { cell($0) }
                    }
                    .padding(Space.md)
                }
                .overlay {
                    if items.isEmpty {
                        Text(filter.isEmpty ? "Empty folder. Use Create, or drag assets here." : "No matches.")
                            .foregroundStyle(.secondary).font(Typo.label)
                    }
                }
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { drop($0, to: model.currentFolder) }
                .contextMenu { createMenuItems }
            }
        }
        .id("\(model.artVersion)-\(model.folderVersion)")
    }

    // MARK: Folder tree

    var folderTree: some View {
        List(selection: Binding(get: { model.currentFolder }, set: { if let v = $0 { model.currentFolder = v } })) {
            OutlineGroup(FolderNode.tree(model.folders), children: \.children) { node in
                Label(node.name, systemImage: node.path == "scripts" ? "curlybraces.square" : "folder")
                    .padding(.vertical, Space.xs)
                    .background(dropTarget == node.path ? Tone.dropTarget : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                    .tag(node.path)
                    .draggable(node.path == "assets" || node.path == "scripts" ? "" : "folder:" + node.path)
                    .onDrop(of: [.fileURL, .plainText], isTargeted: Binding(get: { dropTarget == node.path },
                                                                            set: { dropTarget = $0 ? node.path : (dropTarget == node.path ? nil : dropTarget) })) {
                        drop($0, to: node.path)
                    }
                    .contextMenu { folderMenu(node.path) }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder func folderMenu(_ path: String) -> some View {
        Button("New Folder Inside…") { model.createFolder(in: path) }
        if path != "assets" && path != "scripts" {
            Button("Rename…") { model.renameFolder(path) }
            Divider()
            Button("Move to Trash…", role: .destructive) { model.trashFolder(path) }
        }
        Divider()
        Button("Show in Finder") { if let p = model.project { NSWorkspace.shared.activateFileViewerSelecting([p.url(path)]) } }
    }

    // MARK: Toolbar with breadcrumb

    var toolbar: some View {
        HStack(spacing: Space.xs) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, crumb in
                if i > 0 { Image(systemName: "chevron.right").font(Typo.caption).foregroundStyle(.tertiary) }
                Button(crumb.name) { model.currentFolder = crumb.path }
                    .buttonStyle(.plain)
                    .font(Typo.label.weight(i == crumbs.count - 1 ? .semibold : .regular))
                    .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { drop($0, to: crumb.path) }
            }
            Spacer()
            Menu { createMenuItems } label: { Label("Create", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
            TextField("Search all", text: $filter).textFieldStyle(.roundedBorder).frame(width: 150).controlSize(.small)
            Button { if let p = model.project { NSWorkspace.shared.activateFileViewerSelecting([p.url(model.currentFolder)]) } } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless).help("Show in Finder")
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
    }

    var crumbs: [(name: String, path: String)] {
        let parts = model.currentFolder.split(separator: "/").map(String.init)
        return parts.indices.map { i in
            let path = parts[0...i].joined(separator: "/")
            return (i == 0 ? (path == "scripts" ? "Scripts" : "Assets") : parts[i], path)
        }
    }

    @ViewBuilder var createMenuItems: some View {
        Button("Folder…") { model.createFolder() }
        Divider()
        Button("Script…") { model.createScript() }
        Button("Scene") { model.createScene() }
        Button("Prefab") { model.createPrefab() }
        Menu("Ready-made Prefab") {
            ForEach(EditorModel.Premade.allCases, id: \.self) { k in
                Button(k.rawValue) { if let id = model.premadePrefab(k) { model.selection = .asset(id) } }
            }
        }
        Button("Platformer Settings") { model.createPlatformer() }
        Divider()
        Button("Dialogue") { model.createDialogue() }
        Button("Speaker") { model.createSpeaker() }
        Button("Text Box Style") { model.createTextBox() }
        Divider()
        Button("Import Sprite Sheet…") { model.importImage(asTileset: false) }
        Button("Import Tileset…") { model.importImage(asTileset: true) }
    }

    // MARK: Contents

    var items: [Item] {
        guard let p = model.project else { return [] }
        let folder = model.currentFolder
        let searching = !filter.isEmpty
        func here(_ path: String) -> Bool { searching ? true : (path as NSString).deletingLastPathComponent == folder }
        func match(_ n: String) -> Bool { !searching || n.localizedCaseInsensitiveContains(filter) }
        func thumb(_ path: String, _ image: String, _ w: Int, _ h: Int) -> Bitmap? {
            model.art.frames(p.imageURL(assetPath: path, image: image), w: w, h: h).first
        }

        var out: [Item] = []
        if !searching {
            for f in model.folders where (f as NSString).deletingLastPathComponent == folder {
                out.append(Item(id: "folder:" + f, name: (f as NSString).lastPathComponent, icon: "folder.fill", kind: "Folder", folder: f))
            }
        }
        for (id, s) in p.scenes where here(s.path) && match(s.name) {
            out.append(Item(id: id.uuidString, name: s.name, icon: id == p.settings.startScene ? "flag.checkered" : "square.on.square", kind: "Scene", asset: id))
        }
        for (id, s) in p.prefabs where here(s.path) && match(s.name) {
            var it = Item(id: id.uuidString, name: s.name, icon: "cube.fill", kind: "Prefab", asset: id)
            if let sid = s.value.def.sprite?.sprite, let sp = p.sprites[sid] {
                it.thumb = thumb(sp.path, sp.value.image, sp.value.frameWidth, sp.value.frameHeight)
            }
            out.append(it)
        }
        for (id, s) in p.sprites where here(s.path) && match(s.name) {
            out.append(Item(id: id.uuidString, name: s.name, icon: "photo", kind: "Sprite", asset: id,
                            thumb: thumb(s.path, s.value.image, s.value.frameWidth, s.value.frameHeight)))
        }
        for (id, s) in p.tilesets where here(s.path) && match(s.name) {
            out.append(Item(id: id.uuidString, name: s.name, icon: "square.grid.3x3.fill", kind: "Tileset", asset: id,
                            thumb: model.art.bitmap(p.imageURL(assetPath: s.path, image: s.value.image))))
        }
        for (id, s) in p.dialogues where here(s.path) && match(s.name) {
            out.append(Item(id: id.uuidString, name: s.name, icon: "text.bubble", kind: "Dialogue", asset: id))
        }
        for (id, s) in p.speakers where here(s.path) && match(s.name) {
            var it = Item(id: id.uuidString, name: s.name, icon: "person.crop.square", kind: "Speaker", asset: id)
            if let pid = s.value.portrait, let sp = p.sprites[pid] { it.thumb = thumb(sp.path, sp.value.image, sp.value.frameWidth, sp.value.frameHeight) }
            out.append(it)
        }
        for (id, s) in p.textboxes where here(s.path) && match(s.name) {
            out.append(Item(id: id.uuidString, name: s.name, icon: "rectangle.bottomthird.inset.filled", kind: "Text Box", asset: id))
        }
        for (id, s) in p.fonts where here(s.path) && match(s.name) {
            out.append(Item(id: id.uuidString, name: s.name, icon: "textformat", kind: "Font", asset: id))
        }
        for (id, s) in p.platformers where here(s.path) && match(s.name) {
            out.append(Item(id: id.uuidString, name: s.name, icon: "figure.run", kind: "Platformer", asset: id))
        }
        for sc in p.scripts {
            let rel = p.relative(sc.file)
            if here(rel) && match(sc.name) {
                out.append(Item(id: "script:" + sc.name, name: sc.name, icon: "curlybraces", kind: "Script", script: sc.name, file: rel))
            }
        }
        for snd in p.sounds() where here(snd.path) && match(snd.name) {
            out.append(Item(id: "file:" + snd.path, name: snd.name, icon: "speaker.wave.2.fill", kind: "Sound", loose: snd.path))
        }
        for rel in model.looseImages where here(rel) && match((rel as NSString).lastPathComponent) {
            out.append(Item(id: "file:" + rel, name: (rel as NSString).lastPathComponent, icon: "photo.badge.plus", kind: "Image",
                            loose: rel, thumb: model.art.bitmap(p.url(rel))))
        }
        let order = ["Folder": 0, "Scene": 1, "Prefab": 2, "Script": 3, "Dialogue": 4, "Speaker": 5, "Sprite": 6, "Tileset": 7,
                     "Text Box": 8, "Font": 9, "Platformer": 10, "Sound": 11, "Image": 12]
        return out.sorted { (order[$0.kind] ?? 9, $0.name.lowercased()) < (order[$1.kind] ?? 9, $1.name.lowercased()) }
    }

    func isSelected(_ it: Item) -> Bool {
        if model.projectSelection.contains(it.id) { return true }
        if let l = it.loose { return model.selection == .file(l) }
        if let a = it.asset { return model.selection == .asset(a) }
        if let s = it.script { return model.selection == .script(s) }
        return false
    }

    @ViewBuilder func cell(_ it: Item) -> some View {
        let view = VStack(spacing: Space.xs) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.control).fill(Color.primary.opacity(it.kind == "Folder" ? 0 : 0.06))
                if let t = it.thumb { PixelImage(bitmap: t).padding(Space.sm) }
                else {
                    Image(systemName: it.icon).font(.system(size: it.kind == "Folder" ? 32 : 24))
                        .foregroundStyle(it.kind == "Prefab" ? Tone.prefab : it.kind == "Folder" ? Tone.accent : .secondary)
                }
            }
            .frame(width: 56, height: 56)
            Text(it.name).font(Typo.caption).lineLimit(2).multilineTextAlignment(.center)
            if it.loose != nil && it.kind == "Image" { Text("not imported").font(Typo.caption).foregroundStyle(Tone.warning) }
            if !filter.isEmpty, let path = it.asset.flatMap({ model.assetPath($0) }) ?? it.file {
                Text((path as NSString).deletingLastPathComponent).font(Typo.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(width: 84)
        .padding(Space.xs)
        .background(isSelected(it) || (it.folder != nil && dropTarget == it.folder) ? Tone.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(it) }
        .onTapGesture { select(it) }
        .contextMenu { itemMenu(it) }
        .help(it.kind)
        if let folder = it.folder {
            view.draggable(it.payload ?? "")
                .onDrop(of: [.fileURL, .plainText], isTargeted: Binding(get: { dropTarget == folder },
                                                                        set: { dropTarget = $0 ? folder : (dropTarget == folder ? nil : dropTarget) })) {
                    drop($0, to: folder)
                }
        } else if let payload = it.payload {
            view.draggable(payload)
        } else {
            view
        }
    }

    @ViewBuilder func itemMenu(_ it: Item) -> some View {
        if let folder = it.folder {
            folderMenu(folder)
        } else if let l = it.loose, it.kind == "Sound" {
            Button("Play") { model.previewSound(l) }
            if model.openScene != nil { Button("Use as This Scene's Music") { model.checkpoint(); model.updateScene { $0.music = it.name } } }
            Divider()
            Button("Show in Finder") { if let p = model.project { NSWorkspace.shared.activateFileViewerSelecting([p.url(l)]) } }
            Button("Move to Trash", role: .destructive) { model.trashFile(l) }
        } else if let l = it.loose {
            Button("Use as Sprite") { model.useImage(l, asTileset: false) }
            Button("Use as Tileset") { model.useImage(l, asTileset: true) }
            Divider()
            Button("Show in Finder") { if let p = model.project { NSWorkspace.shared.activateFileViewerSelecting([p.url(l)]) } }
            Button("Move to Trash", role: .destructive) { model.trashFile(l) }
        } else {
            Button("Open") { open(it) }
            if let a = it.asset, model.project?.prefabs[a] != nil {
                Button("Add to Scene") { model.instantiate(prefab: a) }
            }
            if let file = it.file, let p = model.project {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url(file)]) }
            }
            if let a = it.asset, let path = model.assetPath(a), let p = model.project {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url(path)]) }
                Divider()
                Button("Delete…", role: .destructive) { model.deleteAsset(a) }
            }
        }
    }

    /// Drops: files from Finder are copied in; items dragged inside the panel are moved
    func drop(_ providers: [NSItemProvider], to folder: String) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.importFiles([url], to: folder) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSString.self) { s, _ in
                    guard let s = s as? String else { return }
                    Task { @MainActor in model.move(s, to: folder) }
                }
            }
        }
        return handled
    }

    /// Click: select one. Shift-click: everything from the last click to here. Cmd-click: add or remove one.
    func select(_ it: Item) {
        model.focusArea = .project
        let mods = NSEvent.modifierFlags
        let ids = items.map(\.id)
        if mods.contains(.shift), let anchor = model.projectAnchor, let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: it.id) {
            model.projectSelection = Set(ids[min(a, b)...max(a, b)])
        } else if mods.contains(.command) {
            if model.projectSelection.contains(it.id) { model.projectSelection.remove(it.id) } else { model.projectSelection.insert(it.id) }
            model.projectAnchor = it.id
        } else {
            model.projectSelection = [it.id]
            model.projectAnchor = it.id
        }
        if let l = it.loose { model.selection = .file(l) }
        if let a = it.asset { model.selection = .asset(a) }
        if let s = it.script { model.selection = .script(s) }
    }

    func open(_ it: Item) {
        guard let p = model.project else { return }
        if let f = it.folder { model.currentFolder = f; filter = ""; return }
        if let l = it.loose { model.selection = .file(l); if it.kind == "Sound" { model.previewSound(l) }; return }
        if let s = it.script, let info = p.script(s) { ExternalEditor.open(info.file, line: info.line, workspace: p.root); return }
        guard let a = it.asset else { return }
        if p.scenes[a] != nil { model.openSceneAsset(a) }
        else if p.prefabs[a] != nil || p.speakers[a] != nil || p.fonts[a] != nil { model.selection = .asset(a) }
        else { model.selection = .asset(a); model.center = .asset(a) }
    }
}

struct ConsoleView: View {
    @EnvironmentObject var model: EditorModel
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Raw build log", isOn: $showLog).toggleStyle(.checkbox).controlSize(.small)
                Spacer()
                Button("Clear") { model.diagnostics = []; model.buildLog = "" }.controlSize(.small)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs)
            if showLog {
                ScrollView {
                    Text(model.buildLog.isEmpty ? "No build yet." : model.buildLog)
                        .font(Typo.mono).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Space.sm)
                }
            } else if model.diagnostics.isEmpty {
                Text(model.buildLog.isEmpty ? "Press Play to build. Errors and warnings show up here." : "No problems.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.diagnostics.filter { $0.severity != .note }) { d in
                    Button { open(d) } label: {
                        HStack(alignment: .top, spacing: Space.sm) {
                            Image(systemName: d.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(d.severity == .error ? Tone.danger : Tone.warning)
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(d.message).textSelection(.enabled)
                                if let f = d.file {
                                    Text("\(URL(fileURLWithPath: f).lastPathComponent):\(d.line ?? 0)").font(Typo.mono).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    func open(_ d: Diagnostic) {
        guard let f = d.file else { return }
        ExternalEditor.open(URL(fileURLWithPath: f), line: d.line, workspace: model.project?.root)
    }
}
