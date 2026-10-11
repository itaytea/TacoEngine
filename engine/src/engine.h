// =====================================================================================
//  GBA Engine — scripting API
//  Every script includes this file. Everything here is safe to use from scripts.
// =====================================================================================
#ifndef ENGINE_H
#define ENGINE_H

#include "gba.h"

#if !defined(__STDC_VERSION__) || __STDC_VERSION__ < 202311L
typedef int bool;           // C23 (GCC's default) has bool/true/false built in
#define true 1
#define false 0
#endif
#ifndef NULL
#define NULL ((void *)0)
#endif

// ---- Fixed point (8 fractional bits): FX(1.5) == 384, FX_INT(384) == 1 ----------------
typedef s32 fixed;
#define FX(v)        ((fixed)((v) * 256))
#define FX_INT(f)    ((int)((f) >> 8))
#define FX_ONE       256
static inline fixed fx_mul(fixed a, fixed b) { return (fixed)(((long long)a * b) >> 8); }
static inline fixed fx_div(fixed a, fixed b) { return b ? (fixed)(((long long)a << 8) / b) : 0; }

// ---- Asset data (filled in by the editor's exporter) ---------------------------------
#define MAX_SCRIPTS        6     // scripts per entity (also maxScripts in the editor's Codegen.swift)
#define SCRIPT_DATA_BYTES  128   // max size of one script's fields

typedef struct Entity Entity;

typedef struct {
    const char *name;
    const u8 *frames;   // indices into the sprite's frames
    u8 count;
    u8 fps;
    u8 loop;
} SpriteAnim;

// Frames bigger than 64x64 are drawn as several hardware sprites ("pieces") that move together
typedef struct {
    s16 x, y;           // top-left within the frame, px
    u8 w, h;            // size in px
    u8 objShape, objSize;
    u16 tile;           // first tile within the frame
} SpritePiece;

typedef struct {
    const char *name;
    u16 w, h;           // frame size in px (one OBJ size, or a multi-piece frame up to 256x256)
    u8 objShape, objSize;   // the OBJ shape when there's a single piece
    s16 pivotX, pivotY; // entity position is at this pixel of the frame
    u16 frameWords;     // 32-bit words per frame
    u16 frameCount;
    const u32 *gfx;
    const u16 *palette;
    u8 animCount;
    const SpriteAnim *anims;
    u8 pieceCount;      // 0 = a single OBJ of objShape/objSize
    const SpritePiece *pieces;
} SpriteAsset;

enum { COLL_NONE, COLL_SOLID, COLL_ONEWAY };

typedef struct {
    u8 collision;       // COLL_*
    u8 flags;           // project-defined tile flags (TILEFLAG_*), see tile_flags_in()
    u8 hx, hy, hw, hh;  // hitbox inside the 16x16 cell used for flags
    u16 gfxTile;        // first of 4 hardware tiles
    u8 pal;             // palette bank
} TileDef;

typedef struct {
    const char *name;
    u16 count;
    const TileDef *defs;
    const u32 *gfx;
    u32 gfxWords;
    u8 palCount;
    const u16 *palettes;   // palCount * 16 colors, loaded into banks 1..palCount
} Tileset;

// Platformer body tuning (all speeds in 1/256 px per frame; multipliers 256 = 1.0)
typedef struct {
    s32 runSpeed, groundAccel, groundDecel, groundTurn, airAccel, airDecel, airTurn;
    s32 gravity, jumpVelocity, jumpCut, apexThreshold, apexGravity, fallGravity, maxFall;
    s32 wallSlideMax, wallJumpX, wallJumpY;
    u8 coyoteFrames, bufferFrames, wallCoyoteFrames, wallJumpLockFrames;
    u8 wallJumps;
    u8 jumpSustainFrames;       // Celeste-style: hold full jump speed this many frames while jump is held
    u8 wallReach;               // px: how far from a wall you can still wall jump (1 = touching)
    u8 airJumps;                // extra jumps in the air (1 = double jump)
    s32 jumpBoostX;             // sideways speed added when jumping in the held direction
    s32 overspeedDecel;         // slowdown when above run speed and still holding that way (0 = normal accel)
    s32 fastFallMax;            // max fall speed while holding down (0 = off)
    u8 autoAnimate;             // play "idle", "run", "jump", "fall", "wall" automatically if the sprite has them
} PlatformerSettings;

