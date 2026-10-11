# Scripting

Game logic lives in C scripts. Attach a script to an entity in the Inspector (**Add Component ▸ Script**), then set its fields per entity. Create one with **Create ▸ Script…**. It opens in VS Code.

## Anatomy of a script

```c
#include "engine.h"

SCRIPT(Coin) {
    int value;        // = 1 Coins given when collected
    int timer;        // @hide
};

void Coin_OnTrigger(Coin *self, Entity *e, Entity *other) {
    if (!has_tag(other, TAG_Player)) return;
    vars[VAR_coins] += self->value;
    destroy(e);
}
```

- **`SCRIPT(Name) { ... };`** declares the script's fields. Each entity that uses the script gets its own copy.
- **`// = value`** after a field sets its default. Any text after the value is the field's tooltip in the Inspector.
  Quote names that contain spaces: `PrefabRef icon; // = "Health Icon"`.
- **`// @hide`** keeps a field out of the Inspector. Use it for internal state.
- A script's fields can use up to 128 bytes. An entity can have up to 6 scripts (the build stops with an error if one has more).

### Field types shown in the Inspector

| Type | Inspector | Notes |
|---|---|---|
| `int`, `s8`…`u32` | number | |
| `fixed` | decimal | 8.8 fixed point: `FX(1.5)` in code |
| `bool` | checkbox | |
| `EntityRef` | entity picker | `ref_entity(self->target)` gives the `Entity *` |
| `SceneRef` | scene picker | `load_scene(self->next)`; -1 = none |
| `PrefabRef` | prefab picker | `spawn(self->bullet, x, y)` |
| `SpriteRef` | sprite picker | |
| `DialogueRef` | dialogue picker | `dialogue_start(self->dialogue)` |
| `SoundRef` | sound picker | `play_sound(self->hit)`; NULL = none |

### Callbacks

Define only the ones you need:

| Callback | When |
|---|---|
| `Name_Start(Name *self, Entity *e)` | once, before the first Update |
| `Name_Update(Name *self, Entity *e)` | every frame (60 per second) |
| `Name_OnTrigger(Name *self, Entity *e, Entity *other)` | colliders start overlapping (at least one is a trigger) |
| `Name_OnTriggerExit(Name *self, Entity *e, Entity *other)` | they stop overlapping |
| `Name_OnMessage(Name *self, Entity *e, int msg, int arg)` | `send_message`, `broadcast`, or an engine event |
| `Name_OnDestroy(Name *self, Entity *e)` | the entity is being removed |

### Frame order

Scripts' **Update**, then platformer bodies move, then animations advance, then triggers fire. Destroyed entities are removed and a requested scene loads at the end of the frame. While a dialogue that pauses the game or the pause menu is open, nothing in the world updates.

## Names generated from your project

| Name | From |
|---|---|
| `TAG_Player` | Project Settings ▸ Tags (`TAG_Untagged` = 0) |
| `VAR_coins` | Project Settings ▸ Variables, read and write through `vars[VAR_coins]` |
| `TILEFLAG_Hazard` | Project Settings ▸ Tile Flags (bit masks) |
| `SCENE_Title` | scene names, in build order |
| `PREFAB_Coin`, `SPRITE_player`, `DIALOGUE_Intro` | asset names (use with `&`) |
| `SOUND_jump` | sound files in the project (use with `&`: `play_sound(&SOUND_jump)`) |
| `SCRIPT_ID_Coin` | used by `get_script` |

## Fixed point

Positions and velocities are `fixed` (8 fractional bits): `FX(1.5)` is 1.5, `FX_INT(f)` is the whole part. Use `fx_mul` and `fx_div` to multiply and divide. `e->x` and `e->y` are fixed; `ex(e)` and `ey(e)` give whole pixels.

## API reference

### Input

| Function | |
|---|---|
| `bool key_held(u16 keys)` | any of the keys is down |
| `bool key_pressed(u16 keys)` | went down this frame |
| `bool key_released(u16 keys)` | went up this frame |

Keys: `KEY_A KEY_B KEY_SELECT KEY_START KEY_RIGHT KEY_LEFT KEY_UP KEY_DOWN KEY_R KEY_L` (combine with `|`).

### Entities

