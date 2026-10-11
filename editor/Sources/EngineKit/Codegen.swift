import Foundation

/// Turns a project into C: build/generated/script_types.h (types scripts see) and assets.c (all data).
public enum Codegen {
    public struct Output {
        public var header: String
        public var assets: String
        public var soundData: String       // assembly that pulls the converted sound files into the ROM
        public var warnings: [String]
    }

    public enum Boot: Equatable, Sendable {
        case start, scene(UUID)
    }

    public struct GenError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    static let maxScripts = 6   // MAX_SCRIPTS in engine.h

    // GBA OBJ sizes: (w, h, shape, size)
    static let objSizes: [(Int, Int, Int, Int)] = [
        (8, 8, 0, 0), (16, 16, 0, 1), (32, 32, 0, 2), (64, 64, 0, 3),
        (16, 8, 1, 0), (32, 8, 1, 1), (32, 16, 1, 2), (64, 32, 1, 3),
        (8, 16, 2, 0), (8, 32, 2, 1), (16, 32, 2, 2), (32, 64, 2, 3),
    ]

    public static func objSize(for w: Int, _ h: Int) -> (Int, Int, Int, Int)? {
        objSizes.filter { $0.0 >= w && $0.1 >= h }.min { $0.0 * $0.1 < $1.0 * $1.1 }
    }