typedef struct {
    const char *name;
    u16 size;
    void (*start)(void *self, Entity *e);
    void (*update)(void *self, Entity *e);
    void (*on_trigger)(void *self, Entity *e, Entity *other);
    void (*on_trigger_exit)(void *self, Entity *e, Entity *other);
    void (*on_message)(void *self, Entity *e, int msg, int arg);
    void (*on_destroy)(void *self, Entity *e);
} ScriptType;

typedef struct {
    const ScriptType *type;
    const void *init;   // initial field values
} ScriptInit;

enum { COLLIDER_ON = 1, COLLIDER_TRIGGER = 2,
       COLLIDER_PLATFORM = 4 };   // one-way platform: platformer bodies (and move_and_collide) land on its top edge
enum { ENT_FLIPX = 1, ENT_HIDDEN = 2 };
enum { BODY_JOYPAD = 1 };

typedef struct {
    const char *name;
    u8 tag;
    u8 flags;                   // ENT_*
    u8 priority;                // 0 = in front .. 3 = behind the tilemap
    const SpriteAsset *sprite;
    u8 anim;
    s8 colX, colY;              // collider offset from the position
    u8 colW, colH;
    u8 colFlags;                // COLLIDER_*
    const PlatformerSettings *platformer;
    u8 bodyFlags;               // BODY_*
    u8 scriptCount;
    const ScriptInit *scripts;
} EntityTemplate;

typedef EntityTemplate Prefab;

typedef struct {
    const EntityTemplate *tmpl;
    s16 x, y;                   // world position
    u16 id;
    u16 parent;                 // 1-based index of its parent in the scene's list (0 = none)
} SceneEntity;

enum { CAM_FOLLOW, CAM_SCREENS, CAM_FIXED };

typedef struct {
    const char *name;
    u16 w, h;                   // in 16x16 cells
    const u8 *map;              // w*h tile indices (0 = empty)
    const Tileset *tileset;
    u16 bgColor;
    u16 entityCount;
    const SceneEntity *entities;
    u8 cameraMode;
    u16 cameraTarget;           // entity id, 0 = none
    const struct SoundAsset *music;   // played when the scene starts (NULL = silence)
} Scene;

// Title and pause menus (generated from Project Settings)
typedef struct {
    u8 titleEnabled, pauseEnabled;
    const char *title, *subtitle;
    s16 titleScene;             // scene shown behind the title menu (-1 = the start scene)
    s16 startScene;             // where NEW GAME begins
    const struct SoundAsset *music, *cursorSound, *confirmSound;
} MenuSettings;

// Sounds: 8-bit mono at 13379 Hz, converted by the editor from any audio file in the project
typedef struct SoundAsset {
    const char *name;
    const s8 *data;
    u32 length;                 // samples
} SoundAsset;

// ---- Dialogue (filled in by the exporter from Dialogue, Speaker and Text Box assets) ----
typedef struct {
    u8 height;                  // line height in px
    u8 widths[96];              // advance per glyph (ASCII 32..127)
    u16 bits[96][12];           // glyph rows, bit x = pixel x (up to 12 wide, 12 tall)
} Font;

typedef struct {
    u8 boxX, boxY, boxW, boxH;  // box in 8x8 tiles, frame included
    u8 nameX, nameY, nameW;     // name plate in tiles (nameW 0 = none)
    u8 padX, padY;              // text inset from the box interior, px
    u8 lines;                   // lines per page
    u8 speed;                   // characters per second
    u8 portraitRight;
    u8 pauseGame;
    u8 shadow;
    u16 colors[16];             // palette 13: 1 text, 2 shadow, 3 name, 4-9 rainbow, 10 fill, 11-15 named colors
    const u32 *frameGfx;        // 9 tiles (3x3 slices of the frame image), palette 12
    const u16 *framePal;
    const Font *font;
} TextBoxStyle;

typedef struct {
    const char *name;
    u16 nameColor;
    const SpriteAsset *portrait;
} Speaker;

typedef struct {
    const Speaker *speaker;
    u8 talkAnim, idleAnim;      // portrait animations while typing / waiting
    const u8 *text;             // text with control codes, wrapped into pages by the editor
} DialogueLine;

typedef struct {
    const char *name;
    const TextBoxStyle *style;
    u16 lineCount;
    const DialogueLine *lines;
} Dialogue;

// Reference types for script fields (editable in the Inspector)
typedef const Dialogue *DialogueRef;
typedef u16 EntityRef;          // id of an entity in the scene — see ref_entity()
typedef int SceneRef;           // scene index — see load_scene()
typedef const Prefab *PrefabRef;
typedef const SpriteAsset *SpriteRef;
typedef const SoundAsset *SoundRef;

