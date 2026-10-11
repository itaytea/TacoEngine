# The editor

When TacoMaker opens it shows your recent projects. Click one to open it, or choose **New Project…** or **Open…**. **File ▸ Open Recent** and **File ▸ Close Project** (⇧⌘W) work from inside a project.

```
┌───────────┬───────────────────────────┬────────────┐
│ Hierarchy │ Scene  /  asset editors    │ Inspector  │
│           ├───────────────────────────┤            │
│           │ Project  /  Console        │            │
└───────────┴───────────────────────────┴────────────┘
```

## Toolbar

- **Move / Paint / Erase**: the Scene view tool.
- **Play** (⌘P) builds and runs the open scene. **Play From Start** (⇧⌘P) runs from the start scene.
- **⚙** opens Project Settings (tags, tile flags, variables, scene order, menus, frame budget).
- **Game ▸ Export for Web…** makes a folder that plays the game in a browser (see [Building](building.md#web-export)).

## Hierarchy

- Lists the entities in the open scene. The menu at the top switches scenes.
- **+** creates a Platformer Player, a Talking NPC, a ready-made Level End, Enemy or Spikes, an empty entity, a sprite entity, or a prefab instance.
- Drag entries to reorder them. Later entries draw on top.
- Drop an entity onto another to make it a **child**: it moves with its parent, in the editor and in the game, and is deleted with it. Its position is shown relative to the parent. Drop it on the strip at the bottom of the list, or right-click ▸ **Un-parent**, to make it top-level again.
- **⇧-click** selects a range, **⌘-click** adds or removes single entities.
- Right-click an entity to duplicate it, make it the camera target, create a prefab from it, or apply, revert or unpack prefab overrides.

## Scene view

| Action | Trackpad | Mouse |
|---|---|---|
| Pan | two-finger scroll | right- or middle-drag |
| Zoom (toward the cursor) | pinch, or ⌘-scroll | scroll wheel |
| Zoom presets / fit | the % menu in the Scene bar | |

- **Move tool**: click to select, drag to move. 8 px snapping is optional. The selection shows a move gizmo: drag the red arrow to move only along X, the green arrow for only Y, or the yellow square for both. ⇧-click or ⌘-click adds to the selection, and dragging moves every selected entity.
- **Arrow keys** nudge the selection 1 px (8 px with ⇧).
- **Paint tool**: draw with the selected palette tile. ⌥-drag erases, ⇧-click picks the tile under the cursor.
- Drag a prefab from the Project panel into the scene to place it.
- A selected Enemy shows its path as an orange dashed line; drag the **B** handle to set where it walks to.
- Orange dashed lines show screen edges in *screen by screen* scenes. Green boxes are colliders, yellow dashed boxes are triggers, cyan boxes are platforms.

## Inspector

- **Entities**: name, position, tag, and components (Sprite, Collider, Platformer Body, Scripts). A Collider's **Type** is *Hitbox*, *Trigger* (fires OnTrigger, doesn't block), or *Platform* (platformer bodies can stand on top of it and pass through from below, and it can move).
- **Add Component** includes two presets, **Platformer Controller** and **Talk**.
- **Prefab instances**: values that differ from the prefab show in **bold blue**. Use **Overrides ▸ Apply All to Prefab / Revert All**.
- **Script fields** come from the script's `SCRIPT(...)` block. Hover a field name to see its comment.
- With nothing selected, it shows the scene: size, tileset, background, music, camera mode and target.
- With several entities selected, it lists them and can duplicate or delete them all.

## Project panel

- The folder tree is on the left and the open folder on the right.
- **Create** makes folders, scripts, scenes, prefabs, dialogues, speakers, text box styles and platformer settings, and imports sprite sheets and tilesets. New items go into the open folder.
- Drag items onto folders to move them. Drag files in from Finder to copy them in.
- Images that aren't used yet show **not imported**. Select one and choose **Use as Sprite** or **Use as Tileset**.
- **⇧-click** selects a range and **⌘-click** toggles items. **Delete** moves the selected files to the Trash after asking.
- Sound files (WAV, AIFF, MP3, M4A, CAF, FLAC) show with a speaker icon. Select one to play it in the Inspector or make it the open scene's music.
- The panel updates by itself when files change on disk (for example after re-exporting from Aseprite).
- Double-clicking opens the item: scenes open in the Scene view, scripts in VS Code, and sprites, tilesets, dialogues, text boxes and platformer settings in the center editor.

## Console

Shows build errors and warnings. Click one to open the file at that line in VS Code.

## Keyboard

| Key | |
|---|---|
| Delete | delete the selected entities (with their children) |
| ⌘C / ⌘V | copy and paste the selected entities, also between scenes and projects. Children and parent links come along |
| ⌘D | duplicate |
| Arrows | nudge in the Scene view (⇧: 8 px) |
| ⌘S | save now |
| ⌘Z / ⇧⌘Z | undo / redo |

These keys are ignored while you're typing in a text field.

## Undo and saving

⌘Z / ⇧⌘Z undo and redo edits. Everything saves automatically, and ⌘S saves at once (the toolbar shows **Saved**). Moving or deleting files in the Project panel can't be undone (deleted folders go to the Trash).
