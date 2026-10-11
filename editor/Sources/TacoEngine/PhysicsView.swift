import EngineKit
import SwiftUI

// Movement tuner: drag points on graphs instead of typing numbers. Styled like the rest of the editor.

/// Colors for the graphs (follow the system appearance and accent color)
enum BP {
    static let background = Color(nsColor: .textBackgroundColor)
    static let panel = Tone.well
    static let yellow = Color.accentColor                  // curves
    static let line = Tone.well          // grid
    static let guide = Color.secondary.opacity(0.5)        // dashed guides
}

enum PhysicsTab: String, CaseIterable, Identifiable {
    case running = "Running", jumping = "Jumping", assists = "Assists", walls = "Walls"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .running: "figure.run"
        case .jumping: "arrow.up.forward"
        case .assists: "hand.raised"
        case .walls: "square.split.1x2"
        }
    }
}

struct PhysicsView: View {
    @EnvironmentObject var store: EditorModel
    @State private var tab: PhysicsTab = .running

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                Picker("", selection: $tab) {
                    ForEach(PhysicsTab.allCases) { t in Label(t.rawValue, systemImage: t.icon).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                Spacer()
                Menu {
                    ForEach(PlatformerSettings.Preset.allCases, id: \.self) { preset in
                        Button(preset.rawValue) {
                            guard let id = store.editingPlatformer else { return }
                            store.checkpoint()
                            store.physics = PlatformerSettings.preset(preset, keeping: id)
                        }
                    }
                } label: {
                    Label("Presets", systemImage: "square.stack")
                }
                .fixedSize()
                .help("Start from a ready-made movement style (Celeste Classic 2, floaty, snappy, double jump…)")
            }
            .controlSize(.small)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            Divider()
            Group {
                switch tab {
                case .running: RunningTab()
                case .jumping: JumpingTab()
                case .assists: AssistsTab()
                case .walls: WallsTab()
                }
            }
            .padding(Space.md)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Shared pieces

extension EditorModel {
    /// The platformer settings asset open in the center panel
    var editingPlatformer: UUID? {
        if case .asset(let id) = center, project?.platformers[id] != nil { return id }
        return nil
    }

    var physics: PlatformerSettings {
        get { editingPlatformer.flatMap { project?.platformers[$0]?.value } ?? PlatformerSettings() }
        set { if let id = editingPlatformer { project?.platformers[id]?.value = newValue } }
    }

    /// Frames of a sprite that uses these settings (for the little previews)
    func previewFrames(_ anim: String) -> (frames: [Bitmap], fps: Int) {
        guard let p = project, let id = editingPlatformer else { return ([], 1) }
        let owner = p.prefabs.values.first { $0.value.def.platformer?.settings == id }?.value.def
            ?? p.scenes.values.flatMap { $0.value.entities.map { p.effectiveDef($0) } }.first { $0.platformer?.settings == id }
        guard let sid = owner?.sprite?.sprite, let s = p.sprites[sid] else { return ([], 1) }
        let all = art.frames(p.imageURL(assetPath: s.path, image: s.value.image), w: s.value.frameWidth, h: s.value.frameHeight)
        let a = s.value.animations.first { $0.name == anim } ?? s.value.animations.first
        let frames = (a?.frames ?? [0]).compactMap { $0 < all.count ? all[$0] : nil }
        return (frames, a?.fps ?? 1)
    }
}

/// Graph background: like the Scene view, a framed canvas with a light grid
struct BlueprintGrid: View {
    var body: some View {
        Canvas { ctx, size in
            var grid = Path()
            for x in stride(from: CGFloat(0), through: size.width, by: 16) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
            for y in stride(from: CGFloat(0), through: size.height, by: 16) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
            ctx.stroke(grid, with: .color(BP.line), lineWidth: 1)
        }
        .background(BP.background)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Tone.border, lineWidth: 1))
    }
}

