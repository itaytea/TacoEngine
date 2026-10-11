# How Taco Engine works

This page is for people working on the engine or the editor themselves. To make games, start with [Getting started](getting-started.md) instead.

Taco Engine has two halves:

- **The runtime** (`engine/`): a small GBA game engine in C. It runs on the console and knows nothing about the editor.
- **The editor** (`editor/`): a SwiftUI Mac app that edits projects, turns them into C (codegen), compiles everything with devkitARM and opens the ROM in mGBA.

The bridge between them is generated C code: the editor writes `build/generated/script_types.h` and `build/generated/assets.c`, and the runtime only ever sees those.

## Repository layout

```
engine/src/            the runtime (C, no libgba)
  engine.h             the scripting API: everything a game script may use
  internal.h           shared between engine modules only
  gba.h                hardware registers and types
  main.c               boot, main loop, input, scene switching, vars, fixed-point math
  entity.c             entities, scripts, spawning, messages, triggers, animation, sprite VRAM/palettes, OAM
  body.c               platformer physics (tiles, one-way tiles, platform entities, coyote/buffer/wall jump)
  tilemap.c            16x16-cell tilemap on BG1, streamed as the camera moves
  camera.c             follow / screen-by-screen / fixed cameras, screen slides, shake, fades
  text.c               8x8 HUD text on BG0
  dialogue.c           dialogue boxes on BG0 (their own screenblock, swapped in while open): typewriter text, effects, portraits
  background.c         the background layer on BG2: tiles, map, colors and scroll set by scripts
  draw.c               draw_line(): lines rasterized each frame into a pool of tiles on BG3
  sound.c              software mixer (1 music + 4 effect channels) feeding Direct Sound A
  save.c               save slots and free space in cartridge SRAM
  menu.c               title and pause menus on the HUD text layer
engine/templates/scripts/   scripts the editor copies into projects (Talk, Respawn, ready-made prefabs)
editor/                Swift package "TacoEngine"
  Sources/EngineKit/   no UI: asset model, JSON, codegen, builder, script parser, physics simulation
  Sources/TacoEngine/   the Mac app (SwiftUI + AppKit)
  Sources/gbaexport/   command-line front end for EngineKit (new / build / check / export-web)
build_editor.sh        builds Taco Engine.app (release) next to the script, with engine/ and docs/ copied into its Resources
docs/                  user documentation and this page
```

## The runtime

### Main loop (`main.c`)

At boot `main()` sets `REG_WAITCNT` to the fast cartridge timing (3/1 wait states with prefetch). Then every frame:

1. `vsync()` (busy-waits on `REG_VCOUNT`)
2. In vblank: `sound_commit()` (points DMA1 at the buffer mixed last frame), `entities_commit()` (OAM + sprite frame DMA), `dialogue_commit()`, `draw_commit()`, `background_commit()` (scroll and colors), `tilemap_draw()` (stream new map columns/rows)
3. `read_input()`: `input_held / input_pressed / input_released`
4. `menu_update()` (returns true while the pause menu freezes the world), `dialogue_update()`
5. `entities_update()`, unless a menu, a camera screen-slide or a pausing dialogue is running:
   scripts' `Start` (first frame) and `Update` → `body_step()` for every platformer body → animation → trigger enter/exit
6. `entities_flush_destroyed()` (children of destroyed entities go too), `camera_update()`, `scene_apply_pending()`, `save_apply_pending()`, `menu_apply_pending()`
7. `entities_render()` fills the OAM shadow and `draw_render()` rasterizes this frame's lines; both are uploaded at the next vblank
8. `sound_update()` mixes the next 224 samples, then the frame budget overlay is drawn if it's on

At boot, before the loop: `sound_init()`, `save_init()`, then the title menu (`menu_boot()`) if it's enabled, otherwise the boot scene.

Input is read right after vblank and its result is on screen at the next vblank: one frame of latency, the minimum for this design.

### Video memory

| Layer | Use | Charblock / screenblock |
|---|---|---|
| BG0 | HUD text (`text.c`). While a dialogue box is open, BG0 shows SBB 28 instead: a copy of the HUD with the box drawn over it (`dialogue.c`) | CBB 2 / SBB 30 (28) |
| BG1 | Level tilemap (`tilemap.c`), 512x512 wrap-around map | CBB 0 / SBB 24–27 |
| BG2 | Background layer (`background.c`), priority 3, behind everything. Its tiles follow the tileset's in CBB 0–1 (whatever of the 1024 the tileset leaves) | CBB 0 / SBB 29 |
| BG3 | Lines from `draw_line` (`draw.c`): tiles 400–511 of CBB 2, rebuilt every frame, only enabled while something is drawn | CBB 2 / SBB 31 |
| OBJ | Entities; OAM 127 is the dialogue portrait. Frames over 64×64 are drawn as several OBJs (`SpritePiece`s, cut by the codegen) | 1D mapping |