    public static func generate(_ p: GameProject, boot: Boot = .start, sounds: [SoundConverter.Converted] = []) throws -> Output {
        var warnings: [String] = []
        let s = p.settings
        guard !s.scenes.isEmpty else { throw GenError(message: "The project has no scenes. Create one in the Project panel.") }
        guard s.tileFlags.count <= 8 else { throw GenError(message: "At most 8 tile flags are supported.") }
        guard s.variables.count <= 64 else { throw GenError(message: "At most 64 variables are supported.") }

        // Stable symbol names
        func sym(_ prefix: String, _ name: String) -> String { prefix + cIdentifier(name) }
        let spriteSym = Dictionary(uniqueKeysWithValues: p.sprites.map { ($0.key, sym("SPRITE_", $0.value.name)) })
        let dialogueSym = Dictionary(uniqueKeysWithValues: p.dialogues.map { ($0.key, sym("DIALOGUE_", $0.value.name)) })
        let prefabSym = Dictionary(uniqueKeysWithValues: p.prefabs.map { ($0.key, sym("PREFAB_", $0.value.name)) })
        let platSym = Dictionary(uniqueKeysWithValues: p.platformers.map { ($0.key, sym("PLATFORMER_", $0.value.name)) })
        let tilesetSym = Dictionary(uniqueKeysWithValues: p.tilesets.map { ($0.key, sym("TILESET_", $0.value.name)) })
        var soundSym: [String: String] = [:]          // sound name -> symbol
        for snd in sounds { soundSym[snd.name] = sym("SOUND_", snd.name) }
        func soundRef(_ name: String?) -> String { name.flatMap { soundSym[$0] }.map { "&\($0)" } ?? "0" }
        for (kind, syms) in [("prefab", prefabSym), ("sprite", spriteSym)] {
            let dupes = Dictionary(grouping: syms.values, by: { $0 }).filter { $0.value.count > 1 }.keys
            if let d = dupes.first { throw GenError(message: "Two \(kind)s share the name \(d) — rename one.") }
        }
        let scripts = p.scripts
        let scriptNames = Dictionary(grouping: scripts, by: \.name).filter { $0.value.count > 1 }.keys
        if let d = scriptNames.first { throw GenError(message: "SCRIPT(\(d)) is declared more than once.") }

        // ---------------- script_types.h ----------------
        var h = CWriter()
        h.line("// Generated from your project by the editor — do not edit.")
        h.line("#ifndef SCRIPT_TYPES_H")
        h.line("#define SCRIPT_TYPES_H")
        h.line()
        h.line("enum { TAG_Untagged" + s.tags.map { ", TAG_\(cIdentifier($0))" }.joined() + " };")
        h.line("enum { " + s.variables.enumerated().map { "VAR_\(cIdentifier($0.element)) = \($0.offset)" }.joined(separator: ", ")
               + (s.variables.isEmpty ? "" : ", ") + "VAR_COUNT = \(s.variables.count) };")
        h.line("enum { TILEFLAG_NONE = 0" + s.tileFlags.enumerated().map { ", TILEFLAG_\(cIdentifier($0.element)) = \(1 << $0.offset)" }.joined() + " };")
        h.line("enum { " + s.scenes.enumerated().map { "SCENE_\(cIdentifier(p.scenes[$0.element]?.name ?? "scene")) = \($0.offset)" }.joined(separator: ", ") + " };")
        h.line()
        for (_, name) in prefabSym.sorted(by: { $0.value < $1.value }) { h.line("extern const Prefab \(name);") }
        for (_, name) in spriteSym.sorted(by: { $0.value < $1.value }) { h.line("extern const SpriteAsset \(name);") }
        for (_, name) in dialogueSym.sorted(by: { $0.value < $1.value }) { h.line("extern const Dialogue \(name);") }
        for name in soundSym.values.sorted() { h.line("extern const SoundAsset \(name);") }
        h.line()
        for (i, sc) in scripts.enumerated() {
            h.line("// \(sc.file.lastPathComponent)")
            h.line("typedef struct \(sc.name) {\(sc.body)} \(sc.name);")
            h.line("#define SCRIPT_ID_\(sc.name) \(i)")
            // Weak, so a callback the script doesn't define is simply NULL instead of a link error
            for cb in ScriptInfo.callbackNames where sc.callbacks.contains(cb) {
                switch cb {
                case "OnTrigger", "OnTriggerExit": h.line("void \(sc.name)_\(cb)(\(sc.name) *self, Entity *e, Entity *other) __attribute__((weak));")
                case "OnMessage": h.line("void \(sc.name)_\(cb)(\(sc.name) *self, Entity *e, int msg, int arg) __attribute__((weak));")
                default: h.line("void \(sc.name)_\(cb)(\(sc.name) *self, Entity *e) __attribute__((weak));")
                }
            }
            h.line()
        }
        h.line("#endif")

        // ---------------- assets.c ----------------
        var c = CWriter()
        c.line("// Generated from your project by the editor — do not edit.")
        c.line("#include \"engine.h\"")
        c.line()
        c.line("const char game_title[] = \(cString(s.name));")
        c.line("const int var_count = \(s.variables.count);")
        c.line("const int show_frame_budget = \(s.showFrameBudget == true ? 1 : 0);")
        c.line("const int player_tag = \(s.tags.firstIndex(of: "Player").map { $0 + 1 } ?? 0);")
        c.line()
        // Sounds: the sample data comes from sounds.s (.incbin of the converted files)
        var asm = "@ Generated from your project by the editor — do not edit.\n    .section .rodata\n"
        for snd in sounds {
            let symName = soundSym[snd.name]!
            c.line("extern const s8 \(symName)_data[];")
            c.line("const SoundAsset \(symName) = { \(cString(snd.name)), \(symName)_data, \(snd.samples) };")
            let stamp = Int(SoundConverter.modified(snd.raw)?.timeIntervalSince1970 ?? 0)   // changes when the sound is reconverted
            asm += "    .align 2\n    .global \(symName)_data\n\(symName)_data:   @ \(stamp)\n    .incbin \"\(snd.raw.path)\"\n"
        }
        if !sounds.isEmpty { c.line() }

        // Sprites
        for (id, stored) in p.sprites.sorted(by: { $0.value.name < $1.value.name }) {
            let a = stored.value
            let name = spriteSym[id]!
            let imgURL = p.imageURL(assetPath: stored.path, image: a.image)
            guard let img = try? Bitmap.load(imgURL) else { throw GenError(message: "Sprite \(stored.name): can't read \(a.image)") }
            // One OBJ when the frame fits (up to 64x64), otherwise pieces of up to 64x64 that move together
            let fw = a.frameWidth, fh = a.frameHeight
            let single = objSize(for: fw, fh)
            guard single != nil || (fw <= 256 && fh <= 256) else {
                throw GenError(message: "Sprite \(stored.name): frames can be at most 256x256 (are \(fw)x\(fh)).")
            }
            let cols = max(1, img.width / max(1, fw)), rows = max(1, img.height / max(1, fh))
            var frames: [Bitmap] = []
            for r in 0..<rows { for col in 0..<cols {
                frames.append(img.crop(x: col * fw, y: r * fh, w: fw, h: fh))
            } }
            var pieces: [(x: Int, y: Int, obj: (Int, Int, Int, Int))] = []
            if let obj = single {
                pieces = [(0, 0, obj)]
            } else {
                for y in stride(from: 0, to: fh, by: 64) { for x in stride(from: 0, to: fw, by: 64) {
                    let obj = objSize(for: min(64, fw - x), min(64, fh - y))!
                    // Leave out pieces that are empty in every frame
                    let used = frames.contains { f in
                        (y..<min(fh, y + 64)).contains { py in (x..<min(fw, x + 64)).contains { px in f[px, py].isOpaque } }
                    }
                    if used { pieces.append((x, y, obj)) }
                } }
                if pieces.isEmpty { pieces = [(0, 0, objSize(for: 8, 8)!)] }
            }
            func piece(_ f: Bitmap, _ pc: (x: Int, y: Int, obj: (Int, Int, Int, Int))) -> Bitmap {
                var out = Bitmap(width: pc.obj.0, height: pc.obj.1)
                for y in 0..<pc.obj.1 where pc.y + y < f.height { for x in 0..<pc.obj.0 where pc.x + x < f.width { out[x, y] = f[pc.x + x, pc.y + y] } }
                return out
            }
            let frameTiles = pieces.reduce(0) { $0 + $1.obj.0 * $1.obj.1 / 64 }
            guard frameTiles <= 512 else {
                throw GenError(message: "Sprite \(stored.name): \(fw)x\(fh) frames use \(frameTiles) tiles; the limit is 512 (half of sprite memory).")
            }
            let pal = Palette16(images: frames)
            if pal.reduced { warnings.append("Sprite \(stored.name): more than 15 colors — reduced to 15.") }
            let words = frames.flatMap { f in pieces.flatMap { tiles4bpp(piece(f, $0), palette: pal) } }
            c.line("static const u32 \(name)_gfx[] = {")
            c.hexRows(words, digits: 8, perLine: 8)
            c.line("};")
            c.line("static const u16 \(name)_pal[16] = {")
            c.hexRows(pal.entries.map { UInt32($0) }, digits: 4, perLine: 16)
            c.line("};")
            var anims = a.animations
            if anims.isEmpty { anims = [SpriteAnimation(name: "default", frames: [0], fps: 0)] }
            for (i, an) in anims.enumerated() {
                let fr = an.frames.isEmpty ? [0] : an.frames.map { max(0, min(frames.count - 1, $0)) }
                c.line("static const u8 \(name)_a\(i)[] = { \(fr.map(String.init).joined(separator: ", ")) };")
            }
            c.line("static const SpriteAnim \(name)_anims[] = {")
            for (i, an) in anims.enumerated() {
                c.line("    { \(cString(an.name)), \(name)_a\(i), \(max(1, an.frames.count)), \(max(0, min(60, an.fps))), \(an.loop ? 1 : 0) },")
            }
            c.line("};")
            if let obj = single {
                c.line("const SpriteAsset \(name) = { \(cString(stored.name)), \(obj.0), \(obj.1), \(obj.2), \(obj.3), \(a.pivotX), \(a.pivotY), \(frameTiles * 8), \(frames.count), \(name)_gfx, \(name)_pal, \(anims.count), \(name)_anims, 0, NULL };")
            } else {
                c.line("static const SpritePiece \(name)_pieces[] = {")
                var tile = 0
                for pc in pieces {
                    c.line("    { \(pc.x), \(pc.y), \(pc.obj.0), \(pc.obj.1), \(pc.obj.2), \(pc.obj.3), \(tile) },")
                    tile += pc.obj.0 * pc.obj.1 / 64
                }
                c.line("};")
                c.line("const SpriteAsset \(name) = { \(cString(stored.name)), \(fw), \(fh), 0, 0, \(a.pivotX), \(a.pivotY), \(frameTiles * 8), \(frames.count), \(name)_gfx, \(name)_pal, \(anims.count), \(name)_anims, \(pieces.count), \(name)_pieces };")
            }
            c.line()
        }

        // Dialogue: fonts, text box styles, speakers, dialogues
        try emitDialogue(p, spriteSym: spriteSym, dialogueSym: dialogueSym, into: &c, warnings: &warnings)

        // Tilesets
        for (id, stored) in p.tilesets.sorted(by: { $0.value.name < $1.value.name }) {
            let name = tilesetSym[id]!
            try emitTileset(stored, p: p, name: name, flags: s.tileFlags, into: &c, warnings: &warnings)
        }

        // Platformer settings
        for (id, stored) in p.platformers.sorted(by: { $0.value.name < $1.value.name }) {
            let v = stored.value
            func fx(_ d: Double) -> Int { Int((d * 256).rounded()) }
            func fr(_ i: Int) -> Int { max(0, min(255, i)) }
            c.line("static const PlatformerSettings \(platSym[id]!) = {")
            c.line("    \(fx(v.runSpeed)), \(fx(v.groundAccel)), \(fx(v.groundDecel)), \(fx(v.groundTurn)), \(fx(v.airAccel)), \(fx(v.airDecel)), \(fx(v.airTurn)),")
            c.line("    \(fx(v.gravity)), \(fx(v.jumpVelocity)), \(fx(v.jumpCut)), \(fx(v.apexThreshold)), \(fx(v.apexGravity)), \(fx(v.fallGravity)), \(fx(v.maxFall)),")
            c.line("    \(fx(v.wallSlideMax)), \(fx(v.wallJumpX)), \(fx(v.wallJumpY)),")
            c.line("    \(fr(v.coyoteFrames)), \(fr(v.bufferFrames)), \(fr(v.wallCoyoteFrames)), \(fr(v.wallJumpLockFrames)), \(v.wallJumps ? 1 : 0),")
            c.line("    \(fr(v.jumpSustainFrames)), \(fr(v.wallReach)), \(fr(v.airJumps)), \(fx(v.jumpBoostX)), \(fx(v.overspeedDecel)), \(fx(v.fastFallMax)), \(v.autoAnimate ? 1 : 0) };")
        }
        c.line()

        // Script types
        for sc in scripts {
            func cb(_ n: String, _ sig: String) -> String { sc.callbacks.contains(n) ? "(\(sig))\(sc.name)_\(n)" : "0" }
            c.line("_Static_assert(sizeof(\(sc.name)) <= SCRIPT_DATA_BYTES, \"Script \(sc.name) has too many fields (max 128 bytes)\");")
            c.line("static const ScriptType script_type_\(sc.name) = { \(cString(sc.name)), sizeof(\(sc.name)), "
                   + cb("Start", "void (*)(void *, Entity *)") + ", " + cb("Update", "void (*)(void *, Entity *)") + ", "
                   + cb("OnTrigger", "void (*)(void *, Entity *, Entity *)") + ", " + cb("OnTriggerExit", "void (*)(void *, Entity *, Entity *)") + ", "
                   + cb("OnMessage", "void (*)(void *, Entity *, int, int)") + ", " + cb("OnDestroy", "void (*)(void *, Entity *)") + " };")
        }
        c.line("const ScriptType *const script_types[] = { " + (scripts.isEmpty ? "0" : scripts.map { "&script_type_\($0.name)" }.joined(separator: ", ")) + " };")
        c.line()

        // Entity templates
        var templateCount = 0
        var scriptLimitErrors: [String] = []
        func emitTemplate(_ def: EntityDef, name: String, symbol: String?, isStatic: Bool, sceneIDs: [UUID: Int]) -> String {
            templateCount += 1
            let t = symbol ?? "tmpl_\(templateCount)"
            let tag = def.tag.isEmpty ? 0 : (s.tags.firstIndex(of: def.tag).map { $0 + 1 } ?? 0)
            if !def.tag.isEmpty && tag == 0 { warnings.append("\(name): tag \"\(def.tag)\" isn't in the project's tag list.") }
            // scripts
            if def.scripts.count > maxScripts {
                scriptLimitErrors.append("\(name) has \(def.scripts.count) scripts; an entity can have at most \(maxScripts).")
            }
            var inits: [String] = []
            for (i, comp) in def.scripts.enumerated() {
                guard let sc = p.script(comp.script) else {
                    warnings.append("\(name): script \(comp.script) not found — skipped.")
                    continue
                }
                var parts: [String] = []
                for f in sc.fields where f.kind != .hidden {
                    let v = comp.fields[f.name] ?? f.defaultValue
                    guard let v else {
                        if f.kind == .scene { parts.append(".\(f.name) = -1") }   // no scene chosen
                        continue
                    }
                    switch f.kind {
                    case .int: parts.append(".\(f.name) = \(Int(v.number ?? 0))")
                    case .fixed: parts.append(".\(f.name) = \(Int(((v.number ?? 0) * 256).rounded()))")
                    case .bool: parts.append(".\(f.name) = \((v.bool ?? false) ? 1 : 0)")
                    case .entity:
                        if let g = v.string.flatMap(UUID.init(uuidString:)), let eid = sceneIDs[g] { parts.append(".\(f.name) = \(eid)") }
                    case .scene:
                        let sid = v.string.flatMap(UUID.init(uuidString:)) ?? v.string.flatMap { p.asset(named: $0) }
                        if let idx = p.sceneIndex(sid) { parts.append(".\(f.name) = \(idx)") } else { parts.append(".\(f.name) = -1") }
                    case .prefab:
                        let pid = v.string.flatMap(UUID.init(uuidString:)) ?? v.string.flatMap { p.asset(named: $0) }
                        if let pid, let ps = prefabSym[pid] { parts.append(".\(f.name) = &\(ps)") }
                    case .sprite:
                        let sid = v.string.flatMap(UUID.init(uuidString:)) ?? v.string.flatMap { p.asset(named: $0) }
                        if let sid, let ss = spriteSym[sid] { parts.append(".\(f.name) = &\(ss)") }
                    case .dialogue:
                        let did = v.string.flatMap(UUID.init(uuidString:)) ?? v.string.flatMap { p.asset(named: $0) }
                        if let did, let ds = dialogueSym[did] { parts.append(".\(f.name) = &\(ds)") }
                    case .sound:
                        if let n = v.string, let ss = soundSym[n] { parts.append(".\(f.name) = &\(ss)") }
                    case .hidden: break
                    }
                }
                c.line("static const \(sc.name) \(t)_s\(i) = { \(parts.isEmpty ? "0" : parts.joined(separator: ", ")) };")
                inits.append("{ &script_type_\(sc.name), &\(t)_s\(i) }")
            }
            if !inits.isEmpty { c.line("static const ScriptInit \(t)_scripts[] = { \(inits.joined(separator: ", ")) };") }
            var spr = "0", anim = 0, flags = 0, prio = 1
            if let sp = def.sprite, let sid = sp.sprite, let ss = spriteSym[sid] {
                spr = "&\(ss)"
                anim = p.sprites[sid]?.value.animations.firstIndex { $0.name == sp.animation } ?? 0
                flags = (sp.flipX ? 1 : 0) | (sp.hidden ? 2 : 0)
                prio = sp.priority
            }
            var col = "0, 0, 0, 0, 0"
            if let cl = def.collider {
                col = "\(cl.x), \(cl.y), \(max(1, min(255, cl.w))), \(max(1, min(255, cl.h))), \(1 | (cl.trigger ? 2 : 0) | (cl.platform ? 4 : 0))"
            }
            var plat = "0, 0"
            if let pl = def.platformer {
                if let ps = pl.settings.flatMap({ platSym[$0] }) { plat = "&\(ps), \(pl.joypad ? 1 : 0)" }
                else { warnings.append("\(name): Platformer has no settings asset — it won't move.") }
                if def.collider == nil { warnings.append("\(name): Platformer works best with a Collider (used as its hitbox).") }
            }
            c.line("\(isStatic ? "static " : "")const EntityTemplate \(t) = { \(cString(name)), \(tag), \(flags), \(prio), \(spr), \(anim), \(col), \(plat), \(inits.count), \(inits.isEmpty ? "0" : "\(t)_scripts") };")
            return t
        }

        for (id, stored) in p.prefabs.sorted(by: { $0.value.name < $1.value.name }) {
            _ = emitTemplate(stored.value.def, name: stored.name, symbol: prefabSym[id]!, isStatic: false, sceneIDs: [:])
        }
        c.line()

        // Scenes
        var sceneSyms: [String] = []
        for (index, sid) in s.scenes.enumerated() {
            guard let stored = p.scenes[sid] else { continue }
            let sc = stored.value
            let sn = "scene_\(index)"
            sceneSyms.append(sn)
            var ids: [UUID: Int] = [:]
            for (i, e) in sc.entities.enumerated() { ids[e.guid] = i + 1 }
            c.line("// Scene \(stored.name)")
            c.line("static const u8 \(sn)_map[] = {")
            c.hexRows(sc.cells.map { UInt32($0) }, digits: 2, perLine: 32)
            c.line("};")
            var rows: [String] = []
            for (i, e) in sc.entities.enumerated() {
                let def = p.effectiveDef(e)
                let t: String
                if let pid = e.prefab, e.overrides == nil, let ps = prefabSym[pid] { t = ps }
                else { t = emitTemplate(def, name: e.name, symbol: nil, isStatic: true, sceneIDs: ids) }
                let w = sc.worldPosition(of: e)
                let parent = e.parent.flatMap { ids[$0] } ?? 0
                rows.append("{ &\(t), \(w.x), \(w.y), \(i + 1), \(parent) }")
            }
            if !rows.isEmpty {
                c.line("static const SceneEntity \(sn)_entities[] = {")
                for r in rows { c.line("    \(r),") }
                c.line("};")
            }
            let (r, g, b) = parseHexColor(sc.background)
            let bg = RGBA(UInt8(r), UInt8(g), UInt8(b)).rgb15
            let ts = sc.tileset.flatMap { tilesetSym[$0] }.map { "&\($0)" } ?? "0"
            let mode = ["follow": 0, "screens": 1, "fixed": 2][sc.cameraMode.rawValue] ?? 0
            let target = sc.cameraTarget.flatMap { ids[$0] } ?? 0
            c.line("static const Scene \(sn) = { \(cString(stored.name)), \(sc.width), \(sc.height), \(sn)_map, \(ts), 0x\(String(format: "%04X", bg)), \(rows.count), \(rows.isEmpty ? "0" : "\(sn)_entities"), \(mode), \(target), \(soundRef(sc.music)) };")
            c.line()
        }
        c.line("const Scene *const scenes[] = { \(sceneSyms.map { "&\($0)" }.joined(separator: ", ")) };")
        c.line("const int scene_count = \(sceneSyms.count);")
        let bootIndex: Int
        switch boot {
        case .start: bootIndex = p.sceneIndex(s.startScene) ?? 0
        case .scene(let id): bootIndex = p.sceneIndex(id) ?? 0
        }
        c.line("const int boot_scene = \(bootIndex);")
        // Menus
        let menu = s.menu
        let startIndex = p.sceneIndex(s.startScene) ?? 0
        let titleScene = menu?.titleScene.flatMap { p.sceneIndex($0) } ?? -1
        let titleOn = menu?.titleEnabled == true
        c.line("const MenuSettings menu_settings = { \(titleOn ? 1 : 0), \(menu?.pauseEnabled == true ? 1 : 0), "
               + "\(cString((menu?.title.isEmpty ?? true) ? s.name.uppercased() : menu!.title.uppercased())), \(cString((menu?.subtitle ?? "").uppercased())), "
               + "\(titleScene), \(startIndex), \(soundRef(menu?.music)), \(soundRef(menu?.cursorSound)), \(soundRef(menu?.confirmSound)) };")
        let bootTitle: Bool
        if case .start = boot { bootTitle = titleOn } else { bootTitle = false }
        c.line("const int boot_title = \(bootTitle ? 1 : 0);")
        if let m = scriptLimitErrors.first { throw GenError(message: m) }
        return Output(header: h.text, assets: c.text, soundData: asm, warnings: warnings)
    }