// ---- Entities ----------------------------------------------------------------------
typedef struct Body Body;

typedef struct {
    const ScriptType *type;
    u32 data[SCRIPT_DATA_BYTES / 4];
} ScriptSlot;

struct Entity {
    fixed x, y;                 // world position in px (8.8 fixed)
    fixed vx, vy;               // velocity; moved by the platformer body if present
    u16 id;                     // scene id (0 for spawned entities)
    u8 tag;
    u8 alive;
    const char *name;
    const EntityTemplate *tmpl;

    // Sprite
    const SpriteAsset *sprite;
    u8 anim, frame, frameTimer;
    u8 flipX, hidden, priority;
    u8 animDone;                // a non-looping animation reached its last frame
    u8 paused;                  // freeze the platformer body and animation (scripts still run)

    // Collider (relative to x, y)
    s8 colX, colY;
    u8 colW, colH;
    u8 colFlags;

    Body *body;                 // platformer movement, or NULL
    Entity *parent;             // moves along with this entity (set_parent); destroyed with it
    s16 localX, localY;         // offset from the parent, px

    u8 scriptCount;
    ScriptSlot scripts[MAX_SCRIPTS];

    // engine internals
    u16 vramTile;               // first tile of the frame on screen (in a shared frame slot)
    s16 frameSlot, shownFrame;  // shared frame slot (-1 = none), and which sprite frame it holds
    u8 palBank, started, dying;
};

#define SCRIPT(Name) struct Name##__fields   // field list is read by the editor (see script_types.h)

// ---- Platformer body --------------------------------------------------------------
struct Body {
    const PlatformerSettings *s;
    u8 joypad;                  // read the D-pad and A (jump) automatically
    s8 inputX;                  // -1/0/1   (set these yourself when joypad is off)
    u8 jumpHeld, jumpPressed;
    u8 autoAnimate;             // play idle/run/jump/fall/wall itself (starts as the settings' Auto-animate;
                                // turn it off to play your own animation, e.g. sleeping or a cutscene)
    // state (read-only for scripts)
    u8 onGround, wallSliding;
    s8 wallDir, facing;
    u8 coyote, buffer, wallCoyote, lockTimer, jumpCuttable;
    u8 sustain, airJumpsLeft;
    s8 lastWallDir;
    fixed sustainSpeed;
    u8 phaseCount;
    struct { s16 cx, cy; } phase[8];
    u16 touchedFlags;           // tile flags touched this frame (OR of TILEFLAG_*)
};

// Messages the engine sends to an entity's scripts (OnMessage). Your own start at MSG_USER.
enum { MSG_JUMPED = 1, MSG_WALL_JUMPED, MSG_LANDED, MSG_CAMERA_MOVED, MSG_DIALOGUE_END,
       MSG_HURT,          // sent by hazards and enemies (arg = damage); the Respawn script reacts to it
       MSG_USER = 100 };

// ---- API ---------------------------------------------------------------------------

// Input (KEY_A, KEY_B, KEY_LEFT, ... from gba.h)
bool key_held(u16 keys);
bool key_pressed(u16 keys);     // went down this frame
bool key_released(u16 keys);

// Entities
Entity *spawn(PrefabRef prefab, int x, int y);
void destroy(Entity *e);                       // removed at the end of the frame
Entity *find_entity(const char *name);
Entity *find_with_tag(int tag);                // first alive entity with this tag
Entity *ref_entity(EntityRef ref);             // entity from an EntityRef field
int entity_count(void);
Entity *entity_at(int index);                  // iterate: for (i < entity_count()) entity_at(i); may be NULL
bool has_tag(const Entity *e, int tag);
void *entity_script(Entity *e, int scriptId);  // see get_script()
#define get_script(e, Type) ((Type *)entity_script((e), SCRIPT_ID_##Type))
void send_message(Entity *e, int msg, int arg);
void broadcast(int msg, int arg);

static inline int ex(const Entity *e) { return FX_INT(e->x); }   // position in whole pixels
static inline int ey(const Entity *e) { return FX_INT(e->y); }
void set_position(Entity *e, int x, int y);
bool overlaps(const Entity *a, const Entity *b);                 // collider vs collider

