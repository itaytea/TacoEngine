import Foundation

/// Export a game as a web page: index.html + game.gba, played in the browser with EmulatorJS
/// (an open-source emulator; its mGBA core is loaded from the EmulatorJS CDN). Upload the folder
/// to itch.io (as an HTML game, zipped) or any web host. Saves are kept in the player's browser.
public enum WebExport {
    public struct ExportError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The EmulatorJS release the page loads (pinned, so a CDN update can't break exported games)
    public static let emulatorVersion = "4.2.3"

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
            try page(title: p.settings.name).write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            try readme(title: p.settings.name).write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
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
    static func page(title: String) -> String {
        let data = "https://cdn.emulatorjs.org/\(emulatorVersion)/data/"
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

    static func readme(title: String) -> String {
        """
        \(title): web version

          index.html   the game, filling the page or the frame it's embedded in
          game.gba     the ROM

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

        The page loads EmulatorJS \(emulatorVersion) (GPL-3.0, https://emulatorjs.org) and its mGBA core from the
        EmulatorJS servers, so players need an internet connection.

        """
    }
}
