# Assets

Each asset is a JSON file (`*.sprite.json`, `*.tileset.json`, `*.prefab.json`, `*.scene.json`, `*.platformer.json`, `*.dialogue.json`, `*.speaker.json`, `*.textbox.json`, `*.font.json`). Images sit next to the JSON that uses them. Edit images in any app; TacoMaker reloads them when they change.

## Sprites

- **Image**: a grid of equal frames, numbered left to right, top to bottom.
- **Frame size**: up to 256×256. The GBA only has certain sprite sizes (8, 16, 32 or 64 per side, square or 2:1); other sizes are padded up to the nearest one. Frames bigger than 64×64 are split into 64×64 pieces that move together (empty pieces are skipped). A 128×128 frame takes a quarter of sprite memory, but copies showing the same frame share it and off-screen sprites use none, so what counts is how many *different* big frames are on screen at once (about three 128×128 ones). Dialogue portraits must fit in 64×64.
- **Pivot**: the pixel that sits at the entity's position (bottom-center suits characters).
- **Animations**: a name, a list of frames, a speed and loop on/off. Click frames on the sheet to add them. Scripts use `play(e, "name")`.
- **Colors**: up to 15 plus transparency per sprite (extra colors are reduced automatically, with a warning). Up to 16 different sprites can be on screen at once.

## Tilesets

- **Image**: a grid of 16×16 tiles. In a scene, tile N is grid cell N-1; 0 means empty.
- **Per tile**: collision (none, solid, one-way), flags, and an optional flag hitbox.
- **Limits**: up to 255 unique tiles per tileset. Colors are packed automatically into up to 10 palettes of 15 colors. The tiles a tileset doesn't use (of 1024) are free for the background layer.

## Scenes

- **Size**: up to 256×256 tiles. A screen is 15×10 tiles.
- **Camera**:
  - **Follow** keeps the target in view with a dead zone.
  - **Screen by screen** slides one screen at a time, Celeste-style, pausing the world during the slide.
  - **Fixed** doesn't move.
- **Entities**: up to 96 at once.

## Prefabs

A prefab is a reusable entity. Instances can override single values, which show in bold blue in the Inspector. **Overrides ▸ Apply All to Prefab** pushes them back to the prefab; **Revert All** drops them.

## Fonts and text box frames

See [Dialogue](dialogue.md#fonts).

## Colors on the GBA

Colors are 15-bit (32 levels per channel). Pure colors look best; very close shades may merge.
