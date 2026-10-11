import AppKit
import EngineKit
import SwiftUI

struct AssetEditor: View {
    @EnvironmentObject var model: EditorModel
    let id: UUID

    var body: some View {
        if model.project?.sprites[id] != nil { SpriteEditor(id: id) }
        else if model.project?.tilesets[id] != nil { TilesetEditor(id: id) }
        else if model.project?.platformers[id] != nil { PhysicsView() }
        else if model.project?.dialogues[id] != nil { DialogueEditor(id: id) }
        else if model.project?.textboxes[id] != nil { TextBoxPreview(id: id) }
        else { Text("Nothing to edit here").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}

// MARK: - Sprite editor

struct SpriteEditor: View {
    @EnvironmentObject var model: EditorModel
    let id: UUID
    @State private var selectedAnim = 0
    @State private var dragging = false

    var stored: Stored<SpriteAsset>? { model.project?.sprites[id] }

    var sprite: Binding<SpriteAsset> {
        Binding(get: { model.project!.sprites[id]!.value }, set: { v in model.project?.sprites[id]?.value = v })
    }

    var body: some View {
        if let stored {
            let url = model.project!.imageURL(assetPath: stored.path, image: stored.value.image)
            HSplitView {
                VStack(alignment: .leading, spacing: Space.sm) {
                    settings
                    sheet(url, stored.value)
                }
                .padding(Space.md)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: Space.md) {
                    animationList
                    Divider()
                    preview(url, stored.value)
                }
                .padding(Space.md)
                .frame(minWidth: 280, idealWidth: 320, maxHeight: .infinity, alignment: .topLeading)
            }
            .id(model.artVersion)
        }
    }

    var settings: some View {
        // Two rows with a fixed label column, so the controls fit a narrow pane
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Text("Frame size").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                IntField(label: "", value: edit(\.frameWidth), width: 48)
                Text("×").foregroundStyle(.secondary)
                IntField(label: "", value: edit(\.frameHeight), width: 48)
                Spacer()
                Button("Replace Image…") { replaceImage() }
            }
            HStack(spacing: Space.sm) {
                Text("Pivot").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                IntField(label: "X", value: edit(\.pivotX), width: 48)
                IntField(label: "Y", value: edit(\.pivotY), width: 48)
                Spacer()
                Menu("Set Pivot") {
                    Button("Bottom Center") { model.checkpoint(); sprite.wrappedValue.pivotX = sprite.wrappedValue.frameWidth / 2; sprite.wrappedValue.pivotY = sprite.wrappedValue.frameHeight }
                    Button("Center") { model.checkpoint(); sprite.wrappedValue.pivotX = sprite.wrappedValue.frameWidth / 2; sprite.wrappedValue.pivotY = sprite.wrappedValue.frameHeight / 2 }
                    Button("Top Left") { model.checkpoint(); sprite.wrappedValue.pivotX = 0; sprite.wrappedValue.pivotY = 0 }
                }
                .fixedSize()
            }
        }
        .font(Typo.label)
        .controlSize(.small)
    }

    func edit(_ kp: WritableKeyPath<SpriteAsset, Int>) -> Binding<Int> {
        Binding(get: { sprite.wrappedValue[keyPath: kp] }, set: { v in model.checkpoint(); sprite.wrappedValue[keyPath: kp] = max(0, min(256, v)) })
    }

    func sheet(_ url: URL, _ s: SpriteAsset) -> some View {
        let img = model.art.bitmap(url)
        let cols = max(1, (img?.width ?? 1) / max(1, s.frameWidth)), rows = max(1, (img?.height ?? 1) / max(1, s.frameHeight))
        let animFrames = s.animations.indices.contains(selectedAnim) ? s.animations[selectedAnim].frames : []
        return VStack(alignment: .leading, spacing: Space.xs) {
            GeometryReader { geo in
                let scale = max(1, min(geo.size.width / CGFloat(img?.width ?? 1), geo.size.height / CGFloat(img?.height ?? 1)))
                let fw = CGFloat(s.frameWidth) * scale, fh = CGFloat(s.frameHeight) * scale
                ZStack(alignment: .topLeading) {
                    Checkerboard()
                    PixelImage(bitmap: img)
                    Canvas { ctx, size in
                        for r in 0..<rows { for c in 0..<cols {
                            let i = r * cols + c
                            let rect = CGRect(x: CGFloat(c) * fw, y: CGFloat(r) * fh, width: fw, height: fh)
                            ctx.stroke(Path(rect), with: .color(.accentColor.opacity(0.5)), lineWidth: 1)
                            if animFrames.contains(i) { ctx.fill(Path(rect), with: .color(.accentColor.opacity(0.18))) }
                            ctx.draw(Text("\(i)").font(Typo.captionStrong).foregroundColor(.accentColor),
                                     at: CGPoint(x: rect.minX + 7, y: rect.minY + 7))
                        } }
                    }
                    Color.clear.contentShape(Rectangle()).onTapGesture { loc in
                        let c = Int(loc.x / fw), r = Int(loc.y / fh)
                        guard c < cols, r < rows, sprite.wrappedValue.animations.indices.contains(selectedAnim) else { return }
                        model.checkpoint()
                        sprite.wrappedValue.animations[selectedAnim].frames.append(r * cols + c)
                    }
                }
                .frame(width: CGFloat(img?.width ?? 0) * scale, height: CGFloat(img?.height ?? 0) * scale)
            }
        }
    }

    var animationList: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                SectionLabel("ANIMATIONS")
                Spacer()
                Button {
                    model.checkpoint()
                    sprite.wrappedValue.animations.append(SpriteAnimation(name: "anim\(sprite.wrappedValue.animations.count)", frames: [], fps: 8))
                    selectedAnim = sprite.wrappedValue.animations.count - 1
                } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
            }
            ForEach(Array(sprite.wrappedValue.animations.enumerated()), id: \.element.id) { i, a in
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack {
                        TextField("name", text: Binding(get: { a.name }, set: { v in model.checkpoint(); sprite.wrappedValue.animations[i].name = v }))
                            .textFieldStyle(.roundedBorder).frame(width: 90)
                        Stepper("\(a.fps) fps", value: Binding(get: { a.fps }, set: { v in model.checkpoint(); sprite.wrappedValue.animations[i].fps = max(0, min(60, v)) }))
                            .fixedSize()
                        Toggle("Loop", isOn: Binding(get: { a.loop }, set: { v in model.checkpoint(); sprite.wrappedValue.animations[i].loop = v }))
                            .toggleStyle(.checkbox)
                        Spacer()
                        Button { model.checkpoint(); sprite.wrappedValue.animations.remove(at: i); selectedAnim = 0 } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    HStack {
                        Text("Frames").font(Typo.caption).foregroundStyle(.secondary)
                        TextField("0, 1, 2", text: Binding(get: { a.frames.map(String.init).joined(separator: ", ") }, set: { v in
                            model.checkpoint()
                            sprite.wrappedValue.animations[i].frames = v.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
                        }))
                        .textFieldStyle(.roundedBorder).font(Typo.mono)
                        Button("Clear") { model.checkpoint(); sprite.wrappedValue.animations[i].frames = [] }.controlSize(.mini)
                    }
                }
                .padding(Space.sm)
                .background(selectedAnim == i ? Tone.selected : Tone.well, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(Rectangle())
                .onTapGesture { selectedAnim = i }
            }
        }
        .controlSize(.small)
    }

    func preview(_ url: URL, _ s: SpriteAsset) -> some View {
        let frames = model.art.frames(url, w: s.frameWidth, h: s.frameHeight)
        let anim = s.animations.indices.contains(selectedAnim) ? s.animations[selectedAnim] : nil
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel("PREVIEW")
            TimelineView(.periodic(from: .now, by: 1.0 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let seq = anim?.frames ?? [0]
                let fi = seq.isEmpty ? 0 : seq[Int(t * Double(max(anim?.fps ?? 1, 1))) % seq.count]
                GeometryReader { geo in
                    let scale = min(geo.size.width / CGFloat(s.frameWidth), geo.size.height / CGFloat(s.frameHeight))
                    ZStack(alignment: .topLeading) {
                        Checkerboard()
                        if fi < frames.count { PixelImage(bitmap: frames[fi]).frame(width: CGFloat(s.frameWidth) * scale, height: CGFloat(s.frameHeight) * scale) }
                        Path { p in
                            let px = CGFloat(s.pivotX) * scale, py = CGFloat(s.pivotY) * scale
                            p.move(to: CGPoint(x: px - 8, y: py)); p.addLine(to: CGPoint(x: px + 8, y: py))
                            p.move(to: CGPoint(x: px, y: py - 8)); p.addLine(to: CGPoint(x: px, y: py + 8))
                        }
                        .stroke(Tone.danger, lineWidth: 2)
                    }
                }
            }
            .frame(width: 180, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        }
    }

    func replaceImage() {
        guard let stored, let p = model.project else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let dest = p.imageURL(assetPath: stored.path, image: stored.value.image)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: src, to: dest)
        model.refreshFromDisk()
    }
}

