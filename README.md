# Taco Engine

Taco Engine makes Game Boy Advance games on a Mac. It comes in two halves:

- **The editor**, a Mac app in the style of Unity: scenes, prefabs, an Inspector and a Project browser.
- **The runtime**, a small C engine that runs on the GBA. Game logic is written as short C scripts against its API.

Press **Play** and Taco Engine generates code from your project, compiles a real `.gba` ROM with devkitARM and opens it in mGBA. The same ROM runs on hardware, in any emulator, or on a web page.

## Features

- **Scenes**: scrolling tilemaps, or rooms that change one screen at a time
- **Entities**: sprites, colliders, triggers, up to six scripts each, and parent/child links
- **Movement**: a platformer controller with coyote time, jump buffering, wall jumps and apex hang, tuned by dragging points on live graphs
- **Dialogue**: portraits, custom text boxes and text effects (wave, shake, rainbow, colors)
- **Sound**: effects and looping music, converted from WAV, AIFF, MP3, M4A or FLAC
- **Saves and menus**: four save slots, a title menu and a pause menu, all set up in Project Settings
- **Web export**: the game as an embeddable web page, for itch.io or any site
- **Plain files**: assets are small JSON files next to their images, so projects work well with git

## Requirements

- macOS 14 or later, with Xcode or the Swift toolchain (to build the editor)
- [devkitPro](https://devkitpro.org/wiki/Getting_Started) with the `gba-dev` package, in `/opt/devkitpro`
- [mGBA](https://mgba.io), in `/Applications`
- Optional: VS Code or Cursor for editing scripts. Taco Engine opens scripts there at the line with the error.

## Quick start

```bash
./build_editor.sh
open TacoEngine.app
```

`TacoEngine.app` carries its own copy of the engine and the docs, so you can move it to Applications.

1. In the launcher, click **New Project…** and choose a folder.
2. Choose **Paint** in the toolbar and draw some ground.
3. Add **Hierarchy ▸ + ▸ Platformer Player**.
4. Press **Play** (⌘P). In mGBA, the arrow keys are the D-pad, **X** is A (jump) and **Z** is B.

## Documentation

Start with [Getting started](docs/getting-started.md). The full list is in [docs/](docs/README.md):

- [The editor](docs/editor.md): panels, scene editing, prefabs and shortcuts
- [Scripting](docs/scripting.md): how scripts work and the full API, including sound, saves and menus
- [Building](docs/building.md): the command line, web export and running on hardware
- [How Taco Engine works](docs/architecture.md): internals, for contributors

## Limitations

- The editor runs on macOS only. Games run anywhere a GBA ROM runs.
- Sound is 8-bit mono at 13.4 kHz. A minute of music takes about 800 KB of the 32 MB cartridge.
- The web export loads EmulatorJS from its servers, so players need an internet connection.

## Repository layout

```
engine/     the GBA runtime in C (engine/src/engine.h is the scripting API)
editor/     Swift package: EngineKit (assets, codegen, builds), the editor app, gbaexport (CLI)
docs/       documentation
```

## License

Taco Engine is released under the [zlib license](LICENSE). Games you make with it are yours: the license does not require crediting Taco Engine in your game, and you may sell your games.

Exported web pages load [EmulatorJS](https://emulatorjs.org) (GPL-3.0) from its CDN. Games are built with [devkitPro](https://devkitpro.org)'s toolchain and played in [mGBA](https://mgba.io). These are separate projects with their own licenses.
