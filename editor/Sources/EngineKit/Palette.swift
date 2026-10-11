import Foundation

/// A GBA 16-color palette: index 0 is transparent, 1...15 are colors (BGR555).
public struct Palette16 {
    public private(set) var colors: [UInt16] = []   // up to 15 entries, for indices 1...15
    public private(set) var reduced = false          // true if the art had more than 15 colors

    /// Build a palette covering all opaque pixels of the given images.
    public init(images: [Bitmap]) {
        var counts: [UInt16: Int] = [:]
        for img in images { for p in img.pixels where p.isOpaque { counts[p.rgb15, default: 0] += 1 } }
        if counts.count <= 15 {
            // Most used first; ties by color value, so the same art always gives the same palette
            colors = counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
        } else {
            reduced = true
            colors = Palette16.medianCut(counts, target: 15)
        }
    }

    /// Palette index (0 = transparent) for a pixel.
    public func index(of p: RGBA) -> Int {
        guard p.isOpaque else { return 0 }
        let c = p.rgb15
        if let i = colors.firstIndex(of: c) { return i + 1 }
        var best = 0, bestD = Int.max
        for (i, k) in colors.enumerated() {
            let d = Palette16.distance(c, k)
            if d < bestD { bestD = d; best = i }
        }
        return best + 1
    }

    /// 16 entries with index 0 = 0
    public var entries: [UInt16] { [0] + colors + Array(repeating: 0, count: 15 - colors.count) }

    static func comps(_ c: UInt16) -> (Int, Int, Int) { (Int(c & 31), Int((c >> 5) & 31), Int((c >> 10) & 31)) }

    static func distance(_ a: UInt16, _ b: UInt16) -> Int {
        let (r1, g1, b1) = comps(a), (r2, g2, b2) = comps(b)
        let dr = r1 - r2, dg = g1 - g2, db = b1 - b2
        return 3 * dr * dr + 4 * dg * dg + 2 * db * db
    }

    static func medianCut(_ counts: [UInt16: Int], target: Int) -> [UInt16] {
        var boxes: [[(UInt16, Int)]] = [counts.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }]   // fixed order: builds are reproducible
        while boxes.count < target {
            // Split the box with the widest channel range (weighted by pixel count)
            var bestBox = -1, bestScore = 0, bestChannel = 0
            for (bi, box) in boxes.enumerated() where box.count > 1 {
                for ch in 0..<3 {
                    let vals = box.map { v -> Int in let c = comps(v.0); return ch == 0 ? c.0 : ch == 1 ? c.1 : c.2 }
                    let range = vals.max()! - vals.min()!
                    let weight = box.reduce(0) { $0 + $1.1 }
                    let score = range * Int(Double(weight).squareRoot() + 1)
                    if score > bestScore { bestScore = score; bestBox = bi; bestChannel = ch }
                }
            }
            if bestBox < 0 { break }
            let ch = bestChannel
            let sorted = boxes[bestBox].sorted { a, b in
                let ca = comps(a.0), cb = comps(b.0)
                return ((ch == 0 ? ca.0 : ch == 1 ? ca.1 : ca.2), a.0) < ((ch == 0 ? cb.0 : ch == 1 ? cb.1 : cb.2), b.0)
            }
            let total = sorted.reduce(0) { $0 + $1.1 }
            var acc = 0, split = 1
            for (i, e) in sorted.enumerated() {
                acc += e.1
                if acc >= total / 2 { split = max(1, min(sorted.count - 1, i + 1)); break }
            }
            boxes[bestBox] = Array(sorted[..<split])
            boxes.append(Array(sorted[split...]))
        }
        return boxes.map { box in
            var r = 0, g = 0, b = 0, n = 0
            for (c, w) in box { let (cr, cg, cb) = comps(c); r += cr * w; g += cg * w; b += cb * w; n += w }
            n = max(n, 1)
            return UInt16(r / n) | (UInt16(g / n) << 5) | (UInt16(b / n) << 10)
        }
    }
}

/// Convert a bitmap region into GBA 4bpp 8x8 tiles (row-major tile order), as 32-bit words.
public func tiles4bpp(_ img: Bitmap, palette: Palette16) -> [UInt32] {
    var words: [UInt32] = []
    for ty in 0..<(img.height / 8) {
        for tx in 0..<(img.width / 8) {
            for y in 0..<8 {
                var row: UInt32 = 0
                for x in 0..<8 {
                    row |= UInt32(palette.index(of: img[tx * 8 + x, ty * 8 + y])) << (x * 4)
                }
                words.append(row)
            }
        }
    }
    return words
}
