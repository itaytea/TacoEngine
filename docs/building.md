# Building and the command line

## What Play does

1. Writes `build/generated/script_types.h` (your script structs, tags, variables and scene names) and `build/generated/assets.c` (every asset, converted to GBA formats).
2. Compiles the engine (`engine/src`), the generated code and your scripts with devkitARM's GCC, in parallel. Only changed files are recompiled.
3. Links `build/game.gba` and opens it in mGBA, replacing a game it's already running. Each run starts fresh (no auto-loaded save states) at real GBA speed (59.73 fps) with a small audio buffer for low input lag, whatever your own mGBA settings say.

Errors show in the Console; click one to open the file at that line.

## Where the engine comes from

Taco Engine looks for an `engine/` folder (one containing `src/engine.h`):

1. the folder in the `GBA_ENGINE` environment variable,
2. an `engine/` folder in or above the project folder (up to five levels),
3. the copy inside `TacoEngine.app` (`build_editor.sh` puts the engine and docs there),
4. an `engine/` folder next to `TacoEngine.app`.

devkitPro is found through `DEVKITPRO`, or `/opt/devkitpro` by default.

## gbaexport

The editor's build tools as a command-line program (`editor/.build/debug/gbaexport` after `swift build`):

```bash
gbaexport new <folder>                         # create a new project
gbaexport build <project> [--scene Name] [--run]
gbaexport check <project>                      # parse scripts and generate code only
gbaexport export-web <project> <folder>        # build and export for the web
```

## Web export

**Game ▸ Export for Web…** builds the game from its start scene and writes a folder with `index.html`, `game.gba` and a `README.txt`. The page is only the game: it fills the browser window, or the iframe it's embedded in, letterboxed to the GBA's 3:2 shape. Titles, descriptions and instructions are left to the page you embed it in.

- **itch.io**: zip the folder and upload it as an HTML game, tick *This file will be played in the browser*, and set the viewport to a 3:2 size such as 720 × 480.
- **Other sites**: upload the folder and embed it with `<iframe src="game/index.html" width="720" height="480" allowfullscreen></iframe>`.

The game runs in [EmulatorJS](https://emulatorjs.org) 4.2.3, loaded from its CDN, so players need an internet connection. EmulatorJS shows a start button first (browsers only allow sound after a click). Its default keys are the arrows for the D-pad, **Z** for A, **X** for B, **Enter** for Start, **V** for Select and **Q**/**E** for L and R. Gamepads work, and touch screens get on-screen buttons. Saves stay in the player's browser.

Browsers won't run the game from a page opened straight from disk. Test it with `python3 -m http.server` inside the folder, then visit `http://localhost:8000`.

## Real hardware

The ROM runs in emulators. Real GBAs and some flashcarts also need the Nintendo logo in the ROM header. Saves use SRAM, which most flashcarts support. Taco Engine writes the title and checksum but not the logo, so run devkitPro's `gbafix build/game.gba`, or let your flashcart patch the header.

## Repository layout

```
engine/            the GBA runtime in C (engine.h is the scripting API)
engine/templates/  scripts copied into projects (talk.c, respawn.c, and the ready-made prefabs' scripts)
editor/            Swift package: EngineKit (assets, codegen, builds), TacoEngine (the editor app), gbaexport
docs/              this documentation
```