/// Draggable graph handle (like the Scene view's selection: accent ring, white center)
struct Handle: View {
    var horizontal = false
    var vertical = false
    @State private var hovering = false
    var body: some View {
        ZStack {
            if horizontal {
                HStack(spacing: Space.xl) {
                    Image(systemName: "chevron.left")
                    Image(systemName: "chevron.right")
                }
                .font(Typo.captionStrong).foregroundStyle(.secondary)
            }
            if vertical {
                VStack(spacing: Space.xl) {
                    Image(systemName: "chevron.up")
                    Image(systemName: "chevron.down")
                }
                .font(Typo.captionStrong).foregroundStyle(.secondary)
            }
            Circle().fill(Color.accentColor).frame(width: hovering ? 20 : 18, height: hovering ? 20 : 18)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            Circle().fill(.white).frame(width: 8, height: 8)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .onHover { hovering = $0 }
    }
}

struct Dot: View {
    var body: some View { Circle().fill(Color.secondary).frame(width: 9, height: 9) }
}

/// Labeled native slider row (Inspector style)
struct BPSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var help: String = ""
    @EnvironmentObject var store: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(format(value)).font(Typo.digits).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range) { editing in if editing { store.checkpoint() } }
                .controlSize(.small)
        }
        .help(help)
    }
}

struct BPCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    @EnvironmentObject var store: EditorModel
    var body: some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { store.checkpoint(); isOn = $0 }))
            .toggleStyle(.checkbox)
    }
}

struct Readout: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(Typo.caption).foregroundStyle(.secondary)
            Text(value).font(Typo.heading.monospacedDigit())
        }
    }
}

struct ResetButton: View {
    let action: () -> Void
    @EnvironmentObject var store: EditorModel
    var body: some View {
        Button {
            store.checkpoint()
            action()
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
        }
        .controlSize(.small)
        .help("Reset this page to the defaults")
    }
}

/// Side panel, styled like an Inspector section
struct ControlPanel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: Space.md) { content }.padding(Space.md) }
            .frame(width: 280)
            .background(BP.panel, in: RoundedRectangle(cornerRadius: Radius.control))
    }
}

func seconds(_ frames: Double) -> String { String(format: "%.2f s", frames / 60) }

/// Animation frame of a sprite that uses these settings (for the little previews)
struct PlayerSprite: View {
    @EnvironmentObject var store: EditorModel
    let anim: String
    let time: Double
    var flipped = false
    var body: some View {
        let (frames, fps) = store.previewFrames(anim)
        let i = frames.isEmpty ? 0 : Int(time * Double(max(fps, 1))) % frames.count
        Group {
            if frames.isEmpty { RoundedRectangle(cornerRadius: Radius.swatch).fill(Color.secondary).frame(width: 16, height: 16) }
            else { PixelImage(bitmap: frames[i]) }
        }
        .frame(width: 48, height: 48)
        .scaleEffect(x: flipped ? -1 : 1, y: 1)
    }
}

// MARK: - Running

struct RunningTab: View {
    @EnvironmentObject var store: EditorModel
    @State private var dragging = false
    static let maxSpeed = 4.0
    static let maxFrames = 30.0   // graph spans 0.5 s of acceleration / deceleration