BG palette banks: 0 backdrop (entries 1–15: `draw_line` colors), 1–10 tileset, 11 background layer, 12–13 dialogue, 14–15 HUD text. Each sprite asset gets its own OBJ palette bank (reference counted, `pal_acquire`). Sprite tiles live in shared frame slots (`frame_acquire` in `entity.c`): entities showing the same frame of the same sprite share one copy, and entities that are off screen or hidden hold none (their frame is uploaded again when they come into view). Frames of 64+ tiles are allocated from the top of sprite memory and small ones from the bottom, so animation churn doesn't fragment the space big frames need.

### Sound (`sound.c`)

Timer 0 overflows at 13379 Hz, exactly 224 samples per 59.73 Hz frame, and drives Direct Sound A's FIFO through DMA1. Two 224-byte buffers alternate: each vblank `sound_commit` restarts DMA1 on the one mixed during the previous frame, and `sound_update` mixes the other (an `IWRAM_CODE` loop adding signed 8-bit samples times volume). Sound data is converted by the editor (`Sound.swift`, through macOS `afconvert`) to raw s8 at that rate and pulled into the ROM with `.incbin` from `build/generated/sounds.s`, so the runtime never resamples. With nothing playing, mixing stops after both buffers are silent.

### Saves (`save.c`) and menus (`menu.c`)

SRAM at `0x0E000000`, byte access only; the `SRAM_V113` string in the ROM tells emulators the save type. Bytes 0–4095 are four 1 KB slots (a `"TACO"` header with scene, player position, variable count, then `vars[]`), the rest is `save_write`/`save_read` space. `load_game` is deferred to the end of the frame like `load_scene`. The player is the first entity tagged `Player` (`player_tag`, generated).

The menus draw on BG0 rows 3–18 and clear the input so scripts don't see it. The pause menu darkens every layer but BG0 with `BLDCNT`/`BLDY`. Their settings are the generated `menu_settings`.

### Entities and scripts

