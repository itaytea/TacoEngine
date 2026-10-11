import Foundation

// Dialogue text: markup parsing, word wrapping into pages, and the bytes the engine reads.
// The exporter and the editor's preview both use this, so the preview matches the game.
//
// Markup:  [b] [i] [wave] [shake] [rainbow] ... [/b] etc.   [color=red] ... [/color]
//          [pause=30] (frames)   [page] (new page)   {coins} (a variable)   new lines are kept

// MARK: - Font

public struct FontData: Equatable, Sendable {
    public var height: Int
    public var widths: [Int]          // 96 entries, ASCII 32..127
    public var rows: [[UInt16]]       // 96 x 12, bit x = pixel x

    public func width(_ c: UInt8) -> Int { c >= 32 && c < 128 ? widths[Int(c) - 32] : 0 }

    /// From a font image: 16 x 6 grid of cells, ASCII 32..127
    public static func from(_ img: Bitmap) -> FontData {
        let cw = max(1, img.width / 16), chh = max(1, img.height / 6)
        var widths = [Int](repeating: 0, count: 96), rows = [[UInt16]](repeating: [UInt16](repeating: 0, count: 12), count: 96)
        for g in 0..<96 {
            let ox = (g % 16) * cw, oy = (g / 16) * chh
            var right = -1
            for y in 0..<min(12, chh) {
                var bits: UInt16 = 0
                for x in 0..<min(16, cw) where img[ox + x, oy + y].isOpaque { bits |= 1 << x; right = max(right, x) }
                rows[g][y] = bits
            }
            widths[g] = right >= 0 ? right + 2 : (g == 0 ? max(3, cw / 2) : 0)
        }
        return FontData(height: min(12, chh), widths: widths, rows: rows)
    }

    /// Render as a font image (16 x 6 cells of 8 x 12), e.g. to give users an editable copy
    public func bitmap() -> Bitmap {
        var img = Bitmap(width: 16 * 8, height: 6 * 12)
        for g in 0..<96 {
            for y in 0..<12 { for x in 0..<8 where rows[g][y] & (1 << x) != 0 { img[(g % 16) * 8 + x, (g / 16) * 12 + y] = RGBA(255, 255, 255) } }
        }
        return img
    }

    /// The built-in font: 5x7 capitals, lowercase with descenders
    public static let standard: FontData = {
        var widths = [Int](repeating: 0, count: 96), rows = [[UInt16]](repeating: [UInt16](repeating: 0, count: 12), count: 96)
        for (ch, art) in DefaultFont.glyphs {
            guard let a = ch.asciiValue, a >= 32, a < 128 else { continue }
            let g = Int(a) - 32
            var right = -1
            for (r, line) in art.enumerated() where r + DefaultFont.top(ch) < 12 {
                var bits: UInt16 = 0
                for (x, c) in line.enumerated() where c == "#" { bits |= 1 << x; right = max(right, x) }
                rows[g][r + DefaultFont.top(ch)] = bits
            }
            widths[g] = right + 2
        }
        widths[0] = 3   // space
        return FontData(height: 11, widths: widths, rows: rows)
    }()
}

enum DefaultFont {
    /// Row where a glyph's art starts (lowercase art includes ascender rows)
    static func top(_ c: Character) -> Int { 1 }

