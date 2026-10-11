import AppKit
import EngineKit
import SwiftUI

// MARK: - Preview (matches the engine's text box)

/// Everything the preview needs, resolved from the project
struct DialoguePreviewData {
    var geometry: TextBoxGeometry
    var style: TextBoxStyleAsset
    var font: FontData
    var frame: [Bitmap]            // 9 slices
    var name: String?
    var nameColor: Color
    var portrait: [Bitmap]         // talk animation frames
    var portraitFPS: Int
    var pages: [[DialogueChar]]

    @MainActor
    static func make(_ model: EditorModel, style styleID: UUID?, speaker speakerID: UUID?, animation: String, text: String) -> DialoguePreviewData? {
        guard let p = model.project else { return nil }
        let stored = styleID.flatMap { p.textboxes[$0] } ?? p.textboxes.values.sorted { $0.path < $1.path }.first
        let style = stored?.value ?? TextBoxStyleAsset()
        let font = Codegen.font(for: style, in: p)
        let geo = TextBoxGeometry(style: style, font: font)
        let speaker = speakerID.flatMap { p.speakers[$0]?.value }
        var portrait: [Bitmap] = [], fps = 0, pw: Int?
        if let sid = speaker?.portrait, let s = p.sprites[sid] {
            let frames = model.art.frames(p.imageURL(assetPath: s.path, image: s.value.image), w: s.value.frameWidth, h: s.value.frameHeight)
            let animName = animation.isEmpty ? speaker!.talkAnimation : animation
            let anim = s.value.animations.first { $0.name == animName } ?? s.value.animations.first
            portrait = (anim?.frames ?? [0]).compactMap { $0 < frames.count ? frames[$0] : nil }
            fps = anim?.fps ?? 0
            pw = Codegen.portraitWidth(speaker, in: p)
        }
        let pages = DialogueText.pages(text, font: font, width: geo.textWidth(portraitWidth: pw), lines: style.lines, variables: p.settings.variables)
        let name = (speaker?.displayName.isEmpty ?? true) ? nil : speaker?.displayName
        return DialoguePreviewData(geometry: geo, style: style, font: font, frame: Codegen.frameSlices(for: stored, in: p),
                                   name: geo.nameW > 0 ? name : nil, nameColor: Color(hex: speaker?.nameColor ?? "#FFE14D"),
                                   portrait: portrait, portraitFPS: fps, pages: pages)
    }
}