- `Entity entities[96]`. An entity has a position (`x, y` in 8.8 fixed point), a sprite + animation, a collider (`colX colY colW colH colFlags`), an optional `Body`, and up to 6 script slots of 128 bytes each (`MAX_SCRIPTS`; the codegen refuses more).
- A script is declared in C with `SCRIPT(Name) { fields... };` and callbacks named `Name_Start`, `Name_Update`, `Name_OnTrigger`, `Name_OnTriggerExit`, `Name_OnMessage`, `Name_OnDestroy`. The editor parses the fields (and the `// = default  tooltip` comments) to build the Inspector, and the codegen emits a `ScriptType` table pointing at whichever callbacks exist. Unused callbacks are declared weak, so they're optional.
- Collider flags: `COLLIDER_ON` (1), `COLLIDER_TRIGGER` (2, fires OnTrigger and doesn't block), `COLLIDER_PLATFORM` (4, a one-way platform that bodies can stand on and that can move).
- `spawn()` creates an entity from a prefab (`EntityTemplate`) immediately. Loops over entities (updates, triggers, rendering, `entity_count()`) only go up to the highest slot in use, and trigger pairs are only checked among entities that have colliders. `destroy()` marks it dying and it's removed at the end of the frame.
- Parenting: `Entity.parent` with `localX/localY`. In `entities_update`, a child without a body is moved to its parent's position plus the offset. Scene rows carry world positions plus a 1-based parent index (the editor stores positions relative to the parent and the codegen converts them), and `scene_start` links them after spawning.
- Messages (`send_message`, `broadcast`) call `OnMessage` synchronously. Built-in ones: `MSG_JUMPED`, `MSG_WALL_JUMPED`, `MSG_LANDED`, `MSG_CAMERA_MOVED`, `MSG_DIALOGUE_END`, `MSG_HURT`; your own start at `MSG_USER` (100).

### Platformer bodies (`body.c`)

Up to 8 bodies. The joypad mode reads the D-pad and **A** (jump); B is never used by the engine. `body_step` order: ground/wall checks → coyote, buffer and wall-coyote timers → horizontal acceleration → jump / wall jump / air jump → jump cut → gravity (apex hang, fall multiplier) → Celeste-style sustain → wall slide → move X then Y with collision → timers count down. Settings come from a `PlatformerSettings` struct generated from the `.platformer.json` asset; all speeds are 8.8 fixed point per frame.

### Speed

Code runs as Thumb from the cartridge. Tight loops can be marked `IWRAM_CODE` (from `gba.h`), which compiles them as ARM and copies them to the fast 32 KB internal RAM at boot. `draw.c`'s rasterizer uses it. To see how much of the frame the game uses, turn on Project Settings ▸ Show frame budget, or hold L + R and press Select in any game: the overlay shows CPU %, the peak and the entity count.

### Fixed point

`fixed` is 8.8 (`FX(1) == 256`). `FX_INT()` gets whole pixels, `fx_mul`, `fx_sin`/`fx_cos` (256 steps per turn) do the rest. There is no floating point on the GBA side.

## The editor

### EngineKit

- `Assets.swift`: every asset type (`SpriteAsset`, `TilesetAsset`, `PrefabAsset`, `SceneAsset`, `PlatformerSettings`, `DialogueAsset`, `SpeakerAsset`, `TextBoxStyleAsset`, `FontAsset`) and the components (`EntityDef`, `ColliderComponent`, ...). Decoding is forgiving: missing keys fall back to defaults, so old projects keep loading.
- `Project.swift`: `GameProject` loads `project.json` plus every `assets/**/*.{sprite,tileset,prefab,scene,platformer,dialogue,speaker,textbox,font}.json` and `scripts/**/*.c`. Assets are keyed by UUID; saving writes only what changed.
- `ScriptParser.swift`: finds `SCRIPT(...)` blocks, fields, defaults and which callbacks exist (comments are stripped first).
- `Codegen.swift`: writes `script_types.h` (tags, vars, tile flags, scene ids, script structs, weak callback prototypes, `extern` prefab/sprite/dialogue names) and `assets.c` (graphics converted to 4bpp tiles + palettes, maps, prefabs, scenes, platformer settings, dialogue).
- `Sound.swift`: converts the project's audio files (cached by modification date).
- `WebExport.swift`: writes a bare `index.html` that only runs the game (EmulatorJS, pinned to one version, from its CDN) and `game.gba`.
- `Builder.swift`: finds the engine and devkitARM, runs GCC directly (in parallel, only on changed files), links, fixes the ROM header, turns compiler/linker output into clickable diagnostics, and launches mGBA (`launch`).
- `PhysicsSim.swift`: the same jump/run math as `body.c`, in Swift, for the movement graphs.
- `Templates.swift`: new-project contents and copying scripts from `engine/templates/scripts`.
- `Placeholders.swift`: pixel art for the ready-made prefabs.

### The editor app (`Sources/TacoEngine`)

- `EditorModel.swift`: the single source of truth (`@Published project`). It also holds the entity and Project-panel selections (sets, with ⇧ range anchors), copy/paste through the pasteboard type `local.tacoengine.entities`, the keyboard monitor (Delete, arrows, ⌘C/⌘V/⌘D, ⌘S) and the recent projects shown by `WelcomeView`. Every edit goes through `checkpoint()` so ⌘Z/⇧⌘Z work through the window's `NSUndoManager`; saving is debounced. A folder watcher and a script timer pick up changes made outside the app.
- `Theme.swift`: the design tokens (spacing on a 4 pt scale, the type ramp, corner radii, semantic colors, animation timing). Views use these instead of literal values; shared pieces (`PanelHeader`, `PanelTabBar`, `PanelTab`, `SectionLabel`) are in `Common.swift`.
- Panels: `HierarchyPanel`, `SceneViewPanel` (with `SceneCamera` for pan/zoom), `InspectorPanel`, `BottomPanel` (Project browser + Console), `AssetEditors`, `PhysicsView` (movement graphs), `DialogueEditor`.
- Ready-made prefabs (`Premade` in `EditorModel.swift`): each one copies its scripts from `engine/templates/scripts`, generates its placeholder art into `assets/premade/` and creates the prefab the first time it's used.

### Where the engine is found

`$GBA_ENGINE`, else an `engine/` folder in or up to five levels above the project, else the copy in `Taco Engine.app/Contents/Resources`, else next to the app. devkitPro comes from `$DEVKITPRO` or `/opt/devkitpro`.

## Common changes

- **New engine API function**: declare it in `engine.h` (with a short comment), implement it in the right module, and document it in [scripting.md](scripting.md).
- **New field in a generated struct** (e.g. `PlatformerSettings`): change the struct in `engine.h`, the Swift model in `Assets.swift` (with a default in the decoder), and the matching line in `Codegen.swift`. The field order in C and in the codegen must match.
- **New ready-made prefab**: add a case to `Premade`, its script(s) to `engine/templates/scripts/`, its art to `Placeholders.swift`, and a row to [prefabs.md](prefabs.md).
- **UI change**: take spacing, fonts, radii and colors from `Theme.swift` (`Space`, `Typo`, `Radius`, `Tone`, `Motion`); add a token rather than a literal. Reuse `PanelHeader`, `PanelTabBar`/`PanelTab` and `SectionLabel` for panel chrome.
- **Testing a change**: `gbaexport build <project> --run` builds and opens a project without the app. `swift build` in `editor/` must stay free of errors, and the C must compile with `-Wall` without warnings.
