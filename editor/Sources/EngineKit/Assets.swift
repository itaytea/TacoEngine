import Foundation

// A project folder:
//   project.json                 settings: name, tags, tile flags, variables, scene build order
//   assets/**/*.sprite.json      sprite sheets + animations (PNG next to it)
//   assets/**/*.tileset.json     16x16 tilesets + per-tile collision/flags
//   assets/**/*.prefab.json      reusable entities
//   assets/**/*.scene.json       tilemap + entities + camera
//   assets/**/*.platformer.json  platformer body tuning
//   scripts/*.c                  C scripts
//   build/                       generated code, objects, game.gba

public let cellSize = 16

public struct ProjectSettings: Codable, Equatable, Sendable {
    public var name: String
    public var romTitle: String
    public var tags: [String]          // tag 0 is always "Untagged"
    public var tileFlags: [String]     // up to 8
    public var variables: [String]     // global ints, kept across scenes
    public var scenes: [UUID]          // build order; index = SceneRef
    public var startScene: UUID?
    public var menu: MenuConfig?       // title and pause menus (nil = off)
    public var showFrameBudget: Bool?  // CPU meter at the bottom of the screen

    public init(name: String) {
        self.name = name
        romTitle = String(name.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(12))
        tags = ["Player"]
        tileFlags = ["Hazard"]
        variables = []
        scenes = []
        startScene = nil
    }
}

// MARK: Sprites

public struct SpriteAnimation: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var frames: [Int]
    public var fps: Int
    public var loop: Bool

    public init(name: String, frames: [Int], fps: Int, loop: Bool = true) {
        self.name = name; self.frames = frames; self.fps = fps; self.loop = loop
    }
    enum CodingKeys: String, CodingKey { case name, frames, fps, loop }

    /// The id only exists in memory (for SwiftUI lists), so it doesn't count for equality
    public static func == (a: SpriteAnimation, b: SpriteAnimation) -> Bool {
        a.name == b.name && a.frames == b.frames && a.fps == b.fps && a.loop == b.loop
    }
}

public struct SpriteAsset: Codable, Equatable, Sendable {
    public var guid: UUID
    public var image: String           // relative to the .sprite.json file
    public var frameWidth: Int
    public var frameHeight: Int
    public var pivotX: Int
    public var pivotY: Int
    public var animations: [SpriteAnimation]

    public init(guid: UUID, image: String, frameWidth: Int, frameHeight: Int, pivotX: Int, pivotY: Int, animations: [SpriteAnimation]) {
        self.guid = guid; self.image = image; self.frameWidth = frameWidth; self.frameHeight = frameHeight
        self.pivotX = pivotX; self.pivotY = pivotY; self.animations = animations
    }
}

// MARK: Tilesets

public enum TileCollision: String, Codable, CaseIterable, Sendable {
    case none, solid, oneway
}

public struct TileProps: Codable, Equatable, Sendable {
    public var collision: TileCollision = .none
    public var flags: [String] = []
    public var hitbox: [Int]? = nil    // x, y, w, h inside the 16x16 cell (for flags); nil = whole cell
    public init(collision: TileCollision = .none, flags: [String] = [], hitbox: [Int]? = nil) {
        self.collision = collision; self.flags = flags; self.hitbox = hitbox
    }
}

public struct TilesetAsset: Codable, Equatable, Sendable {
    public var guid: UUID
    public var image: String           // grid of 16x16 tiles; map tile N = grid cell N-1
    public var tiles: [String: TileProps]   // keyed by grid cell index

    public init(guid: UUID, image: String, tiles: [String: TileProps]) { self.guid = guid; self.image = image; self.tiles = tiles }

    public func props(_ cell: Int) -> TileProps { tiles[String(cell)] ?? TileProps() }
}

// MARK: Platformer settings

