// EngineKit tests. Run with `swift run enginekit-tests` in editor/ (works without Xcode).
// `swift run enginekit-tests --update-golden` rewrites the expected generated code after an intended change.
import EngineKit
import Foundation

var failures = 0, checks = 0
func expect(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL \((file as NSString).lastPathComponent):\(line)  \(what)") }
}
func test(_ name: String, _ body: () throws -> Void) {
    do { try body() } catch { failures += 1; print("FAIL \(name): threw \(error)") }
}
let fixtures = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("Fixtures")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("enginekit-tests-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: tmp)
defer { try? FileManager.default.removeItem(at: tmp) }

// MARK: Script parser

test("script fields") {
    let src = """
    #include "engine.h"
    SCRIPT(Multi) {
        int a, b;          // = 3 Both start at three
        unsigned int c, d[4], *e;
        fixed speed;       // = 1.5 How fast
        EntityHandle target;   // @hide
    };
    void Multi_Update(Multi *self, Entity *e) {}
    """
    let s = ScriptParser.parse(src, file: URL(fileURLWithPath: "/x/multi.c"))
    expect(s.count == 1 && s[0].name == "Multi", "one script named Multi")
    let f = Dictionary(uniqueKeysWithValues: s[0].fields.map { ($0.name, $0) })
    expect(f["a"]?.kind == .int && f["b"]?.kind == .int, "a and b are int fields")
    expect(f["a"]?.defaultValue == .number(3) && f["b"]?.defaultValue == .number(3), "both get the default")
    expect(f["b"]?.help == "Both start at three", "both get the help text")
    expect(f["c"]?.kind == .int, "unsigned int c")
    expect(f["d"]?.kind == .hidden && f["e"]?.kind == .hidden, "arrays and pointers are hidden")
    expect(f["speed"]?.kind == .fixed && f["speed"]?.defaultValue == .number(1.5), "fixed with default")
    expect(f["target"]?.kind == .hidden, "@hide")
    expect(s[0].callbacks == ["Update"], "callbacks")
}

// MARK: Prefab overrides

test("overrides keyed by script name") {
    func script(_ name: String, _ speed: Double) -> JSON { .object(["script": .string(name), "fields": .object(["speed": .number(speed)])]) }
    let prefab = JSON.object(["scripts": .array([script("Walk", 1), script("Jump", 2)])])
    let instance = JSON.object(["scripts": .array([script("Walk", 1), script("Jump", 5)])])
    let patch = instance.diff(from: prefab)
    expect(patch?.contains(path: ["scripts", "@Jump", "fields", "speed"]) == true, "patch is keyed @Jump")
    // The prefab's scripts get reordered: the override still lands on Jump
    let reordered = JSON.object(["scripts": .array([script("Jump", 2), script("Walk", 1)])])
    let merged = reordered.merged(with: patch!)
    expect(merged == .object(["scripts": .array([script("Jump", 5), script("Walk", 1)])]), "override follows the script")
    // Jump removed from the prefab: nothing is applied to Walk
    let removed = JSON.object(["scripts": .array([script("Walk", 1)])])
    expect(removed.merged(with: patch!) == removed, "override of a removed script is ignored")
    // Older projects: index keys still merge
    let legacy = JSON.object(["scripts": .object(["1": .object(["fields": .object(["speed": .number(9)])])])])
    expect(prefab.merged(with: legacy) == .object(["scripts": .array([script("Walk", 1), script("Jump", 9)])]), "index keys")
}

// MARK: Editing several entities

test("multi-entity edits") {
    var a = EntityDef(), b = EntityDef()
    a.tag = "Enemy"; b.tag = "Enemy"
    a.collider = ColliderComponent(x: -4, w: 8); b.collider = ColliderComponent(x: -6, w: 12)
    a.sprite = SpriteComponent(animation: "walk")
    a.scripts = [ScriptComponent(script: "Walk", fields: ["speed": .number(1), "range": .number(10)]), ScriptComponent(script: "Hurt")]
    b.scripts = [ScriptComponent(script: "Walk", fields: ["speed": .number(2), "range": .number(10)])]
    let shared = EntityDef.shared([a, b])
    expect(shared.sprite == nil && shared.collider != nil, "only components both have")
    expect(shared.scripts.map(\.script) == ["Walk"], "only scripts both have")
    let mixed = EntityDef.mixed([a, b])
    expect(mixed?.contains(path: ["collider", "x"]) == true && mixed?.contains(path: ["collider", "w"]) == true, "differing collider values")
    expect(mixed?.contains(path: ["collider", "h"]) == false && mixed?.contains(path: ["tag"]) == false, "equal values aren't mixed")
    expect(mixed?.contains(path: ["scripts", "@Walk", "fields", "speed"]) == true, "differing script field")
    // Changing one value copies only that value
    var edit = shared
    edit.collider?.h = 20
    edit.scripts[0].fields["range"] = .number(50)
    let b2 = b.applyingEdit(from: shared, to: edit)
    expect(b2.collider == ColliderComponent(x: -6, w: 12, h: 20), "h set, x and w kept")
    expect(b2.scripts[0].fields == ["speed": .number(2), "range": .number(50)], "range set, speed kept")
    let a2 = a.applyingEdit(from: shared, to: edit)
    expect(a2.sprite == a.sprite && a2.scripts.count == 2, "components not shown are untouched")
    // Adding and removing components
    var add = shared
    add.platformer = PlatformerComponent()
    add.scripts.append(ScriptComponent(script: "Hurt"))
    expect(b.applyingEdit(from: shared, to: add).platformer != nil, "added component")
    expect(a.applyingEdit(from: shared, to: add).scripts.filter { $0.script == "Hurt" }.count == 1, "a script it has isn't added twice")
    var remove = shared
    remove.collider = nil
    remove.scripts = []
    let b3 = b.applyingEdit(from: shared, to: remove)
    expect(b3.collider == nil && b3.scripts.isEmpty, "removed components")
}

// MARK: Tile tools

test("rectangle and flood fill") {
    var s = SceneAsset(width: 6, height: 4)
    s.fillRect(4, 2, 1, 1, with: 3)
    expect((1...4).allSatisfy { x in s[x, 1] == 3 && s[x, 2] == 3 } && s[0, 1] == 0 && s[1, 3] == 0, "corners in any order")
    s.fillRect(-5, -5, 10, 0, with: 2)
    expect((0..<6).allSatisfy { s[$0, 0] == 2 }, "clipped to the map")
    s.fillRect(10, 10, 20, 20, with: 9)
    expect(!s.cells.contains(9), "a box outside the map does nothing")
    s.floodFill(0, 3, with: 7)
    expect(s[0, 3] == 7 && s[5, 3] == 7 && s[0, 1] == 7 && s[5, 2] == 7, "fills the empty area around the box")
    expect(s[2, 1] == 3 && s[0, 0] == 2, "stops at other tiles")
    let before = s
    s.floodFill(2, 2, with: 3)
    expect(s == before, "filling with the same tile changes nothing")
}

// MARK: Dialogue

test("page character counts") {
    // "Hi" [variable 0] [pause 30] newline "!" [page] "ok"
    let bytes: [UInt8] = [72, 105, 0x08, 0, 0x07, 30, 0x0A, 33, 0x0C, 111, 107, 0]
    expect(DialogueText.pageCharCounts(bytes) == [2 + DialogueText.variableDigits + 1 + 1, 2], "letters, variable digits, pauses; per page")
}

// MARK: Palettes

test("palette order is deterministic") {
    let a = RGBA(255, 0, 0), b = RGBA(0, 255, 0), c = RGBA(0, 0, 255)
    let img = Bitmap(width: 4, height: 1, pixels: [b, a, c, c])   // c used twice; a and b tie
    let p1 = Palette16(images: [img]), p2 = Palette16(images: [img])
    expect(p1.entries == p2.entries, "same art, same palette")
    expect(p1.colors.first == c.rgb15, "most used first")
    expect(Array(p1.colors.dropFirst()) == [a.rgb15, b.rgb15].sorted(), "ties ordered by color value")
}

// MARK: Validation and loading

func newProject(_ name: String) throws -> GameProject {
    let engine = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("../../../engine/templates/scripts").standardizedFileURL
    return try Templates.emptyProject(at: tmp.appendingPathComponent(name), scriptTemplates: engine)
}

test("validation") {
    var p = try newProject("Valid")
    expect(Codegen.validate(p).errors.isEmpty, "a new project is valid: \(Codegen.validate(p).errors)")

    var extra = SceneAsset(width: 20, height: 10)
    p.scenes[extra.guid] = Stored(path: "assets/scenes/Level-1.scene.json", value: extra)
    var other = SceneAsset(width: 20, height: 10)
    p.scenes[other.guid] = Stored(path: "assets/scenes/Level 1.scene.json", value: other)
    p.settings.scenes += [extra.guid, other.guid]
    expect(Codegen.validate(p).errors.contains { $0.contains("SCENE_Level_1") }, "scene names that clash in C")

    p.settings.tags = ["Untagged"]
    expect(Codegen.validate(p).errors.contains { $0.contains("reserved") }, "reserved tag name")
    p.settings.tags = []

    extra.entities = (0..<97).map { SceneEntity(name: "E\($0)", x: 0, y: 0, def: EntityDef()) }
    other.entities = []
    p.scenes[extra.guid]!.value = extra
    p.scenes[other.guid] = nil
    p.settings.scenes.removeLast()
    expect(Codegen.validate(p).errors.contains { $0.contains("97 entities") }, "entity limit")
}

test("unreadable files are reported, scene order kept") {
    let p = try newProject("Broken")
    var second = SceneAsset(width: 20, height: 10)
    second.background = "#000000"
    var q = p
    q.scenes[second.guid] = Stored(path: "assets/scenes/Second.scene.json", value: second)
    q.settings.scenes.append(second.guid)
    try q.saveChanges(since: p)
    // Break the first scene (a merge conflict left in it)
    let first = q.root.appendingPathComponent("assets/scenes/Main.scene.json")
    try ("<<<<<<< HEAD\n" + String(contentsOf: first, encoding: .utf8)).write(to: first, atomically: true, encoding: .utf8)
    let loaded = try GameProject.load(q.root)
    expect(loaded.loadIssues.contains { $0.contains("Main.scene.json") }, "decode failure reported: \(loaded.loadIssues)")
    expect(loaded.settings.scenes == q.settings.scenes, "build order unchanged, so scene numbers don't shift")
    expect(!Codegen.validate(loaded).errors.isEmpty, "builds refuse to run")
    // A Finder copy: two files with the same id
    try FileManager.default.copyItem(at: q.root.appendingPathComponent("assets/scenes/Second.scene.json"),
                                     to: q.root.appendingPathComponent("assets/scenes/Second copy.scene.json"))
    expect(try GameProject.load(q.root).loadIssues.contains { $0.contains("same id") }, "duplicate ids reported")
}

test("scene size is clamped when decoding") {
    let json = #"{"guid":"\#(UUID().uuidString)","width":-5,"height":9999,"map":[]}"#
    let s = try JSONDecoder().decode(SceneAsset.self, from: Data(json.utf8))
    expect(s.width == 1 && s.height == 256 && s.cells.count == 256, "clamped to 1...256")
}

// MARK: Generated code (golden file)

test("generated code for a new project") {
    let p = try newProject("Golden")
    let out = try Codegen.generate(p)
    // Normalize what legitimately varies: the project folder name only appears in the title
    let assets = out.assets
    let golden = fixtures.appendingPathComponent("new_project_assets.c")
    if CommandLine.arguments.contains("--update-golden") {
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try assets.write(to: golden, atomically: true, encoding: .utf8)
        print("updated \(golden.lastPathComponent)")
    } else {
        let expected = (try? String(contentsOf: golden, encoding: .utf8)) ?? ""
        expect(assets == expected, "assets.c matches Fixtures/new_project_assets.c (run with --update-golden after an intended change)")
    }
    expect(try Codegen.generate(p).assets == assets, "generation is deterministic")
    expect(assets.contains("const int boot_player[3] = { 0, 0, 0 };"), "no player position by default")
    let here = try Codegen.generate(p, boot: .sceneAt(p.settings.scenes[0], x: 40, y: -3)).assets
    expect(here.contains("const int boot_player[3] = { 1, 40, -3 };") && here.contains("const int boot_title = 0;"), "Play From Here")
}

print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
exit(failures == 0 ? 0 : 1)