/// A 240x160 GBA screen showing the text box, with effects and the typewriter animated
struct DialoguePreview: View {
    let data: DialoguePreviewData
    var page = 0
    var startTime: Date = .distantPast   // when the typewriter (re)started
    var background: Color = Color(hex: "#6AB8F0")

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { ctx in
            Canvas { g, size in render(g, size, ctx.date) }
        }
        .aspectRatio(1.5, contentMode: .fit)
    }


    func render(_ g: GraphicsContext, _ size: CGSize, _ date: Date) {
        let s = min(size.width / 240, size.height / 160)
        let ox = (size.width - 240 * s) / 2, oy = (size.height - 160 * s) / 2
        let elapsed = date.timeIntervalSince(startTime)
        let frame = Int(date.timeIntervalSinceReferenceDate * 60)
        g.fill(Path(CGRect(x: ox, y: oy, width: 240 * s, height: 160 * s)), with: .color(background))
        let geo = data.geometry
        drawBox(g, s, ox, oy, geo.boxX, geo.boxY, geo.boxW, geo.boxH)
        if let name = data.name {
            drawBox(g, s, ox, oy, geo.nameX, geo.nameY, geo.nameW, 4)
            var x = 2
            for ch in name.utf8 {
                drawChar(g, s, ox + CGFloat((geo.nameX + 1) * 8 + x) * s, oy + CGFloat((geo.nameY + 1) * 8 + (16 - data.font.height) / 2) * s,
                         ch: ch, flags: 0, color: data.nameColor)
                x += data.font.width(ch)
            }
        }
        // Portrait
        var textX0 = geo.padX
        if !data.portrait.isEmpty {
            let f = data.portrait[data.portraitFPS > 0 ? Int(elapsed * Double(data.portraitFPS)) % data.portrait.count : 0]
            let px = (geo.boxX + 1) * 8 + (data.style.portraitRight ? geo.interiorW - f.width - 4 : 4)
            let py = (geo.boxY + 1) * 8 + (geo.interiorH - f.height) / 2
            g.draw(Image(nsImage: f.nsImage).interpolation(.none),
                   in: CGRect(x: ox + CGFloat(px) * s, y: oy + CGFloat(py) * s, width: CGFloat(f.width) * s, height: CGFloat(f.height) * s))
            if !data.style.portraitRight { textX0 += f.width + 6 }
        }
        // Text
        guard page < data.pages.count else { return }
        let chars = data.pages[page]
        var budget = elapsed * Double(max(1, data.style.speed))
        for (i, c) in chars.enumerated() {
            if c.ch == 0 { budget -= Double(c.pause) / 60 * Double(data.style.speed); continue }
            if budget < 1 { break }
            budget -= 1
            var dx = 0, dy = 0
            if c.flags & DialogueText.wave != 0 { dy = Int((sin(Double(frame * 6 + i * 24) / 256 * 2 * .pi) * 2).rounded(.towardZero)) }
            if c.flags & DialogueText.shake != 0 {
                let h = UInt32(truncatingIfNeeded: (frame / 4) &* 2654435761 &+ i &* 40503)
                dx = Int((h >> 13) % 3) - 1; dy += Int((h >> 17) % 3) - 1
            }
            let color: Color
            if c.flags & DialogueText.rainbow != 0 {
                color = Color(hex: data.style.rainbow[(i + frame / 16) % max(1, data.style.rainbow.count)])
            } else if c.color >= 11 {
                color = Color(hex: data.style.colors[TextBoxStyleAsset.colorNames[c.color - 11]] ?? "#FFFFFF")
            } else {
                color = Color(hex: data.style.textColor)
            }
            let bx = ox + CGFloat((geo.boxX + 1) * 8 + textX0 + c.x + dx) * s
            let by = oy + CGFloat((geo.boxY + 1) * 8 + geo.padY + c.y + dy) * s
            if c.ch == 1 {   // a variable: show "123"
                var x: CGFloat = 0
                for d in "123".utf8 { drawChar(g, s, bx + x, by, ch: d, flags: c.flags, color: color); x += CGFloat(data.font.width(d)) * s }
            } else {
                drawChar(g, s, bx, by, ch: c.ch, flags: c.flags, color: color)
            }
        }
    }

    func drawBox(_ g: GraphicsContext, _ s: CGFloat, _ ox: CGFloat, _ oy: CGFloat, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        for ty in 0..<h {
            for tx in 0..<w {
                let sx = tx == 0 ? 0 : tx == w - 1 ? 2 : 1, sy = ty == 0 ? 0 : ty == h - 1 ? 2 : 1
                let rect = CGRect(x: ox + CGFloat((x + tx) * 8) * s, y: oy + CGFloat((y + ty) * 8) * s, width: 8 * s + 0.5, height: 8 * s + 0.5)
                if sx == 1 && sy == 1 { g.fill(Path(rect), with: .color(Color(hex: data.style.fillColor))); continue }
                g.draw(Image(nsImage: data.frame[sy * 3 + sx].nsImage).interpolation(.none), in: rect)
            }
        }
    }

    func drawChar(_ g: GraphicsContext, _ s: CGFloat, _ x: CGFloat, _ y: CGFloat, ch: UInt8, flags: Int, color: Color) {
        guard ch >= 32, ch < 128 else { return }
        let rows = data.font.rows[Int(ch) - 32]
        func path(_ dx: CGFloat, _ dy: CGFloat) -> Path {
            var p = Path()
            for r in 0..<data.font.height {
                var bits = UInt32(rows[r])
                if flags & DialogueText.bold != 0 { bits |= bits << 1 }
                let slant = flags & DialogueText.italic != 0 ? (data.font.height - 1 - r) / 4 : 0
                var b = 0
                while bits != 0 {
                    if bits & 1 != 0 { p.addRect(CGRect(x: x + CGFloat(b + slant) * s + dx, y: y + CGFloat(r) * s + dy, width: s, height: s)) }
                    bits >>= 1; b += 1
                }
            }
            return p
        }
        if data.style.shadow { g.fill(path(s, s), with: .color(Color(hex: data.style.shadowColor))) }
        g.fill(path(0, 0), with: .color(color))
    }
}

// MARK: - Text field that understands tags

/// Multi-line text field; tags like [wave] and {coins} are shown dimmed. The formatting toolbar wraps the selection.
struct RichTextField: NSViewRepresentable {
    @Binding var text: String
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.textContainerInset = NSSize(width: 4, height: 5)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.string = text
        context.coordinator.highlight(tv)
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        tv.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        context.coordinator.parent = self
        if tv.string != text {
            tv.string = text
            context.coordinator.highlight(tv)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextField
        init(_ p: RichTextField) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            highlight(tv)
        }

