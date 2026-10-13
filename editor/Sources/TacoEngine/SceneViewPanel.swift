import AppKit
import EngineKit
import SwiftUI

/// Renders tilemaps and entity sprites for the Scene view (cached).
@MainActor
final class SceneRenderer {
    private var tileImages: [String: [CGImage?]] = [:]
    private var mapCache: (key: Int, image: CGImage)?

    func tiles(_ model: EditorModel, _ tilesetID: UUID?) -> [CGImage?] {
        guard let id = tilesetID, let p = model.project, let ts = p.tilesets[id] else { return [] }
        let url = p.imageURL(assetPath: ts.path, image: ts.value.image)
        let key = url.path + "#\(model.artVersion)"
        if let t = tileImages[key] { return t }
        let frames = model.art.frames(url, w: cellSize, h: cellSize)
        let imgs: [CGImage?] = [nil] + frames.map { $0.cgImage() }   // tile N = frame N-1
        tileImages[key] = imgs
        return imgs
    }

    /// The whole tile layer as one image
    func map(_ model: EditorModel, _ scene: SceneAsset) -> CGImage? {
        var hasher = Hasher()
        hasher.combine(scene.cells)
        hasher.combine(scene.width)
        hasher.combine(scene.tileset)
        hasher.combine(model.artVersion)
        let key = hasher.finalize()
        if let c = mapCache, c.key == key { return c.image }
        let tiles = tiles(model, scene.tileset)
        let w = scene.width * cellSize, h = scene.height * cellSize
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        for y in 0..<scene.height {
            for x in 0..<scene.width {
                let t = scene[x, y]
                guard t > 0, t < tiles.count, let img = tiles[t] else { continue }
                ctx.draw(img, in: CGRect(x: x * cellSize, y: h - (y + 1) * cellSize, width: cellSize, height: cellSize))
            }
        }
        guard let img = ctx.makeImage() else { return nil }
        mapCache = (key, img)
        return img
    }

    /// First frame of the entity's current animation, with frame geometry
    func spriteFrame(_ model: EditorModel, _ comp: SpriteComponent?) -> (Bitmap, SpriteAsset)? {
        guard let comp, let sid = comp.sprite, let p = model.project, let s = p.sprites[sid] else { return nil }
        let frames = model.art.frames(p.imageURL(assetPath: s.path, image: s.value.image), w: s.value.frameWidth, h: s.value.frameHeight)
        let anim = s.value.animations.first { $0.name == comp.animation } ?? s.value.animations.first
        let idx = anim?.frames.first ?? 0
        guard idx < frames.count else { return nil }
        return (frames[idx], s.value)
    }
}

