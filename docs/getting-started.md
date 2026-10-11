# Getting started

## Install

1. **devkitPro** with devkitARM, in `/opt/devkitpro` (the default). Taco Engine uses its compiler. Install devkitPro's pacman from [devkitpro.org](https://devkitpro.org/wiki/Getting_Started), then run `sudo dkp-pacman -S gba-dev`.
2. **mGBA**, in `/Applications`. Play opens your game in it.
3. **VS Code** (optional) for editing scripts. Taco Engine opens scripts there and jumps to the line with the error. Cursor is used if VS Code isn't installed.
4. Build the editor once:

```bash
./build_editor.sh && open TacoEngine.app
```

   The app includes the engine and these docs, so you can move it to Applications.

## Make a project

In the launcher, click **New Project…** (or **File ▸ New Project…**) and choose a folder. A new project has a white 16×16 `square` sprite, a block tileset, a text box style, the Talk and Respawn scripts and one scene.

## A playable level in five minutes

1. In the toolbar choose **Paint**, pick a tile in the palette and draw some ground in the Scene view.
2. **Hierarchy ▸ + ▸ Platformer Player**. This adds the square with a collider and Celeste-style movement, and makes the camera follow it.
3. Press **Play** (⌘P). Run with the D-pad and jump with A. In mGBA's default keys, **A is X** and **B is Z** (switch your keyboard to English first: other layouts like Hebrew change what those keys send).
4. Open **Player Movement** in the Project panel to tune running and jumping by dragging points on the graphs.
5. Make someone talk: **Assets ▸ New Dialogue**, write a line, then **Hierarchy ▸ + ▸ Talking NPC**. In game, stand next to it and press Up.

## Project folder

```
project.json         name, tags, tile flags, variables, scene order
assets/              everything you see in the Project panel (organize with folders)
scripts/             C scripts (scripts can also live under assets/)
build/               generated code, objects and game.gba (safe to delete)
compile_flags.txt    lets VS Code find engine.h while you edit scripts
```

Every asset is a small JSON file next to its image, so projects work well with git.