        func textDidBeginEditing(_ notification: Notification) { parent.onFocus() }
        func textViewDidChangeSelection(_ notification: Notification) {
            if (notification.object as? NSTextView)?.window?.firstResponder === notification.object as? NSTextView { parent.onFocus() }
        }

        static let tagRegex = try! NSRegularExpression(pattern: #"\[/?[a-z]+(=[^\]]*)?\]|\{[A-Za-z_]\w*\}"#)

        func highlight(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor], range: full)
            for m in Coordinator.tagRegex.matches(in: storage.string, range: full) {
                storage.addAttributes([.foregroundColor: NSColor.systemPurple, .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)], range: m.range)
            }
            storage.endEditing()
        }
    }

    /// Wrap the focused text view's selection in tags (or insert at the cursor)
    @MainActor static func wrap(_ open: String, _ close: String = "") {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable else { return }
        let range = tv.selectedRange()
        let selected = (tv.string as NSString).substring(with: range)
        tv.insertText(open + selected + close, replacementRange: range)
        if selected.isEmpty { tv.setSelectedRange(NSRange(location: range.location + (open as NSString).length, length: 0)) }
    }
}

struct FormatToolbar: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        HStack(spacing: Space.xs) {
            fmt("bold", "[b]", "[/b]", "Bold")
            fmt("italic", "[i]", "[/i]", "Italic")
            fmt("water.waves", "[wave]", "[/wave]", "Wavy")
            fmt("waveform.path", "[shake]", "[/shake]", "Shaky")
            fmt("rainbow", "[rainbow]", "[/rainbow]", "Rainbow")
            Menu {
                ForEach(TextBoxStyleAsset.colorNames, id: \.self) { c in
                    Button(c.capitalized) { RichTextField.wrap("[color=\(c)]", "[/color]") }
                }
            } label: { Image(systemName: "paintpalette") }
            .menuIndicator(.hidden).fixedSize().help("Color")
            Divider().frame(height: 16)
            fmt("pause", "[pause=30]", "", "Pause (half a second)")
            Menu {
                ForEach(model.project?.settings.variables ?? [], id: \.self) { v in
                    Button(v) { RichTextField.wrap("{\(v)}") }
                }
                if model.project?.settings.variables.isEmpty ?? true { Text("Add variables in Project Settings") }
            } label: { Image(systemName: "number") }
            .menuIndicator(.hidden).fixedSize().help("Insert a variable's value")
            fmt("doc.badge.plus", "[page]", "", "New page")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    func fmt(_ icon: String, _ open: String, _ close: String, _ help: String) -> some View {
        Button { RichTextField.wrap(open, close) } label: { Image(systemName: icon).frame(width: 22) }
            .help(help)
    }
}

// MARK: - Dialogue editor

struct DialogueEditor: View {
    @EnvironmentObject var model: EditorModel
    let id: UUID
    @State private var selected = 0
    @State private var page = 0
    @State private var start = Date()

    var dialogue: Binding<DialogueAsset> {
        Binding(get: { model.project?.dialogues[id]?.value ?? DialogueAsset(lines: []) },
                set: { model.project?.dialogues[id]?.value = $0 })
    }