public struct PlatformerSettings: Codable, Equatable, Sendable {
    public var guid = UUID()
    public var runSpeed = 1.8
    public var groundAccel = 0.30
    public var groundDecel = 0.40
    public var groundTurn = 0.60
    public var airAccel = 0.20
    public var airDecel = 0.10
    public var airTurn = 0.30
    public var gravity = 0.25
    public var jumpVelocity = 4.6
    public var jumpCut = 0.45
    public var apexThreshold = 0.8
    public var apexGravity = 0.5
    public var fallGravity = 1.5
    public var maxFall = 5.0
    public var wallSlideMax = 1.2
    public var wallJumpX = 2.2
    public var wallJumpY = 4.2
    public var coyoteFrames = 6
    public var bufferFrames = 6
    public var wallCoyoteFrames = 5
    public var wallJumpLockFrames = 10
    public var wallJumps = true
    public var jumpSustainFrames = 0
    public var wallReach = 1
    public var airJumps = 0
    public var jumpBoostX = 0.0
    public var overspeedDecel = 0.0
    public var fastFallMax = 0.0
    public var autoAnimate = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = PlatformerSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? def }
        guid = try v(.guid, d.guid)
        runSpeed = try v(.runSpeed, d.runSpeed); groundAccel = try v(.groundAccel, d.groundAccel)
        groundDecel = try v(.groundDecel, d.groundDecel); groundTurn = try v(.groundTurn, d.groundTurn)
        airAccel = try v(.airAccel, d.airAccel); airDecel = try v(.airDecel, d.airDecel); airTurn = try v(.airTurn, d.airTurn)
        gravity = try v(.gravity, d.gravity); jumpVelocity = try v(.jumpVelocity, d.jumpVelocity)
        jumpCut = try v(.jumpCut, d.jumpCut); apexThreshold = try v(.apexThreshold, d.apexThreshold)
        apexGravity = try v(.apexGravity, d.apexGravity); fallGravity = try v(.fallGravity, d.fallGravity)
        maxFall = try v(.maxFall, d.maxFall); wallSlideMax = try v(.wallSlideMax, d.wallSlideMax)
        wallJumpX = try v(.wallJumpX, d.wallJumpX); wallJumpY = try v(.wallJumpY, d.wallJumpY)
        coyoteFrames = try v(.coyoteFrames, d.coyoteFrames); bufferFrames = try v(.bufferFrames, d.bufferFrames)
        wallCoyoteFrames = try v(.wallCoyoteFrames, d.wallCoyoteFrames)
        wallJumpLockFrames = try v(.wallJumpLockFrames, d.wallJumpLockFrames)
        wallJumps = try v(.wallJumps, d.wallJumps)
        jumpSustainFrames = try v(.jumpSustainFrames, d.jumpSustainFrames)
        wallReach = try v(.wallReach, d.wallReach)
        airJumps = try v(.airJumps, d.airJumps)
        jumpBoostX = try v(.jumpBoostX, d.jumpBoostX)
        overspeedDecel = try v(.overspeedDecel, d.overspeedDecel)
        fastFallMax = try v(.fastFallMax, d.fastFallMax)
        autoAnimate = try v(.autoAnimate, d.autoAnimate)
    }

    /// Ready-made movement styles (keeps the asset's guid)
    public enum Preset: String, CaseIterable, Sendable {
        case standard = "Standard"
        case celesteClassic2 = "Celeste Classic 2"
        case floaty = "Floaty"
        case snappy = "Snappy"
        case doubleJump = "Double Jump"
    }

    public static func preset(_ p: Preset, keeping guid: UUID = UUID()) -> PlatformerSettings {
        var s = PlatformerSettings()
        s.guid = guid
        switch p {
        case .standard:
            break
        case .celesteClassic2:
            // Converted from Celeste Classic 2's player.lua (PICO-8, 30 fps, 8 px tiles) to 60 fps and 16 px tiles:
            // speeds keep their numbers, accelerations halve, frame counts double.
            s.runSpeed = 2.0; s.groundAccel = 0.4; s.groundDecel = 0.4; s.groundTurn = 0.4
            s.airAccel = 0.2; s.airDecel = 0.1; s.airTurn = 0.2
            s.gravity = 0.4; s.apexThreshold = 0.2; s.apexGravity = 0.5; s.fallGravity = 1.0; s.maxFall = 4.4
            s.jumpVelocity = 4.0; s.jumpCut = 1.0; s.jumpSustainFrames = 10; s.jumpBoostX = 0.2
            s.coyoteFrames = 8; s.bufferFrames = 8
            s.wallJumps = true; s.wallJumpX = 3.0; s.wallJumpY = 3.0; s.wallReach = 4; s.wallJumpLockFrames = 0
            s.wallSlideMax = 4.4; s.wallCoyoteFrames = 0
            s.overspeedDecel = 0.05; s.fastFallMax = 5.2
        case .floaty:
            s.gravity = 0.15; s.jumpVelocity = 3.6; s.apexGravity = 0.35; s.apexThreshold = 1.0; s.fallGravity = 1.1
            s.airAccel = 0.12; s.airDecel = 0.04; s.maxFall = 3.5; s.coyoteFrames = 8; s.bufferFrames = 8
        case .snappy:
            s.runSpeed = 2.4; s.groundAccel = 0.8; s.groundDecel = 0.8; s.groundTurn = 1.2
            s.airAccel = 0.5; s.airDecel = 0.3; s.airTurn = 0.6
            s.gravity = 0.35; s.jumpVelocity = 5.2; s.jumpCut = 0.3; s.fallGravity = 1.8; s.maxFall = 6
            s.apexGravity = 0.7; s.wallSlideMax = 1.6
        case .doubleJump:
            s.airJumps = 1
        }
        return s
    }
}

