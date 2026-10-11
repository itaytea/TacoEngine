import AppKit

public struct Diagnostic: Equatable, Sendable, Identifiable, Hashable {
    public enum Severity: String, Sendable { case error, warning, note }
    public var id = UUID()
    public var severity: Severity
    public var file: String?
    public var line: Int?
    public var column: Int?
    public var message: String
}

public struct BuildResult: Sendable {
    public var success: Bool
    public var log: String
    public var diagnostics: [Diagnostic]
    public var rom: URL?
}

/// Exports the project and compiles it with devkitARM (no make, so paths with spaces are fine).
public enum Builder {
    public static var devkitPro: String { ProcessInfo.processInfo.environment["DEVKITPRO"] ?? "/opt/devkitpro" }
    static var tool: String { devkitPro + "/devkitARM/bin/arm-none-eabi-" }

    /// The engine folder: $GBA_ENGINE, an `engine/` folder in or above the project, the copy inside
    /// TacoEngine.app, or an `engine/` folder next to the app.
    public static func findEngine(for project: URL) -> URL? {
        func check(_ u: URL) -> URL? {
            let e = u.appendingPathComponent("engine")
            return FileManager.default.fileExists(atPath: e.appendingPathComponent("src/engine.h").path) ? e : nil
        }
        if let env = ProcessInfo.processInfo.environment["GBA_ENGINE"] { return URL(fileURLWithPath: env) }
        var dir = project
        for _ in 0..<5 {
            if let e = check(dir) { return e }
            dir = dir.deletingLastPathComponent()
        }
        if let resources = Bundle.main.resourceURL, let e = check(resources) { return e }
        return check(Bundle.main.bundleURL.deletingLastPathComponent())
    }

    public static func romURL(_ p: GameProject) -> URL { p.buildDir.appendingPathComponent("game.gba") }

    /// Write generated files (only touching them if their content changed, to keep builds incremental).
    public static func export(_ p: GameProject, boot: Codegen.Boot) throws -> [String] {
        let sounds = try SoundConverter.convertAll(p)
        let out = try Codegen.generate(p, boot: boot, sounds: sounds)
        let gen = p.buildDir.appendingPathComponent("generated")
        try FileManager.default.createDirectory(at: gen, withIntermediateDirectories: true)
        try writeIfChanged(out.header, gen.appendingPathComponent("script_types.h"))
        try writeIfChanged(out.assets, gen.appendingPathComponent("assets.c"))
        try writeIfChanged(out.soundData, gen.appendingPathComponent("sounds.s"))
        // Lets clangd (Cursor / VS Code) find engine.h and the generated types while editing scripts
        if let engine = findEngine(for: p.root) {
            let flags = ["-xc", "-std=gnu2x", "--target=arm-none-eabi", "-I\(engine.appendingPathComponent("src").path)", "-I\(gen.path)"]
            try? writeIfChanged(flags.joined(separator: "\n") + "\n", p.root.appendingPathComponent("compile_flags.txt"))
        }
        return out.warnings
    }

