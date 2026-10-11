# Changelog

## 1.0

First public release.

- **Editor**: a launcher with recent projects, a move gizmo, multi-select (⇧ for a range, ⌘ for single items), copy and paste of entities between scenes and projects, parent/child entities, Delete and arrow-key shortcuts, and ⌘S to save.
- **Sound**: effects and looping music from ordinary audio files, a music setting for each scene, and `play_sound`, `play_music` and `set_volume`.
- **Saves**: four save slots in cartridge SRAM, plus free space for scripts (`save_game`, `load_game`, `save_write`).
- **Menus**: an optional title menu (New Game / Continue) and pause menu (Resume / Save / Quit to Title).
- **Frame budget**: an optional on-screen CPU meter.
- **Web export**: Game ▸ Export for Web… writes a page that's only the game, ready to embed on itch.io or any site.
- **App**: the editor is now called Taco Engine, like the runtime, and Taco Engine.app includes the engine and documentation, so it works outside the repository.