    static let glyphs: [Character: [String]] = {
        var g: [Character: [String]] = [:]
        let caps: [(Character, String)] = [
            ("A", ".###.#...##...######...##...##...#"), ("B", "####.#...##...#####.#...##...#####."),
            ("C", ".###.#...##....#....#....#...#.###."), ("D", "####.#...##...##...##...##...#####."),
            ("E", "######....#....####.#....#....#####"), ("F", "######....#....####.#....#....#...."),
            ("G", ".###.#...##....#.####...##...#.####"), ("H", "#...##...##...#######...##...##...#"),
            ("I", "###.#..#..#..#.###"), ("J", "..###...#....#....##..#.#..#..##.."),
            ("K", "#...##..#.#.#..##...#.#..#..#.#...#"), ("L", "#...#...#...#...#...#...####"),
            ("M", "#...###.###.#.##.#.##...##...##...#"), ("N", "#...##...###..##.#.##..###...##...#"),
            ("O", ".###.#...##...##...##...##...#.###."), ("P", "####.#...##...#####.#....#....#...."),
            ("Q", ".###.#...##...##...##.#.##..#..##.#"), ("R", "####.#...##...#####.#.#..#..#.#...#"),
            ("S", ".#####....#.....###.....#....######."), ("T", "#####..#....#....#....#....#....#.."),
            ("U", "#...##...##...##...##...##...#.###."), ("V", "#...##...##...##...##...#.#.#...#.."),
            ("W", "#...##...##...##.#.##.#.##.#.#.#.#."), ("X", "#...##...#.#.#...#...#.#.#...##...#"),
            ("Y", "#...##...#.#.#...#....#....#....#.."), ("Z", "#####....#...#...#...#...#....#####"),
            ("0", ".###.#...##..###.#.###..##...#.###."), ("1", ".#.##..#..#..#..#.###"),
            ("2", ".###.#...#....#...#...#...#...#####"), ("3", "####.....#....#.###.....#....#####."),
            ("4", "...#...##..#.#.#..#.#####...#....#."), ("5", "######....####.....#....##...#.###."),
            ("6", ".###.#....#....####.#...##...#.###."), ("7", "#####....#...#...#...#....#....#..."),
            ("8", ".###.#...##...#.###.#...##...#.###."), ("9", ".###.#...##...#.####....#....#.###."),
        ]
        for (c, s) in caps {
            let w = s.count / 7
            g[c] = (0..<7).map { r in String(Array(s)[(r * w)..<(r * w + w)]) }
        }
        // Lowercase: 9 rows (ascender top .. descender bottom), x-height rows 3-7
        let lower: [Character: [String]] = [
            "a": [".....", ".....", ".###.", "....#", ".####", "#...#", ".####"],
            "b": ["#....", "#....", "####.", "#...#", "#...#", "#...#", "####."],
            "c": ["....", "....", ".###", "#...", "#...", "#...", ".###"],
            "d": ["....#", "....#", ".####", "#...#", "#...#", "#...#", ".####"],
            "e": [".....", ".....", ".###.", "#...#", "#####", "#....", ".###."],
            "f": ["..##", ".#..", "###.", ".#..", ".#..", ".#..", ".#.."],
            "g": [".....", ".....", ".####", "#...#", "#...#", "#...#", ".####", "....#", ".###."],
            "h": ["#....", "#....", "####.", "#...#", "#...#", "#...#", "#...#"],
            "i": ["#", ".", "#", "#", "#", "#", "#"],
            "j": ["..#", "...", "..#", "..#", "..#", "..#", "..#", "..#", "##."],
            "k": ["#...", "#...", "#..#", "#.#.", "##..", "#.#.", "#..#"],
            "l": ["#.", "#.", "#.", "#.", "#.", "#.", ".#"],
            "m": [".....", ".....", "##.#.", "#.#.#", "#.#.#", "#.#.#", "#.#.#"],
            "n": [".....", ".....", "####.", "#...#", "#...#", "#...#", "#...#"],
            "o": [".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###."],
            "p": [".....", ".....", "####.", "#...#", "#...#", "#...#", "####.", "#....", "#...."],
            "q": [".....", ".....", ".####", "#...#", "#...#", "#...#", ".####", "....#", "....#"],
            "r": ["....", "....", "#.##", "##..", "#...", "#...", "#..."],
            "s": ["....", "....", ".###", "#...", ".##.", "...#", "###."],
            "t": [".#..", ".#..", "###.", ".#..", ".#..", ".#..", "..##"],
            "u": [".....", ".....", "#...#", "#...#", "#...#", "#...#", ".####"],
            "v": [".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
            "w": [".....", ".....", "#...#", "#...#", "#.#.#", "#.#.#", ".#.#."],
            "x": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
            "y": [".....", ".....", "#...#", "#...#", "#...#", "#...#", ".####", "....#", ".###."],
            "z": [".....", ".....", "#####", "...#.", "..#..", ".#...", "#####"],
        ]
        for (c, rows) in lower { g[c] = rows }
        let punct: [Character: [String]] = [
            "!": ["#", "#", "#", "#", "#", ".", "#"],
            "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
            ".": [".", ".", ".", ".", ".", ".", "#"],
            ",": ["..", "..", "..", "..", "..", "..", ".#", "#."],
            "'": ["#", "#"],
            "\"": ["#.#", "#.#"],
            ":": [".", ".", "#", ".", ".", ".", "#"],
            ";": ["..", "..", ".#", "..", "..", "..", ".#", "#."],
            "-": ["....", "....", "....", "####"],
            "+": ["...", "...", ".#.", "###", ".#."],
            "=": ["....", "....", "####", "....", "####"],
            "(": [".#", "#.", "#.", "#.", "#.", "#.", ".#"],
            ")": ["#.", ".#", ".#", ".#", ".#", ".#", "#."],
            "/": ["...#", "...#", "..#.", ".#..", ".#..", "#...", "#..."],
            "<": ["...", "..#", ".#.", "#..", ".#.", "..#"],
            ">": ["...", "#..", ".#.", "..#", ".#.", "#.."],
            "*": [".....", "#.#.#", ".###.", "#.#.#"],
            "%": ["##..#", "##.#.", "..#..", ".#...", "#..##", "...##"],
            "#": [".#.#.", "#####", ".#.#.", "#####", ".#.#."],
            "&": [".##..", "#..#.", ".##..", "#..##", "#..#.", ".##.#"],
            "_": [".....", ".....", ".....", ".....", ".....", ".....", ".....", "#####"],
            "@": [".###.", "#...#", "#.###", "#.#.#", "#.###", "#....", ".###."],
            "$": ["..#..", ".####", "#.#..", ".###.", "..#.#", "####.", "..#.."],
            "~": [".....", ".....", ".#..#", "#.##."],
            "^": [".#.", "#.#"],
            "[": ["##", "#.", "#.", "#.", "#.", "#.", "##"],
            "]": ["##", ".#", ".#", ".#", ".#", ".#", "##"],
            "|": ["#", "#", "#", "#", "#", "#", "#", "#"],
        ]
        for (c, rows) in punct { g[c] = rows }
        return g
    }()
}

// MARK: - Text box geometry

public struct TextBoxGeometry: Equatable, Sendable {
    public var boxX, boxY, boxW, boxH: Int       // tiles, frame included
    public var nameX, nameY, nameW: Int          // tiles (nameW 0 = none)
    public var padX = 4, padY = 3                // px inside the interior