| | |
|---|---|
| `Entity *spawn(PrefabRef p, int x, int y)` | create an entity from a prefab |
| `void destroy(Entity *e)` | removed at the end of the frame |
| `Entity *find_entity(const char *name)` | first entity with that name |
| `Entity *find_with_tag(int tag)` | first entity with that tag |
| `Entity *ref_entity(EntityRef r)` | entity for an EntityRef field |
| `EntityHandle entity_handle(Entity *e)` / `Entity *entity_get(EntityHandle h)` | a reference you can keep across frames: `entity_get` returns NULL once that entity is destroyed. Store handles, not `Entity *`: slots are reused, so an old pointer can end up pointing at a different, newer entity |
| `bool has_tag(const Entity *e, int tag)` | |
| `get_script(e, Type)` | the entity's `Type` script data, or NULL |
| `void send_message(Entity *e, int msg, int arg)` | calls OnMessage on that entity's scripts |
| `void broadcast(int msg, int arg)` | OnMessage on every entity |
| `int entity_count(void)` / `Entity *entity_at(int i)` | loop over all slots (`entity_at` returns NULL for empty slots) |
| `void set_position(Entity *e, int x, int y)` | in pixels |
| `int ex(e)`, `int ey(e)` | position in pixels |
| `bool overlaps(const Entity *a, const Entity *b)` | colliders overlap |
| `int move_and_collide(Entity *e, fixed dx, fixed dy)` | move, stopping at solid tiles; returns `HIT_LEFT/RIGHT/TOP/BOTTOM` |
| `void set_parent(Entity *child, Entity *parent)` | the child keeps its current offset and moves with the parent; it's destroyed with it. NULL detaches. Children set up in the Hierarchy are linked the same way. A child with a platformer body moves on its own |

Useful `Entity` fields: `x, y, vx, vy` (fixed), `name`, `tag`, `parent`, `flipX`, `hidden`, `priority`, `paused` (freezes the body and animation), `animDone`, the collider `colX colY colW colH`, and `body`.

### Sprites