    // MARK: Dialogue

    static func rgb15(_ hex: String) -> UInt16 {
        let (r, g, b) = parseHexColor(hex)
        return RGBA(UInt8(r), UInt8(g), UInt8(b)).rgb15
    }

    /// The font a text box style uses
    public static func font(for style: TextBoxStyleAsset, in p: GameProject) -> FontData {
        if let fid = style.font, let f = p.fonts[fid], let img = try? Bitmap.load(p.imageURL(assetPath: f.path, image: f.value.image)) {
            return FontData.from(img)
        }
        return .standard
    }

    /// The 3x3 frame slices (8x8 each) of a text box style
    public static func frameSlices(for stored: Stored<TextBoxStyleAsset>?, in p: GameProject) -> [Bitmap] {
        var img = Templates.defaultFrame()
        if let stored, let f = stored.value.frameImage, let b = try? Bitmap.load(p.imageURL(assetPath: stored.path, image: f)) { img = b }
        let cw = max(1, img.width / 3), chh = max(1, img.height / 3)
        return (0..<9).map { i in img.crop(x: (i % 3) * cw, y: (i / 3) * chh, w: cw, h: chh).scaled(toWidth: 8, height: 8) }
    }

    /// The style a dialogue uses (its own, else the project's first, else the defaults)
    public static func style(for d: DialogueAsset, in p: GameProject) -> Stored<TextBoxStyleAsset>? {
        if let sid = d.style, let s = p.textboxes[sid] { return s }
        return p.textboxes.values.sorted { $0.path < $1.path }.first
    }