    var body: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            GeometryReader { geo in graph(geo.size) }.background(BlueprintGrid())
            ControlPanel {
                let p = store.physics
                HStack(spacing: Space.xl) {
                    Readout(title: "Top speed", value: String(format: "%.1f tiles/s", p.runSpeed * 60 / 16))
                    Readout(title: "Accel", value: seconds(PhysicsSim.accelFrames(p)))
                    Readout(title: "Decel", value: seconds(PhysicsSim.decelFrames(p)))
                }
                BPSlider(title: "Turn Speed", value: $store.physics.groundTurn, range: 0.02...2,
                         format: { seconds(store.physics.runSpeed * 2 / $0) + " to reverse" },
                         help: "How quickly you change direction on the ground (pushing against your current momentum).")
                BPCheckbox(title: "Instant Movement", isOn: Binding(
                    get: { store.physics.groundAccel >= store.physics.runSpeed && store.physics.groundDecel >= store.physics.runSpeed },
                    set: { on in
                        let p = store.physics
                        store.physics.groundAccel = on ? p.runSpeed : p.runSpeed / 6
                        store.physics.groundDecel = on ? p.runSpeed : p.runSpeed / 5
                        store.physics.groundTurn = on ? p.runSpeed * 2 : p.runSpeed / 3
                    }))
                Spacer(minLength: 0)
                ResetButton {
                    let d = PlatformerSettings()
                    store.physics.runSpeed = d.runSpeed
                    store.physics.groundAccel = d.groundAccel
                    store.physics.groundDecel = d.groundDecel
                    store.physics.groundTurn = d.groundTurn
                }
            }
        }
    }

    func graph(_ size: CGSize) -> some View {
        let p = store.physics
        let W = size.width, H = size.height
        let baseY = H * 0.68, topY = H * 0.24
        let startX = W * 0.05, endX = W * 0.95, mid = W / 2, plateau = W * 0.08
        let range = mid - plateau - startX
        let tA = min(PhysicsSim.accelFrames(p), Self.maxFrames), tD = min(PhysicsSim.decelFrames(p), Self.maxFrames)
        let sy = baseY - CGFloat(p.runSpeed / Self.maxSpeed) * (baseY - topY)
        let ax = startX + CGFloat(tA / Self.maxFrames) * range
        let dx = endX - CGFloat(tD / Self.maxFrames) * range

        return ZStack(alignment: .topLeading) {
            // Speedometer
            Gauge(fraction: p.runSpeed / Self.maxSpeed).frame(width: 110, height: 56).offset(x: 14, y: 14)

            // Guides
            Path { $0.move(to: CGPoint(x: ax, y: topY - 20)); $0.addLine(to: CGPoint(x: ax, y: baseY + 30)) }
                .stroke(BP.guide, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            Path { $0.move(to: CGPoint(x: dx, y: topY - 20)); $0.addLine(to: CGPoint(x: dx, y: baseY + 30)) }
                .stroke(BP.guide, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            Text("Acceleration").font(Typo.title).foregroundStyle(Color.secondary.opacity(0.35))
                .fixedSize().rotationEffect(.degrees(-90)).position(x: ax + 34, y: (topY + baseY) / 2 + 20)
            Text("Deceleration").font(Typo.title).foregroundStyle(Color.secondary.opacity(0.35))
                .fixedSize().rotationEffect(.degrees(-90)).position(x: dx - 34, y: (topY + baseY) / 2 + 20)

            // Speed-over-time curve
            Path { path in
                path.move(to: CGPoint(x: startX, y: baseY))
                path.addLine(to: CGPoint(x: ax, y: sy))
                path.addLine(to: CGPoint(x: dx, y: sy))
                path.addLine(to: CGPoint(x: endX, y: baseY))
            }
            .stroke(BP.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            Dot().position(x: startX, y: baseY)
            Dot().position(x: endX, y: baseY)

            label(seconds(tA), at: CGPoint(x: ax, y: sy + 46))
            label(String(format: "%.2f px/frame", p.runSpeed), at: CGPoint(x: mid, y: sy - 46))
            label(seconds(tD), at: CGPoint(x: dx, y: sy + 46))

            Handle(horizontal: true).position(x: ax, y: sy)
                .gesture(drag { pt in
                    let t = Double(max(0, min(1, (pt.x - startX) / range))) * Self.maxFrames
                    store.physics.groundAccel = t < 1 ? store.physics.runSpeed : store.physics.runSpeed / t
                })
            Handle(vertical: true).position(x: mid, y: sy)
                .gesture(drag { pt in
                    let ta = PhysicsSim.accelFrames(store.physics), td = PhysicsSim.decelFrames(store.physics)
                    let v = Double(max(0.05, min(1, (baseY - pt.y) / (baseY - topY)))) * Self.maxSpeed
                    store.physics.runSpeed = (v * 20).rounded() / 20
                    // keep the same accel/decel times
                    store.physics.groundAccel = ta < 1 ? store.physics.runSpeed : store.physics.runSpeed / ta
                    store.physics.groundDecel = td < 1 ? store.physics.runSpeed : store.physics.runSpeed / td
                })
            Handle(horizontal: true).position(x: dx, y: sy)
                .gesture(drag { pt in
                    let t = Double(max(0, min(1, (endX - pt.x) / range))) * Self.maxFrames
                    store.physics.groundDecel = t < 1 ? store.physics.runSpeed : store.physics.runSpeed / t
                })

            RunPreview(physics: p)
                .frame(width: W, height: H - baseY - 50)
                .offset(y: baseY + 50)
        }
        .coordinateSpace(name: "graph")
    }

    func label(_ s: String, at pt: CGPoint) -> some View {
        Text(s).font(Typo.captionDigits).foregroundStyle(.primary)
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.control))
            .fixedSize()
            .position(pt)
    }

    func drag(_ apply: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("graph"))
            .onChanged { v in
                if !dragging { store.checkpoint(); dragging = true }
                apply(v.location)
            }
            .onEnded { _ in dragging = false }
    }
}

