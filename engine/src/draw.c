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
    p[0] = p[1] = p[2] = p[3] = p[4] = p[5] = p[6] = p[7] = 0;   // (a loop compiles to a call to ROM memset)
    return p;
}

// A horizontal run of pixels x0..x1 on row y, in `pat` (the color in all 8 nibbles). A tile row is
// one 32-bit word, so each tile the run crosses takes a single masked write.
static inline __attribute__((always_inline)) void hspan(int x0, int x1, int y, u32 pat) {
    if ((unsigned)y >= SCREEN_H) return;
    if (x0 < 0) x0 = 0;
    if (x1 >= SCREEN_W) x1 = SCREEN_W - 1;
    int base = (y >> 3) * MAP_W;
    for (int x = x0; x <= x1;) {
        int end = (x | 7) < x1 ? (x | 7) : x1;          // last pixel of the run in this tile
        u32 *tile = tile_for(base + (x >> 3));
        if (tile) {
            u32 mask = (~0u << ((x & 7) * 4)) & (~0u >> ((7 - (end & 7)) * 4));
            u32 *row = tile + (y & 7);
            *row = (*row & ~mask) | (pat & mask);
        }
        x = end + 1;
    }
}

// Cohen-Sutherland: cut a line to the screen (plus a margin for its width), so a line with a far-off
// end costs only the part that's visible. Returns 0 when nothing is left.
#define CLIP_M 8
static int outcode(int x, int y) {
    return (x < -CLIP_M) | ((x > SCREEN_W + CLIP_M) << 1) | ((y < -CLIP_M) << 2) | ((y > SCREEN_H + CLIP_M) << 3);
}

static int clip(int *x0, int *y0, int *x1, int *y1) {
    int c0 = outcode(*x0, *y0), c1 = outcode(*x1, *y1);
    // A short line (like one of a rope's segments) is cheaper to walk than to cut, since cutting
    // takes 64-bit divisions in ROM and the spans skip whatever is off screen anyway
    int dx = *x1 - *x0, dy = *y1 - *y0;
    if (!(c0 & c1) && dx < 128 && dx > -128 && dy < 128 && dy > -128) return 1;
    while (c0 | c1) {
        if (c0 & c1) return 0;
        int c = c0 ? c0 : c1;
        long long dx = *x1 - *x0, dy = *y1 - *y0;   // 64-bit: far-off ends overflow 32-bit products
        int x, y;
        if (c & 8)      { y = SCREEN_H + CLIP_M; x = *x0 + (int)(dx * (y - *y0) / dy); }
        else if (c & 4) { y = -CLIP_M;           x = *x0 + (int)(dx * (y - *y0) / dy); }
        else if (c & 2) { x = SCREEN_W + CLIP_M; y = *y0 + (int)(dy * (x - *x0) / dx); }
        else            { x = -CLIP_M;           y = *y0 + (int)(dy * (x - *x0) / dx); }
        if (c == c0) { *x0 = x; *y0 = y; c0 = outcode(x, y); }
        else         { *x1 = x; *y1 = y; c1 = outcode(x, y); }
    }
    return 1;
}

IWRAM_CODE static void raster(const Line *l, int camX, int camY) {
    int x0 = l->x0 - camX, y0 = l->y0 - camY, x1 = l->x1 - camX, y1 = l->y1 - camY;
    if (!clip(&x0, &y0, &x1, &y1)) return;
    int dx = x1 > x0 ? x1 - x0 : x0 - x1, sx = x0 < x1 ? 1 : -1;
    int dy = y1 > y0 ? y1 - y0 : y0 - y1, sy = y0 < y1 ? 1 : -1;
    int lo = -(l->width - 1) / 2, hi = lo + l->width;
    int err = dx - dy;
    u32 pat = l->color * 0x11111111u;
    if (dx >= dy) {
        // Mostly horizontal: thickness is vertical. Gather the pixels Bresenham puts on one row into a
        // run and draw it once per row of thickness when the line steps to the next row.
        int runX = x0;
        for (;;) {
            int done = x0 == x1 && y0 == y1, nx = x0, ny = y0;
            if (!done) {
                int e2 = err * 2;
                if (e2 > -dy) { err -= dy; nx += sx; }
                if (e2 < dx) { err += dx; ny += sy; }
            }
            if (done || ny != y0) {
                int a = runX < x0 ? runX : x0, b = runX < x0 ? x0 : runX;
                for (int k = lo; k < hi; k++) hspan(a, b, y0 + k, pat);
                runX = nx;
            }
            if (done) break;
            x0 = nx;
            y0 = ny;
        }
    } else {
        // Mostly vertical: thickness is horizontal, one run per row
        for (;;) {
            hspan(x0 + lo, x0 + hi - 1, y0, pat);
            if (x0 == x1 && y0 == y1) break;
            int e2 = err * 2;
            if (e2 > -dy) { err -= dy; x0 += sx; }
            if (e2 < dx) { err += dx; y0 += sy; }
        }
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
