// Scrolling tilemap of 16x16 cells on BG1. Palette banks 1-10 belong to the tileset
// (11 is the background layer, 12-13 the dialogue box, 14-15 the HUD text). The scene's map is copied to work RAM so
// scripts can change it; the visible window is streamed into a 512x512 wrapping BG.
#include "internal.h"

#define MAP_CBB 0
#define MAP_SBB 24
#define MAX_CELLS (256 * 256)

static EWRAM_BSS u8 map[MAX_CELLS];
static const Tileset *tileset;
int tilemap_w, tilemap_h;
static int drawn_cx = -9999, drawn_cy = -9999;

void tilemap_load(const Scene *s) {
    tilemap_w = s->w > 256 ? 256 : s->w;
    tilemap_h = s->h > 256 ? 256 : s->h;
    int n = tilemap_w * tilemap_h;
    for (int i = 0; i < n; i++) map[i] = s->map ? s->map[i] : 0;
    // Clear the visible map before replacing the tiles, so the old map never shows the new tiles
    // (tile 0 is empty in every tileset)
    u16 *m = SCREENBLOCK(MAP_SBB);
    for (int i = 0; i < 4 * 1024; i++) m[i] = 0;
    tileset = s->tileset;
    if (tileset) {
        dma_copy32(CHARBLOCK(MAP_CBB), tileset->gfx, tileset->gfxWords);
        for (int i = 0; i < tileset->palCount * 16 && i < 10 * 16; i++) PAL_BG[16 + i] = tileset->palettes[i];
    }
    PAL_BG[0] = s->bgColor;
    REG_BG1CNT = BG_PRIO(2) | BG_CBB(MAP_CBB) | BG_SBB(MAP_SBB) | (3 << 14);
    drawn_cx = drawn_cy = -9999;
}

int tilemap_tile_words(void) { return tileset ? (int)tileset->gfxWords : 0; }

int tilemap_cell(int cx, int cy) {
    if (cx < 0 || cy < 0 || cx >= tilemap_w || cy >= tilemap_h) return 0;
    return map[cy * tilemap_w + cx];
}

int tilemap_collision(int cx, int cy) {
    if (cx < 0 || cx >= tilemap_w) return COLL_SOLID;   // left/right scene edges are walls
    if (cy < 0 || cy >= tilemap_h) return COLL_NONE;    // open above and below
    int t = map[cy * tilemap_w + cx];
    if (!t || !tileset || t >= tileset->count) return COLL_NONE;
    return tileset->defs[t].collision;
}

static u16 *hw_at(int tx, int ty) {
    tx &= 63;
    ty &= 63;
    return SCREENBLOCK(MAP_SBB) + ((ty >> 5) * 2 + (tx >> 5)) * 1024 + (ty & 31) * 32 + (tx & 31);
}

static void draw_cell(int cx, int cy) {
    int t = tilemap_cell(cx, cy);
    u16 a = 0, b = 0, c = 0, d = 0;
    if (t && tileset && t < tileset->count) {
        const TileDef *def = &tileset->defs[t];
        u16 pal = SE_PAL(def->pal);
        a = (u16)(def->gfxTile | pal);
        b = (u16)((def->gfxTile + 1) | pal);
        c = (u16)((def->gfxTile + 2) | pal);
        d = (u16)((def->gfxTile + 3) | pal);
    }
    int tx = cx * 2, ty = cy * 2;
    *hw_at(tx, ty) = a;
    *hw_at(tx + 1, ty) = b;
    *hw_at(tx, ty + 1) = c;
    *hw_at(tx + 1, ty + 1) = d;
}

void tilemap_draw(int camX, int camY) {
    int cx0 = camX >> 4, cy0 = camY >> 4;
    if (cx0 != drawn_cx || cy0 != drawn_cy) {
        // Redraw only the newly exposed column and/or row when scrolling by one cell on either axis
        int ddx = cx0 - drawn_cx, ddy = cy0 - drawn_cy;
        if (ddx >= -1 && ddx <= 1 && ddy >= -1 && ddy <= 1) {
            if (ddx) {
                int col = ddx > 0 ? cx0 + 15 : cx0;
                for (int cy = cy0; cy <= cy0 + 10; cy++) draw_cell(col, cy);
            }
            if (ddy) {
                int row = ddy > 0 ? cy0 + 10 : cy0;
                for (int cx = cx0; cx <= cx0 + 15; cx++) draw_cell(cx, row);
            }
        } else {
            for (int cy = cy0; cy <= cy0 + 10; cy++)
                for (int cx = cx0; cx <= cx0 + 15; cx++) draw_cell(cx, cy);
        }
        drawn_cx = cx0;
        drawn_cy = cy0;
    }
    REG_BG1HOFS = (u16)(camX & 511);
    REG_BG1VOFS = (u16)(camY & 511);
}

static void redraw_if_visible(int cx, int cy) {
    if (cx >= drawn_cx && cx <= drawn_cx + 15 && cy >= drawn_cy && cy <= drawn_cy + 10) draw_cell(cx, cy);
}

// ---- Script API ----

int tile_at(int px, int py) { return tilemap_cell(px >> 4, py >> 4); }

void set_tile(int cx, int cy, int tile) {
    if (cx < 0 || cy < 0 || cx >= tilemap_w || cy >= tilemap_h) return;
    map[cy * tilemap_w + cx] = (u8)tile;
    redraw_if_visible(cx, cy);
}

void swap_tiles(int a, int b) {
    int n = tilemap_w * tilemap_h;
    for (int i = 0; i < n; i++) {
        if (map[i] == a) map[i] = (u8)b;
        else if (map[i] == b) map[i] = (u8)a;
    }
    drawn_cx = drawn_cy = -9999;   // full redraw next frame
}

bool solid_at(int px, int py) { return tilemap_collision(px >> 4, py >> 4) == COLL_SOLID; }

u16 tile_flags_in(int x, int y, int w, int h) {
    if (!tileset) return 0;
    u16 flags = 0;
    for (int cy = y >> 4; cy <= (y + h - 1) >> 4; cy++)
        for (int cx = x >> 4; cx <= (x + w - 1) >> 4; cx++) {
            int t = tilemap_cell(cx, cy);
            if (!t || t >= tileset->count) continue;
            const TileDef *d = &tileset->defs[t];
            if (!d->flags) continue;
            int hx = cx * CELL + d->hx, hy = cy * CELL + d->hy;
            if (x < hx + d->hw && hx < x + w && y < hy + d->hh && hy < y + h) flags |= d->flags;
        }
    return flags;
}

int scene_width(void) { return tilemap_w * CELL; }
int scene_height(void) { return tilemap_h * CELL; }
