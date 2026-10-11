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
}

print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
exit(failures == 0 ? 0 : 1)