    static func writeIfChanged(_ text: String, _ url: URL) throws {
        if let old = try? String(contentsOf: url, encoding: .utf8), old == text { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func build(_ p: GameProject, boot: Codegen.Boot = .start, progress: ((String) -> Void)? = nil) -> BuildResult {
        var log = ""
        var diags: [Diagnostic] = []
        func fail(_ msg: String) -> BuildResult {
            diags.append(Diagnostic(severity: .error, message: msg))
            return BuildResult(success: false, log: log + msg + "\n", diagnostics: diags, rom: nil)
        }
        guard let engine = findEngine(for: p.root) else { return fail("Couldn't find the engine runtime (engine/src/engine.h). Rebuild TacoEngine.app with build_editor.sh, or set the GBA_ENGINE environment variable to the engine folder.") }
        guard FileManager.default.fileExists(atPath: tool + "gcc") else { return fail("devkitARM isn't installed (looked in \(devkitPro)). Taco Engine needs it to build games: install devkitPro with the gba-dev package, see https://devkitpro.org/wiki/Getting_Started") }

        progress?("Exporting assets…")
        do {
            for w in try export(p, boot: boot) { diags.append(Diagnostic(severity: .warning, message: w)) }
        } catch {
            return fail(error.localizedDescription)
        }

        let gen = p.buildDir.appendingPathComponent("generated")
        let obj = p.buildDir.appendingPathComponent("obj")
        try? FileManager.default.createDirectory(at: obj, withIntermediateDirectories: true)
        let fm = FileManager.default
        func files(_ dir: URL, _ ext: String) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == ext }
        }
        let engineSrc = engine.appendingPathComponent("src")
        let sources = files(engineSrc, "c").sorted { $0.path < $1.path } + [gen.appendingPathComponent("assets.c"), gen.appendingPathComponent("sounds.s")]
            + p.scriptFiles()
        // Any header change rebuilds everything that could include it
        let headers = files(engineSrc, "h") + files(gen, "h") + GameProject.files(in: p.scriptsDir, ext: "h")
        func mtime(_ u: URL) -> Date { (try? fm.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast }
        let newestHeader = headers.map(mtime).max() ?? .distantPast

        let arch = ["-mthumb", "-mthumb-interwork", "-mcpu=arm7tdmi", "-mtune=arm7tdmi"]
        let cflags = arch + ["-O2", "-Wall", "-Wno-unused-parameter", "-Wno-unused-function", "-Wno-unused-const-variable", "-fno-strict-aliasing",
                             "-ffunction-sections", "-fdata-sections", "-fdiagnostics-color=never",
                             "-I", engineSrc.path, "-I", gen.path, "-I", p.scriptsDir.path]

        struct Job { let src: URL; let obj: URL }
        let jobs = sources.map { src -> Job in
            let name: String
            if src.path.hasPrefix(engineSrc.path) { name = "engine_" + src.deletingPathExtension().lastPathComponent }
            else if src.path.hasPrefix(gen.path) { name = "gen_" + src.deletingPathExtension().lastPathComponent }
            else {   // scripts can sit in any folder: keep their relative path in the object name so names never clash
                name = "script_" + p.relative(src.deletingPathExtension()).replacingOccurrences(of: "/", with: "__").replacingOccurrences(of: " ", with: "_")
            }
            return Job(src: src, obj: obj.appendingPathComponent(name + ".o"))
        }
        let stale = jobs.filter { j in
            let o = mtime(j.obj)
            return o < mtime(j.src) || o < newestHeader
        }
        progress?("Compiling \(stale.count) file\(stale.count == 1 ? "" : "s")…")

        let lock = NSLock()
        var outputs: [String] = []
        var ok = true
        DispatchQueue.concurrentPerform(iterations: stale.count) { i in
            let j = stale[i]
            let (status, out) = run(tool + "gcc", cflags + ["-c", j.src.path, "-o", j.obj.path])
            lock.lock()
            if status != 0 { ok = false; try? fm.removeItem(at: j.obj) }
            if !out.isEmpty { outputs.append(out) }
            lock.unlock()
        }
        for o in outputs {
            log += o
            diags += parseDiagnostics(o)
        }
        guard ok else { return BuildResult(success: false, log: log, diagnostics: diags, rom: nil) }

        progress?("Linking…")
        let elf = p.buildDir.appendingPathComponent("game.elf")
        let (ls, lout) = run(tool + "gcc", arch + ["-specs=gba.specs", "-Wl,--gc-sections"] + jobs.map(\.obj.path) + ["-o", elf.path])
        log += lout
        diags += parseDiagnostics(lout) + linkerDiagnostics(lout)
        guard ls == 0 else {
            if !diags.contains(where: { $0.severity == .error && $0.message != "ld returned 1 exit status" }) {
                // Show whatever the linker said rather than failing silently
                for l in lout.split(separator: "\n") where !l.contains("collect2") {
                    diags.append(Diagnostic(severity: .error, message: String(l.split(separator: ":").suffix(2).joined(separator: ":")).trimmingCharacters(in: .whitespaces)))
                }
                if !diags.contains(where: { $0.severity == .error }) { diags.append(Diagnostic(severity: .error, message: "Linking failed (see Raw build log)")) }
            }
            diags.removeAll { $0.message == "ld returned 1 exit status" }
            return BuildResult(success: false, log: log, diagnostics: diags, rom: nil)
        }
        let rom = romURL(p)
        let (os, oout) = run(tool + "objcopy", ["-O", "binary", elf.path, rom.path])
        log += oout
        guard os == 0 else { return fail("objcopy failed") }
        do { try fixHeader(rom, title: p.settings.romTitle) } catch { return fail("Couldn't finalize the ROM: \(error.localizedDescription)") }
        let size = (try? fm.attributesOfItem(atPath: rom.path)[.size] as? Int) ?? 0
        log += "Built \(rom.lastPathComponent) (\(size / 1024) KB)\n"
        return BuildResult(success: true, log: log, diagnostics: diags, rom: rom)
    }

    static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = devkitPro + "/devkitARM/bin:/usr/bin:/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "Couldn't run \(exe): \(error.localizedDescription)\n") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static let diagRegex = try! NSRegularExpression(pattern: #"^(.+?):(\d+):(?:(\d+):)? (error|warning|note|fatal error): (.*)$"#, options: .anchorsMatchLines)

    public static func parseDiagnostics(_ text: String) -> [Diagnostic] {
        let ns = text as NSString
        return diagRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            let sev: Diagnostic.Severity = g(4)!.contains("error") ? .error : g(4) == "warning" ? .warning : .note
            return Diagnostic(severity: sev, file: g(1), line: g(2).flatMap { Int($0) }, column: g(3).flatMap { Int($0) }, message: g(5) ?? "")
        }
    }