// MARK: Entities

public struct SpriteComponent: Codable, Equatable, Sendable {
    public var sprite: UUID?
    public var animation: String = ""
    public var flipX = false
    public var hidden = false
    public var priority = 1            // 0/1 front .. 3 behind the tilemap
    public init(sprite: UUID? = nil, animation: String = "") { self.sprite = sprite; self.animation = animation }
}

public struct ColliderComponent: Codable, Equatable, Sendable {
    public var x = -8
    public var y = -16
    public var w = 16
    public var h = 16
    public var trigger = false
    public var platform = false      // one-way platform: bodies land on its top edge
    public init(x: Int = -8, y: Int = -16, w: Int = 16, h: Int = 16, trigger: Bool = false, platform: Bool = false) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.trigger = trigger; self.platform = platform
    }

    enum CodingKeys: String, CodingKey { case x, y, w, h, trigger, platform }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Int.self, forKey: .x) ?? -8
        y = try c.decodeIfPresent(Int.self, forKey: .y) ?? -16
        w = try c.decodeIfPresent(Int.self, forKey: .w) ?? 16
        h = try c.decodeIfPresent(Int.self, forKey: .h) ?? 16
        trigger = try c.decodeIfPresent(Bool.self, forKey: .trigger) ?? false
        platform = try c.decodeIfPresent(Bool.self, forKey: .platform) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x); try c.encode(y, forKey: .y); try c.encode(w, forKey: .w); try c.encode(h, forKey: .h)
        try c.encode(trigger, forKey: .trigger)
        if platform { try c.encode(platform, forKey: .platform) }
    }
}

public struct PlatformerComponent: Codable, Equatable, Sendable {
    public var settings: UUID?
    public var joypad = true
    public init(settings: UUID? = nil, joypad: Bool = true) { self.settings = settings; self.joypad = joypad }
}

public struct ScriptComponent: Codable, Equatable, Sendable {
    public var script: String          // script name = file name without .c
    public var fields: [String: JSON] = [:]
    public init(script: String, fields: [String: JSON] = [:]) { self.script = script; self.fields = fields }
}

