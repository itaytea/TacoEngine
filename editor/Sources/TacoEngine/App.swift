import AppKit
import EngineKit
import SwiftUI

@main
struct TacoEngineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = EditorModel()

    var body: some Scene {
        WindowGroup("Taco Engine") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { model.newProject() }
                Button("Open Project…") { model.chooseProject() }.keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(model.recents.filter(\.exists)) { r in Button(r.name) { model.open(r.url) } }
                }
                Divider()
                Button("Close Project") { model.closeProject() }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(model.project == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveFromKeyboard() }.keyboardShortcut("s")
            }
            CommandMenu("Assets") {
                Button("New Scene") { model.createScene() }
                Button("New Script…") { model.createScript() }
                Button("New Prefab") { model.createPrefab() }
                Button("New Platformer Settings") { model.createPlatformer() }
                Button("New Dialogue") { model.createDialogue() }
                Button("New Speaker") { model.createSpeaker() }
                Button("New Text Box Style") { model.createTextBox() }
                Divider()
                Button("Import Sprite Sheet…") { model.importImage(asTileset: false) }
                Button("Import Tileset…") { model.importImage(asTileset: true) }
            }
            CommandGroup(replacing: .help) {
                Button("Taco Engine Documentation") { model.openDocumentation() }
            }
            CommandMenu("Game") {
                Button("Play Current Scene") { model.play() }.keyboardShortcut("p")
                Button("Play From Start") { model.play(fromStart: true) }.keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Export for Web…") { model.exportWeb() }.disabled(model.building)
                Divider()
                Button("Project Settings…") { model.selection = .projectSettings }.keyboardShortcut(",", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct MainView: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if model.project != nil {
                HSplitView {
                    HierarchyPanel()
                        .frame(minWidth: 200, idealWidth: 230, maxWidth: 360)
                    VSplitView {
                        CenterPanel()
                            .frame(minHeight: 300)
                        BottomPanel()
                            .frame(minHeight: 140, idealHeight: 220)
                    }
                    .frame(minWidth: 480)
                    InspectorPanel()
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 460)
                }
                .toolbar { toolbar }
            } else {
                WelcomeView()
            }
        }
        .alert("Taco Engine", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, um in model.undoManager = um }
        .navigationTitle(model.project?.settings.name ?? "Taco Engine")
        .navigationSubtitle(model.openScene.flatMap { model.project?.scenes[$0]?.name } ?? "")
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker("Tool", selection: $model.tool) {
                ForEach(SceneTool.allCases, id: \.self) { t in
                    Label(t.rawValue, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .help("Move: select and drag entities · Paint: draw tiles · Rectangle: drag to fill a box · Fill: flood an area · Erase: remove tiles")
        }
        ToolbarItemGroup(placement: .principal) {
            Button { model.play() } label: {
                // The button itself shows that a build is running
                if model.building { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                else { Label("Play", systemImage: "play.fill") }
            }
            .help("Build and run the current scene in mGBA (⌘P)")
            .disabled(model.building)
            Button { model.play(fromStart: true) } label: { Label("Play From Start", systemImage: "forward.end.fill") }
                .help("Build and run from the start scene (⇧⌘P)")
                .disabled(model.building)
            BuildStatusView()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.selection = .projectSettings } label: { Label("Project Settings", systemImage: "gearshape") }
                .help("Project Settings (⇧⌘,)")
        }
    }
}

/// The toolbar's status: building, saved, failed or done, each with its own icon
struct BuildStatusView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        HStack(spacing: Space.xs) {
            if let icon { Image(systemName: icon.name).foregroundStyle(icon.color) }
            Text(text).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(Typo.caption)
        .frame(minWidth: 140, alignment: .leading)
        .animation(Motion.standard, value: text)
    }

    var text: String { model.savedFlash ? "Saved" : model.buildStatus }

    var icon: (name: String, color: Color)? {
        if model.savedFlash { return ("checkmark.circle.fill", Tone.success) }
        if model.building || text.isEmpty { return nil }
        if text.localizedCaseInsensitiveContains("failed") { return ("xmark.octagon.fill", Tone.danger) }
        return ("checkmark.circle", .secondary)
    }
}