    public var interiorW: Int { (boxW - 2) * 8 }
    public var interiorH: Int { (boxH - 2) * 8 }

    public init(style s: TextBoxStyleAsset, font: FontData) {
        boxW = max(6, 30 - 2 * s.marginX)
        boxX = (30 - boxW) / 2
        let inner = s.lines * font.height + 2 * padY
        boxH = max(4, (inner + 7) / 8 + 2)
        boxY = s.position == .bottom ? 20 - s.marginY - boxH : s.marginY
        nameW = s.nameWidth > 0 ? min(boxW, max(4, s.nameWidth)) : 0
        nameX = boxX + 1
        nameY = s.position == .bottom ? boxY - 4 : boxY + boxH
        if nameY < 0 || nameY + 4 > 20 { nameW = 0 }
    }

    /// Width available for text on a line (narrower when the speaker has a portrait)
    public func textWidth(portraitWidth: Int?) -> Int {
        interiorW - 2 * padX - (portraitWidth.map { $0 + 6 } ?? 0)
    }
}

// MARK: - Layout

public struct DialogueChar: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var ch: UInt8            // 0 = a pause marker
    public var flags: Int           // 1 bold, 2 italic, 4 wave, 8 rainbow, 16 shake
    public var color: Int           // 0 default, 11..15 named colors
    public var pause: Int = 0
}

public enum DialogueText {
    public static let bold = 1, italic = 2, wave = 4, rainbow = 8, shake = 16
    /// Room left for a {variable} when wrapping: 5 digits (up to 99999, or -9999)
    public static let variableDigits = 5
    /// Characters the engine lays out per page at most (MAX_CHARS in dialogue.c); more are cut off
    public static let maxPageChars = 160

    /// Characters per page as the engine counts them (letters, spaces, pauses, variable digits)
    public static func pageCharCounts(_ bytes: [UInt8]) -> [Int] {
        var counts = [0], i = 0
        while i < bytes.count, bytes[i] != 0 {
            let b = bytes[i]
            switch b {
            case 0x0C: counts.append(0)
            case 0x06: i += 1
            case 0x07: counts[counts.count - 1] += 1; i += 1
            case 0x08: counts[counts.count - 1] += variableDigits; i += 1
            case 0x20...: counts[counts.count - 1] += 1
            default: break
            }
            i += 1
        }
        return counts
    }

    enum Token {
        case char(UInt8, flags: Int, color: Int)
        case variable(Int, flags: Int, color: Int)
        case newline, page
        case pause(Int)
    }

    static let tagFlags: [String: Int] = ["b": bold, "i": italic, "wave": wave, "rainbow": rainbow, "shake": shake]