/// Everything about an entity except its name/position: what prefabs store and instances override.
public struct EntityDef: Codable, Equatable, Sendable {
    public var tag: String = ""
    public var sprite: SpriteComponent?
    public var collider: ColliderComponent?
    public var platformer: PlatformerComponent?
    public var scripts: [ScriptComponent] = []
    public init() {}
}

public struct PrefabAsset: Codable, Equatable, Sendable {
    public var guid: UUID
    public var def: EntityDef
    public init(guid: UUID, def: EntityDef) { self.guid = guid; self.def = def }
}

/// Title and pause menus (Project Settings)
public struct MenuConfig: Codable, Equatable, Sendable {
    public var titleEnabled = true
    public var title = ""
    public var subtitle = "PRESS A"
    public var titleScene: UUID?       // shown behind the title menu (nil = the start scene)
    public var pauseEnabled = true
    public var music: String?          // sound names
    public var cursorSound: String?
    public var confirmSound: String?
    public init() {}
    enum CodingKeys: String, CodingKey { case titleEnabled, title, subtitle, titleScene, pauseEnabled, music, cursorSound, confirmSound }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titleEnabled = try c.decodeIfPresent(Bool.self, forKey: .titleEnabled) ?? true
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? "PRESS A"
        titleScene = try c.decodeIfPresent(UUID.self, forKey: .titleScene)
        pauseEnabled = try c.decodeIfPresent(Bool.self, forKey: .pauseEnabled) ?? true
        music = try c.decodeIfPresent(String.self, forKey: .music)
        cursorSound = try c.decodeIfPresent(String.self, forKey: .cursorSound)
        confirmSound = try c.decodeIfPresent(String.self, forKey: .confirmSound)
    }
}

public struct SceneEntity: Codable, Equatable, Identifiable, Sendable {
    public var guid: UUID
    public var name: String
    public var x: Int                  // relative to the parent, if it has one
    public var y: Int
    public var parent: UUID?
    public var prefab: UUID?           // instance of a prefab: `overrides` patch the prefab's def
    public var def: EntityDef?         // standalone entity
    public var overrides: JSON?
    public var id: UUID { guid }

    public init(name: String, x: Int, y: Int, prefab: UUID? = nil, def: EntityDef? = nil) {
        guid = UUID(); self.name = name; self.x = x; self.y = y; self.prefab = prefab; self.def = def
    }
}

public enum CameraMode: String, Codable, CaseIterable, Sendable {
    case follow, screens, fixed
}

public struct SceneAsset: Codable, Equatable, Sendable {
    public var guid: UUID
    public var width: Int
    public var height: Int
    public var tileset: UUID?
    public var background: String
    public var cameraMode: CameraMode
    public var cameraTarget: UUID?
    public var cells: [UInt8]          // width * height tile indices, row-major (saved as hex rows)
    public var entities: [SceneEntity]
    public var music: String?          // sound name, played when the scene starts

    public init(width: Int, height: Int) {
        guid = UUID(); self.width = width; self.height = height
        tileset = nil; background = "#6AB8F0"; cameraMode = .follow; cameraTarget = nil
        cells = Array(repeating: 0, count: width * height)
        entities = []
    }

    public subscript(x: Int, y: Int) -> Int {
        get { (x >= 0 && y >= 0 && x < width && y < height) ? Int(cells[y * width + x]) : 0 }
        set { if x >= 0 && y >= 0 && x < width && y < height { cells[y * width + x] = UInt8(max(0, min(255, newValue))) } }
    }

    /// World positions of all entities (one pass)
    public func worldPositions() -> [UUID: (x: Int, y: Int)] {
        var out: [UUID: (x: Int, y: Int)] = [:]
        for e in entities { out[e.guid] = worldPosition(of: e) }
        return out
    }

