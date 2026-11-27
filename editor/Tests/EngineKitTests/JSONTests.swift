import XCTest
@testable import EngineKit

final class JSONTests: XCTestCase {
    private func roundTrip(_ value: JSON) throws -> JSON {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSON.self, from: data)
    }

    func testRoundTripOfNestedValue() throws {
        // Avoids 0 and 1 as numbers: the decoder tries Bool before Double.
        let value: JSON = .object([
            "name": .string("hero"),
            "speed": .number(3.5),
            "alive": .bool(true),
            "dead": .bool(false),
            "nothing": .null,
            "list": .array([.number(2), .string("x"), .null, .array([.bool(true)])]),
            "child": .object(["w": .number(16), "h": .number(32)]),
        ])
        XCTAssertEqual(try roundTrip(value), value)
    }

    func testDecodeFromText() throws {
        let text = #"{"a": 42, "b": "hi", "c": [true, null], "d": {"e": 2.5}}"#
        let json = try JSONDecoder().decode(JSON.self, from: Data(text.utf8))
        XCTAssertEqual(json, .object([
            "a": .number(42),
            "b": .string("hi"),
            "c": .array([.bool(true), .null]),
            "d": .object(["e": .number(2.5)]),
        ]))
    }

    func testAccessors() {
        XCTAssertEqual(JSON.number(4).number, 4)
        XCTAssertEqual(JSON.bool(true).number, 1)
        XCTAssertEqual(JSON.bool(false).number, 0)
        XCTAssertNil(JSON.string("4").number)
        XCTAssertEqual(JSON.bool(true).bool, true)
        XCTAssertEqual(JSON.number(2).bool, true)
        XCTAssertEqual(JSON.number(0).bool, false)
        XCTAssertNil(JSON.string("true").bool)
        XCTAssertEqual(JSON.string("s").string, "s")
        XCTAssertNil(JSON.number(1).string)
        XCTAssertEqual(JSON.object(["k": .null]).object, ["k": .null])
        XCTAssertNil(JSON.array([]).object)
    }

    func testMergedObjectsRecursively() {
        let base: JSON = .object(["a": .number(10), "b": .object(["c": .number(20)])])
        let patch: JSON = .object(["b": .object(["d": .number(30)]), "e": .string("new")])
        XCTAssertEqual(base.merged(with: patch), .object([
            "a": .number(10),
            "b": .object(["c": .number(20), "d": .number(30)]),
            "e": .string("new"),
        ]))
    }

    func testMergedScalarPatchReplaces() {
        XCTAssertEqual(JSON.number(2).merged(with: .string("x")), .string("x"))
        XCTAssertEqual(JSON.object(["a": .number(2)]).merged(with: .number(5)), .number(5))
    }

    func testMergedArrayPatchedByIndex() {
        let base: JSON = .array([.number(2), .number(3)])
        XCTAssertEqual(base.merged(with: .object(["1": .number(9)])), .array([.number(2), .number(9)]))
        // out-of-range and non-numeric keys are ignored
        XCTAssertEqual(base.merged(with: .object(["5": .number(9), "x": .number(9)])), base)
    }

    func testDiff() {
        let base: JSON = .object(["a": .number(10), "b": .number(20)])
        XCTAssertNil(base.diff(from: base))
        let changed: JSON = .object(["a": .number(10), "b": .number(21), "c": .string("added")])
        XCTAssertEqual(changed.diff(from: base), .object(["b": .number(21), "c": .string("added")]))
        // keys missing from self are not reported
        XCTAssertNil(JSON.object(["a": .number(10)]).diff(from: base))
    }

    func testDiffOfArrays() {
        let base: JSON = .array([.number(2), .number(3), .number(4)])
        XCTAssertEqual(JSON.array([.number(2), .number(9), .number(4)]).diff(from: base), .object(["1": .number(9)]))
        // different length: the whole array is the patch
        let shorter: JSON = .array([.number(2)])
        XCTAssertEqual(shorter.diff(from: base), shorter)
    }

    func testDiffThenMergeReproducesValue() {
        let base: JSON = .object(["pos": .object(["x": .number(8), "y": .number(16)]), "tags": .array([.string("a"), .string("b")])])
        let edited: JSON = .object(["pos": .object(["x": .number(8), "y": .number(24)]), "tags": .array([.string("a"), .string("c")])])
        let patch = edited.diff(from: base)
        XCTAssertNotNil(patch)
        XCTAssertEqual(base.merged(with: patch!), edited)
    }

    func testContainsPath() {
        let patch: JSON = .object(["components": .object(["collider": .object(["w": .number(8)])])])
        XCTAssertTrue(patch.contains(path: []))
        XCTAssertTrue(patch.contains(path: ["components"]))
        XCTAssertTrue(patch.contains(path: ["components", "collider", "w"]))
        XCTAssertFalse(patch.contains(path: ["components", "collider", "h"]))
        XCTAssertFalse(patch.contains(path: ["other"]))
        XCTAssertFalse(patch.contains(path: ["components", "collider", "w", "deeper"]))
    }

    func testRemovingPath() {
        let patch: JSON = .object(["a": .object(["b": .number(10), "c": .number(20)]), "d": .number(30)])
        XCTAssertEqual(patch.removing(path: ["a", "b"]), .object(["a": .object(["c": .number(20)]), "d": .number(30)]))
        XCTAssertEqual(patch.removing(path: ["d"]), .object(["a": .object(["b": .number(10), "c": .number(20)])]))
        // removing the last key leaves nothing
        XCTAssertNil(JSON.object(["a": .object(["b": .number(10)])]).removing(path: ["a", "b"]))
        XCTAssertNil(patch.removing(path: []))
        XCTAssertNil(JSON.number(2).removing(path: ["a"]))
    }

    private struct Sample: Codable, Equatable {
        var name: String
        var size: Int
        var tags: [String]
    }

    func testFromAndDecodeCodable() {
        let sample = Sample(name: "box", size: 12, tags: ["a", "b"])
        let json = JSON.from(sample)
        XCTAssertEqual(json, .object(["name": .string("box"), "size": .number(12), "tags": .array([.string("a"), .string("b")])]))
        XCTAssertEqual(json.decode(Sample.self), sample)
        XCTAssertNil(JSON.string("nope").decode(Sample.self))
    }
}
