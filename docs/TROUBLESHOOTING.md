# Troubleshooting

Problems building or running games, and what to check. For the basics, see [Building](building.md). For contributor setup, see [CONTRIBUTING](../CONTRIBUTING.md).

## "devkitARM isn't installed"

The Console shows: `devkitARM isn't installed (looked in /opt/devkitpro)`.

Taco Engine needs `arm-none-eabi-gcc` at `$DEVKITPRO/devkitARM/bin/`. `DEVKITPRO` defaults to `/opt/devkitpro`.

- Install devkitPro with the `gba-dev` package: <https://devkitpro.org/wiki/Getting_Started>.
- Check that the compiler exists: `ls /opt/devkitpro/devkitARM/bin/arm-none-eabi-gcc`.
- If you installed devkitPro somewhere else, set `DEVKITPRO` to that folder. Apps opened from Finder don't read your shell profile, so start the editor from a terminal after exporting it (`export DEVKITPRO=/path/to/devkitpro`, then `open TacoEngine.app`), or run `gbaexport` from the terminal.

## "Couldn't find the engine runtime"

The Console shows: `Couldn't find the engine runtime (engine/src/engine.h)`.

The engine is looked up in this order (see [Where the engine comes from](building.md#where-the-engine-comes-from)): `$GBA_ENGINE`, an `engine/` folder in or above the project, the copy inside `TacoEngine.app`, then an `engine/` folder next to the app.

- If you run the editor from the repository, rebuild the app with `./build_editor.sh` so the engine copy is included, or set `GBA_ENGINE` to the repository's `engine/` folder.
- `GBA_ENGINE` must point at the `engine/` folder itself (the one containing `src/engine.h`), not at the repository root. When it is set, it is used as given, so a wrong path won't fall back to the other locations. Unset it, or fix it, if builds fail with missing `engine.h` or source files.
- As with `DEVKITPRO`, apps opened from Finder don't see variables exported in your shell. Launch with `open TacoEngine.app` from the same terminal.

## mGBA not found

The Console shows: `The game built, but mGBA isn't installed, so it can't be opened.`

Taco Engine looks for `/Applications/mGBA.app` and then `~/Applications/mGBA.app`. If neither exists, it still builds `build/game.gba` and opens it with the default app for `.gba` files.

- Download mGBA from <https://mgba.io> and move it into `/Applications`.
- The ROM is at `build/game.gba` in your project folder, so you can open it in any other GBA emulator.
- If the app is renamed or lives in another folder, it won't be found. Keep the name `mGBA.app`.

## macOS Gatekeeper blocks an app

macOS may refuse to open `TacoEngine.app` or `mGBA.app` ("cannot be opened because the developer cannot be verified", or "is damaged"). `build_editor.sh` signs `TacoEngine.app` ad hoc only, which Gatekeeper doesn't treat as a trusted developer.

- Control-click (or right-click) the app, choose **Open**, then confirm. This is needed once per app.
- Or allow it in **System Settings ▸ Privacy & Security**, in the section that mentions the blocked app, with **Open Anyway**.
- If the app came from a download and still shows "is damaged", remove the quarantine flag in Terminal: `xattr -dr com.apple.quarantine /path/to/TacoEngine.app`. Only do this for apps you built or trust.
- Apps you build yourself with `./build_editor.sh` normally don't carry the quarantine flag, so this mostly affects copies you downloaded or moved between machines.

## A build doesn't pick up changes (stale incremental build)

Builds are incremental: a file is recompiled only if its object file in `build/obj/` is older than the source file or than the newest header (engine headers, generated headers and your script headers). Generated files are rewritten only when their content changes.

If the ROM seems to ignore your latest change, for example after restoring files from a backup or git (which can reset modification times), or after changing the engine under `GBA_ENGINE`:

1. Quit mGBA and press **Play** again. Each run replaces a running game.
2. Force a full rebuild by deleting the project's build folder: `rm -rf <project>/build`. The next build regenerates everything. It's safe to delete: it only holds generated code, objects and `game.gba`.
3. Save your changes first (⌘S). The build reads project files from disk.
4. Check that `GBA_ENGINE` points at the engine you think it does, since it overrides the copy inside `TacoEngine.app`.

To build the editor itself from scratch, run `swift package clean --package-path editor` (or delete `editor/.build/`) and then `./build_editor.sh`.

## Still stuck

Open the **Raw build log** in the Console and check the first error. Compiler errors show as `file:line:` messages you can click. If you open an issue, include the log, your macOS and Swift versions, and the output of `ls /opt/devkitpro/devkitARM/bin | head`.