    /// The entity and everything under it (children, grandchildren...), in scene order
    public func subtree(_ id: UUID) -> [UUID] {
        var ids: Set<UUID> = [id], changed = true
        while changed {
            changed = false
            for e in entities where !ids.contains(e.guid) { if let p = e.parent, ids.contains(p) { ids.insert(e.guid); changed = true } }
        }
        return entities.map(\.guid).filter { ids.contains($0) }
    }

    /// Where an entity really is: its position plus all its parents' (positions are relative to the parent)
    public func worldPosition(of e: SceneEntity) -> (x: Int, y: Int) {
        var x = e.x, y = e.y, p = e.parent, guard_ = 0
        while let pid = p, let parent = entities.first(where: { $0.guid == pid }), guard_ < 32 {
            x += parent.x; y += parent.y; p = parent.parent; guard_ += 1
        }
        return (x, y)
    }

    /// Resize, keeping the top-left content
    public mutating func resize(width w: Int, height h: Int) {
        let old = self
        width = max(1, min(256, w))
        height = max(1, min(256, h))
        cells = Array(repeating: 0, count: width * height)
        for y in 0..<min(old.height, height) { for x in 0..<min(old.width, width) { self[x, y] = old[x, y] } }
    }

    enum CodingKeys: String, CodingKey { case guid, width, height, tileset, background, cameraMode, cameraTarget, map, entities, music }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guid = try c.decode(UUID.self, forKey: .guid)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        tileset = try c.decodeIfPresent(UUID.self, forKey: .tileset)
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? "#000000"
        cameraMode = try c.decodeIfPresent(CameraMode.self, forKey: .cameraMode) ?? .follow
        cameraTarget = try c.decodeIfPresent(UUID.self, forKey: .cameraTarget)
        entities = try c.decodeIfPresent([SceneEntity].self, forKey: .entities) ?? []
        music = try c.decodeIfPresent(String.self, forKey: .music)
        let rows = try c.decodeIfPresent([String].self, forKey: .map) ?? []
        cells = Array(repeating: 0, count: width * height)
        for (y, row) in rows.prefix(height).enumerated() {
            let bytes = Array(row.utf8)
            for x in 0..<min(width, bytes.count / 2) {
                let hex = String(decoding: bytes[(x * 2)..<(x * 2 + 2)], as: UTF8.self)
                cells[y * width + x] = UInt8(hex, radix: 16) ?? 0
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(guid, forKey: .guid)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encodeIfPresent(tileset, forKey: .tileset)
        try c.encode(background, forKey: .background)
        try c.encode(cameraMode, forKey: .cameraMode)
        try c.encodeIfPresent(cameraTarget, forKey: .cameraTarget)
        let rows = (0..<height).map { y in (0..<width).map { String(format: "%02X", cells[y * width + $0]) }.joined() }
        try c.encode(rows, forKey: .map)
        try c.encode(entities, forKey: .entities)
        try c.encodeIfPresent(music, forKey: .music)
    }
}

// MARK: Dialogue

public struct DialogueLine: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var speaker: UUID?
    public var animation: String = ""       // portrait animation while talking ("" = the speaker's)
    public var text: String
    public init(speaker: UUID?, text: String) { self.speaker = speaker; self.text = text }
}

public struct DialogueAsset: Codable, Equatable, Sendable {
    public var guid: UUID
    public var style: UUID?                  // text box style (nil = the project's first one)
    public var lines: [DialogueLine]
    public init(guid: UUID = UUID(), style: UUID? = nil, lines: [DialogueLine]) { self.guid = guid; self.style = style; self.lines = lines }
}

public struct SpeakerAsset: Codable, Equatable, Sendable {
    public var guid: UUID
    public var displayName: String
    public var nameColor: String = "#FFE14D"
    public var portrait: UUID?               // sprite (up to 64x64)
    public var talkAnimation: String = "talk"
    public var idleAnimation: String = "idle"
    public init(guid: UUID = UUID(), displayName: String, portrait: UUID? = nil) {
        self.guid = guid; self.displayName = displayName; self.portrait = portrait
    }
}