struct Gauge: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width / 2, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: r)
            let a = Angle.degrees(180 + 180 * min(max(fraction, 0), 1))
            ZStack {
                Path { p in p.addArc(center: c, radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false); p.closeSubpath() }
                    .fill(Color.secondary.opacity(0.12))
                Path { p in
                    p.move(to: c)
                    p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a.radians)) * r * 0.85, y: c.y + CGFloat(sin(a.radians)) * r * 0.85))
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                Circle().fill(Color.secondary).frame(width: 8, height: 8).position(c)
            }
        }
    }
}

/// A little character running right then left with the real accel/decel values.
struct RunPreview: View {
    let physics: PlatformerSettings
    var body: some View {
        let track = simulate()
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { ctx in
            GeometryReader { geo in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let i = Int(t * 60) % max(track.count, 1)
                let (x, v) = track.isEmpty ? (0, 0) : track[i]
                let maxX = max(track.map(\.0).max() ?? 1, 1)
                let s = (geo.size.width * 0.8) / CGFloat(maxX)
                ZStack(alignment: .bottomLeading) {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height - 4))
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 4))
                        var tx: CGFloat = 0
                        while tx < geo.size.width { p.move(to: CGPoint(x: tx, y: geo.size.height - 4)); p.addLine(to: CGPoint(x: tx, y: geo.size.height - 22)); tx += 40 }
                    }
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    PlayerSprite(anim: abs(v) > 0.25 ? "run" : "idle", time: t, flipped: v < -0.01)
                        .offset(x: geo.size.width * 0.1 + CGFloat(x) * s - 24, y: -4)
                }
            }
        }
    }

    /// (position px, velocity) per frame for: run right, stop, pause, run left, stop, pause
    func simulate() -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        var x = 0.0, v = 0.0
        func step(_ dir: Double, _ frames: Int) {
            for _ in 0..<frames {
                let target = dir * physics.runSpeed
                let turning = dir != 0 && v != 0 && (dir > 0) != (v > 0)
                let a = turning ? physics.groundTurn : (dir != 0 ? physics.groundAccel : physics.groundDecel)
                if v < target { v = min(v + a, target) } else if v > target { v = max(v - a, target) }
                x += v
                out.append((x, v))
            }
        }
        step(1, 70); step(0, 60); step(-1, 70); step(0, 60)
        // normalize so the track starts at 0
        let minX = out.map(\.0).min() ?? 0
        return out.map { ($0.0 - minX, $0.1) }
    }
}

// MARK: - Jumping

struct JumpingTab: View {
    @EnvironmentObject var store: EditorModel
    @State private var dragging = false
    static let maxT = 100.0     // frames across the graph
    static let maxH = 112.0     // px (7 tiles) up the graph

