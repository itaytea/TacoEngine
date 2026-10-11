// Line drawing on BG3. Scripts call draw_line() with world coordinates during Update; the lines are
// rasterized into a small pool of tiles once the camera has moved, shown at the next vblank, and
// gone the frame after unless drawn again. The layer sits behind sprites and behind the tilemap
// (BG1 wins ties), so a line lying on the ground tucks under the edge of the tiles.
#include "internal.h"

#define REG_BG3CNT   IO16(0x00E)
#define REG_BG3HOFS  IO16(0x01C)
#define REG_BG3VOFS  IO16(0x01E)
#define DCNT_BG3     0x0800

#define DRAW_CBB     2          // shares the HUD/dialogue charblock...
#define DRAW_TILE    400        // ...after the dialogue canvas (112 + 288)
#define POOL         112        // tiles 400-511
#define DRAW_SBB     31
#define MAX_LINES    96
#define MAP_W        32
#define VIS_ROWS     20

typedef struct { s16 x0, y0, x1, y1; u8 color, width; } Line;
static Line lines[MAX_LINES];
static int line_count;

static u32 pool[POOL * 8];             // 4bpp tiles being drawn this frame
static u16 cell_of[POOL];              // which map cell each pool tile sits in
static u8 slot[MAP_W * VIS_ROWS];      // map cell -> pool tile + 1 (0 = empty)
static u16 hw_map[MAP_W * VIS_ROWS];   // what goes to the screenblock
static int used, shown;                // tiles drawn this frame / last committed frame

static u16 colors[15];                 // BG palette bank 0, entries 1-15
static int color_count;

static int color_index(u16 rgb) {
    for (int i = 0; i < color_count; i++) if (colors[i] == rgb) return i + 1;
    if (color_count == 15) return 15;                 // palette full: reuse the last one
    colors[color_count] = rgb;
    PAL_BG[color_count + 1] = rgb;
    return ++color_count;
}

void draw_line(int x0, int y0, int x1, int y1, u16 color, int width) {
    if (line_count == MAX_LINES) return;
    Line *l = &lines[line_count++];
    l->x0 = (s16)x0; l->y0 = (s16)y0; l->x1 = (s16)x1; l->y1 = (s16)y1;
    l->color = (u8)color_index(color);
    l->width = (u8)(width < 1 ? 1 : width > 8 ? 8 : width);
}

// The pool tile for a map cell, taking a fresh one if needed (NULL when the pool is full)
static inline __attribute__((always_inline)) u32 *tile_for(int cell) {
    int t = slot[cell];
    if (t) return &pool[(t - 1) * 8];
    if (used == POOL) return NULL;                     // out of tiles: the rest isn't drawn
    t = ++used;
    slot[cell] = (u8)t;
    cell_of[t - 1] = (u16)cell;
    u32 *p = &pool[(t - 1) * 8];
    for (int i = 0; i < 8; i++) p[i] = 0;
    return p;
}

typedef struct { int cell; u32 *tile; u32 color; } Pen;

static inline __attribute__((always_inline)) void plot(Pen *pen, int x, int y) {
    if ((unsigned)x >= SCREEN_W || (unsigned)y >= SCREEN_H) return;
    int cell = (y >> 3) * MAP_W + (x >> 3);
    if (cell != pen->cell) { pen->cell = cell; pen->tile = tile_for(cell); }   // neighbors share a tile
    if (!pen->tile) return;
    u32 *row = pen->tile + (y & 7);
    int sh = (x & 7) * 4;
    *row = (*row & ~(15u << sh)) | (pen->color << sh);
}

IWRAM_CODE static void raster(const Line *l, int camX, int camY) {
    int x0 = l->x0 - camX, y0 = l->y0 - camY, x1 = l->x1 - camX, y1 = l->y1 - camY;
    if ((x0 < -8 && x1 < -8) || (x0 > SCREEN_W + 8 && x1 > SCREEN_W + 8) ||
        (y0 < -8 && y1 < -8) || (y0 > SCREEN_H + 8 && y1 > SCREEN_H + 8)) return;
    int dx = x1 > x0 ? x1 - x0 : x0 - x1, sx = x0 < x1 ? 1 : -1;
    int dy = y1 > y0 ? y1 - y0 : y0 - y1, sy = y0 < y1 ? 1 : -1;
    int lo = -(l->width - 1) / 2, hi = lo + l->width;
    int xMajor = dx >= dy;
    int err = dx - dy;
    Pen pen = { -1, NULL, l->color };
    for (;;) {
        // Thickness: a span across the line's main direction
        if (xMajor) for (int k = lo; k < hi; k++) plot(&pen, x0, y0 + k);
        else for (int k = lo; k < hi; k++) plot(&pen, x0 + k, y0);
        if (x0 == x1 && y0 == y1) break;
        int e2 = err * 2;
        if (e2 > -dy) { err -= dy; x0 += sx; }
        if (e2 < dx) { err += dx; y0 += sy; }
    }
}

// Before scripts run: start a new set of lines. (When the world is paused, e.g. during a screen
// slide, scripts don't run and this isn't called, so last frame's lines stay up.)
void draw_begin(void) { line_count = 0; }

// After the camera update: turn the lines into tiles
void draw_render(int camX, int camY) {
    for (int i = 0; i < used; i++) slot[cell_of[i]] = 0;
    used = 0;
    for (int i = 0; i < line_count; i++) raster(&lines[i], camX, camY);
}

// In vblank
void draw_commit(void) {
    if (!used && !shown) return;
    for (int i = 0; i < MAP_W * VIS_ROWS; i++) hw_map[i] = 0;
    for (int i = 0; i < used; i++) hw_map[cell_of[i]] = (u16)(DRAW_TILE + i);
    if (used) dma_copy32(CHARBLOCK(DRAW_CBB) + DRAW_TILE * 8, pool, (u32)used * 8);
    dma_copy32(SCREENBLOCK(DRAW_SBB), hw_map, MAP_W * VIS_ROWS / 2);
    if (used) REG_DISPCNT |= DCNT_BG3; else REG_DISPCNT &= ~DCNT_BG3;
    shown = used;
}

void draw_reset(void) {
    line_count = used = shown = color_count = 0;
    for (int i = 0; i < MAP_W * VIS_ROWS; i++) slot[i] = 0;
    REG_DISPCNT &= ~DCNT_BG3;
    REG_BG3CNT = BG_PRIO(2) | BG_CBB(DRAW_CBB) | BG_SBB(DRAW_SBB);
    REG_BG3HOFS = 0;
    REG_BG3VOFS = 0;
}
