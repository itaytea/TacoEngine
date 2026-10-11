import AppKit
import EngineKit
import SwiftUI

extension Bitmap {
    /// Converted once and cached: building images from pixels on every redraw made the editor sluggish.
    @MainActor var nsImage: NSImage { BitmapImages.image(for: self) }
}

@MainActor
enum BitmapImages {
    private static var cache: [Bitmap: NSImage] = [:]

    static func image(for b: Bitmap) -> NSImage {
        if let img = cache[b] { return img }
        if cache.count > 2000 { cache.removeAll() }
        let img = NSImage(cgImage: b.cgImage(), size: NSSize(width: b.width, height: b.height))
        cache[b] = img
        return img
    }
}

/// Pixel-art image view (nearest-neighbor scaling)
struct PixelImage: View {
    let bitmap: Bitmap?
    var body: some View {
        if let bitmap, bitmap.width > 0 {
            Image(nsImage: bitmap.nsImage).interpolation(.none).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "questionmark.square.dashed").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 6
            for y in 0..<Int(size.height / s + 1) {
                for x in 0..<Int(size.width / s + 1) where (x + y) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s)), with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}

/// Loads images from disk, re-reading when the file changes.
@MainActor
final class ArtCache {
    private struct Entry { let modified: Date; let bitmap: Bitmap?; var image: NSImage?; var frames: [String: [Bitmap]] }
    private var cache: [URL: Entry] = [:]

    private func entry(_ url: URL) -> Entry {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        if let e = cache[url], e.modified == modified { return e }
        let e = Entry(modified: modified, bitmap: try? Bitmap.load(url), image: nil, frames: [:])
        cache[url] = e
        return e
    }

    func bitmap(_ url: URL) -> Bitmap? { entry(url).bitmap }

    func image(_ url: URL) -> NSImage? {
        var e = entry(url)
        if let i = e.image { return i }
        e.image = e.bitmap?.nsImage
        cache[url] = e
        return e.image
    }

    /// Grid frames (left-to-right, top-to-bottom)
    func frames(_ url: URL, w: Int, h: Int) -> [Bitmap] {
        var e = entry(url)
        let key = "\(w)x\(h)"
        if let f = e.frames[key] { return f }
        guard let b = e.bitmap, w > 0, h > 0 else { return [] }
        var out: [Bitmap] = []
        for r in 0..<(b.height / h) { for c in 0..<(b.width / w) { out.append(b.crop(x: c * w, y: r * h, w: w, h: h)) } }
        e.frames[key] = out
        cache[url] = e
        return out
    }

    func invalidate() { cache.removeAll() }
}

extension Color {
    init(hex: String) {
        let (r, g, b) = parseHexColor(hex)
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    var hexString: String {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return hexColor(r: Int(ns.redComponent * 255 + 0.5), g: Int(ns.greenComponent * 255 + 0.5), b: Int(ns.blueComponent * 255 + 0.5))
    }
}

/// Section header used in the Inspector and side panels
struct PanelHeader<Trailing: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: Space.sm) {
            if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
            SectionLabel(title)
            Spacer()
            trailing
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, icon: String? = nil) { self.init(title: title, icon: icon) { EmptyView() } }
}

/// Small uppercase label above a group of controls
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Typo.section).textCase(.uppercase).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A row of tabs above a panel (the center editor, the Project/Console panel)
struct PanelTabBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.xs) {
                content
                Spacer()
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .background(.bar)
            Divider()
        }
    }
}

struct PanelTab: View {
    let title: String
    let icon: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(Typo.label)
                .foregroundStyle(active ? .primary : .secondary)
                .padding(.horizontal, Space.md).padding(.vertical, Space.xs)
                .background(active ? Tone.selected : hovering ? Tone.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Opens a file in VS Code at a line (Cursor if VS Code isn't installed, otherwise the default app).
enum ExternalEditor {
    static let candidates = [
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
        NSHomeDirectory() + "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
        "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
    ]

    static func open(_ file: URL, line: Int? = nil, workspace: URL? = nil) {
        if let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            var args: [String] = []
            if let workspace { args.append(workspace.path) }
            args += ["-g", file.path + (line.map { ":\($0)" } ?? "")]
            p.arguments = args
            if (try? p.run()) != nil { return }
        }
        NSWorkspace.shared.open(file)
    }
}

/// Integer text field that commits on Enter/blur
struct IntField: View {
    let label: String
    @Binding var value: Int
    var width: CGFloat = 54
    var body: some View {
        HStack(spacing: Space.xs) {
            if !label.isEmpty { Text(label).foregroundStyle(.secondary).font(Typo.caption) }
            TextField("", value: $value, format: .number).frame(width: width).textFieldStyle(.roundedBorder).controlSize(.small)
        }
    }
}

/// Pick one of the project's sounds (audio files under assets/, by name)
struct SoundPicker: View {
    @EnvironmentObject var model: EditorModel
    @Binding var selection: String?
    var noneLabel = "None"

    var body: some View {
        HStack(spacing: Space.xs) {
            Picker("", selection: $selection) {
                Text(noneLabel).tag(String?.none)
                ForEach(model.project?.sounds().map(\.name) ?? [], id: \.self) { n in Text(n).tag(String?.some(n)) }
            }
            .labelsHidden()
            Button { model.previewSound(selection) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless).disabled(selection == nil).help("Listen")
        }
    }
}