    var body: some View {
        let d = dialogue.wrappedValue
        let line = d.lines.indices.contains(selected) ? d.lines[selected] : nil
        VStack(spacing: 0) {
            // Preview
            HStack(alignment: .top, spacing: Space.md) {
                if let line, let data = DialoguePreviewData.make(model, style: d.style, speaker: line.speaker, animation: line.animation, text: line.text) {
                    DialoguePreview(data: data, page: min(page, max(0, data.pages.count - 1)), startTime: start)
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                        .onTapGesture { start = Date() }
                        .help("Click to replay")
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Line \(selected + 1) of \(d.lines.count)").font(Typo.caption).foregroundStyle(.secondary)
                        if data.pages.count > 1 {
                            HStack {
                                Button { page = max(0, page - 1); start = Date() } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
                                Text("Page \(min(page, data.pages.count - 1) + 1)/\(data.pages.count)").font(Typo.captionDigits)
                                Button { page = min(data.pages.count - 1, page + 1); start = Date() } label: { Image(systemName: "chevron.right") }
                                    .disabled(page >= data.pages.count - 1)
                            }
                            .buttonStyle(.borderless)
                        }
                        Button { start = Date() } label: { Label("Replay", systemImage: "arrow.counterclockwise") }.controlSize(.small)
                        Spacer()
                    }
                    .frame(width: 120)
                } else {
                    Text("Add a line to see the preview").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(Space.md)
            Divider()
            // Lines
            HStack {
                Picker("Text box", selection: Binding(get: { d.style }, set: { v in model.checkpoint(); dialogue.wrappedValue.style = v })) {
                    Text("Default").tag(UUID?.none)
                    ForEach((model.project?.textboxes ?? [:]).sorted { $0.value.name < $1.value.name }, id: \.key) { id, s in
                        Text(s.name).tag(UUID?.some(id))
                    }
                }
                .frame(maxWidth: 220)
                Spacer()
                FormatToolbar()
            }
            .controlSize(.small)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            ScrollView {
                VStack(spacing: Space.sm) {
                    ForEach(Array(d.lines.enumerated()), id: \.element.id) { i, l in
                        lineCard(i, l)
                    }
                    Button {
                        model.checkpoint()
                        dialogue.wrappedValue.lines.append(DialogueLine(speaker: d.lines.last?.speaker, text: ""))
                        selected = dialogue.wrappedValue.lines.count - 1
                        page = 0; start = Date()
                    } label: { Label("Add Line", systemImage: "plus") }
                    .padding(.top, Space.xs)
                }
                .padding(Space.md)
            }
        }
    }

    func lineCard(_ i: Int, _ l: DialogueLine) -> some View {
        let lines = dialogue
        let speakers = (model.project?.speakers ?? [:]).sorted { $0.value.name < $1.value.name }
        let portrait = l.speaker.flatMap { model.project?.speakers[$0]?.value.portrait }.flatMap { pid -> Bitmap? in
            guard let p = model.project, let s = p.sprites[pid] else { return nil }
            return model.art.frames(p.imageURL(assetPath: s.path, image: s.value.image), w: s.value.frameWidth, h: s.value.frameHeight).first
        }
        return HStack(alignment: .top, spacing: Space.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.control).fill(Tone.well)
                if let portrait { PixelImage(bitmap: portrait).padding(Space.xs) }
                else { Image(systemName: l.speaker == nil ? "text.bubble" : "person.crop.square").foregroundStyle(.secondary) }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack {
                    Picker("", selection: Binding(get: { l.speaker }, set: { v in
                        model.checkpoint()
                        if lines.wrappedValue.lines.indices.contains(i) { lines.wrappedValue.lines[i].speaker = v }
                    })) {
                        Text("No speaker").tag(UUID?.none)
                        ForEach(speakers, id: \.key) { id, s in Text(s.value.displayName.isEmpty ? s.name : s.value.displayName).tag(UUID?.some(id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                    Spacer()
                    Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                    Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.disabled(i == lines.wrappedValue.lines.count - 1)
                    Button {
                        model.checkpoint()
                        lines.wrappedValue.lines.remove(at: i)
                        selected = max(0, min(selected, lines.wrappedValue.lines.count - 1))
                    } label: { Image(systemName: "trash") }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                RichTextField(text: Binding(get: { l.text }, set: { v in
                    if lines.wrappedValue.lines.indices.contains(i) { lines.wrappedValue.lines[i].text = v }
                }), onFocus: { if selected != i { selected = i; page = 0; start = Date() } })
                .frame(height: 54)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Tone.border))
            }
        }
        .padding(Space.sm)
        .background(selected == i ? Tone.selected : Tone.well, in: RoundedRectangle(cornerRadius: Radius.control))
        .contentShape(Rectangle())
        .onTapGesture { selected = i; page = 0; start = Date() }
    }

    func move(_ i: Int, _ d: Int) {
        model.checkpoint()
        dialogue.wrappedValue.lines.swapAt(i, i + d)
        selected = i + d
    }
}

// MARK: - Text box style preview (center panel)

struct TextBoxPreview: View {
    @EnvironmentObject var model: EditorModel
    let id: UUID
    @State private var start = Date()
    static let sample = "Hi! This text is [b]bold[/b], [i]italic[/i], [wave]wavy[/wave], [shake]shaky[/shake], [rainbow]rainbow[/rainbow] and [color=red]red[/color]. Change the box in the Inspector."

    var body: some View {
        VStack {
            if let data = DialoguePreviewData.make(model, style: id, speaker: model.project?.speakers.keys.sorted().first, animation: "", text: Self.sample) {
                DialoguePreview(data: data, startTime: start)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                    .onTapGesture { start = Date() }
                    .help("Click to replay")
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