| | |
|---|---|
| `void play(Entity *e, const char *anim)` | play an animation by name (no-op if it's already playing) |
| `void play_index(Entity *e, int anim)` | by index |
| `void set_flip(Entity *e, bool flipX)` | |

### Platformer body

| | |
|---|---|
| `void body_jump(Entity *e, fixed velocity)` | launch upward (jump pads); can't be cut short |
| `void body_unstick(Entity *e)` | let it pass through solids it's currently inside (e.g. after `swap_tiles`) |
| `e->body->onGround`, `wallSliding`, `wallDir`, `facing` | state |
| `e->body->touchedFlags` | tile flags touched this frame |
| `e->body->inputX`, `jumpHeld`, `jumpPressed` | drive it yourself when D-pad control is off |

See [Platformer movement](platformer.md).

### Tilemap

| | |
|---|---|
| `int tile_at(int px, int py)` | tile index (0 = empty) |
| `void set_tile(int cx, int cy, int tile)` | change a cell (cells are 16×16) |
| `void swap_tiles(int a, int b)` | swap every a with b across the scene |
| `bool solid_at(int px, int py)` | |
| `u16 tile_flags_in(int x, int y, int w, int h)` | flags of tiles whose hitbox overlaps the box |
| `int scene_width(void)`, `scene_height(void)` | in pixels |

### Camera

| | |
|---|---|
| `void camera_follow(Entity *e)` | |
| `void camera_shake(int frames, int strength)` | |
| `int camera_x(void)`, `camera_y(void)` | top-left of the view |
| `bool camera_moving(void)` | a screen-to-screen slide is in progress |

### Scenes and variables

| | |
|---|---|
| `void load_scene(SceneRef s)` | switch at the end of the frame (`SCENE_Name` or a SceneRef field) |
| `SceneRef current_scene(void)` | |
| `int vars[]` | global variables that persist across scenes (`vars[VAR_coins]`) |
| `game_title` | the project's name |

### Sound and music

| | |
|---|---|
| `void play_sound(SoundRef s)` | a sound effect (`&SOUND_coin` or a SoundRef field). Up to 4 play at once; a fifth replaces the oldest |
| `void play_music(SoundRef s)` | loops until changed. Asking for the music that's already playing does nothing, so scenes that share a song don't restart it |
| `void stop_music(void)` | |
| `void set_volume(int music, int sounds)` | 0 (silent) to 16 (full) |

Put audio files (WAV, AIFF, MP3, M4A/AAC, CAF or FLAC; not OGG) anywhere in the project folder. The build converts them to 8-bit mono at 13379 Hz, so a minute of music takes about 800 KB of the 32 MB cartridge. Short, looping tracks are best. A scene's **Music** (Inspector, with nothing selected) starts when the scene loads.

### Saving

| | |
|---|---|
| `bool save_game(int slot)` | slot 0–3: saves the current scene, the position of the entity tagged `Player`, and all variables |
| `bool load_game(int slot)` | loads at the end of the frame: variables first, then the scene, then the player is moved to the saved spot. False if the slot is empty |
| `bool save_exists(int slot)`, `void save_erase(int slot)` | |
| `void save_write(int offset, const void *data, int size)`, `void save_read(...)` | your own data, offsets 0–28671, separate from the slots |

Saves live in the cartridge's battery-backed SRAM (32 KB). mGBA keeps them in a `.sav` file next to the ROM; the web export keeps them in the browser. The pause menu's **SAVE** and the title menu's **CONTINUE** use slot 0.

### Menus

Turn them on in **Project Settings ▸ Menus**:

- **Title menu**: shown when the game starts, over the start scene (or another scene you pick), with the title, subtitle, **NEW GAME** and, once there's a save, **CONTINUE**. NEW GAME clears the variables and loads the start scene.
- **Pause menu**: **Start** during play opens **RESUME / SAVE / QUIT TO TITLE** and freezes and dims the game. B or Start closes it.
- Optional menu music and cursor and confirm sounds.

| | |
|---|---|
| `void go_to_title(void)` | back to the title menu (for a game over, say) |
| `bool menu_open(void)` | a menu is showing |

While a menu is open it takes the buttons, so scripts see no input.

### Dialogue

| | |
|---|---|
| `void dialogue_start(DialogueRef d)` | open a dialogue (`&DIALOGUE_Intro` or a DialogueRef field) |
| `bool dialogue_active(void)` | |

`MSG_DIALOGUE_END` is broadcast when it closes. See [Dialogue](dialogue.md).

### Screen

| | |
|---|---|
| `text_print(col, row, s)`, `text_print_int(col, row, n)`, `text_print_centered(row, s)` | HUD text on a 30×20 grid (text outside it is ignored) |
| `text_clear()`, `text_clear_row(row)` | |
| `screen_fade(level)` | 0 = normal … 16 = black |
| `set_background(RGB15(r, g, b))` | components 0–31 |
| `background_tile(i)`, `background_set(tx, ty, tile)`, `background_color(i, RGB15(r, g, b))`, `background_scroll(x, y)`, `background_show(on)`, `background_tile_count()` | the background layer behind everything: 256×256 px, wraps around, cleared on every scene change. Draw 4bpp tiles into `background_tile(i)` (8 rows, 4 bits per pixel, colors 1–15), place them on the 32×32 map, and change colors for color cycling. It can use the tiles the level's tileset leaves free |
| `draw_line(x0, y0, x1, y1, RGB15(r, g, b), width)` | a line in world pixels for this frame only, so call it every Update. Drawn behind sprites and the tilemap. Up to 15 colors and about 100 tiles' worth of lines on screen at once |

### Utilities

`rand_int(lo, hi)` (inclusive; seeded from when the player first presses a button, so each run differs), `frame_count()`, `fx_sin(angle)` / `fx_cos(angle)` (angle 0–255 = full turn, result in fixed), `clamp`, `iabs`, `sign`.

### Engine messages (OnMessage)

| Message | arg |
|---|---|
| `MSG_JUMPED`, `MSG_WALL_JUMPED`, `MSG_LANDED` | — (sent to the entity whose body did it) |
| `MSG_CAMERA_MOVED` | 0 left, 1 right, 2 up, 3 down (screen-by-screen slides) |
| `MSG_DIALOGUE_END` | — |
| `MSG_USER` and up | yours |

## Frame budget

Turn on **Project Settings ▸ Testing ▸ Show frame budget** to show `CPU x% PEAK y% ENT n` on the bottom row: the share of the frame the game used, the highest it has been, and the entity count. It turns yellow at 85%; over 100% the game slows down. The row above it names any limit hit in the last two seconds: all 16 sprite palettes in use, sprite memory full, the 96-entity limit, or the 8-platformer-body limit. In any game you can also hold **L + R** and press **Select** to toggle it. If a heavy loop (physics for many points, say) costs too much, put `IWRAM_CODE` before its function: it then runs as fast ARM code from internal RAM.
