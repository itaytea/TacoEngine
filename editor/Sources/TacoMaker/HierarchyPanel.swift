import EngineKit
import SwiftUI

struct HierarchyPanel: View {
    @EnvironmentObject var model: EditorModel
    @State private var dropTarget: UUID?
    @State private var rootTargeted = false

    struct Node: Identifiable { let id: UUID; var children: [Node]? }

    /// Entities as a tree (children under their parent, in scene order)
    var tree: [Node] {
        let list = model.scene?.entities ?? []
        let ids = Set(list.map(\.guid))
        func kids(_ p: UUID?) -> [Node] {
            list.filter { e in p == nil ? (e.parent.map { !ids.contains($0) } ?? true) : e.parent == p }
                .map { e in let k = kids(e.guid); return Node(id: e.guid, children: k.isEmpty ? nil : k) }
        }
        return kids(nil)
    }

    func drop(_ items: [String], onto parent: UUID?) -> Bool {
        let dragged = items.compactMap { $0.hasPrefix("entity:") ? UUID(uuidString: String($0.dropFirst(7))) : nil }
        guard !dragged.isEmpty else { return false }
        // Dragging one of several selected entities moves all of them
        let moving = dragged.count == 1 && model.entitySelection.contains(dragged[0]) ? model.orderedSelection() : dragged
        for id in moving where id != parent { model.setParent(id, to: parent) }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Hierarchy", icon: "list.bullet.indent") {
                createMenu
            }
            scenePicker
            Divider()
            // Shift-click selects a range, Cmd-click adds or removes one (macOS list behavior).
            // Drag an entity onto another to make it a child; drag it to the empty space below to make it top-level.
            List(selection: Binding(get: { model.entitySelection }, set: { (ids: Set<UUID>) in
                model.focusArea = .hierarchy
                let added = ids.subtracting(model.entitySelection)
                model.entitySelection = ids
                if let a = added.first ?? model.orderedSelection().last { model.selection = .entity(a) }
                else { model.selection = .none }
            })) {
                OutlineGroup(tree, children: \.children) { node in
                    if let e = model.entity(node.id) {
                        row(e)
                            .contextMenu { contextMenu(e) }
                            .draggable("entity:" + e.guid.uuidString)
                            .dropDestination(for: String.self) { items, _ in drop(items, onto: e.guid) } isTargeted: { t in dropTarget = t ? e.guid : (dropTarget == e.guid ? nil : dropTarget) }
                            .listRowBackground(dropTarget == e.guid ? Tone.dropTarget : nil)
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.scene?.entities.isEmpty ?? true {
                    Text("No entities")
                        .multilineTextAlignment(.center).font(Typo.label).foregroundStyle(.secondary).padding(Space.lg)
                }
            }
            // Drop zone for making children top-level again, shown once the scene has any
            if model.scene?.entities.contains(where: { $0.parent != nil }) == true {
                Divider()
                Label("Drop here to un-parent", systemImage: "arrow.turn.left.up")
                    .font(Typo.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Space.xxl)
                    .background(rootTargeted ? Tone.dropTarget : .clear)
                    .dropDestination(for: String.self) { items, _ in drop(items, onto: nil) } isTargeted: { rootTargeted = $0 }
            }
        }
    }

    var scenePicker: some View {
        Menu {
            ForEach(model.project?.settings.scenes ?? [], id: \.self) { id in
                Button {
                    model.openSceneAsset(id)
                } label: {
                    Label(model.project?.scenes[id]?.name ?? "?", systemImage: id == model.project?.settings.startScene ? "flag.checkered" : "square.on.square")
                }
            }
            Divider()
            Button("New Scene") { model.createScene() }
        } label: {
            Label(model.openScene.flatMap { model.project?.scenes[$0]?.name } ?? "No scene", systemImage: "square.on.square")
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }

    var createMenu: some View {
        Menu {
            Button("Platformer Player") { model.createPlatformerPlayer() }
            Button("Talking NPC") { model.createTalkingNPC() }
            ForEach(EditorModel.Premade.allCases, id: \.self) { k in
                Button(k.rawValue) { model.placePremade(k) }
            }
            Divider()
            Button("Empty Entity") { model.createEmpty() }
            Menu("Sprite Entity") {
                ForEach(sortedSprites, id: \.0) { id, name in Button(name) { model.createEmpty(withSprite: id) } }
            }
            Menu("Prefab Instance") {
                ForEach(sortedPrefabs, id: \.0) { id, name in Button(name) { model.instantiate(prefab: id) } }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.scene == nil)
    }

    var sortedSprites: [(UUID, String)] { (model.project?.sprites ?? [:]).map { ($0.key, $0.value.name) }.sorted { $0.1 < $1.1 } }
    var sortedPrefabs: [(UUID, String)] { (model.project?.prefabs ?? [:]).map { ($0.key, $0.value.name) }.sorted { $0.1 < $1.1 } }

    func row(_ e: SceneEntity) -> some View {
        let isPrefab = e.prefab != nil
        let def = model.def(e)
        return HStack(spacing: Space.sm) {
            Image(systemName: isPrefab ? "cube.fill" : "cube")
                .foregroundStyle(isPrefab ? Tone.prefab : .secondary)
            Text(e.name).lineLimit(1)
                .foregroundStyle(isPrefab ? Tone.prefab : .primary)
            Spacer()
            if model.scene?.cameraTarget == e.guid {
                Image(systemName: "video.fill").font(Typo.caption).foregroundStyle(.secondary).help("Camera target")
            }
            if !def.scripts.isEmpty {
                Image(systemName: "curlybraces").font(Typo.caption).foregroundStyle(.secondary).help(def.scripts.map(\.script).joined(separator: ", "))
            }
        }
    }

    @ViewBuilder func contextMenu(_ e: SceneEntity) -> some View {
        Button("Duplicate") { model.duplicate(e.guid) }
        if e.parent != nil { Button("Un-parent") { model.setParent(e.guid, to: nil) } }
        Button("Make Camera Target") { model.checkpoint(); model.updateScene { $0.cameraTarget = e.guid } }
        Divider()
        if e.prefab != nil {
            Button("Select Prefab") { if let p = e.prefab { model.selection = .asset(p) } }
            Button("Apply Overrides to Prefab") { model.applyOverridesToPrefab(e.guid) }
            Button("Unpack Prefab") { model.unpack(e.guid) }
        } else {
            Button("Create Prefab From Entity") { model.makePrefab(from: e.guid) }
        }
        Divider()
        Button("Delete", role: .destructive) {
            if model.entitySelection.contains(e.guid) { model.deleteSelection() } else { model.deleteEntity(e.guid) }
        }
    }
}