    static func tokens(_ text: String, variables: [String]) -> [Token] {
        var out: [Token] = []
        var flags = 0, colorStack: [Int] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "[", let close = chars[i...].firstIndex(of: "]") {
                let tag = String(chars[(i + 1)..<close]).lowercased()
                var handled = true
                if let f = tagFlags[tag] { flags |= f }
                else if tag.hasPrefix("/"), let f = tagFlags[String(tag.dropFirst())] { flags &= ~f }
                else if tag.hasPrefix("color=") {
                    let name = String(tag.dropFirst(6))
                    colorStack.append(TextBoxStyleAsset.colorNames.firstIndex(of: name).map { 11 + $0 } ?? 0)
                } else if tag == "/color" { _ = colorStack.popLast() }
                else if tag.hasPrefix("pause=") { out.append(.pause(max(1, min(255, Int(tag.dropFirst(6)) ?? 30)))) }
                else if tag == "page" { out.append(.page) }
                else { handled = false }
                if handled { i = close + 1; continue }
            }
            if c == "{", let close = chars[i...].firstIndex(of: "}") {
                let name = String(chars[(i + 1)..<close])
                if let v = variables.firstIndex(of: name) {
                    out.append(.variable(v, flags: flags, color: colorStack.last ?? 0))
                    i = close + 1
                    continue
                }
            }
            if c == "\n" { out.append(.newline) }
            else if let a = c.asciiValue, a >= 32, a < 128 { out.append(.char(a, flags: flags, color: colorStack.last ?? 0)) }
            else { out.append(.char(63, flags: flags, color: colorStack.last ?? 0)) }   // '?' for characters the font lacks
            i += 1
        }
        return out
    }

    /// Wrap text into pages of positioned characters
    public static func pages(_ text: String, font: FontData, width: Int, lines: Int, variables: [String]) -> [[DialogueChar]] {
        let toks = tokens(text, variables: variables)
        var pages: [[DialogueChar]] = [[]]
        var x = 0, line = 0
        func adv(_ c: UInt8, _ flags: Int) -> Int { font.width(c) + (flags & bold != 0 ? 1 : 0) }
        func newLine() {
            x = 0
            line += 1
            if line >= lines { pages.append([]); line = 0 }
        }
        func newPage() { x = 0; line = 0; if !(pages.last?.isEmpty ?? true) { pages.append([]) } }
        // Group into words so wrapping happens at spaces
        var i = 0
        while i < toks.count {
            switch toks[i] {
            case .newline: newLine(); i += 1; continue
            case .page: newPage(); i += 1; continue
            case .pause(let n):
                pages[pages.count - 1].append(DialogueChar(x: x, y: line * font.height, ch: 0, flags: 0, color: 0, pause: n))
                i += 1; continue
            case .char(32, let f, _):
                if x > 0 { x += adv(32, f) }
                i += 1; continue
            default: break
            }
            // a word: everything up to the next space/newline/page
            var j = i, w = 0
            var word: [Token] = []
            while j < toks.count {
                if case .char(32, _, _) = toks[j] { break }
                if case .newline = toks[j] { break }
                if case .page = toks[j] { break }
                switch toks[j] {
                case .char(let c, let f, _): w += adv(c, f)
                case .variable(_, let f, _): w += variableDigits * adv(48, f)
                default: break
                }
                word.append(toks[j])
                j += 1
            }
            if x > 0 && x + w > width { newLine() }
            for t in word {
                switch t {
                case .char(let c, let f, let col):
                    if x + adv(c, f) > width && x > 0 { newLine() }   // a single word longer than the line
                    pages[pages.count - 1].append(DialogueChar(x: x, y: line * font.height, ch: c, flags: f, color: col))
                    x += adv(c, f)
                case .variable(let v, let f, let col):
                    pages[pages.count - 1].append(DialogueChar(x: x, y: line * font.height, ch: 1, flags: f, color: col, pause: v))
                    x += variableDigits * adv(48, f)
                case .pause(let n):
                    pages[pages.count - 1].append(DialogueChar(x: x, y: line * font.height, ch: 0, flags: 0, color: 0, pause: n))
                default: break
                }
            }
            i = j
        }
        if pages.count > 1 && pages.last!.isEmpty { pages.removeLast() }
        return pages
    }

    /// Bytes for the engine (see engine/src/dialogue.c). The engine lays a page out by advancing x
    /// character by character, so spaces between words are written out again here.
    public static func bytes(_ text: String, font: FontData, width: Int, lines: Int, variables: [String]) -> [UInt8] {
        var out: [UInt8] = []
        let pgs = pages(text, font: font, width: width, lines: lines, variables: variables)
        for (pi, page) in pgs.enumerated() {
            if pi > 0 { out.append(0x0C) }
            var flags = 0, color = 0, y = 0, x = 0
            for c in page {
                while c.y > y { out.append(0x0A); y += font.height; x = 0 }
                if c.ch == 0 { out += [0x07, UInt8(c.pause)]; continue }
                let space = font.width(32) + (flags & bold != 0 ? 1 : 0)
                while x + space / 2 < c.x { out.append(32); x += space }
                x = c.x
                let diff = flags ^ c.flags
                for bit in 0..<5 where diff & (1 << bit) != 0 { out.append(UInt8(bit + 1)) }
                flags = c.flags
                if c.color != color { out += [0x06, UInt8(c.color)]; color = c.color }
                let boldW = flags & bold != 0 ? 1 : 0
                if c.ch == 1 { out += [0x08, UInt8(c.pause)]; x += variableDigits * (font.width(48) + boldW); continue }   // variable
                out.append(c.ch)
                x += font.width(c.ch) + boldW
            }
        }
        out.append(0)
        return out
    }
}
