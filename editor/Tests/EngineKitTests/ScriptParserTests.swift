import XCTest
@testable import EngineKit

final class ScriptParserTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/test_script.c")

    private func fields(_ lines: String) -> [ScriptField] { ScriptParser.parseFields(lines) }

    private func only(_ lines: String, file: StaticString = #filePath, line: UInt = #line) -> ScriptField {
        let f = fields(lines)
        XCTAssertEqual(f.count, 1, file: file, line: line)
        return f[0]
    }

    // MARK: single-declarator fields

    func testBasicKinds() {
        let f = fields("""
            int speed;
            fixed gravity;
            bool alive;
            EntityRef target;
            SceneRef next;
            PrefabRef bullet;
            SpriteRef icon;
            DialogueRef talk;
            SoundRef jump;
            """)
        XCTAssertEqual(f.map(\.name), ["speed", "gravity", "alive", "target", "next", "bullet", "icon", "talk", "jump"])
        XCTAssertEqual(f.map(\.kind), [.int, .fixed, .bool, .entity, .scene, .prefab, .sprite, .dialogue, .sound])
        XCTAssertEqual(f.map(\.ctype), ["int", "fixed", "bool", "EntityRef", "SceneRef", "PrefabRef", "SpriteRef", "DialogueRef", "SoundRef"])
        XCTAssertTrue(f.allSatisfy { $0.defaultValue == nil && $0.help.isEmpty })
    }

    func testIntegerTypeAliases() {
        let f = fields("""
            u8 a;
            s16 b;
            unsigned int c;
            unsigned char d;
            """)
        XCTAssertEqual(f.map(\.kind), [.int, .int, .int, .int])
        XCTAssertEqual(f[2].ctype, "unsigned int")
        XCTAssertEqual(f[2].name, "c")
    }

    func testUnknownTypeIsHidden() {
        let f = only("Vec2 offset;")
        XCTAssertEqual(f.kind, .hidden)
        XCTAssertEqual(f.ctype, "Vec2")
        XCTAssertEqual(f.name, "offset")
    }

    func testIgnoresLinesThatAreNotFields() {
        let f = fields("""

            // just a comment
            int a, b;
            void helper(void);
            int ok;
            """)
        XCTAssertEqual(f.map(\.name), ["ok"])
    }

    // MARK: pointers and arrays

    func testPointerIsHidden() {
        let f = only("Entity *owner;")
        XCTAssertEqual(f.kind, .hidden)
        XCTAssertEqual(f.ctype, "Entity")
        XCTAssertEqual(f.name, "owner")
        let g = only("int* p;")
        XCTAssertEqual(g.kind, .hidden)
        XCTAssertEqual(g.ctype, "int")
        XCTAssertEqual(g.name, "p")
    }

    func testArrayIsHidden() {
        let f = only("int values[4];")
        XCTAssertEqual(f.kind, .hidden)
        XCTAssertEqual(f.ctype, "int")
        XCTAssertEqual(f.name, "values")
        XCTAssertEqual(only("u8 grid[W * H];").kind, .hidden)
    }

    func testPointerWithDefaultCommentHasNoDefault() {
        let f = only("int *p; // = 5")
        XCTAssertEqual(f.kind, .hidden)
        XCTAssertNil(f.defaultValue)
        XCTAssertEqual(f.help, "")
    }

    // MARK: // comments: help text, = default, @hide

    func testHelpText() {
        let f = only("int speed; // Pixels per frame")
        XCTAssertEqual(f.help, "Pixels per frame")
        XCTAssertNil(f.defaultValue)
    }

    func testNumericDefaultAndHelp() {
        let f = only("int speed; // = 5  Move speed")
        XCTAssertEqual(f.defaultValue, .number(5))
        XCTAssertEqual(f.help, "Move speed")
        XCTAssertEqual(only("fixed g; // = 0.5").defaultValue, .number(0.5))
        XCTAssertEqual(only("int n; // = -3").defaultValue, .number(-3))
    }

    func testNonNumericDefaultForIntIsDropped() {
        let f = only("int n; // = abc rest")
        XCTAssertNil(f.defaultValue)
        XCTAssertEqual(f.help, "rest")
    }

    func testBoolDefault() {
        XCTAssertEqual(only("bool a; // = true").defaultValue, .bool(true))
        XCTAssertEqual(only("bool a; // = 1").defaultValue, .bool(true))
        XCTAssertEqual(only("bool a; // = false").defaultValue, .bool(false))
        XCTAssertEqual(only("bool a; // = no").defaultValue, .bool(false))
    }

    func testReferenceDefaultsAreStrings() {
        XCTAssertEqual(only("PrefabRef bullet; // = Bullet").defaultValue, .string("Bullet"))
        XCTAssertEqual(only("SceneRef next; // = Level2 Where to go").defaultValue, .string("Level2"))
        XCTAssertEqual(only("SceneRef next; // = Level2 Where to go").help, "Where to go")
    }

    func testQuotedDefaultWithSpaces() {
        let f = only(#"SpriteRef icon; // = "Cloud Icon" The icon"#)
        XCTAssertEqual(f.defaultValue, .string("Cloud Icon"))
        XCTAssertEqual(f.help, "The icon")
    }

    func testEntityDefaultIsIgnoredButCommentIsConsumed() {
        let f = only("EntityRef target; // = Player Who to chase")
        XCTAssertEqual(f.kind, .entity)
        XCTAssertNil(f.defaultValue)
        XCTAssertEqual(f.help, "Who to chase")
    }

    func testHideMarker() {
        let f = only("int timer; // @hide frames left")
        XCTAssertEqual(f.kind, .hidden)
        XCTAssertEqual(f.help, "frames left")
        XCTAssertNil(f.defaultValue)
        let g = only("int timer; // @hide")
        XCTAssertEqual(g.kind, .hidden)
        XCTAssertEqual(g.help, "")
    }

    func testHideMarkerThenDefaultIsParsedButHiddenKindHasNoDefault() {
        let f = only("int timer; // @hide = 5")
        XCTAssertEqual(f.kind, .hidden)
        XCTAssertNil(f.defaultValue)
        XCTAssertEqual(f.help, "")
    }

    // MARK: whole files

    private let sample = """
        #include "engine.h"

        SCRIPT(Player) {
            int speed;      // = 3  Walk speed
            bool grounded;  // @hide
            Entity *target;
        }

        void Player_Start(Entity *e) {
            if (e) { e->x = 0; }
        }
        void Player_Update(Entity *e) {}
        // void Player_OnDestroy(Entity *e) {}

        // SCRIPT(Ghost) {
        //     int a;
        // }
        """

    func testParseFile() {
        let scripts = ScriptParser.parse(sample, file: file)
        XCTAssertEqual(scripts.count, 1)
        let s = scripts[0]
        XCTAssertEqual(s.name, "Player")
        XCTAssertEqual(s.file, file)
        XCTAssertEqual(s.line, 3)
        XCTAssertEqual(s.fields.map(\.name), ["speed", "grounded", "target"])
        XCTAssertEqual(s.fields.map(\.kind), [.int, .hidden, .hidden])
        XCTAssertEqual(s.callbacks, ["Start", "Update"])
    }

    func testDefaultFieldsSkipsHiddenAndUndefaulted() {
        let s = ScriptParser.parse(sample, file: file)[0]
        XCTAssertEqual(s.defaultFields(), ["speed": .number(3)])
    }

    func testMultipleScriptsInOneFile() {
        let text = """
            SCRIPT(A) {
                int x;
            }
            SCRIPT( B ) {
                bool y;
            }
            void B_OnTrigger(Entity *e, Entity *o) {}
            """
        let scripts = ScriptParser.parse(text, file: file)
        XCTAssertEqual(scripts.map(\.name), ["A", "B"])
        XCTAssertEqual(scripts.map(\.line), [1, 4])
        XCTAssertEqual(scripts[0].callbacks, [])
        XCTAssertEqual(scripts[1].callbacks, ["OnTrigger"])
    }

    func testUnclosedScriptIsSkipped() {
        XCTAssertTrue(ScriptParser.parse("SCRIPT(A) {\n int x;\n", file: file).isEmpty)
    }

    func testCallbackNameMustMatchScriptName() {
        let text = "SCRIPT(A) {\n}\nvoid AB_Start(Entity *e) {}\nvoid A_Update(Entity *e) {}\n"
        XCTAssertEqual(ScriptParser.parse(text, file: file)[0].callbacks, ["Update"])
    }

    func testWithoutCommentsKeepsLengthAndStrings() {
        let text = "a // x\nb /* y\nz */ c \"//keep\" d"
        let out = ScriptParser.withoutComments(text)
        XCTAssertEqual(out.utf16.count, text.utf16.count)
        XCTAssertFalse(out.contains("x"))
        XCTAssertFalse(out.contains("y"))
        XCTAssertTrue(out.contains("\"//keep\""))
        XCTAssertEqual(out.components(separatedBy: "\n").count, 3)
    }
}
