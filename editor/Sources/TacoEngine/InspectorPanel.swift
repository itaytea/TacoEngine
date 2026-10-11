import AppKit
import EngineKit
import SwiftUI

struct InspectorPanel: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Inspector", icon: "slider.horizontal.3")
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    content
                }
                .padding(Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder var content: some View {
        switch model.selection {
        case .entity(let id):
            if model.entitySelection.count > 1 { MultiEntityInspector() }
            else if model.entity(id) != nil { EntityInspector(id: id) } else { SceneInspector() }
        case .asset(let id):
            AssetInspector(id: id)
        case .script(let name):
            ScriptInspector(name: name)
        case .projectSettings:
            ProjectSettingsInspector()
        case .file(let rel):
            if GameProject.audioExtensions.contains((rel as NSString).pathExtension.lowercased()) { SoundInspector(rel: rel) }
            else { LooseFileInspector(rel: rel) }
        case .none:
            SceneInspector()
        }
    }
}

// MARK: - Shared rows

struct InspectorSection<Content: View, Actions: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 10)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                Text(title).font(Typo.heading)
                Spacer()
                actions
            }
            if expanded { content.padding(.leading, Space.xs) }
        }
        .padding(Space.md)
        .background(Tone.well, in: RoundedRectangle(cornerRadius: Radius.control))
    }
}

extension InspectorSection where Actions == EmptyView {
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, icon: icon, actions: { EmptyView() }, content: content)
    }
}

/// Label that turns bold+blue when the value overrides the prefab
struct PropLabel: View {
    let text: String
    var overridden = false
    var body: some View {
        Text(text)
            .fontWeight(overridden ? .bold : .regular)
            .foregroundStyle(overridden ? Tone.prefab : .secondary)
            .frame(width: 92, alignment: .leading)
            .help(overridden ? "Overrides the prefab's value" : "")
    }
}

struct AssetPicker: View {
    @EnvironmentObject var model: EditorModel
    let kind: AssetKind
    @Binding var selection: UUID?
    var allowNone = true

    var options: [(UUID, String)] {
        guard let p = model.project else { return [] }
        let dict: [UUID: String]
        switch kind {
        case .sprite: dict = p.sprites.mapValues(\.name)
        case .tileset: dict = p.tilesets.mapValues(\.name)
        case .prefab: dict = p.prefabs.mapValues(\.name)
        case .scene: dict = p.scenes.mapValues(\.name)
        case .platformer: dict = p.platformers.mapValues(\.name)
        case .dialogue: dict = p.dialogues.mapValues(\.name)
        case .speaker: dict = p.speakers.mapValues(\.name)
        case .textbox: dict = p.textboxes.mapValues(\.name)
        case .font: dict = p.fonts.mapValues(\.name)
        }
        return dict.map { ($0.key, $0.value) }.sorted { $0.1 < $1.1 }
    }

    var body: some View {
        Picker("", selection: $selection) {
            if allowNone { Text("None").tag(UUID?.none) }
            ForEach(options, id: \.0) { id, name in Text(name).tag(UUID?.some(id)) }
        }
        .labelsHidden()
    }
}

// MARK: - Entity

struct EntityInspector: View {
    @EnvironmentObject var model: EditorModel
    let id: UUID

    var body: some View {
        if let e = model.entity(id) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    Image(systemName: e.prefab != nil ? "cube.fill" : "cube").foregroundStyle(e.prefab != nil ? Tone.prefab : .secondary)
                    TextField("Name", text: Binding(get: { e.name }, set: { v in model.checkpoint(); model.updateEntity(id) { $0.name = v } }))
                        .textFieldStyle(.roundedBorder).font(Typo.title)
                }
                HStack {
                    PropLabel(text: "Position")
                    IntField(label: "X", value: Binding(get: { e.x }, set: { v in model.checkpoint(); model.updateEntity(id) { $0.x = v } }))
                    IntField(label: "Y", value: Binding(get: { e.y }, set: { v in model.checkpoint(); model.updateEntity(id) { $0.y = v } }))
                }
                if let pid = e.prefab {
                    HStack(spacing: Space.sm) {
                        Text("Prefab").foregroundStyle(.secondary)
                        Button(model.project?.prefabs[pid]?.name ?? "missing") { model.selection = .asset(pid) }.buttonStyle(.link)
                        Spacer()
                        Menu("Overrides") {
                            Button("Apply All to Prefab") { model.applyOverridesToPrefab(id) }.disabled(e.overrides == nil)
                            Button("Revert All") { model.revertOverrides(id) }.disabled(e.overrides == nil)
                            Divider()
                            Button("Unpack Prefab") { model.unpack(id) }
                        }
                        .fixedSize()
                    }
                    .font(Typo.label)
                }
                Divider()
                DefEditor(def: Binding(get: { model.def(e) }, set: { model.checkpoint(); model.setDef(id, $0) }),
                          overrides: e.overrides, entityID: id)
            }
        }
    }
}

/// Edits the components of an entity or prefab
struct DefEditor: View {
    @EnvironmentObject var model: EditorModel
    @Binding var def: EntityDef
    var overrides: JSON?
    var entityID: UUID?

