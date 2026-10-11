import CryptoKit
import Foundation

/// The EmulatorJS files a web export ships next to the game, so exported games run offline and don't
/// depend on a third-party server. They're downloaded once per version into the user's cache folder,
/// and every file is checked against a SHA-256 hash recorded here, so a changed file is never used.
public enum EmulatorJS {
    public static let version = "4.2.3"
    static let cdn = "https://cdn.emulatorjs.org/\(version)/data/"
    static let licenseURL = "https://raw.githubusercontent.com/EmulatorJS/EmulatorJS/v\(version)/LICENSE"

    /// What a GBA game needs (the legacy core and English text are forced in the page, so these never vary)
    static let files: [(path: String, sha256: String)] = [
        ("loader.js", "69e0903bf1e2f62ced78895e7e511fa26e11316f7eb734925c35e919ba1287b2"),
        ("emulator.min.js", "6aec3fd7bb2721255801b0a6af02e47e78b05e28a1822b1f213aacbd348abaee"),
        ("emulator.min.css", "16406c60b2dc3b04ae9b115e308613e6f567a0cc7068e21d9d0c1e5030fb395e"),
        ("localization/en-US.json", "b0c9a9bb92ecd2d03614ee2b0eeda160e883ee79ea94d9e8131addb92c5803f9"),
        ("cores/reports/mgba.json", "08219f6c855a9d996f04ed21169bb0c5ac64d469a8a536468b9876205b5c268d"),
        ("cores/mgba-legacy-wasm.data", "e300d2f368c82bf61d77c972c36e367cf16408ec3d50beede080337519a3d696"),
        ("compression/extract7z.js", "4ac9933b995a516cb6b3ca4027db860278372a20c21c405d93ceb1998498853a"),
        ("LICENSE", "a617fab6d251b3302b1cb2c1c94f52d1c584f6fcb2fc218ec1a475bc08053a61"),
    ]

    public struct DownloadError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TacoEngine/emulatorjs/\(version)")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The verified files in the cache, downloading any that are missing (needs internet the first time)
    public static func ensureCached(progress: ((String) -> Void)? = nil) throws -> URL {
        let fm = FileManager.default
        for f in files {
            let dest = cacheDir.appendingPathComponent(f.path)
            if let d = try? Data(contentsOf: dest), sha256(d) == f.sha256 { continue }
            progress?("Downloading EmulatorJS (first export only)…")
            let source = URL(string: f.path == "LICENSE" ? licenseURL : cdn + f.path)!
            guard let data = try? Data(contentsOf: source) else {
                throw DownloadError(message: "Couldn't download EmulatorJS \(version) (\(f.path)). The first web export needs an internet connection; later ones use the saved copy.")
            }
            guard sha256(data) == f.sha256 else {
                throw DownloadError(message: "The downloaded EmulatorJS file \(f.path) doesn't match the expected version, so it wasn't used.")
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
        }
        return cacheDir
    }

    /// Copy the files into `folder` (an export's emulatorjs/ folder)
    public static func copy(to folder: URL, progress: ((String) -> Void)? = nil) throws {
        let src = try ensureCached(progress: progress)
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        for f in files {
            let dest = folder.appendingPathComponent(f.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src.appendingPathComponent(f.path), to: dest)
        }
    }
}
