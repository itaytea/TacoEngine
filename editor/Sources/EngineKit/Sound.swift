import Foundation

/// Turns the project's audio files into the engine's sound format: signed 8-bit mono at 13379 Hz
/// (exactly 224 samples per GBA frame). macOS's afconvert does the decoding and resampling, so any
/// format Core Audio reads works: WAV, AIFF, MP3, M4A/AAC, CAF, FLAC.
public enum SoundConverter {
    public static let rate = 13379

    public struct Converted: Sendable {
        public let name: String
        public let raw: URL        // build/sounds/<name>.raw
        public let samples: Int
    }

    public struct ConvertError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Convert every sound in the project (reusing conversions that are newer than their source file)
    public static func convertAll(_ p: GameProject) throws -> [Converted] {
        let dir = p.buildDir.appendingPathComponent("sounds")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [Converted] = []
        for s in p.sounds() {
            let src = p.url(s.path)
            let raw = dir.appendingPathComponent(cIdentifier(s.name) + ".raw")
            if let rawDate = modified(raw), let srcDate = modified(src), rawDate > srcDate,
               let size = try? FileManager.default.attributesOfItem(atPath: raw.path)[.size] as? Int {
                out.append(Converted(name: s.name, raw: raw, samples: size))
                continue
            }
            let wav = dir.appendingPathComponent(cIdentifier(s.name) + ".wav")
            try? FileManager.default.removeItem(at: wav)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            proc.arguments = ["-f", "WAVE", "-d", "LEI16@\(rate)", "-c", "1", "--mix", src.path, wav.path]
            let pipe = Pipe()
            proc.standardError = pipe
            proc.standardOutput = pipe
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0, let data = try? Data(contentsOf: wav) else {
                let msg = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw ConvertError(message: "Sound \(s.name): couldn't convert \((s.path as NSString).lastPathComponent). \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            let pcm = pcm16(fromWAV: data)
            var bytes = [UInt8](repeating: 0, count: max(1, pcm.count))
            for (i, v) in pcm.enumerated() { bytes[i] = UInt8(bitPattern: Int8(truncatingIfNeeded: Int(v) >> 8)) }
            try Data(bytes).write(to: raw)
            try? FileManager.default.removeItem(at: wav)
            out.append(Converted(name: s.name, raw: raw, samples: bytes.count))
        }
        return out
    }

    static func modified(_ u: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
    }

    /// The samples of a 16-bit PCM WAV file (the "data" chunk)
    static func pcm16(fromWAV d: Data) -> [Int16] {
        let b = [UInt8](d)
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        var i = 12
        while i + 8 <= b.count {
            let id = String(bytes: b[i..<i + 4], encoding: .ascii) ?? ""
            let size = u32(i + 4)
            if id == "data" {
                let end = min(b.count, i + 8 + size)
                var out: [Int16] = []
                out.reserveCapacity((end - i - 8) / 2)
                var j = i + 8
                while j + 1 < end { out.append(Int16(bitPattern: UInt16(b[j]) | UInt16(b[j + 1]) << 8)); j += 2 }
                return out
            }
            i += 8 + size + (size & 1)
        }
        return []
    }
}