    var body: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            GeometryReader { geo in graph(geo.size) }.background(BlueprintGrid())
            ControlPanel {
                let p = store.physics
                let a = PhysicsSim.arc(p)
                HStack(spacing: Space.lg) {
                    Readout(title: "Height", value: String(format: "%.1f tiles", a.apexHeight / 16))
                    Readout(title: "Airtime", value: seconds(a.landTime))
                    Readout(title: "Distance", value: String(format: "%.1f tiles", PhysicsSim.jumpDistance(p) / 16))
                }
                BPSlider(title: "Air Acceleration", value: $store.physics.airAccel, range: 0.02...1,
                         help: "Speeding up while airborne.")
                BPSlider(title: "Air Control", value: $store.physics.airTurn, range: 0.02...1,
                         help: "Changing direction mid-air.")
                BPSlider(title: "Air Brake", value: $store.physics.airDecel, range: 0...1,
                         help: "Slowing down in the air when you let go of the D-pad.")
                BPSlider(title: "Apex Hang", value: Binding(get: { 1 - store.physics.apexGravity }, set: { store.physics.apexGravity = 1 - $0 }),
                         range: 0...0.9, format: { String(format: "%.0f%%", $0 * 100) },
                         help: "Floatier peak while jump is held.")
                BPCheckbox(title: "Double Jump", isOn: Binding(
                    get: { store.physics.airJumps > 0 },
                    set: { store.physics.airJumps = $0 ? 1 : 0 }))
                BPSlider(title: "Hold Jump", value: Binding(get: { Double(store.physics.jumpSustainFrames) },
                                                          set: { store.physics.jumpSustainFrames = Int($0.rounded()) }),
                         range: 0...20, format: { $0 < 0.5 ? "off" : "\(Int($0.rounded())) frames" },
                         help: "Celeste-style: holding jump keeps full upward speed for this long (taller when held, short when tapped).")
                BPCheckbox(title: "Variable Height", isOn: Binding(
                    get: { store.physics.jumpCut < 0.99 },
                    set: { store.physics.jumpCut = $0 ? 0.45 : 1.0 }))
                if store.physics.jumpCut < 0.99 {
                    BPSlider(title: "Release Cut", value: $store.physics.jumpCut, range: 0.05...0.95,
                             help: "Letting go of jump multiplies your upward speed by this. Dashed curve = a quick tap.")
                }
                Spacer(minLength: 0)
                ResetButton {
                    let d = PlatformerSettings()
                    store.physics.jumpVelocity = d.jumpVelocity
                    store.physics.gravity = d.gravity
                    store.physics.fallGravity = d.fallGravity
                    store.physics.apexGravity = d.apexGravity
                    store.physics.jumpCut = d.jumpCut
                    store.physics.airAccel = d.airAccel
                    store.physics.airDecel = d.airDecel
                    store.physics.airTurn = d.airTurn
                    store.physics.airJumps = d.airJumps
                    store.physics.jumpSustainFrames = d.jumpSustainFrames
                }
            }
        }
    }

    func graph(_ size: CGSize) -> some View {
        let p = store.physics
        let arc = PhysicsSim.arc(p)
        let tap = PhysicsSim.arc(p, holdFrames: 1)
        let W = size.width, H = size.height
        let ox = W * 0.08, baseY = H * 0.86
        let xs = (W * 0.88) / CGFloat(Self.maxT), ys = (H * 0.78) / CGFloat(Self.maxH)
        func pt(_ t: Double, _ h: Double) -> CGPoint { CGPoint(x: ox + CGFloat(t) * xs, y: baseY - CGFloat(h) * ys) }
        func curve(_ hs: [Double], landTime: Double) -> Path {
            Path { path in
                path.move(to: pt(0, 0))
                for (i, h) in hs.enumerated() where i > 0 { path.addLine(to: pt(min(Double(i), landTime), h)) }
            }
        }
        let apex = pt(arc.apexTime, arc.apexHeight)
        let land = pt(arc.landTime, 0)

        return ZStack(alignment: .topLeading) {
            // Tile-height guides
            ForEach(1..<7) { tiles in
                let y = baseY - CGFloat(tiles * 16) * ys
                Path { $0.move(to: CGPoint(x: ox, y: y)); $0.addLine(to: CGPoint(x: W, y: y)) }
                    .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Text("\(tiles)").font(Typo.captionDigits).foregroundStyle(.secondary)
                    .position(x: ox - 16, y: y)
            }
            Text("tiles").font(Typo.caption).foregroundStyle(.secondary)
                .position(x: ox - 16, y: baseY - 7 * 16 * ys)
            Path { $0.move(to: CGPoint(x: ox - 10, y: baseY)); $0.addLine(to: CGPoint(x: W, y: baseY)) }
                .stroke(Color.secondary.opacity(0.6), lineWidth: 1.5)

            if p.jumpCut < 0.99 {
                curve(tap.heights, landTime: tap.landTime)
                    .stroke(BP.yellow.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5]))
            }
            curve(arc.heights, landTime: arc.landTime)
                .stroke(BP.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

            // Apex guide
            Path { $0.move(to: CGPoint(x: apex.x, y: apex.y)); $0.addLine(to: CGPoint(x: apex.x, y: baseY)) }
                .stroke(BP.guide, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            label(String(format: "%.1f tiles · %@", arc.apexHeight / 16, seconds(arc.apexTime)), at: CGPoint(x: apex.x, y: apex.y - 48))
            label("fall " + seconds(arc.fallTime), at: CGPoint(x: land.x, y: land.y + 34))

            JumpPreview(arc: arc, pt: pt)

            Dot().position(pt(0, 0))
            Handle(horizontal: true, vertical: true).position(apex)
                .gesture(drag { loc in
                    let t = Double((loc.x - ox) / xs), h = Double((baseY - loc.y) / ys)
                    let fall = PhysicsSim.arc(store.physics).fallTime
                    var q = PhysicsSim.solveApex(store.physics, time: min(max(t, 4), 60), height: min(max(h, 8), Self.maxH - 8))
                    q = PhysicsSim.solveFall(q, time: fall)   // keep the fall duration
                    store.physics = q
                })
            Handle(horizontal: true).position(land)
                .gesture(drag { loc in
                    let t = Double((loc.x - ox) / xs)
                    let a = PhysicsSim.arc(store.physics)
                    store.physics = PhysicsSim.solveFall(store.physics, time: max(2, t - a.apexTime))
                })
        }
        .coordinateSpace(name: "jumpgraph")
    }

    func label(_ s: String, at pt: CGPoint) -> some View {
        Text(s).font(Typo.captionDigits).foregroundStyle(.primary)
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.control))
            .fixedSize()
            .position(pt)
    }

    func drag(_ apply: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("jumpgraph"))
            .onChanged { v in
                if !dragging { store.checkpoint(); dragging = true }
                apply(v.location)
            }
            .onEnded { _ in dragging = false }
    }
}

