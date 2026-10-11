import Foundation

/// Built-in starting content for new projects and presets.
public enum Templates {
    /// A plain white 16x16 square
    public static func whiteSquare() -> Bitmap { Bitmap(width: 16, height: 16, fill: RGBA(255, 255, 255)) }

    /// Simple block tiles: white, light gray (both solid) and a one-way ledge
    public static func blockTiles() -> Bitmap {
        var white = Bitmap(width: 16, height: 16, fill: RGBA(255, 255, 255))
        var gray = Bitmap(width: 16, height: 16, fill: RGBA(170, 176, 190))
        var ledge = Bitmap(width: 16, height: 16)
        for i in 0..<16 {
            white[i, 15] = RGBA(200, 204, 214); white[15, i] = RGBA(200, 204, 214)
            gray[i, 15] = RGBA(120, 126, 140); gray[15, i] = RGBA(120, 126, 140)
            for y in 0..<4 { ledge[i, y] = RGBA(255, 255, 255) }
        }
        return Bitmap.strip([white, gray, ledge])
    }

    /// Default text box frame: 24x24, 3x3 slices of 8x8 — a rounded white border on dark blue
    public static func defaultFrame() -> Bitmap {
        var img = Bitmap(width: 24, height: 24)
        let border = RGBA(240, 240, 250), fill = RGBA(41, 54, 111), dark = RGBA(26, 28, 44)
        for y in 0..<24 { for x in 0..<24 {
            let ex = min(x, 23 - x), ey = min(y, 23 - y)
            if ex + ey < 2 { continue }                      // rounded corners
            if ex == 0 || ey == 0 { img[x, y] = dark }
            else if ex == 1 || ey == 1 || (ex + ey == 2) { img[x, y] = border }
            else { img[x, y] = fill }
        } }
        return img
    }

    /// Adds the white square sprite at `folder` (relative). Returns its id.
    @discardableResult
    public static func addSquareSprite(to p: inout GameProject, folder: String = "assets") throws -> UUID {
        let json = p.uniquePath(folder, "square", ".sprite.json")
        let image = assetName(URL(fileURLWithPath: json)) + ".png"
        try whiteSquare().savePNG(p.url(folder).appendingPathComponent(image))
        let s = SpriteAsset(guid: UUID(), image: image, frameWidth: 16, frameHeight: 16, pivotX: 8, pivotY: 16,
                            animations: [SpriteAnimation(name: "idle", frames: [0], fps: 0)])
        p.sprites[s.guid] = Stored(path: json, value: s)
        return s.guid
    }

    /// Adds platformer movement settings (Celeste Classic 2 style by default). Returns its id.
    @discardableResult
    public static func addPlatformerSettings(to p: inout GameProject, folder: String = "assets",
                                             preset: PlatformerSettings.Preset = .celesteClassic2) -> UUID {
        let s = PlatformerSettings.preset(preset)
        p.platformers[s.guid] = Stored(path: p.uniquePath(folder, "Player Movement", ".platformer.json"), value: s)
        return s.guid
    }

    /// A new, mostly empty project: square sprite, block tileset, one scene with a floor.
    /// engine/templates/scripts: ready-made scripts (Talk, Respawn, Hazard, LevelEnd, Patroller)
    public static func scriptLibrary(engine: URL?) -> URL? { engine.map { $0.appendingPathComponent("templates/scripts") } }

    /// Copy a library script into the project if it isn't there yet. Returns true if the project has it afterwards.
    @discardableResult
    public static func ensureScript(_ file: String, in p: GameProject, library: URL?) -> Bool {
        let dest = p.scriptsDir.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: dest.path) { return true }
        guard let src = library?.appendingPathComponent(file), FileManager.default.fileExists(atPath: src.path) else { return false }
        try? FileManager.default.createDirectory(at: p.scriptsDir, withIntermediateDirectories: true)
        return (try? FileManager.default.copyItem(at: src, to: dest)) != nil
    }

    public static func emptyProject(at root: URL, scriptTemplates: URL? = nil) throws -> GameProject {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        var p = GameProject(root: root, settings: ProjectSettings(name: root.lastPathComponent.uppercased()))
        try addSquareSprite(to: &p, folder: "assets/sprites")
        // Dialogue: a text box style and the Talk script, ready to use
        try defaultFrame().savePNG(root.appendingPathComponent("assets/dialogue/box_frame.png"))
        var box = TextBoxStyleAsset()
        box.frameImage = "box_frame.png"
        p.textboxes[box.guid] = Stored(path: "assets/dialogue/Text Box.textbox.json", value: box)
        for file in ["talk.c", "respawn.c"] {
            if let src = scriptTemplates?.appendingPathComponent(file), FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: root.appendingPathComponent("scripts/" + file))
            }
        }
        try blockTiles().savePNG(root.appendingPathComponent("assets/tilesets/blocks.png"))
        let ts = TilesetAsset(guid: UUID(), image: "blocks.png",
                              tiles: ["0": TileProps(collision: .solid), "1": TileProps(collision: .solid), "2": TileProps(collision: .oneway)])
        p.tilesets[ts.guid] = Stored(path: "assets/tilesets/blocks.tileset.json", value: ts)
        var scene = SceneAsset(width: 30, height: 10)
        scene.tileset = ts.guid
        scene.background = "#3A4466"
        for x in 0..<30 { scene[x, 9] = 1 }
        p.scenes[scene.guid] = Stored(path: "assets/scenes/Main.scene.json", value: scene)
        p.settings.scenes = [scene.guid]
        p.settings.startScene = scene.guid
        try p.saveChanges(since: nil)
        return p
    }
}
