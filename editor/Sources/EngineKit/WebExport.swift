import Foundation

/// Export a game as a web page: index.html + game.gba, played in the browser with EmulatorJS (an
/// open-source emulator with an mGBA core), whose files are copied into emulatorjs/ next to the game.
/// Upload the folder to itch.io (as an HTML game, zipped) or any web host. Saves stay in the browser.
public enum WebExport {
    public struct ExportError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static var emulatorVersion: String { EmulatorJS.version }

    /// Build from the start scene (with the title menu, if any) and write the web folder
    public static func export(_ p: GameProject, to folder: URL, progress: ((String) -> Void)? = nil) -> BuildResult {
        var result = Builder.build(p, boot: .start, progress: progress)
        guard result.success, let rom = result.rom else { return result }
        progress?("Writing the web page…")
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent("game.gba")
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: rom, to: dest)
            // The emulator goes next to the game; if it can't be downloaded (offline, first export), the
            // page loads it from the EmulatorJS servers instead
            var bundled = true
            do {
                try EmulatorJS.copy(to: folder.appendingPathComponent("emulatorjs"), progress: progress)
            } catch {
                bundled = false
                try? fm.removeItem(at: folder.appendingPathComponent("emulatorjs"))
                result.diagnostics.append(Diagnostic(severity: .warning, message: "\(error.localizedDescription) This export loads EmulatorJS from its servers instead, so players need internet. Export again when you're online to include it."))
            }
            try page(title: p.settings.name, bundled: bundled).write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            try readme(title: p.settings.name, bundled: bundled).write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        } catch {
            result.success = false
            result.diagnostics.append(Diagnostic(severity: .error, message: "Couldn't write the web export: \(error.localizedDescription)"))
        }
        return result
    }

    static func html(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func js(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "<", with: "\\u003c")
    }

    /// Only the game: it fills the page (or the iframe it's embedded in), letterboxed to 3:2.
    /// EmulatorJS shows its own start button, which also lets the browser play sound.
    static func page(title: String, bundled: Bool) -> String {
        let data = bundled ? "emulatorjs/" : EmulatorJS.cdn
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(html(title))</title>
        <style>
          html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: #000; }
          #game { width: 100%; height: 100%; }
          #message { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; padding: 16px;
                     color: #ccc; font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; text-align: center; }
        </style>
        </head>
        <body>
        <div id="game"></div>
        <script>
          if (location.protocol === "file:") {
            // Browsers block the game on pages opened straight from disk
            document.body.insertAdjacentHTML("beforeend", '<div id="message">Open this page through a web server to play (see README.txt).</div>');
          } else {
            window.EJS_player = "#game";
            window.EJS_core = "gba";
            window.EJS_gameUrl = "game.gba";
            window.EJS_gameName = "\(js(title))";
            window.EJS_pathtodata = "\(data)";
            window.EJS_forceLegacyCores = true;    // always the same core file (the one shipped in emulatorjs/)
            window.EJS_language = "en-US";
            window.EJS_disableAutoLang = true;
            var script = document.createElement("script");
            script.src = "\(data)loader.js";
            script.onerror = function () {
              document.body.insertAdjacentHTML("beforeend", '<div id="message">The emulator couldn\\'t be downloaded. Check your connection and reload.</div>');
            };
            document.body.appendChild(script);
          }
        </script>
        </body>
        </html>

        """
    }

    static func readme(title: String, bundled: Bool) -> String {
        let emulator = bundled
            ? """
              The game runs in EmulatorJS \(emulatorVersion) (https://emulatorjs.org), included in emulatorjs/ under
              the GPL-3.0 license (emulatorjs/LICENSE). Its source is at https://github.com/EmulatorJS/EmulatorJS.
              Nothing is loaded from other servers, so the game also works offline.
              """
            : """
              The page loads EmulatorJS \(emulatorVersion) (GPL-3.0, https://emulatorjs.org) from the EmulatorJS
              servers, so players need an internet connection. Export again while online to include it instead.
              """
        return """
        \(title): web version

          index.html   the game, filling the page or the frame it's embedded in
          game.gba     the ROM
        \(bundled ? "  emulatorjs/  the emulator (keep it next to index.html)\n" : "")
        itch.io
          Zip this folder and upload it as an HTML game. Tick "This file will be played in the browser"
          and set the viewport to 720 x 480 (or any 3:2 size, e.g. 960 x 640). Optionally tick
          "Mobile friendly" and "Fullscreen button".

        Other websites
          Upload the folder and embed it with an iframe:
            <iframe src="game/index.html" width="720" height="480" allowfullscreen></iframe>

        Testing on your computer
          Browsers won't run the game from a page opened straight from disk. In this folder, run
            python3 -m http.server
          then visit http://localhost:8000

        Controls (EmulatorJS defaults, changeable in its menu): arrows = D-pad, Z = A, X = B,
        Enter = Start, V = Select, Q / E = L / R. Gamepads work, and touch screens get on-screen buttons.
        Saves stay in the player's browser.

        \(emulator)

        """
    }
}