    /// Linker messages ("undefined reference to `foo'") in plain words
    static func linkerDiagnostics(_ text: String) -> [Diagnostic] {
        var out: [Diagnostic] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n").map(String.init) {
            for (pattern, message) in [("undefined reference to `", "is used but never defined (missing function or variable, or a typo?)"),
                                       ("multiple definition of `", "is defined twice (two scripts use the same global name? make one `static`)")] {
                guard let r = line.range(of: pattern), let end = line[r.upperBound...].firstIndex(of: "'") else { continue }
                let name = String(line[r.upperBound..<end])
                if seen.insert(name + message).inserted { out.append(Diagnostic(severity: .error, message: "\(name) \(message)")) }
            }
        }
        return out
    }

    /// GBA header: title, game code, fixed byte, complement check
    static func fixHeader(_ url: URL, title: String) throws {
        var rom = [UInt8](try Data(contentsOf: url))
        if rom.count < 0xC0 { rom += [UInt8](repeating: 0, count: 0xC0 - rom.count) }
        let t = Array(title.uppercased().utf8.prefix(12))
        for i in 0..<12 { rom[0xA0 + i] = i < t.count ? t[i] : 0 }
        for (i, b) in "GBAE00".utf8.enumerated() { rom[0xAC + i] = b }
        rom[0xB2] = 0x96
        var chk = 0
        for i in 0xA0..<0xBD { chk -= Int(rom[i]) }
        rom[0xBD] = UInt8((chk - 0x19) & 0xFF)
        while rom.count % 4 != 0 { rom.append(0) }
        try Data(rom).write(to: url)
    }

    /// mGBA settings for this run: no auto-loaded save states, real GBA speed, and a small audio buffer
    /// (with audio sync on, a big buffer lets the emulator run ahead of the screen and makes input feel late).
    static let mgbaOptions = ["autoload=0", "autosave=0", "fpsTarget=59.7275", "audioBuffers=1024", "frameskip=0"]

    /// Opens the ROM in mGBA if installed (replacing a game it's already running), otherwise the default app.
    /// mGBA's location, if it's installed
    public static var mgbaApp: String? {
        ["/Applications/mGBA.app", NSHomeDirectory() + "/Applications/mGBA.app"].first { FileManager.default.fileExists(atPath: $0) }
    }

    public static func launch(_ rom: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let mgba = mgbaApp
        if mgba != nil {
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "com.endrift.mgba-qt" { app.terminate() }
        }
        p.arguments = mgba.map { ["-n", "-a", $0, "--args"] + mgbaOptions.flatMap { ["-C", $0] } + [rom.path] } ?? [rom.path]
        try? p.run()
    }
}