/// The launcher: recent projects, or start a new one
struct WelcomeView: View {
    @EnvironmentObject var model: EditorModel
    @State private var hovered: String?

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: Space.lg) {
                Spacer()
                if let icon = NSApp.applicationIconImage { Image(nsImage: icon).resizable().frame(width: 96, height: 96) }
                VStack(spacing: Space.xs) {
                    Text("Taco Engine").font(Typo.display)
                    Text("Game Boy Advance games, made on a Mac").font(Typo.label).foregroundStyle(.secondary)
                }
                VStack(spacing: Space.sm) {
                    Button { model.newProject() } label: { Label("New Project…", systemImage: "plus").frame(width: 200) }
                        .buttonStyle(.borderedProminent).keyboardShortcut("n")
                    Button { model.chooseProject() } label: { Label("Open Project…", systemImage: "folder").frame(width: 200) }
                }
                .controlSize(.large)
                .padding(.top, Space.sm)
                Spacer()
                Text("Version \(version)").font(Typo.caption).foregroundStyle(.tertiary)
            }
            .padding(Space.xl)
            .frame(width: 320)
            .frame(maxHeight: .infinity)
            .background(.background.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent Projects").font(Typo.heading)
                    .padding(.horizontal, Space.xl).padding(.top, Space.xl).padding(.bottom, Space.md)
                if model.recents.isEmpty {
                    VStack(spacing: Space.sm) {
                        Image(systemName: "clock").font(Typo.title).foregroundStyle(.tertiary)
                        Text("No recent projects").font(Typo.bodyStrong)
                        Text("Projects you create or open appear here.").font(Typo.label).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: Space.xs) {
                            ForEach(model.recents) { r in recentRow(r) }
                        }
                        .padding(.horizontal, Space.md)
                        .padding(.bottom, Space.md)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    func recentRow(_ r: EditorModel.RecentProject) -> some View {
        let ok = r.exists
        return HStack(spacing: Space.md) {
            Image(systemName: "gamecontroller").font(Typo.title).foregroundStyle(ok ? Tone.accent : .secondary)
                .frame(width: 32, height: 32)
                .background(Tone.well, in: RoundedRectangle(cornerRadius: Radius.control))
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(r.name).font(Typo.bodyStrong)
                Text(ok ? r.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") : "Missing: \(r.path)")
                    .font(Typo.caption).foregroundStyle(ok ? .secondary : Tone.warning).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Space.md)
            if let d = r.modified { Text(d, format: .relative(presentation: .named)).font(Typo.caption).foregroundStyle(.tertiary) }
        }
        .padding(Space.sm)
        .background(hovered == r.id && ok ? Tone.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.quick) { hovered = h ? r.id : (hovered == r.id ? nil : hovered) } }
        .onTapGesture { if ok { model.open(r.url) } }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }.disabled(!ok)
            Button("Remove from List") { model.removeRecent(r) }
        }
        .opacity(ok ? 1 : 0.6)
        .help(ok ? "Open \(r.name)" : "This folder has been moved or deleted")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Scene view, or the editor for an open asset
struct CenterPanel: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            PanelTabBar {
                PanelTab(title: "Scene", icon: "square.on.square", active: model.center == .scene) { model.center = .scene }
                if case .asset(let id) = model.center, let name = model.project?.name(of: id) {
                    PanelTab(title: name, icon: "pencil.and.outline", active: true) {}
                    Button { model.center = .scene } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).controlSize(.small).help("Close and go back to the scene")
                }
            }
            switch model.center {
            case .scene: SceneViewPanel()
            case .asset(let id): AssetEditor(id: id)
            }
        }
    }

}