    func over(_ path: String...) -> Bool { overrides?.contains(path: path) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                PropLabel(text: "Tag", overridden: over("tag"))
                Picker("", selection: $def.tag) {
                    Text("Untagged").tag("")
                    ForEach(model.project?.settings.tags ?? [], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            if def.sprite != nil { spriteSection }
            if def.collider != nil { colliderSection }
            if def.platformer != nil { platformerSection }
            ForEach(def.scripts.indices, id: \.self) { i in scriptSection(i) }
            addComponentMenu
        }
    }

    var spriteSection: some View {
        let comp = Binding(get: { def.sprite ?? SpriteComponent() }, set: { def.sprite = $0 })
        let anims = comp.wrappedValue.sprite.flatMap { model.project?.sprites[$0]?.value.animations.map(\.name) } ?? []
        return InspectorSection(title: "Sprite", icon: "photo", actions: { remove { def.sprite = nil } }) {
            HStack { PropLabel(text: "Sprite", overridden: over("sprite", "sprite")); AssetPicker(kind: .sprite, selection: comp.sprite) }
            HStack {
                PropLabel(text: "Animation", overridden: over("sprite", "animation"))
                Picker("", selection: Binding(get: { comp.wrappedValue.animation }, set: { comp.wrappedValue.animation = $0 })) {
                    if !anims.contains(comp.wrappedValue.animation) { Text(comp.wrappedValue.animation.isEmpty ? "(first)" : comp.wrappedValue.animation).tag(comp.wrappedValue.animation) }
                    ForEach(anims, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            HStack {
                PropLabel(text: "Flip X", overridden: over("sprite", "flipX"))
                Toggle("", isOn: comp.flipX).labelsHidden()
                Spacer()
                Text("Hidden").foregroundStyle(over("sprite", "hidden") ? Tone.prefab : .secondary)
                Toggle("", isOn: comp.hidden).labelsHidden()
            }
            HStack {
                PropLabel(text: "Layer", overridden: over("sprite", "priority"))
                Picker("", selection: comp.priority) {
                    Text("Front").tag(1)
                    Text("With tiles").tag(2)
                    Text("Behind tiles").tag(3)
                }
                .labelsHidden()
            }
            if let sid = comp.wrappedValue.sprite {
                Button("Edit Sprite…") { model.selection = .asset(sid); model.center = .asset(sid) }.controlSize(.small)
            }
        }
    }

    var colliderSection: some View {
        let c = Binding(get: { def.collider ?? ColliderComponent() }, set: { def.collider = $0 })
        return InspectorSection(title: "Collider", icon: "square.dashed", actions: { remove { def.collider = nil } }) {
            HStack {
                PropLabel(text: "Offset", overridden: over("collider", "x") || over("collider", "y"))
                IntField(label: "X", value: c.x)
                IntField(label: "Y", value: c.y)
            }
            HStack {
                PropLabel(text: "Size", overridden: over("collider", "w") || over("collider", "h"))
                IntField(label: "W", value: c.w)
                IntField(label: "H", value: c.h)
            }
            HStack {
                PropLabel(text: "Type", overridden: over("collider", "trigger") || over("collider", "platform"))
                Picker("", selection: Binding(get: { c.wrappedValue.trigger ? 1 : c.wrappedValue.platform ? 2 : 0 },
                                              set: { v in var n = c.wrappedValue; n.trigger = v == 1; n.platform = v == 2; c.wrappedValue = n })) {
                    Text("Hitbox").tag(0)
                    Text("Trigger").tag(1)
                    Text("Platform").tag(2)
                }
                .labelsHidden()
                .help("Hitbox: collides with tiles. Trigger: sends OnTrigger. Platform: one-way, others can stand on its top edge.")
            }
            HStack {
                Spacer()
                Button("Fit to Sprite") { fitCollider() }.controlSize(.small).disabled(def.sprite?.sprite == nil)
            }
        }
    }

    func fitCollider() {
        guard let sid = def.sprite?.sprite, let p = model.project, let s = p.sprites[sid] else { return }
        let frames = model.art.frames(p.imageURL(assetPath: s.path, image: s.value.image), w: s.value.frameWidth, h: s.value.frameHeight)
        guard let f = frames.first else { return }
        var minX = f.width, minY = f.height, maxX = -1, maxY = -1
        for y in 0..<f.height { for x in 0..<f.width where f[x, y].isOpaque { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        guard maxX >= 0 else { return }
        var c = def.collider ?? ColliderComponent()
        c.x = minX - s.value.pivotX
        c.y = minY - s.value.pivotY
        c.w = maxX - minX + 1
        c.h = maxY - minY + 1
        def.collider = c
    }

    var platformerSection: some View {
        let c = Binding(get: { def.platformer ?? PlatformerComponent() }, set: { def.platformer = $0 })
        return InspectorSection(title: "Platformer Body", icon: "figure.run", actions: { remove { def.platformer = nil } }) {
            HStack { PropLabel(text: "Settings", overridden: over("platformer", "settings")); AssetPicker(kind: .platformer, selection: c.settings) }
            HStack { PropLabel(text: "D-pad control", overridden: over("platformer", "joypad")); Toggle("", isOn: c.joypad).labelsHidden() }
            if let sid = c.wrappedValue.settings {
                Button("Tune Movement…") { model.selection = .asset(sid); model.center = .asset(sid) }.controlSize(.small)
            }
        }
    }

    func scriptSection(_ i: Int) -> some View {
        let comp = def.scripts[i]
        let info = model.project?.script(comp.script)
        return InspectorSection(title: comp.script, icon: "curlybraces", actions: {
            if let info {
                Button { ExternalEditor.open(info.file, line: info.line, workspace: model.project?.root) } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("Open \(info.file.lastPathComponent)")
            }
            remove { def.scripts.remove(at: i) }
        }) {
            if let info {
                let visible = info.fields.filter { $0.kind != .hidden }
                if visible.isEmpty { Text("No fields").font(Typo.caption).foregroundStyle(.secondary) }
                ForEach(visible) { f in
                    fieldRow(f, scriptIndex: i)
                }
            } else {
                Label("Script \"\(comp.script)\" not found in scripts/", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.warning).font(Typo.label)
            }
        }
    }

    @ViewBuilder func fieldRow(_ f: ScriptField, scriptIndex i: Int) -> some View {
        // Overrides of a script are keyed by its name ("@Name"); older projects used its position
        let scriptKey = def.scripts.indices.contains(i) ? "@" + def.scripts[i].script : String(i)
        let isOver = over("scripts", scriptKey, "fields", f.name) || over("scripts", String(i), "fields", f.name)
        let value = Binding<JSON?>(
            get: { def.scripts.indices.contains(i) ? (def.scripts[i].fields[f.name] ?? f.defaultValue) : nil },
            set: { v in if def.scripts.indices.contains(i) { def.scripts[i].fields[f.name] = v } })
        HStack {
            PropLabel(text: f.name, overridden: isOver).help(f.help)
            switch f.kind {
            case .int:
                TextField("", value: Binding(get: { Int(value.wrappedValue?.number ?? 0) }, set: { value.wrappedValue = .number(Double($0)) }), format: .number)
                    .textFieldStyle(.roundedBorder)
            case .fixed:
                TextField("", value: Binding(get: { value.wrappedValue?.number ?? 0 }, set: { value.wrappedValue = .number($0) }),
                          format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder)
            case .bool:
                Toggle("", isOn: Binding(get: { value.wrappedValue?.bool ?? false }, set: { value.wrappedValue = .bool($0) })).labelsHidden()
                Spacer()
            case .scene, .prefab, .sprite, .dialogue:
                let kind: AssetKind = f.kind == .scene ? .scene : f.kind == .prefab ? .prefab : f.kind == .dialogue ? .dialogue : .sprite
                AssetPicker(kind: kind, selection: Binding(get: { resolve(value.wrappedValue) }, set: { value.wrappedValue = .string($0?.uuidString ?? "") }))
            case .sound:
                SoundPicker(selection: Binding(get: { value.wrappedValue?.string.flatMap { $0.isEmpty ? nil : $0 } },
                                               set: { value.wrappedValue = .string($0 ?? "") }))
            case .entity:
                Picker("", selection: Binding(get: { value.wrappedValue?.string.flatMap(UUID.init(uuidString:)) },
                                              set: { value.wrappedValue = .string($0?.uuidString ?? "") })) {
                    Text("None").tag(UUID?.none)
                    ForEach(model.scene?.entities ?? []) { e in Text(e.name).tag(UUID?.some(e.guid)) }
                }
                .labelsHidden()
                .disabled(entityID == nil)
            case .hidden:
                EmptyView()
            }
        }
    }

    /// Field values can be a UUID or (for defaults) an asset name
    func resolve(_ v: JSON?) -> UUID? {
        guard let s = v?.string, !s.isEmpty else { return nil }
        return UUID(uuidString: s) ?? model.project?.asset(named: s)
    }

    func remove(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove component")
    }

    var addComponentMenu: some View {
        Menu {
            if def.sprite == nil { Button("Sprite") { def.sprite = SpriteComponent(sprite: model.project?.sprites.keys.first) } }
            if def.collider == nil { Button("Collider") { def.collider = ColliderComponent() } }
            if def.platformer == nil {
                Button("Platformer Controller (preset)") { def = model.withPlatformerController(def) }
                Button("Platformer Body only") { def.platformer = PlatformerComponent(settings: model.ensurePlatformerSettings()) }
            }
            if !def.scripts.contains(where: { $0.script == "Talk" }) {
                Button("Talk (preset)") { def = model.withTalk(def) }
            }
            Menu("Script") {
                ForEach(model.project?.scripts ?? []) { s in
                    Button(s.name) { def.scripts.append(ScriptComponent(script: s.name, fields: s.defaultFields())) }
                }
                Divider()
                Button("New Script…") { model.createScript() }
            }
        } label: {
            Label("Add Component", systemImage: "plus")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Scene

struct SceneInspector: View {
    @EnvironmentObject var model: EditorModel
    @State private var newW = 0
    @State private var newH = 0

    var body: some View {
        if let id = model.openScene, let stored = model.project?.scenes[id] {
            let s = stored.value
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    Image(systemName: "square.on.square").foregroundStyle(Color.accentColor)
                    RenameField(id: id, name: stored.name)
                }
                if model.project?.settings.startScene == id {
                    Label("Start scene", systemImage: "flag.checkered").foregroundStyle(Tone.success).font(Typo.label)
                } else {
                    Button("Make Start Scene") { model.edit { $0.settings.startScene = id } }.controlSize(.small)
                }
                InspectorSection(title: "Map", icon: "square.grid.3x3") {
                    HStack {
                        PropLabel(text: "Size (tiles)")
                        IntField(label: "W", value: $newW)
                        IntField(label: "H", value: $newH)
                        Button("Apply") {
                            model.checkpoint()
                            model.updateScene { $0.resize(width: newW, height: newH) }
                        }
                        .controlSize(.small).disabled(newW == s.width && newH == s.height)
                    }
                    HStack {
                        PropLabel(text: "Tileset")
                        AssetPicker(kind: .tileset, selection: Binding(get: { s.tileset }, set: { v in model.checkpoint(); model.updateScene { $0.tileset = v } }))
                    }
                    HStack {
                        PropLabel(text: "Background")
                        ColorPicker("", selection: Binding(get: { Color(hex: s.background) },
                                                           set: { c in model.checkpoint(); model.updateScene { $0.background = c.hexString } }), supportsOpacity: false).labelsHidden()
                    }
                }
                InspectorSection(title: "Music", icon: "music.note") {
                    HStack {
                        PropLabel(text: "Plays")
                        SoundPicker(selection: Binding(get: { s.music }, set: { v in model.checkpoint(); model.updateScene { $0.music = v } }),
                                    noneLabel: "Silence")
                    }
                }
                InspectorSection(title: "Camera", icon: "video") {
                    HStack {
                        PropLabel(text: "Mode")
                        Picker("", selection: Binding(get: { s.cameraMode }, set: { v in model.checkpoint(); model.updateScene { $0.cameraMode = v } })) {
                            Text("Follow").tag(CameraMode.follow)
                            Text("Screen by screen").tag(CameraMode.screens)
                            Text("Fixed").tag(CameraMode.fixed)
                        }
                        .labelsHidden()
                        .help(cameraHelp(s.cameraMode))
                    }
                    HStack {
                        PropLabel(text: "Target")
                        Picker("", selection: Binding(get: { s.cameraTarget }, set: { v in model.checkpoint(); model.updateScene { $0.cameraTarget = v } })) {
                            Text("None").tag(UUID?.none)
                            ForEach(s.entities) { e in Text(e.name).tag(UUID?.some(e.guid)) }
                        }
                        .labelsHidden()
                    }
                }
                Text("\(s.entities.count) entities · scene index \(model.project?.sceneIndex(id) ?? 0) (SCENE_\(cIdentifier(stored.name)))")
                    .font(Typo.caption).foregroundStyle(.secondary)
            }
            .onAppear { newW = s.width; newH = s.height }
            .onChange(of: model.openScene) { _, _ in if let sc = model.scene { newW = sc.width; newH = sc.height } }
        } else {
            Text("Nothing selected").foregroundStyle(.secondary)
        }
    }

    func cameraHelp(_ m: CameraMode) -> String {
        switch m {
        case .follow: "Smoothly follows the target, staying inside the scene."
        case .screens: "Celeste-style: the camera slides one screen at a time when the target leaves the screen (orange lines). The world pauses during the slide."
        case .fixed: "Stays at the top-left of the scene."
        }
    }
}

struct RenameField: View {
    @EnvironmentObject var model: EditorModel
    let id: UUID
    let name: String
    @State private var text = ""
    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder).font(Typo.title)
            .onSubmit { if text != name { model.renameAsset(id, to: text) } }
            .onAppear { text = name }
            .onChange(of: name) { _, n in text = n }
            .help("Press Return to rename")
    }
}

// MARK: - Assets

struct AssetInspector: View {
    @EnvironmentObject var model: EditorModel
    let id: UUID

    var body: some View {
        if let p = model.project {
            VStack(alignment: .leading, spacing: Space.md) {
                if let s = p.sprites[id] { header("photo", "Sprite"); sprite(s) }
                else if let t = p.tilesets[id] { header("square.grid.3x3.fill", "Tileset"); tileset(t) }
                else if p.prefabs[id] != nil { header("cube.fill", "Prefab"); prefab() }
                else if p.scenes[id] != nil { header("square.on.square", "Scene"); sceneAsset() }
                else if let pl = p.platformers[id] { header("figure.run", "Platformer Settings"); platformer(pl.value) }
                else if p.dialogues[id] != nil { header("text.bubble", "Dialogue"); dialogueAsset() }
                else if p.speakers[id] != nil { header("person.crop.square", "Speaker"); SpeakerInspector(id: id) }
                else if p.textboxes[id] != nil { header("rectangle.bottomthird.inset.filled", "Text Box Style"); TextBoxInspector(id: id) }
                else if let f = p.fonts[id] { header("textformat", "Font"); fontAsset(f) }
                else { Text("Missing asset").foregroundStyle(.secondary) }
            }
        }
    }

    func header(_ icon: String, _ kind: String) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel(kind)
            HStack {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                RenameField(id: id, name: model.project?.name(of: id) ?? "")
            }
        }
    }

    func sprite(_ s: Stored<SpriteAsset>) -> some View {
        let url = model.project!.imageURL(assetPath: s.path, image: s.value.image)
        return VStack(alignment: .leading, spacing: Space.md) {
            PixelImage(bitmap: model.art.bitmap(url)).frame(maxWidth: .infinity, maxHeight: 120).background(Checkerboard()).clipShape(RoundedRectangle(cornerRadius: Radius.control))
            Text("\(s.value.image) · frames \(s.value.frameWidth)×\(s.value.frameHeight) · \(s.value.animations.count) animations")
                .font(Typo.caption).foregroundStyle(.secondary)
            HStack(spacing: Space.sm) {
                Button("Open Sprite Editor") { model.center = .asset(id) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            usage
        }
    }

    func tileset(_ t: Stored<TilesetAsset>) -> some View {
        let url = model.project!.imageURL(assetPath: t.path, image: t.value.image)
        return VStack(alignment: .leading, spacing: Space.md) {
            PixelImage(bitmap: model.art.bitmap(url)).frame(maxWidth: .infinity, maxHeight: 120).background(Checkerboard()).clipShape(RoundedRectangle(cornerRadius: Radius.control))
            Text("\(t.value.image) · 16×16 tiles").font(Typo.caption).foregroundStyle(.secondary)
            HStack(spacing: Space.sm) {
                Button("Open Tileset Editor") { model.center = .asset(id) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    func prefab() -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            DefEditor(def: Binding(get: { model.project?.prefabs[id]?.value.def ?? EntityDef() },
                                   set: { v in model.checkpoint(); model.project?.prefabs[id]?.value.def = v }),
                      overrides: nil, entityID: nil)
            Button("Add to Scene") { model.instantiate(prefab: id) }.disabled(model.scene == nil)
            usage
        }
    }

    func dialogueAsset() -> some View {
        let d = model.project?.dialogues[id]?.value
        return VStack(alignment: .leading, spacing: Space.md) {
            Text("\(d?.lines.count ?? 0) lines").foregroundStyle(.secondary)
            Button("Open Dialogue Editor") { model.center = .asset(id) }
        }
    }

    func fontAsset(_ f: Stored<FontAsset>) -> some View {
        let url = model.project!.imageURL(assetPath: f.path, image: f.value.image)
        return VStack(alignment: .leading, spacing: Space.md) {
            PixelImage(bitmap: model.art.bitmap(url)).frame(maxHeight: 120).background(Color.black).clipShape(RoundedRectangle(cornerRadius: Radius.control))
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    func sceneAsset() -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Button("Open Scene") { model.openSceneAsset(id) }
                if model.project?.settings.startScene != id {
                    Button("Make Start Scene") { model.edit { $0.settings.startScene = id } }
                }
            }
        }
    }

    func platformer(_ v: PlatformerSettings) -> some View {
        let a = PhysicsSim.arc(v)
        return VStack(alignment: .leading, spacing: Space.md) {
            Text(String(format: "Top speed %.1f tiles/s · jump %.1f tiles · airtime %.2f s", v.runSpeed * 60 / 16, a.apexHeight / 16, a.landTime / 60))
                .font(Typo.caption).foregroundStyle(.secondary)
            Button("Open Movement Graphs") { model.center = .asset(id) }
            usage
        }
    }

    @ViewBuilder var usage: some View {
        if let p = model.project {
            let prefabs = p.prefabs.values.filter { s in
                let d = s.value.def
                return d.sprite?.sprite == id || d.platformer?.settings == id || s.value.guid == id
            }.map(\.name).sorted()
            if !prefabs.isEmpty && p.prefabs[id] == nil {
                Text("Used by: " + prefabs.joined(separator: ", ")).font(Typo.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Script

struct ScriptInspector: View {
    @EnvironmentObject var model: EditorModel
    let name: String

    var body: some View {
        if let s = model.project?.script(name) {
            VStack(alignment: .leading, spacing: Space.md) {
                SectionLabel("SCRIPT")
                Label(s.name, systemImage: "curlybraces").font(Typo.title)
                Text(s.file.lastPathComponent).font(Typo.mono).foregroundStyle(.secondary)
                Button("Open in Code Editor") { ExternalEditor.open(s.file, line: s.line, workspace: model.project?.root) }
                InspectorSection(title: "Callbacks", icon: "bolt") {
                    ForEach(ScriptInfo.callbackNames.filter { s.callbacks.contains($0) }, id: \.self) { cb in
                        Text("\(s.name)_\(cb)").font(Typo.code)
                    }
                }
                InspectorSection(title: "Fields", icon: "list.bullet") {
                    if s.fields.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(s.fields) { f in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            HStack {
                                Text(f.name).font(Typo.code.weight(.semibold))
                                Text(f.ctype).font(Typo.mono).foregroundStyle(.secondary)
                                if f.kind == .hidden { Text("hidden").font(Typo.caption).padding(.horizontal, Space.xs).background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.swatch)) }
                            }
                            if !f.help.isEmpty { Text(f.help).font(Typo.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        } else {
            Text("Script \(name) not found").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Project settings

struct ProjectSettingsInspector: View {
    @EnvironmentObject var model: EditorModel

    var s: Binding<ProjectSettings> {
        Binding(get: { model.project?.settings ?? ProjectSettings(name: "") }, set: { model.project?.settings = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionLabel("PROJECT SETTINGS")
            HStack { PropLabel(text: "Game name"); TextField("", text: s.name).textFieldStyle(.roundedBorder) }
            HStack { PropLabel(text: "ROM title"); TextField("", text: s.romTitle).textFieldStyle(.roundedBorder) }
            ListEditor(title: "Tags", icon: "tag", items: s.tags, prefix: "TAG_", limit: 255)
            ListEditor(title: "Tile Flags", icon: "flag", items: s.tileFlags, prefix: "TILEFLAG_", limit: 8)
            ListEditor(title: "Variables", icon: "number", items: s.variables, prefix: "VAR_", limit: 64)
            InspectorSection(title: "Scenes (build order)", icon: "square.stack") {
                ForEach(Array(s.wrappedValue.scenes.enumerated()), id: \.element) { i, id in
                    HStack {
                        Text("\(i)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
                        Text(model.project?.scenes[id]?.name ?? "?")
                        if s.wrappedValue.startScene == id { Image(systemName: "flag.checkered").foregroundStyle(Tone.success) }
                        Spacer()
                        Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(i == 0)
                        Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(i == s.wrappedValue.scenes.count - 1)
                    }
                }
            }
            menuSection
            InspectorSection(title: "Testing", icon: "gauge.with.dots.needle.33percent") {
                Toggle("Show frame budget", isOn: Binding(get: { s.wrappedValue.showFrameBudget == true },
                                                         set: { v in model.checkpoint(); s.wrappedValue.showFrameBudget = v ? true : nil }))
                Text("A CPU meter at the bottom of the screen: how much of each frame the game uses, and the peak. Above about 85% it turns yellow; past 100% the game slows down.")
                    .font(Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack { PropLabel(text: "Folder"); Text(model.project?.root.path ?? "").font(Typo.caption).textSelection(.enabled) }
            Button("Open Project Folder in Code Editor") { if let r = model.project?.root { ExternalEditor.open(r.appendingPathComponent("scripts"), workspace: r) } }
                .controlSize(.small)
        }
    }

    func move(_ i: Int, _ d: Int) {
        model.edit { p in p.settings.scenes.swapAt(i, i + d) }
    }

    /// Title and pause menus
    var menu: Binding<MenuConfig> {
        Binding(get: { s.wrappedValue.menu ?? { var m = MenuConfig(); m.titleEnabled = false; m.pauseEnabled = false; return m }() },
                set: { v in s.wrappedValue.menu = (v.titleEnabled || v.pauseEnabled) ? v : nil })
    }

    var menuSection: some View {
        InspectorSection(title: "Menus", icon: "list.bullet.rectangle") {
            Toggle("Title menu (New Game / Continue)", isOn: Binding(get: { menu.wrappedValue.titleEnabled },
                                                                    set: { v in model.checkpoint(); menu.wrappedValue.titleEnabled = v }))
            if menu.wrappedValue.titleEnabled {
                HStack { PropLabel(text: "Title"); TextField(s.wrappedValue.name, text: menu.title).textFieldStyle(.roundedBorder) }
                HStack { PropLabel(text: "Subtitle"); TextField("", text: menu.subtitle).textFieldStyle(.roundedBorder) }
                HStack {
                    PropLabel(text: "Behind it")
                    Picker("", selection: Binding(get: { menu.wrappedValue.titleScene }, set: { v in model.checkpoint(); menu.wrappedValue.titleScene = v })) {
                        Text("Start scene").tag(UUID?.none)
                        ForEach(s.wrappedValue.scenes, id: \.self) { id in Text(model.project?.scenes[id]?.name ?? "?").tag(UUID?.some(id)) }
                    }
                    .labelsHidden()
                }
                HStack { PropLabel(text: "Music"); SoundPicker(selection: Binding(get: { menu.wrappedValue.music }, set: { v in model.checkpoint(); menu.wrappedValue.music = v }), noneLabel: "Scene's music") }
            }
            Toggle("Pause menu (Start: Resume / Save / Quit)", isOn: Binding(get: { menu.wrappedValue.pauseEnabled },
                                                                           set: { v in model.checkpoint(); menu.wrappedValue.pauseEnabled = v }))
            if menu.wrappedValue.titleEnabled || menu.wrappedValue.pauseEnabled {
                HStack { PropLabel(text: "Move sound"); SoundPicker(selection: Binding(get: { menu.wrappedValue.cursorSound }, set: { v in model.checkpoint(); menu.wrappedValue.cursorSound = v })) }
                HStack { PropLabel(text: "Pick sound"); SoundPicker(selection: Binding(get: { menu.wrappedValue.confirmSound }, set: { v in model.checkpoint(); menu.wrappedValue.confirmSound = v })) }
                Text("Saving uses slot 0: the scene, the player's position and all variables. Play From Start (⇧⌘P) shows the title menu.")
                    .font(Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ListEditor: View {
    @EnvironmentObject var model: EditorModel
    let title: String
    let icon: String
    @Binding var items: [String]
    let prefix: String
    let limit: Int
    @State private var newItem = ""

    var body: some View {
        InspectorSection(title: title, icon: icon) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack {
                    Text(item)
                    Text(prefix + cIdentifier(item)).font(Typo.mono).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.checkpoint(); items.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Add…", text: $newItem).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(newItem.isEmpty || items.count >= limit)
            }
        }
    }

    func add() {
        let v = newItem.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !items.contains(v), items.count < limit else { return }
        model.checkpoint()
        items.append(v)
        newItem = ""
    }
}

// MARK: - Loose file

/// An image in the project that isn't a sprite or tileset yet
struct LooseFileInspector: View {
    @EnvironmentObject var model: EditorModel
    let rel: String

    var body: some View {
        if let p = model.project {
            let url = p.url(rel)
            let bmp = model.art.bitmap(url)
            VStack(alignment: .leading, spacing: Space.md) {
                SectionLabel("IMAGE")
                Label(url.lastPathComponent, systemImage: "photo").font(Typo.title)
                Text(rel).font(Typo.mono).foregroundStyle(.secondary).textSelection(.enabled)
                PixelImage(bitmap: bmp).frame(maxWidth: .infinity, maxHeight: 160).background(Checkerboard())
                if let bmp { Text("\(bmp.width) × \(bmp.height) px").font(Typo.caption).foregroundStyle(.secondary) }
                Text("Not used yet").font(Typo.label).foregroundStyle(.secondary)
                Button { model.useImage(rel, asTileset: false) } label: { Label("Use as Sprite", systemImage: "photo") }
                    .help("Frames are read as a row of squares (you can change the frame size in the Sprite editor)")
                Button { model.useImage(rel, asTileset: true) } label: { Label("Use as Tileset", systemImage: "square.grid.3x3.fill") }
                    .help("A grid of 16×16 tiles")
                Divider()
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Move to Trash", role: .destructive) { model.trashFile(rel) }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Dialogue assets

struct SpeakerInspector: View {
    @EnvironmentObject var model: EditorModel
    let id: UUID

    var sp: Binding<SpeakerAsset> {
        Binding(get: { model.project?.speakers[id]?.value ?? SpeakerAsset(displayName: "") },
                set: { v in model.checkpoint(); model.project?.speakers[id]?.value = v })
    }

    var body: some View {
        let anims = sp.wrappedValue.portrait.flatMap { model.project?.sprites[$0]?.value.animations.map(\.name) } ?? []
        VStack(alignment: .leading, spacing: Space.md) {
            HStack { PropLabel(text: "Name"); TextField("", text: sp.displayName).textFieldStyle(.roundedBorder) }
            HStack {
                PropLabel(text: "Name color")
                ColorPicker("", selection: Binding(get: { Color(hex: sp.wrappedValue.nameColor) }, set: { sp.wrappedValue.nameColor = $0.hexString }),
                            supportsOpacity: false).labelsHidden()
            }
            HStack { PropLabel(text: "Portrait"); AssetPicker(kind: .sprite, selection: sp.portrait) }
            if !anims.isEmpty {
                HStack {
                    PropLabel(text: "Talking")
                    Picker("", selection: sp.talkAnimation) { ForEach(anims, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                }
                HStack {
                    PropLabel(text: "Waiting")
                    Picker("", selection: sp.idleAnimation) { ForEach(anims, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                }
            }
        }
        .help("Portraits can be up to 64×64. The talking animation plays while text appears.")
    }
}

struct TextBoxInspector: View {
    @EnvironmentObject var model: EditorModel
    let id: UUID

    var st: Binding<TextBoxStyleAsset> {
        Binding(get: { model.project?.textboxes[id]?.value ?? TextBoxStyleAsset() },
                set: { v in model.checkpoint(); model.project?.textboxes[id]?.value = v })
    }

    func color(_ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> Binding<Color> {
        Binding(get: { Color(hex: get()) }, set: { set($0.hexString) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            InspectorSection(title: "Layout", icon: "rectangle.bottomthird.inset.filled") {
                HStack {
                    PropLabel(text: "Position")
                    Picker("", selection: st.position) { Text("Bottom").tag(TextBoxStyleAsset.Position.bottom); Text("Top").tag(TextBoxStyleAsset.Position.top) }
                        .pickerStyle(.segmented).labelsHidden()
                }
                Stepper("Lines: \(st.wrappedValue.lines)", value: st.lines, in: 1...6)
                Stepper("Side margin: \(st.wrappedValue.marginX)", value: st.marginX, in: 0...6)
                Stepper("Edge margin: \(st.wrappedValue.marginY)", value: st.marginY, in: 0...6)
                Stepper("Name plate: \(st.wrappedValue.nameWidth == 0 ? "off" : "\(st.wrappedValue.nameWidth) tiles")", value: st.nameWidth, in: 0...20)
                Toggle("Portrait on the right", isOn: st.portraitRight)
            }
            InspectorSection(title: "Text", icon: "textformat") {
                HStack {
                    PropLabel(text: "Speed")
                    Slider(value: Binding(get: { Double(st.wrappedValue.speed) }, set: { st.wrappedValue.speed = Int($0) }), in: 5...120)
                    Text("\(st.wrappedValue.speed)/s").font(Typo.captionDigits).frame(width: 40)
                }
                HStack {
                    PropLabel(text: "Font")
                    AssetPicker(kind: .font, selection: st.font)
                }
                if st.wrappedValue.font == nil {
                    Button("Make Editable Copy of Font") { model.exportBuiltInFont(for: id) }.controlSize(.small)
                        .help("Saves the built-in font as a PNG you can redraw")
                }
                Toggle("Shadow", isOn: st.shadow)
                Toggle("Pause the game while open", isOn: st.pauseGame)
            }
            InspectorSection(title: "Colors", icon: "paintpalette") {
                HStack {
                    ColorPicker("Text", selection: color({ st.wrappedValue.textColor }, { st.wrappedValue.textColor = $0 }), supportsOpacity: false)
                    ColorPicker("Shadow", selection: color({ st.wrappedValue.shadowColor }, { st.wrappedValue.shadowColor = $0 }), supportsOpacity: false)
                    ColorPicker("Box", selection: color({ st.wrappedValue.fillColor }, { st.wrappedValue.fillColor = $0 }), supportsOpacity: false)
                }
                HStack(spacing: Space.sm) {
                    ForEach(TextBoxStyleAsset.colorNames, id: \.self) { n in
                        ColorPicker("", selection: color({ st.wrappedValue.colors[n] ?? "#FFFFFF" }, { st.wrappedValue.colors[n] = $0 }), supportsOpacity: false)
                            .labelsHidden().help("[color=\(n)]")
                    }
                }
                HStack(spacing: Space.sm) {
                    ForEach(0..<6, id: \.self) { i in
                        ColorPicker("", selection: color({ i < st.wrappedValue.rainbow.count ? st.wrappedValue.rainbow[i] : "#FFFFFF" },
                                                         { v in while st.wrappedValue.rainbow.count <= i { st.wrappedValue.rainbow.append("#FFFFFF") }; st.wrappedValue.rainbow[i] = v }),
                                    supportsOpacity: false).labelsHidden().help("Rainbow")
                    }
                }
            }
            InspectorSection(title: "Frame", icon: "square.dashed") {
                if let p = model.project, let stored = p.textboxes[id] {
                    let slices = Codegen.frameSlices(for: stored, in: p)
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        ForEach(0..<3, id: \.self) { r in
                            GridRow { ForEach(0..<3, id: \.self) { c in PixelImage(bitmap: slices[r * 3 + c]).frame(width: 24, height: 24) } }
                        }
                    }
                    HStack {
                        Button("Replace…") { replaceFrame() }
                        if let f = stored.value.frameImage {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.imageURL(assetPath: stored.path, image: f)]) }
                        }
                    }
                    .controlSize(.small)
                }
            }
            .help("A 24×24 image cut into 3×3 pieces of 8×8: corners, edges and middle")
        }
        .onChange(of: st.wrappedValue) { _, _ in }
    }

    func replaceFrame() {
        guard let p = model.project, let stored = p.textboxes[id] else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let name = stored.value.frameImage ?? (assetName(URL(fileURLWithPath: stored.path)) + " frame.png")
        let dest = p.imageURL(assetPath: stored.path, image: name)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: src, to: dest)
        model.checkpoint()
        model.project?.textboxes[id]?.value.frameImage = name
        model.refreshFromDisk()
    }
}

// MARK: - Several entities

struct MultiEntityInspector: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        let ids = model.orderedSelection()
        VStack(alignment: .leading, spacing: Space.md) {
            Label("\(ids.count) objects selected", systemImage: "square.stack.3d.up").font(Typo.heading)
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(ids, id: \.self) { id in Text(model.entity(id)?.name ?? "?").font(Typo.label).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Duplicate") { model.duplicateSelection() }
                Button("Delete", role: .destructive) { model.deleteSelection() }
            }
            .controlSize(.small)
            Text("Drag them in the Scene view to move them together. ⌘C / ⌘V copy and paste them, keeping links between them (like a switch and the door it opens).")
                .font(Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Sound

struct SoundInspector: View {
    @EnvironmentObject var model: EditorModel
    let rel: String

    var body: some View {
        let name = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
        VStack(alignment: .leading, spacing: Space.md) {
            Label(name, systemImage: "speaker.wave.2.fill").font(Typo.heading)
            Text(rel).font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button { model.previewSound(rel) } label: { Label("Play", systemImage: "play.fill") }
            if model.openScene != nil {
                Button("Use as This Scene's Music") { model.checkpoint(); model.updateScene { $0.music = name } }
            }
            Text("Any audio file in the project is a sound, named after its file. Building converts it to the GBA's format (8-bit mono, 13 kHz), so it will sound a bit crunchier in the game. In scripts: `SoundRef` fields, `play_sound()` and `play_music()`.")
                .font(Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