    /// Portrait width in px (OBJ size) of a speaker, if it has one
    public static func portraitWidth(_ speaker: SpeakerAsset?, in p: GameProject) -> Int? {
        guard let sid = speaker?.portrait, let s = p.sprites[sid]?.value else { return nil }
        return objSize(for: s.frameWidth, s.frameHeight)?.0
    }

    static func emitDialogue(_ p: GameProject, spriteSym: [UUID: String], dialogueSym: [UUID: String],
                             into c: inout CWriter, warnings: inout [String]) throws {
        guard !p.dialogues.isEmpty else { return }
        func sym(_ prefix: String, _ name: String) -> String { prefix + cIdentifier(name) }
        var fontSyms: [String: String] = [:]   // key: font id or "default"
        func fontSym(_ style: TextBoxStyleAsset) -> String {
            let key = style.font?.uuidString ?? "default"
            if let s = fontSyms[key] { return s }
            let f = font(for: style, in: p)
            let name = "FONT_\(fontSyms.count)"
            c.line("static const Font \(name) = { \(f.height), { \(f.widths.map(String.init).joined(separator: ",")) }, {")
            for g in 0..<96 { c.line("    { \(f.rows[g].map { String(format: "0x%04X", $0) }.joined(separator: ",")) },") }
            c.line("} };")
            fontSyms[key] = name
            return name
        }
        var styleSyms: [String: String] = [:]
        func styleSym(_ stored: Stored<TextBoxStyleAsset>?) -> String {
            let key = stored?.value.guid.uuidString ?? "default"
            if let s = styleSyms[key] { return s }
            let st = stored?.value ?? TextBoxStyleAsset()
            let name = stored.map { sym("TEXTBOX_", $0.name) } ?? "TEXTBOX__default"
            let f = font(for: st, in: p)
            let fs = fontSym(st)
            let geo = TextBoxGeometry(style: st, font: f)
            let slices = frameSlices(for: stored, in: p)
            let pal = Palette16(images: slices)
            c.line("static const u32 \(name)_frame[] = {")
            c.hexRows(slices.flatMap { tiles4bpp($0, palette: pal) }, digits: 8, perLine: 8)
            c.line("};")
            c.line("static const u16 \(name)_framepal[16] = {")
            c.hexRows(pal.entries.map { UInt32($0) }, digits: 4, perLine: 16)
            c.line("};")
            var colors = [UInt16](repeating: 0, count: 16)
            colors[1] = rgb15(st.textColor); colors[2] = rgb15(st.shadowColor); colors[3] = rgb15("#FFE14D")
            for i in 0..<6 { colors[4 + i] = rgb15(i < st.rainbow.count ? st.rainbow[i] : "#FFFFFF") }
            colors[10] = rgb15(st.fillColor)
            for (i, n) in TextBoxStyleAsset.colorNames.enumerated() { colors[11 + i] = rgb15(st.colors[n] ?? TextBoxStyleAsset.defaultColors[n]!) }
            c.line("static const TextBoxStyle \(name) = { \(geo.boxX), \(geo.boxY), \(geo.boxW), \(geo.boxH), \(geo.nameX), \(geo.nameY), \(geo.nameW), \(geo.padX), \(geo.padY), \(st.lines), \(max(1, min(255, st.speed))), \(st.portraitRight ? 1 : 0), \(st.pauseGame ? 1 : 0), \(st.shadow ? 1 : 0),")
            c.line("    { \(colors.map { String(format: "0x%04X", $0) }.joined(separator: ", ")) }, \(name)_frame, \(name)_framepal, &\(fs) };")
            styleSyms[key] = name
            return name
        }
        var speakerSyms: [UUID: String] = [:]
        for (id, s) in p.speakers.sorted(by: { $0.value.name < $1.value.name }) {
            let name = sym("SPEAKER_", s.name)
            let portrait = s.value.portrait.flatMap { spriteSym[$0] }.map { "&\($0)" } ?? "0"
            c.line("static const Speaker \(name) = { \(cString(s.value.displayName)), 0x\(String(format: "%04X", rgb15(s.value.nameColor))), \(portrait) };")
            speakerSyms[id] = name
        }
        for (id, d) in p.dialogues.sorted(by: { $0.value.name < $1.value.name }) {
            let name = dialogueSym[id]!
            let styleStored = style(for: d.value, in: p)
            let st = styleStored?.value ?? TextBoxStyleAsset()
            let ss = styleSym(styleStored)
            let f = font(for: st, in: p)
            let geo = TextBoxGeometry(style: st, font: f)
            var lines: [String] = []
            for (i, l) in d.value.lines.enumerated() {
                let speaker = l.speaker.flatMap { p.speakers[$0]?.value }
                let width = geo.textWidth(portraitWidth: portraitWidth(speaker, in: p))
                let bytes = DialogueText.bytes(l.text, font: f, width: width, lines: st.lines, variables: p.settings.variables)
                c.line("static const u8 \(name)_t\(i)[] = { \(bytes.map(String.init).joined(separator: ",")) };")
                var talk = 0, idle = 0
                if let sp = speaker, let pid = sp.portrait, let anims = p.sprites[pid]?.value.animations {
                    let talkName = l.animation.isEmpty ? sp.talkAnimation : l.animation
                    talk = anims.firstIndex { $0.name == talkName } ?? 0
                    idle = anims.firstIndex { $0.name == sp.idleAnimation } ?? talk
                }
                let spk = l.speaker.flatMap { speakerSyms[$0] }.map { "&\($0)" } ?? "0"
                lines.append("{ \(spk), \(talk), \(idle), \(name)_t\(i) }")
            }
            if lines.isEmpty { warnings.append("Dialogue \(d.name) has no lines.") }
            c.line("static const DialogueLine \(name)_lines[] = { \(lines.isEmpty ? "{ 0, 0, 0, (const u8 *)\"\" }" : lines.joined(separator: ", ")) };")
            c.line("const Dialogue \(name) = { \(cString(d.name)), &\(ss), \(lines.count), \(name)_lines };")
            c.line()
        }
    }