// MARK: - Tileset editor

struct TilesetEditor: View {
    @EnvironmentObject var model: EditorModel
    let id: UUID
    private var selected: Int {
        get { model.tilesetSelection[id] ?? 0 }
        nonmutating set { model.tilesetSelection[id] = newValue }
    }

    var tileset: Binding<TilesetAsset> {
        Binding(get: { model.project!.tilesets[id]!.value }, set: { v in model.project?.tilesets[id]?.value = v })
    }

    var body: some View {
        if let stored = model.project?.tilesets[id] {
            let url = model.project!.imageURL(assetPath: stored.path, image: stored.value.image)
            let img = model.art.bitmap(url)
            let cols = max(1, (img?.width ?? 16) / 16), rows = max(1, (img?.height ?? 16) / 16)
            HSplitView {
                VStack(alignment: .leading, spacing: Space.sm) {
                    GeometryReader { geo in
                        let scale = max(1, min(geo.size.width / CGFloat(cols * 16), geo.size.height / CGFloat(rows * 16)))
                        let ts = 16 * scale
                        ZStack(alignment: .topLeading) {
                            Checkerboard()
                            PixelImage(bitmap: img)
                            Canvas { ctx, _ in
                                for i in 0..<(cols * rows) {
                                    let r = CGRect(x: CGFloat(i % cols) * ts, y: CGFloat(i / cols) * ts, width: ts, height: ts)
                                    let props = stored.value.props(i)
                                    switch props.collision {
                                    case .solid: ctx.fill(Path(r.insetBy(dx: 1, dy: 1)), with: .color(.green.opacity(0.18)))
                                    case .oneway: ctx.fill(Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: 4)), with: .color(.green.opacity(0.7)))
                                    case .none: break
                                    }
                                    if !props.flags.isEmpty {
                                        let hb = props.hitbox ?? [0, 0, 16, 16]
                                        let hr = CGRect(x: r.minX + CGFloat(hb[0]) * scale, y: r.minY + CGFloat(hb[1]) * scale, width: CGFloat(hb[2]) * scale, height: CGFloat(hb[3]) * scale)
                                        ctx.stroke(Path(hr), with: .color(.red), lineWidth: 1.5)
                                    }
                                    ctx.stroke(Path(r), with: .color(i == selected ? .accentColor : .white.opacity(0.25)), lineWidth: i == selected ? 3 : 1)
                                }
                            }
                            Color.clear.contentShape(Rectangle()).onTapGesture { loc in
                                let c = Int(loc.x / ts), r = Int(loc.y / ts)
                                if c < cols && r < rows { selected = r * cols + c }
                            }
                        }
                        .frame(width: CGFloat(cols) * ts, height: CGFloat(rows) * ts)
                    }
                }
                .padding(Space.md)
                .frame(minWidth: 320)
                tileProps(img, cols: cols)
                    .padding(Space.md)
                    .frame(minWidth: 260, idealWidth: 280)
            }
            .id(model.artVersion)
        }
    }

    func tileProps(_ img: Bitmap?, cols: Int) -> some View {
        let key = String(selected)
        let props = Binding<TileProps>(get: { tileset.wrappedValue.tiles[key] ?? TileProps() },
                                       set: { v in model.checkpoint(); tileset.wrappedValue.tiles[key] = v })
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                PixelImage(bitmap: img?.crop(x: (selected % cols) * 16, y: (selected / cols) * 16, w: 16, h: 16))
                    .frame(width: 64, height: 64).background(Checkerboard())
                VStack(alignment: .leading) {
                    Text("Tile \(selected + 1)").font(Typo.title)
                    Text("grid cell \(selected)").font(Typo.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Collision", selection: props.collision) {
                Text("None").tag(TileCollision.none)
                Text("Solid").tag(TileCollision.solid)
                Text("One-way").tag(TileCollision.oneway)
            }
            .pickerStyle(.segmented)
            SectionLabel("FLAGS")
            ForEach(model.project?.settings.tileFlags ?? [], id: \.self) { flag in
                Toggle(flag, isOn: Binding(get: { props.wrappedValue.flags.contains(flag) }, set: { on in
                    var p = props.wrappedValue
                    if on { p.flags.append(flag) } else { p.flags.removeAll { $0 == flag } }
                    props.wrappedValue = p
                }))
            }
            Toggle("Custom flag hitbox", isOn: Binding(get: { props.wrappedValue.hitbox != nil }, set: { on in
                var p = props.wrappedValue
                p.hitbox = on ? [2, 2, 12, 12] : nil
                props.wrappedValue = p
            }))
            if let hb = props.wrappedValue.hitbox, hb.count == 4 {
                HStack {
                    ForEach(0..<4, id: \.self) { k in
                        IntField(label: ["X", "Y", "W", "H"][k], value: Binding(get: { hb[k] }, set: { v in
                            var p = props.wrappedValue
                            p.hitbox?[k] = max(0, min(16, v))
                            props.wrappedValue = p
                        }), width: 36)
                    }
                }
            }
            Spacer()
        }
    }
}