/// The player hopping along the arc in real time
struct JumpPreview: View {
    let arc: PhysicsSim.Arc
    let pt: (Double, Double) -> CGPoint
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let cycle = Int(arc.landTime) + 40
            let f = Int(t * 60) % max(cycle, 1)
            let airborne = f < arc.heights.count - 1
            let h = airborne ? arc.heights[f] : 0
            let x = Double(min(f, arc.heights.count - 1))
            let rising = airborne && f + 1 < arc.heights.count && arc.heights[f + 1] > h
            let p = pt(x, h)
            PlayerSprite(anim: airborne ? (rising ? "jump" : "fall") : "idle", time: t)
                .position(x: p.x, y: p.y - 22)
        }
    }
}

// MARK: - Other pages

struct AssistsTab: View {
    @EnvironmentObject var store: EditorModel
    var body: some View {
        HStack(alignment: .top, spacing: Space.xxl) {
            VStack(alignment: .leading, spacing: Space.xl) {
                frames("Coyote Time", \.coyoteFrames, "You can still jump this long after running off a ledge.")
                frames("Jump Buffer", \.bufferFrames, "A jump pressed this long before landing still happens on landing.")
                BPSlider(title: "Max Fall Speed", value: $store.physics.maxFall, range: 2...8,
                         format: { String(format: "%.1f px/frame", $0) }, help: "Terminal velocity.")
                BPSlider(title: "Apex Threshold", value: $store.physics.apexThreshold, range: 0...2,
                         format: { String(format: "%.2f px/frame", $0) },
                         help: "How close to the peak (in vertical speed) the Apex Hang applies.")
            }
            .frame(maxWidth: 420)
            VStack(alignment: .leading, spacing: Space.xl) {
                BPSlider(title: "Fast Fall (hold Down)", value: $store.physics.fastFallMax, range: 0...8,
                         format: { $0 < 0.05 ? "off" : String(format: "%.1f px/frame", $0) },
                         help: "Falling speed while holding Down.")
                BPSlider(title: "Jump Side Boost", value: $store.physics.jumpBoostX, range: 0...1,
                         format: { String(format: "%.2f px/frame", $0) },
                         help: "Extra sideways speed when you jump while holding a direction.")
                BPSlider(title: "Keep Momentum", value: $store.physics.overspeedDecel, range: 0...0.3,
                         format: { $0 < 0.005 ? "off" : String(format: "%.2f", $0) },
                         help: "Above run speed (after a wall jump or a launch), slow down this gently while still holding that way.")
                BPCheckbox(title: "Auto-Animate", isOn: $store.physics.autoAnimate)
            }
            .frame(maxWidth: 420)
            Spacer()
            ResetButton {
                let d = PlatformerSettings()
                store.physics.coyoteFrames = d.coyoteFrames
                store.physics.bufferFrames = d.bufferFrames
                store.physics.maxFall = d.maxFall
                store.physics.apexThreshold = d.apexThreshold
                store.physics.fastFallMax = d.fastFallMax
                store.physics.jumpBoostX = d.jumpBoostX
                store.physics.overspeedDecel = d.overspeedDecel
                store.physics.autoAnimate = d.autoAnimate
            }
        }
    }

