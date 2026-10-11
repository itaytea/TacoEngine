import EngineKit
import Foundation

// Command-line companion to Taco Engine:
//   gbaexport new <folder>                        create a new project
//   gbaexport build <project> [--scene Name] [--run]
//   gbaexport check <project>                     parse scripts and generate code without compiling
//   gbaexport export-web <project> <folder>       build and write a web version (index.html + game.gba)

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("usage: gbaexport new|build|check|export-web <projectFolder> [--scene Name] [--run]")
    exit(1)
}
let root = URL(fileURLWithPath: args[1]).standardizedFileURL

do {
    switch args[0] {
    case "new":
        let p = try Templates.emptyProject(at: root, scriptTemplates: Templates.scriptLibrary(engine: Builder.findEngine(for: root)))
        print("Created empty project: \(p.sprites.count) sprite, \(p.tilesets.count) tileset, \(p.scenes.count) scene")
    case "export-web":
        guard args.count >= 3 else { print("usage: gbaexport export-web <project> <folder>"); exit(1) }
        let p = try GameProject.load(root)
        let r = WebExport.export(p, to: URL(fileURLWithPath: args[2])) { print($0) }
        for d in r.diagnostics { print("\(d.severity.rawValue): \(d.message)") }
        print(r.success ? "Exported to \(args[2])" : "Export failed")
        if !r.success { exit(1) }
    case "check":
        let p = try GameProject.load(root)
        for s in p.scripts { print("script \(s.name): fields \(s.fields.filter { $0.kind != .hidden }.map(\.name)) callbacks \(s.callbacks.sorted())") }
        for w in try Builder.export(p, boot: .start) { print("warning: \(w)") }
        print("Generated code in build/generated")
    case "build":
        let p = try GameProject.load(root)
        var boot = Codegen.Boot.start
        if let i = args.firstIndex(of: "--scene"), i + 1 < args.count {
            guard let id = p.scenes.first(where: { $0.value.name == args[i + 1] })?.key else { print("no scene \(args[i + 1])"); exit(1) }
            boot = .scene(id)
        }
        let r = Builder.build(p, boot: boot) { print($0) }
        for d in r.diagnostics {
            let loc = d.file.map { "\($0):\(d.line ?? 0): " } ?? ""
            print("\(loc)\(d.severity.rawValue): \(d.message)")
        }
        print(r.log.components(separatedBy: "\n").last { !$0.isEmpty } ?? "")
        if !r.success { exit(1) }
        if args.contains("--run"), let rom = r.rom { Builder.launch(rom) }
    default:
        print("unknown command \(args[0])")
        exit(1)
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