    // MARK: Tilesets

    static func emitTileset(_ stored: Stored<TilesetAsset>, p: GameProject, name: String, flags flagNames: [String],
                            into c: inout CWriter, warnings: inout [String]) throws {
        let ts = stored.value
        guard let img = try? Bitmap.load(p.imageURL(assetPath: stored.path, image: ts.image)) else {
            throw GenError(message: "Tileset \(stored.name): can't read \(ts.image)")
        }
        let cols = img.width / cellSize, rows = img.height / cellSize
        let count = min(255, cols * rows)
        if cols * rows > 255 { warnings.append("Tileset \(stored.name): only the first 255 tiles are used.") }
        var tiles: [Bitmap] = []
        for i in 0..<count { tiles.append(img.crop(x: (i % cols) * cellSize, y: (i / cols) * cellSize, w: cellSize, h: cellSize)) }

        // Pack tiles into up to 10 palette banks of 15 colors (11 is the background layer, 12-13 the dialogue box, 14-15 HUD text)
        var tileColors: [Set<UInt16>] = tiles.map { t in Set(t.pixels.filter(\.isOpaque).map(\.rgb15)) }
        for i in tiles.indices where tileColors[i].count > 15 {
            warnings.append("Tileset \(stored.name): tile \(i) has more than 15 colors — reduced.")
            tileColors[i] = Set(Palette16(images: [tiles[i]]).colors)
        }
        var banks: [Set<UInt16>] = []
        var bankOf = [Int](repeating: 0, count: tiles.count)
        for i in tiles.indices.sorted(by: { tileColors[$0].count > tileColors[$1].count }) {
            let cs = tileColors[i]
            if cs.isEmpty { continue }
            var best = -1, bestAdd = Int.max
            for (b, bank) in banks.enumerated() {
                let add = cs.subtracting(bank).count
                if bank.count + add <= 15 && add < bestAdd { best = b; bestAdd = add }
            }
            if best < 0 {
                if banks.count < 10 { banks.append([]); best = banks.count - 1 }
                else {
                    best = banks.indices.min { banks[$0].union(cs).count < banks[$1].union(cs).count }!
                    warnings.append("Tileset \(stored.name): too many colors overall — some tiles use approximate colors.")
                }
            }
            banks[best].formUnion(cs)
            bankOf[i] = best
        }
        let palettes: [Palette16] = banks.map { bank in
            Palette16(images: [Bitmap(width: bank.count, height: 1, pixels: bank.sorted().map { RGBA(rgb15: $0) })])
        }

        // Graphics, de-duplicated
        var words = [UInt32](repeating: 0, count: 8)   // hw tile 0 stays empty
        var seen: [[UInt32]: Int] = [:]
        var defs: [String] = ["{ 0, 0, 0, 0, 16, 16, 0, 1 }"]   // map index 0 = empty
        for i in 0..<count {
            let bank = bankOf[i]
            let gfx = tileColors[i].isEmpty ? [UInt32](repeating: 0, count: 32) : tiles4bpp(tiles[i], palette: palettes.isEmpty ? Palette16(images: []) : palettes[bank])
            let first: Int
            if let at = seen[gfx] { first = at } else {
                first = words.count / 8
                words += gfx
                seen[gfx] = first
            }
            let props = ts.props(i)
            let coll = ["none": 0, "solid": 1, "oneway": 2][props.collision.rawValue] ?? 0
            var f = 0
            for name in props.flags { if let bit = flagNames.firstIndex(of: name) { f |= 1 << bit } }
            let hb = props.hitbox ?? [0, 0, 16, 16]
            defs.append("{ \(coll), \(f), \(hb[0]), \(hb[1]), \(hb[2]), \(hb[3]), \(first), \(bank + 1) }")
        }
        if words.count / 8 > 1024 { throw GenError(message: "Tileset \(stored.name) has too many unique tiles for VRAM (max 255).") }
        c.line("static const u32 \(name)_gfx[] = {")
        c.hexRows(words, digits: 8, perLine: 8)
        c.line("};")
        c.line("static const u16 \(name)_pal[] = {")
        c.hexRows(palettes.flatMap { $0.entries }.map { UInt32($0) }, digits: 4, perLine: 16)
        if palettes.isEmpty { c.line("    0") }
        c.line("};")
        c.line("static const TileDef \(name)_defs[] = {")
        for d in defs { c.line("    \(d),") }
        c.line("};")
        c.line("static const Tileset \(name) = { \(cString(stored.name)), \(defs.count), \(name)_defs, \(name)_gfx, \(words.count), \(palettes.count), \(name)_pal };")
        c.line()
    }

    public static func cString(_ s: String) -> String {
        let ascii = s.unicodeScalars.map { $0.isASCII && $0.value >= 32 ? String($0) : "?" }.joined()
        return "\"" + ascii.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

struct CWriter {
    var text = ""
    mutating func line(_ s: String = "") { text += s + "\n" }
    mutating func hexRows(_ values: [UInt32], digits: Int, perLine: Int) {
        var i = 0
        while i < values.count {
            let chunk = values[i..<min(i + perLine, values.count)]
            line("    " + chunk.map { String(format: "0x%0\(digits)X", $0) }.joined(separator: ", ") + ",")
            i += perLine
        }
    }
}

public func parseHexColor(_ s: String) -> (r: Int, g: Int, b: Int) {
    let hex = s.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    let v = Int(hex, radix: 16) ?? 0
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)
}

public func hexColor(r: Int, g: Int, b: Int) -> String { String(format: "#%02X%02X%02X", r, g, b) }