/// Pan and zoom for the Scene view. Trackpad: two-finger scroll pans, pinch zooms. Mouse: wheel zooms,
/// right- or middle-drag pans. ⌘/⌥-scroll zooms too. Zoom happens around the cursor.
@MainActor
final class SceneCamera: ObservableObject {
    @Published var zoom: CGFloat = 2
    @Published var pan: CGPoint = CGPoint(x: 40, y: 40)
    var cursor: CGPoint?            // view coordinates while the pointer is over the canvas
    var viewSize: CGSize = .zero
    var sceneSize: CGSize = .zero   // px
    var framed: UUID?
    /// A right-click that didn't pan (view coordinates): the Scene view's context menu
    var onRightClick: ((CGPoint) -> Void)?
    private var rightDrag: CGFloat = 0
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .rightMouseDragged, .otherMouseDragged, .rightMouseDown, .rightMouseUp]) { [weak self] e in
            let input = PointerInput(e)   // local monitors run on the main thread
            let handled = MainActor.assumeIsolated { self?.handle(input) ?? false }
            return handled ? nil : e
        }
    }

    func remove() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    /// The parts of an NSEvent the camera needs (plain values, safe to hand across isolation)
    struct PointerInput: Sendable {
        enum Kind: Sendable { case magnify, scroll, drag, rightDown, rightUp, other }
        let kind: Kind
        let magnification, dx, dy: CGFloat
        let precise, zoomKey: Bool
        init(_ e: NSEvent) {
            switch e.type {
            case .magnify: kind = .magnify
            case .scrollWheel: kind = .scroll
            case .rightMouseDragged, .otherMouseDragged: kind = .drag
            case .rightMouseDown: kind = .rightDown
            case .rightMouseUp: kind = .rightUp
            default: kind = .other
            }
            magnification = e.type == .magnify ? e.magnification : 0
            dx = e.type == .scrollWheel ? e.scrollingDeltaX : (kind == .drag ? e.deltaX : 0)
            dy = e.type == .scrollWheel ? e.scrollingDeltaY : (kind == .drag ? e.deltaY : 0)
            precise = e.type == .scrollWheel && e.hasPreciseScrollingDeltas
            zoomKey = e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option)
        }
    }

    private func handle(_ e: PointerInput) -> Bool {
        guard let p = cursor else { return false }
        switch e.kind {
        case .magnify:
            zoom(by: 1 + e.magnification, at: p)
        case .scroll:
            if e.precise && !e.zoomKey {
                pan.x += e.dx
                pan.y += e.dy
                clamp()
            } else {
                let dy = e.precise ? e.dy / 40 : e.dy
                guard dy != 0 else { return true }
                zoom(by: pow(1.12, dy > 0 ? min(dy, 3) : max(dy, -3)), at: p)
            }
        case .drag:
            pan.x += e.dx
            pan.y += e.dy
            rightDrag += abs(e.dx) + abs(e.dy)
            clamp()
        case .rightDown:
            rightDrag = 0
            return false
        case .rightUp:
            // Only a click opens the menu: right-dragging pans
            if rightDrag < 4, let menu = onRightClick { DispatchQueue.main.async { menu(p) } }
            return false
        case .other:
            return false
        }
        return true
    }

    func zoom(by factor: CGFloat, at p: CGPoint) {
        let newZoom = min(8, max(0.25, zoom * factor))
        let sx = (p.x - pan.x) / zoom, sy = (p.y - pan.y) / zoom
        zoom = newZoom
        pan = CGPoint(x: p.x - sx * newZoom, y: p.y - sy * newZoom)
        clamp()
    }

    func set(zoom z: CGFloat) {
        zoom(by: z / zoom, at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    /// Fit the whole scene in the view
    func fit() {
        guard viewSize.width > 0, sceneSize.width > 0 else { return }
        zoom = max(0.25, min(8, min((viewSize.width - 60) / sceneSize.width, (viewSize.height - 60) / sceneSize.height)))
        zoom = zoom >= 1 ? zoom.rounded(.down) : zoom
        pan = CGPoint(x: (viewSize.width - sceneSize.width * zoom) / 2, y: (viewSize.height - sceneSize.height * zoom) / 2)
    }

    /// Keep at least a bit of the scene on screen
    func clamp() {
        let w = sceneSize.width * zoom, h = sceneSize.height * zoom, keep: CGFloat = 60
        pan.x = min(max(pan.x, keep - w), viewSize.width - keep)
        pan.y = min(max(pan.y, keep - h), viewSize.height - keep)
    }
}

struct SceneViewPanel: View {
    @EnvironmentObject var model: EditorModel
    @StateObject private var camera = SceneCamera()
    @State private var renderer = SceneRenderer()
    @State private var hover: CGPoint?
    /// Moving entities: which ones, where each started (its own, parent-relative position), where the drag started,
    /// which axis the gizmo limits it to (nil = free), whether anything moved yet
    struct Drag { var ids: [UUID]; var start: [UUID: (Int, Int)]; var from: CGPoint; var axis: Character?; var moved: Bool }
    @State private var dragging: Drag?
    @State private var draggingPathEnd: (id: UUID, script: Int, moved: Bool)?   // a Patroller's point B
    @State private var painting = false
    @State private var rectFrom: (x: Int, y: Int)?   // Rectangle tool: the corner where the drag started

    var body: some View {
        if let scene = model.scene {
            VStack(spacing: 0) {
                topBar(scene)
                Divider()
                HStack(spacing: 0) {
                    if model.tool != .select { TilePalette(tileset: scene.tileset).frame(width: 132) ; Divider() }
                    canvas(scene)
                }
            }
        } else {
            VStack(spacing: Space.md) {
                Text("No scene open").foregroundStyle(.secondary)
                Button("New Scene") { model.createScene() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func topBar(_ scene: SceneAsset) -> some View {
        HStack(spacing: Space.md) {
            Toggle("Grid", isOn: $model.showGrid)
            Toggle("Colliders", isOn: $model.showColliders)
            Toggle("Snap 8px", isOn: $model.snap)
            Spacer()
            if let h = hover {
                Text("x \(Int(h.x))  y \(Int(h.y))   cell \(Int(h.x) / 16), \(Int(h.y) / 16)")
                    .font(Typo.captionDigits).foregroundStyle(.secondary)
            }
            Menu("\(Int((camera.zoom * 100).rounded()))%") {
                ForEach([0.5, 1, 2, 3, 4, 6], id: \.self) { z in Button("\(Int(z * 100))%") { camera.set(zoom: z) } }
                Divider()
                Button("Fit Scene") { camera.fit() }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Pinch or use the scroll wheel to zoom; two-finger scroll or right-drag to pan")
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
    }

    func canvas(_ scene: SceneAsset) -> some View {
        let z = camera.zoom
        let world = scene.worldPositions()
        let W = CGFloat(scene.width * cellSize) * z, H = CGFloat(scene.height * cellSize) * z
        let content = ZStack(alignment: .topLeading) {
            Color(hex: scene.background)
            if let img = renderer.map(model, scene) {
                Image(decorative: img, scale: 1).interpolation(.none).resizable().frame(width: W, height: H)
            }
            ForEach(scene.entities) { e in entityView(e, z, world[e.guid] ?? (e.x, e.y)) }
            gizmos(scene, z).allowsHitTesting(false)
            interaction(scene, z)
        }
        .frame(width: W, height: H)
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                content.offset(x: camera.pan.x, y: camera.pan.y)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())   // clipping only hides the scene outside the view; this stops it catching clicks there too
            .onContinuousHover { phase in
                if case .active(let p) = phase { camera.cursor = p } else { camera.cursor = nil }
            }
            .onAppear {
                camera.viewSize = geo.size
                camera.sceneSize = CGSize(width: scene.width * cellSize, height: scene.height * cellSize)
                camera.install()
                camera.onRightClick = { p in showContextMenu(CGPoint(x: (p.x - camera.pan.x) / camera.zoom, y: (p.y - camera.pan.y) / camera.zoom)) }
                if camera.framed != model.openScene { camera.fit(); camera.framed = model.openScene }
            }
            .onDisappear { camera.remove(); camera.cursor = nil; camera.onRightClick = nil }
            .onChange(of: geo.size) { _, s in camera.viewSize = s }
            .onChange(of: model.openScene) { _, id in
                if let sc = model.scene { camera.sceneSize = CGSize(width: sc.width * cellSize, height: sc.height * cellSize) }
                camera.fit(); camera.framed = id
            }
            .onChange(of: scene.width * 1000 + scene.height) { _, _ in
                camera.sceneSize = CGSize(width: scene.width * cellSize, height: scene.height * cellSize)
            }
            .dropDestination(for: String.self) { items, location in
                guard let s = items.first, let id = UUID(uuidString: s), model.project?.prefabs[id] != nil else { return false }
                model.instantiate(prefab: id, at: CGPoint(x: (location.x - camera.pan.x) / z, y: (location.y - camera.pan.y) / z))
                return true
            }
        }
    }

    // Entity sprite (or an icon for sprite-less entities)
    @ViewBuilder func entityView(_ e: SceneEntity, _ z: CGFloat, _ w: (x: Int, y: Int)) -> some View {
        let def = model.def(e)
        if let (frame, s) = renderer.spriteFrame(model, def.sprite), !(def.sprite?.hidden ?? false) {
            let flip = def.sprite?.flipX ?? false
            let x = CGFloat(flip ? w.x - (s.frameWidth - s.pivotX) : w.x - s.pivotX) * z
            PixelImage(bitmap: frame)
                .frame(width: CGFloat(s.frameWidth) * z, height: CGFloat(s.frameHeight) * z)
                .scaleEffect(x: flip ? -1 : 1, y: 1)
                .offset(x: x, y: CGFloat(w.y - s.pivotY) * z)
                .allowsHitTesting(false)
        } else {
            VStack(spacing: 0) {
                Image(systemName: def.scripts.isEmpty ? "cube" : "curlybraces.square")
                    .font(Typo.body)
                Text(e.name).font(Typo.caption)
            }
            .padding(Space.xs)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: Radius.control))
            .foregroundStyle(.white)
            .fixedSize()
            .offset(x: CGFloat(w.x) * z - 10, y: CGFloat(w.y) * z - 30)
            .allowsHitTesting(false)
        }
    }

    /// Bounds of an entity in scene pixels (sprite, else collider, else a 16x16 box)
    func bounds(_ e0: SceneEntity) -> CGRect {
        var e = e0
        if let w = model.scene?.worldPosition(of: e0) { e.x = w.x; e.y = w.y }
        let def = model.def(e)
        if let (_, s) = renderer.spriteFrame(model, def.sprite) {
            let flip = def.sprite?.flipX ?? false
            return CGRect(x: flip ? e.x - (s.frameWidth - s.pivotX) : e.x - s.pivotX, y: e.y - s.pivotY, width: s.frameWidth, height: s.frameHeight)
        }
        if let c = def.collider { return CGRect(x: e.x + c.x, y: e.y + c.y, width: c.w, height: c.h) }
        return CGRect(x: e.x - 12, y: e.y - 30, width: 24, height: 30)
    }

    func gizmos(_ scene: SceneAsset, _ z: CGFloat) -> some View {
        Canvas { ctx, size in
            if model.showGrid && z >= 1 {
                var grid = Path()
                for x in 0...scene.width { grid.move(to: CGPoint(x: CGFloat(x * 16) * z, y: 0)); grid.addLine(to: CGPoint(x: CGFloat(x * 16) * z, y: size.height)) }
                for y in 0...scene.height { grid.move(to: CGPoint(x: 0, y: CGFloat(y * 16) * z)); grid.addLine(to: CGPoint(x: size.width, y: CGFloat(y * 16) * z)) }
                ctx.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
            }
            // Screen boundaries (what one GBA screen shows)
            var screens = Path()
            for x in stride(from: 240, to: scene.width * 16, by: 240) { screens.move(to: CGPoint(x: CGFloat(x) * z, y: 0)); screens.addLine(to: CGPoint(x: CGFloat(x) * z, y: size.height)) }
            for y in stride(from: 160, to: scene.height * 16, by: 160) { screens.move(to: CGPoint(x: 0, y: CGFloat(y) * z)); screens.addLine(to: CGPoint(x: size.width, y: CGFloat(y) * z)) }
            ctx.stroke(screens, with: .color(scene.cameraMode == .screens ? .orange : .white.opacity(0.25)),
                       style: StrokeStyle(lineWidth: scene.cameraMode == .screens ? 2 : 1, dash: [8, 6]))
            let world = scene.worldPositions()
            let selected = model.entitySelection
            for e0 in scene.entities {
                var e = e0
                if let w = world[e0.guid] { e.x = w.x; e.y = w.y }
                let def = model.def(e0)
                if model.showColliders, let c = def.collider {
                    let r = CGRect(x: CGFloat(e.x + c.x) * z, y: CGFloat(e.y + c.y) * z, width: CGFloat(c.w) * z, height: CGFloat(c.h) * z)
                    ctx.stroke(Path(r), with: .color(c.trigger ? .yellow : c.platform ? .cyan : .green), style: StrokeStyle(lineWidth: c.platform ? 2 : 1, dash: c.trigger ? [3, 3] : []))
                }
                if selected.contains(e.guid) || model.selection == .entity(e.guid) {
                    let b = bounds(e0)
                    let r = CGRect(x: b.minX * z, y: b.minY * z, width: b.width * z, height: b.height * z).insetBy(dx: -2, dy: -2)
                    ctx.stroke(Path(r), with: .color(.accentColor), lineWidth: 2)
                    // pivot
                    let p = CGPoint(x: CGFloat(e.x) * z, y: CGFloat(e.y) * z)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: p.x - 5, y: p.y)); $0.addLine(to: CGPoint(x: p.x + 5, y: p.y))
                        $0.move(to: CGPoint(x: p.x, y: p.y - 5)); $0.addLine(to: CGPoint(x: p.x, y: p.y + 5)) },
                               with: .color(.accentColor), lineWidth: 1.5)
                }
            }
            // Move gizmo on the selected entity: red X arrow, green Y arrow (up), a square for free moves
            if model.tool == .select, case .entity(let sel) = model.selection, let w = world[sel] {
                let p = CGPoint(x: CGFloat(w.x) * z, y: CGFloat(w.y) * z)
                let len = Self.gizmoLength
                func arrow(_ to: CGPoint, _ color: Color, _ head: [CGPoint]) {
                    ctx.stroke(Path { $0.move(to: p); $0.addLine(to: to) }, with: .color(color), lineWidth: 2.5)
                    ctx.fill(Path { $0.move(to: head[0]); $0.addLine(to: head[1]); $0.addLine(to: head[2]); $0.closeSubpath() }, with: .color(color))
                }
                arrow(CGPoint(x: p.x + len, y: p.y), .red, [CGPoint(x: p.x + len + 9, y: p.y), CGPoint(x: p.x + len, y: p.y - 5), CGPoint(x: p.x + len, y: p.y + 5)])
                arrow(CGPoint(x: p.x, y: p.y - len), .green, [CGPoint(x: p.x, y: p.y - len - 9), CGPoint(x: p.x - 5, y: p.y - len), CGPoint(x: p.x + 5, y: p.y - len)])
                ctx.fill(Path(CGRect(x: p.x + 4, y: p.y - 16, width: 12, height: 12)), with: .color(.yellow.opacity(0.55)))
                ctx.stroke(Path(CGRect(x: p.x + 4, y: p.y - 16, width: 12, height: 12)), with: .color(.yellow), lineWidth: 1)
            }
            // Patroller paths: dashed line from point A (the entity) to point B, with a handle
            for e in scene.entities {
                guard let (_, b0) = patrolEnd(e) else { continue }
                let w = world[e.guid] ?? (e.x, e.y)
                let b = CGPoint(x: b0.x + CGFloat(w.x - e.x), y: b0.y + CGFloat(w.y - e.y))
                let a = CGPoint(x: CGFloat(w.x) * z, y: CGFloat(w.y) * z), bp = CGPoint(x: b.x * z, y: b.y * z)
                let selected = model.selection == .entity(e.guid)
                ctx.stroke(Path { $0.move(to: a); $0.addLine(to: bp) }, with: .color(.orange.opacity(selected ? 1 : 0.6)),
                           style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: [5, 4]))
                let r: CGFloat = selected ? 6 : 4
                ctx.fill(Path(ellipseIn: CGRect(x: bp.x - r, y: bp.y - r, width: r * 2, height: r * 2)), with: .color(.orange))
                if selected { ctx.draw(Text("B").font(Typo.captionStrong).foregroundColor(.orange), at: CGPoint(x: bp.x + 12, y: bp.y - 10)) }
            }
            if let h = hover, model.tool != .select {
                // The cell under the cursor, or the box the Rectangle tool is dragging out
                let a = rectFrom ?? (Int(h.x) / 16, Int(h.y) / 16), b = (Int(h.x) / 16, Int(h.y) / 16)
                let r = CGRect(x: CGFloat(min(a.0, b.0) * 16) * z, y: CGFloat(min(a.1, b.1) * 16) * z,
                               width: CGFloat((abs(a.0 - b.0) + 1) * 16) * z, height: CGFloat((abs(a.1 - b.1) + 1) * 16) * z)
                if rectFrom != nil { ctx.fill(Path(r), with: .color(.white.opacity(0.2))) }
                ctx.stroke(Path(r), with: .color(.white), lineWidth: 2)
            }
        }
    }

    func interaction(_ scene: SceneAsset, _ z: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = CGPoint(x: p.x / z, y: p.y / z) } else { hover = nil }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let p = CGPoint(x: v.location.x / z, y: v.location.y / z)
                    hover = p
                    switch model.tool {
                    case .select: dragSelect(scene, start: CGPoint(x: v.startLocation.x / z, y: v.startLocation.y / z), now: p)
                    case .paint, .erase: paint(scene, at: p)
                    case .fill: if !painting { fill(scene, at: p) }
                    case .rect: if rectFrom == nil && !painting { startRect(scene, at: p) }
                    }
                }
                .onEnded { v in
                    if let a = rectFrom { endRect(scene, from: a, to: CGPoint(x: v.location.x / z, y: v.location.y / z)) }
                    dragging = nil
                    draggingPathEnd = nil
                    painting = false
                    rectFrom = nil
                })
    }

    /// Point B of an entity's Patroller script: (script index, scene position)
    func patrolEnd(_ e: SceneEntity) -> (Int, CGPoint)? {
        let d = model.def(e)
        guard let i = d.scripts.firstIndex(where: { $0.script == "Patroller" }) else { return nil }
        let info = model.project?.script("Patroller")
        func field(_ n: String) -> Int {
            Int(d.scripts[i].fields[n]?.number ?? info?.fields.first { $0.name == n }?.defaultValue?.number ?? 0)
        }
        return (i, CGPoint(x: e.x + field("toX"), y: e.y + field("toY")))
    }

    func dragSelect(_ scene: SceneAsset, start: CGPoint, now: CGPoint) {
        // Dragging the selected enemy's point B handle
        if draggingPathEnd == nil && dragging == nil, case .entity(let sel) = model.selection,
           let e = scene.entities.first(where: { $0.guid == sel }), let (i, b) = patrolEnd(e),
           hypot(start.x - b.x, start.y - b.y) <= 8 / camera.zoom + 3 {
            draggingPathEnd = (e.guid, i, false)
        }
        if var pe = draggingPathEnd, let e = model.entity(pe.id) {
            var bx = Int(now.x), by = Int(now.y)
            if model.snap { bx = Int((Double(bx) / 8).rounded()) * 8; by = Int((Double(by) / 8).rounded()) * 8 }
            var d = model.def(e)
            guard pe.script < d.scripts.count else { return }
            let nx = JSON.number(Double(bx - e.x)), ny = JSON.number(Double(by - e.y))
            if d.scripts[pe.script].fields["toX"] == nx && d.scripts[pe.script].fields["toY"] == ny { return }
            if !pe.moved { model.checkpoint(); pe.moved = true; draggingPathEnd = pe }
            d.scripts[pe.script].fields["toX"] = nx
            d.scripts[pe.script].fields["toY"] = ny
            model.setDef(e.guid, d)
            return
        }
        if dragging == nil {
            model.focusArea = .scene
            let world = scene.worldPositions()
            // The gizmo of the selected entity first: arrows limit the move to one axis
            var axis: Character? = nil, onGizmo = false
            if case .entity(let sel) = model.selection, let w = world[sel] {
                let z = camera.zoom, len = Self.gizmoLength / z
                let dx = start.x - CGFloat(w.x), dy = start.y - CGFloat(w.y), tol = 6 / z
                if dx >= 4 / z && dx <= 16 / z && dy >= -16 / z && dy <= -4 / z { onGizmo = true }                       // square
                else if abs(dy) <= tol && dx > 0 && dx <= len + 9 / z { onGizmo = true; axis = "x" }                     // red arrow
                else if abs(dx) <= tol && dy < 0 && -dy <= len + 9 / z { onGizmo = true; axis = "y" }                    // green arrow
            }
            if !onGizmo {
                // Topmost entity under the cursor (later entities draw on top)
                guard let hit = scene.entities.reversed().first(where: { bounds($0).contains(start) }) else {
                    if !NSEvent.modifierFlags.contains(.shift) && !NSEvent.modifierFlags.contains(.command) { model.selectEntities([]) }
                    dragging = Drag(ids: [], start: [:], from: start, axis: nil, moved: false)   // nothing to drag; swallow this gesture
                    return
                }
                let mods = NSEvent.modifierFlags
                if mods.contains(.shift) || mods.contains(.command) {
                    model.toggleEntity(hit.guid)
                    dragging = Drag(ids: [], start: [:], from: start, axis: nil, moved: false)
                    return
                }
                if !model.entitySelection.contains(hit.guid) { model.selectEntities([hit.guid]) }
                else { model.selection = .entity(hit.guid) }
            }
            // Move the selected entities, but not ones whose parent is moving too (they come along)
            let sel = model.entitySelection
            let ids = scene.entities.filter { sel.contains($0.guid) && !ancestorSelected($0, sel, scene) }.map(\.guid)
            var starts: [UUID: (Int, Int)] = [:]
            for e in scene.entities where ids.contains(e.guid) { starts[e.guid] = (e.x, e.y) }
            dragging = Drag(ids: ids, start: starts, from: start, axis: axis, moved: false)
        }
        guard var d = dragging, !d.ids.isEmpty else { return }
        var ddx = Int((now.x - d.from.x).rounded()), ddy = Int((now.y - d.from.y).rounded())
        if d.axis == "x" { ddy = 0 }
        if d.axis == "y" { ddx = 0 }
        if model.snap { ddx = Int((Double(ddx) / 8).rounded()) * 8; ddy = Int((Double(ddy) / 8).rounded()) * 8 }
        let changed = d.ids.contains { id in model.entity(id).map { e in (e.x, e.y) != (d.start[id]!.0 + ddx, d.start[id]!.1 + ddy) } ?? false }
        guard changed else { return }
        if !d.moved { model.checkpoint(); d.moved = true; dragging = d }
        for id in d.ids { if let st = d.start[id] { model.updateEntity(id) { $0.x = st.0 + ddx; $0.y = st.1 + ddy } } }
    }

    static let gizmoLength: CGFloat = 40   // screen px

    /// Right-click in the scene (scene pixels)
    func showContextMenu(_ p: CGPoint) {
        guard let sc = model.scene else { return }
        let inside = p.x >= 0 && p.y >= 0 && p.x < CGFloat(sc.width * cellSize) && p.y < CGFloat(sc.height * cellSize)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let play = MenuAction.item("Play From Here") { model.playFromHere(p) }
        play.isEnabled = inside && !model.building
        play.toolTip = "Build and run this scene with the entity tagged Player starting here"
        menu.addItem(play)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func ancestorSelected(_ e: SceneEntity, _ sel: Set<UUID>, _ scene: SceneAsset) -> Bool {
        var p = e.parent, n = 0
        while let pid = p, n < 32 {
            if sel.contains(pid) { return true }
            p = scene.entities.first { $0.guid == pid }?.parent
            n += 1
        }
        return false
    }

    /// What the tile tools put down: the palette tile, or nothing for Erase and ⌥
    var tileValue: Int { model.tool == .erase || NSEvent.modifierFlags.contains(.option) ? 0 : model.paintTile }

    /// ⇧-click with a tile tool picks the tile under the cursor; returns whether it did
    func pickTile(_ scene: SceneAsset, _ cx: Int, _ cy: Int) -> Bool {
        guard NSEvent.modifierFlags.contains(.shift) else { return false }
        if scene[cx, cy] > 0 { model.paintTile = scene[cx, cy] }
        return true
    }

    func fill(_ scene: SceneAsset, at p: CGPoint) {
        let cx = Int(p.x) / 16, cy = Int(p.y) / 16
        painting = true   // one fill per click
        guard cx >= 0, cy >= 0, cx < scene.width, cy < scene.height, !pickTile(scene, cx, cy), scene[cx, cy] != tileValue else { return }
        let value = tileValue
        model.checkpoint()
        model.updateScene { $0.floodFill(cx, cy, with: value) }
    }

    func startRect(_ scene: SceneAsset, at p: CGPoint) {
        let cx = Int(p.x) / 16, cy = Int(p.y) / 16
        guard cx >= 0, cy >= 0, cx < scene.width, cy < scene.height else { return }
        if pickTile(scene, cx, cy) { painting = true; return }
        rectFrom = (cx, cy)
    }

    func endRect(_ scene: SceneAsset, from a: (x: Int, y: Int), to p: CGPoint) {
        let bx = Int(floor(p.x / 16)), by = Int(floor(p.y / 16)), value = tileValue
        var after = scene
        after.fillRect(a.x, a.y, bx, by, with: value)
        guard after.cells != scene.cells else { return }
        model.checkpoint()
        model.updateScene { $0.fillRect(a.x, a.y, bx, by, with: value) }
    }

    func paint(_ scene: SceneAsset, at p: CGPoint) {
        let cx = Int(p.x) / 16, cy = Int(p.y) / 16
        guard cx >= 0, cy >= 0, cx < scene.width, cy < scene.height else { return }
        if pickTile(scene, cx, cy) { return }
        let value = tileValue
        guard scene[cx, cy] != value else { return }
        if !painting { model.checkpoint(); painting = true }
        model.updateScene { $0[cx, cy] = value }
    }
}