// Moves by (dx, dy) fixed-point, stopping at solid tiles. Returns HIT_* flags.
enum { HIT_LEFT = 1, HIT_RIGHT = 2, HIT_TOP = 4, HIT_BOTTOM = 8 };
int move_and_collide(Entity *e, fixed dx, fixed dy);

void set_parent(Entity *child, Entity *parent);   // child keeps its current offset from parent (NULL = detach)

// Sprites & animation
void play(Entity *e, const char *anim);        // no-op if already playing
void play_index(Entity *e, int anim);
void set_flip(Entity *e, bool flipX);

// Platformer body
void body_jump(Entity *e, fixed velocity);     // launch upward (e.g. jump pads); can't be cut short
void body_unstick(Entity *e);                  // let the body pass through solids it's currently inside

// Tilemap (positions in px, cells are 16x16)
int tile_at(int px, int py);                   // tile index, 0 = empty
void set_tile(int cx, int cy, int tile);
void swap_tiles(int a, int b);                 // every a becomes b and every b becomes a
bool solid_at(int px, int py);
u16 tile_flags_in(int x, int y, int w, int h); // OR of flags of tiles whose hitbox overlaps the box
int scene_width(void);                         // px
int scene_height(void);

// Camera
void camera_follow(Entity *e);
void camera_shake(int frames, int strength);
int camera_x(void);
int camera_y(void);
bool camera_moving(void);                      // screen-to-screen slide in progress

// Scenes & variables
void load_scene(SceneRef scene);               // happens at the end of the frame
SceneRef current_scene(void);
extern int vars[];                             // global variables, kept across scenes (VAR_*)
extern const char game_title[];

// Sound
void play_sound(SoundRef s);                   // a sound effect; up to 4 at once (a new one replaces the oldest)
void play_music(SoundRef s);                   // loops; NULL stops it; asking for the music already playing does nothing
void stop_music(void);
void set_volume(int music, int sounds);        // 0 (silent) .. 16 (full)

// Saving (battery-backed cartridge memory, 32 KB)
bool save_game(int slot);                      // slot 0..3: the scene, the player's position and all variables
bool load_game(int slot);                      // false if the slot is empty; otherwise loads at the end of the frame
bool save_exists(int slot);
void save_erase(int slot);
void save_write(int offset, const void *data, int size);   // your own data: offset 0 .. 28671
void save_read(int offset, void *data, int size);

// Menus (set up in Project Settings): the title menu shows when the game starts; the pause menu
// opens with Start
void go_to_title(void);
bool menu_open(void);                          // the title or pause menu is showing

// Dialogue
void dialogue_start(DialogueRef d);            // opens the text box; A/B advance; MSG_DIALOGUE_END is broadcast when it closes
bool dialogue_active(void);

// Screen
void text_print(int col, int row, const char *s);
void text_print_int(int col, int row, int value);
void text_print_centered(int row, const char *s);
void text_clear(void);
void text_clear_row(int row);
void screen_fade(int level);                   // 0 = normal .. 16 = black
void set_background(u16 color);                // RGB15(r, g, b) with 0..31 components
// Background layer: behind everything, 256x256 px, wrapping around. Fill it from a script (it's
// cleared on every scene change): 4bpp tiles (8 rows of 8 pixels, 4 bits each, color 0 =
// transparent) using background colors 1..15. It can use the tiles the level's tileset leaves free.
int background_tile_count(void);
u32 *background_tile(int index);               // a tile's 8 rows, to draw into
void background_set(int tx, int ty, int tile); // which tile goes in map cell (0..31, 0..31)
void background_color(int index, u16 color);   // color 1..15 (change them for color cycling)
void background_scroll(int x, int y);          // px
void background_show(bool on);
// A line in world pixels, shown for this frame only (call it every Update; while the world is
// paused, e.g. during a screen slide, the last lines stay up). Behind sprites and the tilemap;
// up to 15 colors and about 100 tiles' worth of lines on screen at once.
void draw_line(int x0, int y0, int x1, int y1, u16 color, int width);

// Utilities
int rand_int(int lo, int hi);                  // inclusive
int frame_count(void);
fixed fx_sin(int angle);                       // angle 0..255 = full turn
fixed fx_cos(int angle);
static inline int clamp(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }
static inline int iabs(int v) { return v < 0 ? -v : v; }
static inline int sign(int v) { return (v > 0) - (v < 0); }

// Generated from your project: script structs + SCRIPT_ID_*, TAG_*, VAR_*, SCENE_*, PREFAB_*, TILEFLAG_*
#include "script_types.h"

#endif