public struct TextBoxStyleAsset: Codable, Equatable, Sendable {
    public enum Position: String, Codable, CaseIterable, Sendable { case bottom, top }
    public var guid = UUID()
    public var position: Position = .bottom
    public var lines = 3
    public var marginX = 1                   // tiles from the screen edge
    public var marginY = 1
    public var nameWidth = 9                 // name plate width in tiles (0 = no name plate)
    public var speed = 40                    // characters per second
    public var portraitRight = false
    public var pauseGame = true
    public var shadow = true
    public var frameImage: String? = nil     // 24x24 PNG: 3x3 slices of 8x8 (relative to the style file)
    public var font: UUID? = nil             // nil = built-in font
    public var textColor = "#FFFFFF"
    public var shadowColor = "#1A1C2C"
    public var fillColor = "#29366F"
    public var colors: [String: String] = TextBoxStyleAsset.defaultColors
    public var rainbow: [String] = ["#FF5050", "#FFA040", "#FFE14D", "#50E070", "#50A8FF", "#B070FF"]

    public static let colorNames = ["red", "yellow", "green", "blue", "gray"]
    public static let defaultColors = ["red": "#FF5A5A", "yellow": "#FFE14D", "green": "#6BD15A", "blue": "#6AB8FF", "gray": "#9AA0B4"]

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = TextBoxStyleAsset()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? def }
        guid = try v(.guid, d.guid); position = try v(.position, d.position); lines = try v(.lines, d.lines)
        marginX = try v(.marginX, d.marginX); marginY = try v(.marginY, d.marginY); nameWidth = try v(.nameWidth, d.nameWidth)
        speed = try v(.speed, d.speed); portraitRight = try v(.portraitRight, d.portraitRight); pauseGame = try v(.pauseGame, d.pauseGame)
        shadow = try v(.shadow, d.shadow); frameImage = try c.decodeIfPresent(String.self, forKey: .frameImage)
        font = try c.decodeIfPresent(UUID.self, forKey: .font)
        textColor = try v(.textColor, d.textColor); shadowColor = try v(.shadowColor, d.shadowColor); fillColor = try v(.fillColor, d.fillColor)
        colors = try v(.colors, d.colors); rainbow = try v(.rainbow, d.rainbow)
    }
}

/// A font image: 16 columns x 6 rows of glyphs for ASCII 32-127 (cells up to 12x12)
public struct FontAsset: Codable, Equatable, Sendable {
    public var guid: UUID
    public var image: String
    public init(guid: UUID = UUID(), image: String) { self.guid = guid; self.image = image }
}

// MARK: Asset files

public enum AssetKind: String, CaseIterable, Sendable {
    case sprite, tileset, prefab, scene, platformer, dialogue, speaker, textbox, font

    public var fileSuffix: String { ".\(rawValue).json" }

    public static func of(_ url: URL) -> AssetKind? {
        let name = url.lastPathComponent
        return allCases.first { name.hasSuffix($0.fileSuffix) }
    }

    public var displayName: String {
        switch self {
        case .sprite: "Sprite"
        case .tileset: "Tileset"
        case .prefab: "Prefab"
        case .scene: "Scene"
        case .platformer: "Platformer Settings"
        case .dialogue: "Dialogue"
        case .speaker: "Speaker"
        case .textbox: "Text Box Style"
        case .font: "Font"
        }
    }
}

/// Asset name = file name without the kind suffix
public func assetName(_ url: URL) -> String {
    var n = url.lastPathComponent
    if let k = AssetKind.of(url) { n.removeLast(k.fileSuffix.count) }
    return n
}

/// Valid C identifier from an asset/script name
public func cIdentifier(_ s: String) -> String {
    var out = s.map { $0.isLetter || $0.isNumber || $0 == "_" ? String($0) : "_" }.joined()
    if let f = out.first, f.isNumber { out = "_" + out }
    return out.isEmpty ? "_" : out
}