/// Tiles of the scene's tileset, to pick what to paint
struct TilePalette: View {
    @EnvironmentObject var model: EditorModel
    let tileset: UUID?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Tiles")
            if let id = tileset, let p = model.project, let ts = p.tilesets[id] {
                let frames = model.art.frames(p.imageURL(assetPath: ts.path, image: ts.value.image), w: 16, h: 16)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: Space.xs), count: 3), spacing: Space.xs) {
                        ForEach(frames.indices, id: \.self) { i in
                            let props = ts.value.props(i)
                            Button { model.paintTile = i + 1; if model.tool == .erase { model.tool = .paint } } label: {
                                PixelImage(bitmap: frames[i])
                                    .frame(width: 32, height: 32)
                                    .background(Checkerboard())
                                    .overlay(RoundedRectangle(cornerRadius: Radius.swatch).stroke(model.paintTile == i + 1 ? Color.accentColor : .clear, lineWidth: 3))
                            }
                            .buttonStyle(.plain)
                            .help("Tile \(i + 1) · \(props.collision.rawValue)\(props.flags.isEmpty ? "" : " · " + props.flags.joined(separator: ", "))")
                        }
                    }
                    .padding(Space.sm)
                }
            } else {
                Text("No tileset").font(Typo.caption).foregroundStyle(.secondary).padding(Space.lg)
                Spacer()
            }
        }
        .id(model.artVersion)
        .help("⌥-drag erases · ⇧-click picks a tile from the scene")
    }
}

/// An NSMenuItem that runs a closure (the item keeps the closure alive)
final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func runAction() { run() }

    static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.runAction), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}
