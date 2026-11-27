import XCTest
@testable import EngineKit

final class DialogueTextTests: XCTestCase {
    /// Every glyph is 6 px wide, lines are 8 px tall, so expected positions are easy to read.
    private let font = FontData(height: 8, widths: [Int](repeating: 6, count: 96), rows: [[UInt16]](repeating: [UInt16](repeating: 0, count: 12), count: 96))

    private func pages(_ text: String, width: Int = 100, lines: Int = 2, variables: [String] = []) -> [[DialogueChar]] {
        DialogueText.pages(text, font: font, width: width, lines: lines, variables: variables)
    }

    private func bytes(_ text: String, width: Int = 100, lines: Int = 2, variables: [String] = []) -> [UInt8] {
        DialogueText.bytes(text, font: font, width: width, lines: lines, variables: variables)
    }

    // MARK: font

    func testFontWidthLookup() {
        XCTAssertEqual(font.width(65), 6)
        XCTAssertEqual(font.width(32), 6)
        XCTAssertEqual(font.width(31), 0)
        XCTAssertEqual(font.width(128), 0)
    }

    func testStandardFontShape() {
        let f = FontData.standard
        XCTAssertEqual(f.widths.count, 96)
        XCTAssertEqual(f.rows.count, 96)
        XCTAssertEqual(f.height, 11)
        XCTAssertEqual(f.width(32), 3)
        XCTAssertGreaterThan(f.width(UInt8(ascii: "A")), 0)
    }

    // MARK: layout

    func testPlainTextPositions() {
        let p = pages("Hi")
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].map(\.ch), [72, 105])
        XCTAssertEqual(p[0].map(\.x), [0, 6])
        XCTAssertEqual(p[0].map(\.y), [0, 0])
    }

    func testEmptyTextIsOneEmptyPage() {
        XCTAssertEqual(pages("").count, 1)
        XCTAssertTrue(pages("")[0].isEmpty)
    }

    func testSpacesAdvanceButAreNotEmitted() {
        let p = pages("a b")[0]
        XCTAssertEqual(p.map(\.ch), [97, 98])
        XCTAssertEqual(p.map(\.x), [0, 12])
    }

    func testWordWrapMovesWordToNextLine() {
        let p = pages("aaa bbb", width: 18)[0]
        XCTAssertEqual(p.count, 6)
        XCTAssertEqual(p.map(\.x), [0, 6, 12, 0, 6, 12])
        XCTAssertEqual(p.map(\.y), [0, 0, 0, 8, 8, 8])
    }

    func testOverflowingLinesStartsNewPage() {
        let p = pages("aaa bbb", width: 18, lines: 1)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].count, 3)
        XCTAssertEqual(p[1].map(\.y), [0, 0, 0])
    }

    func testNewlineAndPageMarkers() {
        let n = pages("a\nb")[0]
        XCTAssertEqual(n.map(\.y), [0, 8])
        XCTAssertEqual(n.map(\.x), [0, 0])

        let p = pages("a[page]b")
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].map(\.ch), [97])
        XCTAssertEqual(p[1].map(\.ch), [98])
    }

    func testLongWordBreaksAtWidth() {
        let p = pages("aaaa", width: 12)[0]
        XCTAssertEqual(p.map(\.x), [0, 6, 0, 6])
        XCTAssertEqual(p.map(\.y), [0, 0, 8, 8])
    }

    // MARK: markup

    func testBoldAddsOnePixelAndSetsFlag() {
        let p = pages("[b]a[/b]b")[0]
        XCTAssertEqual(p.map(\.flags), [DialogueText.bold, 0])
        XCTAssertEqual(p.map(\.x), [0, 7])
    }

    func testFlagTagsAreCaseInsensitiveAndCombine() {
        let p = pages("[I][Wave]a[/i]b")[0]
        XCTAssertEqual(p[0].flags, DialogueText.italic | DialogueText.wave)
        XCTAssertEqual(p[1].flags, DialogueText.wave)
    }

    func testColorTags() {
        let p = pages("[color=red]a[color=blue]b[/color]c[/color]d[color=nope]e")[0]
        XCTAssertEqual(p.map(\.color), [11, 14, 11, 0, 0])
    }

    func testPauseMarker() {
        let p = pages("a[pause=10]b")[0]
        XCTAssertEqual(p.map(\.ch), [97, 0, 98])
        XCTAssertEqual(p[1].pause, 10)
        XCTAssertEqual(p[1].x, 6)
        XCTAssertEqual(p[2].x, 6)
    }

    func testPauseIsClampedAndDefaulted() {
        XCTAssertEqual(pages("[pause=999]a")[0][0].pause, 255)
        XCTAssertEqual(pages("[pause=x]a")[0][0].pause, 30)
    }

    func testVariables() {
        let p = pages("{coins}", variables: ["coins"])[0]
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].ch, 1)
        XCTAssertEqual(p[0].pause, 0)   // the variable's index
        let q = pages("a{b}", variables: ["a", "b"])[0]
        XCTAssertEqual(q.map(\.ch), [97, 1])
        XCTAssertEqual(q[1].pause, 1)
        XCTAssertEqual(q[1].x, 6)
    }

    func testUnknownVariableAndTagAreLiteralText() {
        XCTAssertEqual(pages("{x}")[0].map(\.ch), [123, 120, 125])
        XCTAssertEqual(pages("[foo]")[0].map(\.ch), [91, 102, 111, 111, 93])
    }

    func testNonAsciiBecomesQuestionMark() {
        XCTAssertEqual(pages("\u{E9}")[0].map(\.ch), [63])
    }

    // MARK: bytes

    func testBytesPlainText() {
        XCTAssertEqual(bytes("Hi"), [72, 105, 0])
        XCTAssertEqual(bytes(""), [0])
    }

    func testBytesSpacesAreWrittenOut() {
        XCTAssertEqual(bytes("a b"), [97, 32, 98, 0])
    }

    func testBytesNewlinePageAndPause() {
        XCTAssertEqual(bytes("a\nb"), [97, 0x0A, 98, 0])
        XCTAssertEqual(bytes("a[page]b"), [97, 0x0C, 98, 0])
        XCTAssertEqual(bytes("a[pause=10]b"), [97, 0x07, 10, 98, 0])
    }

    func testBytesStyleColorAndVariable() {
        XCTAssertEqual(bytes("[b]a"), [1, 97, 0])                   // bold bit 0 -> code 1
        XCTAssertEqual(bytes("[color=red]a"), [0x06, 11, 97, 0])
        XCTAssertEqual(bytes("{v}", variables: ["v"]), [0x08, 0, 0])
    }
}
