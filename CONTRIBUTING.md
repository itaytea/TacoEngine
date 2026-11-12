# Contributing to Taco Engine

Thanks for helping out. Taco Engine has two halves: a Swift editor (`editor/`) and a C runtime for the GBA (`engine/`). Both need a Mac to build and test, so please read the prerequisites below before you start.

For how the pieces fit together, see [How Taco Engine works](docs/architecture.md). If something goes wrong while building, see [Troubleshooting](docs/TROUBLESHOOTING.md).

## Prerequisites

- macOS 14 or later (`editor/Package.swift` targets `.macOS(.v14)`).
- Xcode or the Swift toolchain. The package uses `swift-tools-version:5.9`.
- [devkitPro](https://devkitpro.org/wiki/Getting_Started) with the `gba-dev` package. Taco Engine uses `devkitARM/bin/arm-none-eabi-gcc` and `objcopy` from `/opt/devkitpro`, or from the folder in the `DEVKITPRO` environment variable.
- [mGBA](https://mgba.io) in `/Applications` (or `~/Applications`). Without it the game still builds, but nothing opens it for you.
- Optional: set `GBA_ENGINE` to the `engine/` folder of your checkout, so builds always use your working copy of the runtime. Without it, the engine is found in this order: an `engine/` folder in or above the project (up to five levels), the copy inside `TacoEngine.app`, then an `engine/` folder next to the app. See [Building](docs/building.md#where-the-engine-comes-from).

## Building and running the editor

From the repository root:

```bash
./build_editor.sh
open TacoEngine.app
```

`build_editor.sh` runs `swift build -c release --package-path editor` and wraps the result in `TacoEngine.app`, together with a copy of `engine/` and `docs/`. The app is ad-hoc signed.

For a quicker debug build of the editor package and the `gbaexport` command-line tool:

```bash
swift build --package-path editor
```

The binaries land in `editor/.build/debug/` (`TacoEngine` and `gbaexport`).

## Building and running a ROM

In the editor: create a project with **New Project…**, then press **Play** (⌘P). This generates code, compiles `build/game.gba` inside the project folder and opens it in mGBA.

From the command line, using `gbaexport` (see [Building](docs/building.md#gbaexport)):

```bash
editor/.build/debug/gbaexport new <folder>
editor/.build/debug/gbaexport check <project>            # parse scripts and generate code only
editor/.build/debug/gbaexport build <project> --run      # build, then open in mGBA
```

If you changed the C runtime in `engine/src`, point the build at your checkout:

```bash
export GBA_ENGINE="$PWD/engine"
```

and build a project with Play or `gbaexport build`. Header changes in `engine/src` rebuild every file in the project; changes to a single `.c` file rebuild only that file.

## Pull requests

- Keep each PR focused on one change, with a clear title and a short description of what changed and why.
- **Every PR needs a local build check.** Before you open it, build on a Mac and say in the PR what you ran. At minimum:
  - `./build_editor.sh` succeeds if you touched anything under `editor/`.
  - If you touched `engine/`, build and run a project ROM (Play, or `gbaexport build <project> --run`) and describe what you tried in mGBA.
  - If you changed code generation or script parsing, `gbaexport check <project>` should also pass.
- Docs-only PRs do not need a ROM run, but say so in the description. Check that any links you added resolve.
- Update the docs in `docs/` when you change user-visible behavior, and add an entry to [CHANGELOG.md](CHANGELOG.md) for notable changes.
- Do not commit build output. `build/`, `editor/.build/`, `TacoEngine.app/` and save files are already ignored by `.gitignore`.

## License

By contributing you agree that your work is released under the [zlib license](LICENSE).
