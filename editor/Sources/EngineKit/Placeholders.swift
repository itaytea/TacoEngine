import Foundation

/// Placeholder pixel art for the ready-made prefabs. Everything here is meant to be replaced.
public enum Placeholders {

    static func draw(_ rows: [String], _ key: [Character: UInt32]) -> Bitmap {
        var img = Bitmap(width: rows.first?.count ?? 0, height: rows.count)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                if let hex = key[ch] { img[x, y] = RGBA(hex: hex) }
            }
        }
        return img
    }

    static let spikeKey: [Character: UInt32] = ["K": 0x2A2A3A, "L": 0xE8E8F0, "M": 0x9A9AB0]
    static let spike = [
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
        "...KK......KK...",
        "..KLMK....KLMK..",
        "..KLMK....KLMK..",
        ".KLLMMK..KLLMMK.",
        ".KLLMMK..KLLMMK.",
        "KLLLMMMKKLLLMMMK",
        "KLLLMMMKKLLLMMMK",
        "KKKKKKKKKKKKKKKK",
    ]


    static let flagKey: [Character: UInt32] = ["K": 0x22222E, "P": 0xE8E8F0, "Y": 0xFFE14D, "F": 0xFF5A5A, "f": 0xC23A4A, "G": 0x8A8AA0]
    static let flagA = [
        "..KYK...........",
        "..KPKFFFFFF.....",
        "..KPKFFFFFFFF...",
        "..KPKFfFFFFFFFF.",
        "..KPKFfFFFFFFF..",
        "..KPKFFFFFFF....",
        "..KPKFFFF.......",
        "..KPK...........",
        "..KPK...........",
        "..KPK...........",
        "..KPK...........",
        "..KPK...........",
        "..KPK...........",
        ".KKPKK..........",
        "KGGGGGK.........",
        "KKKKKKK.........",
    ]
    static let flagB = [
        "..KYK...........",
        "..KPKFFFF.......",
        "..KPKFFFFFFF....",
        "..KPKFfFFFFFFFF.",
        "..KPKFfFFFFFFFFF",
        "..KPKFFFFFFFF...",
        "..KPKFFFFFF.....",
        "..KPK...........",
        "..KPK...........",
        "..KPK...........",
        "..KPK...........",
        "..KPK...........",
        "..KPK...........",
        ".KKPKK..........",
        "KGGGGGK.........",
        "KKKKKKK.........",
    ]

    public static func flagSheet() -> Bitmap { Bitmap.strip([draw(flagA, flagKey), draw(flagB, flagKey)]) }

    /// Slime enemy, 2 frames
    public static func slimeSheet() -> Bitmap {
        let frames = [(6.5, 6.0), (7.5, 5.0)].map { (rx, ry) -> Bitmap in
            var f = Bitmap(width: 16, height: 16)
            for y in 0..<16 { for x in 0..<16 {
                let dx = (Double(x) + 0.5 - 8) / rx, dy = (Double(y) + 0.5 - 16) / (ry * 1.6)
                let d = dx * dx + dy * dy
                if d <= 1 && y < 16 { f[x, y] = RGBA(hex: d > 0.7 ? 0x5A1E6E : 0xB04ADA) }
            } }
            let eyeY = Int(16 - ry * 1.1)
            for ex in [6, 10] { f[ex, eyeY] = RGBA(hex: 0xFFFFFF); f[ex, eyeY + 1] = RGBA(hex: 0x14142E) }
            return f
        }
        return Bitmap.strip(frames)
    }

    /// Spikes pointing up, one frame
    public static func spikeSprite() -> Bitmap { draw(spike, spikeKey) }
}