    func frames(_ title: String, _ key: WritableKeyPath<PlatformerSettings, Int>, _ help: String) -> some View {
        BPSlider(title: title, value: Binding(get: { Double(store.physics[keyPath: key]) },
                                              set: { store.physics[keyPath: key] = Int($0.rounded()) }),
                 range: 0...20, format: { "\(Int($0.rounded())) frames (\(seconds($0.rounded())))" }, help: help)
    }
}

struct WallsTab: View {
    @EnvironmentObject var store: EditorModel
    var body: some View {
        HStack(alignment: .top, spacing: Space.xxl) {
            VStack(alignment: .leading, spacing: Space.xl) {
                BPCheckbox(title: "Wall Jumps", isOn: $store.physics.wallJumps)
                BPSlider(title: "Wall Reach", value: Binding(get: { Double(store.physics.wallReach) },
                                                           set: { store.physics.wallReach = max(1, Int($0.rounded())) }),
                         range: 1...8, format: { "\(Int($0.rounded())) px" },
                         help: "How close to a wall you must be to wall jump (Celeste lets you jump from a few pixels away).")
                BPSlider(title: "Wall Slide Speed", value: $store.physics.wallSlideMax, range: 0.2...4,
                         format: { String(format: "%.1f px/frame", $0) }, help: "Fall speed cap while holding toward a wall.")
                BPSlider(title: "Wall Jump Push", value: $store.physics.wallJumpX, range: 0.5...5,
                         format: { String(format: "%.1f px/frame", $0) }, help: "Horizontal kick away from the wall.")
                BPSlider(title: "Wall Jump Height", value: $store.physics.wallJumpY, range: 2...8,
                         format: { String(format: "%.1f px/frame", $0) }, help: "Upward speed of a wall jump.")
                frames("Wall Coyote Time", \.wallCoyoteFrames, "You can still wall jump this long after leaving a wall.")
                frames("Steering Lock", \.wallJumpLockFrames, "Reduced steering right after a wall jump, so you can't instantly cling back.")
            }
            .frame(maxWidth: 520)
            Spacer()
            ResetButton {
                let d = PlatformerSettings()
                store.physics.wallSlideMax = d.wallSlideMax
                store.physics.wallJumpX = d.wallJumpX
                store.physics.wallJumpY = d.wallJumpY
                store.physics.wallCoyoteFrames = d.wallCoyoteFrames
                store.physics.wallJumpLockFrames = d.wallJumpLockFrames
                store.physics.wallJumps = d.wallJumps
                store.physics.wallReach = d.wallReach
            }
        }
    }

    func frames(_ title: String, _ key: WritableKeyPath<PlatformerSettings, Int>, _ help: String) -> some View {
        BPSlider(title: title, value: Binding(get: { Double(store.physics[keyPath: key]) },
                                              set: { store.physics[keyPath: key] = Int($0.rounded()) }),
                 range: 0...20, format: { "\(Int($0.rounded())) frames" }, help: help)
    }
}

