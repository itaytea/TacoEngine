// Background layer on BG2: behind everything, 256x256 px, wraps around, drawn by scripts.
// Its tiles live in the level tileset's charblocks, right after the tileset's own tiles, so it can
// use whatever the tileset leaves free (up to 1024 tiles in all). Palette bank 11 is its colors.
// Scroll and colors are applied in vblank so they never change halfway down the screen.
#include "internal.h"

#define REG_BG2CNT   IO16(0x00C)
#define REG_BG2HOFS  IO16(0x018)
#define REG_BG2VOFS  IO16(0x01A)
#define DCNT_BG2     0x0400

#define LAYER_CBB    0          // shares the tileset's charblocks (0 and 1)
#define LAYER_SBB    29
#define LAYER_PAL    11

static int first_tile;          // first tile after the tileset's
static u16 colors[16];
static int scroll_x, scroll_y, colors_dirty, visible;

int background_tile_count(void) { return 1024 - first_tile; }

u32 *background_tile(int index) {
    if (index < 0 || index >= 1024 - first_tile) return NULL;
    return CHARBLOCK(LAYER_CBB) + (first_tile + index) * 8;
}

void background_set(int tx, int ty, int tile) {
    if (tile < 0 || tile >= 1024 - first_tile) return;
    SCREENBLOCK(LAYER_SBB)[(ty & 31) * 32 + (tx & 31)] = (u16)((first_tile + tile) | SE_PAL(LAYER_PAL));
}

void background_color(int index, u16 color) {
    if (index < 1 || index > 15) return;
    colors[index] = color;
    colors_dirty = 1;
}

void background_scroll(int x, int y) { scroll_x = x; scroll_y = y; }

void background_show(bool on) { visible = on; }

// In vblank
void background_commit(void) {
    REG_BG2HOFS = (u16)(scroll_x & 255);
    REG_BG2VOFS = (u16)(scroll_y & 255);
    if (colors_dirty) {
        for (int i = 1; i < 16; i++) PAL_BG[LAYER_PAL * 16 + i] = colors[i];
        colors_dirty = 0;
    }
    if (visible) REG_DISPCNT |= DCNT_BG2; else REG_DISPCNT &= ~DCNT_BG2;
}

// After the scene's tileset is loaded
void background_reset(void) {
    first_tile = (tilemap_tile_words() / 8 + 1) & ~1;
    if (first_tile > 1024) first_tile = 1024;
    visible = scroll_x = scroll_y = colors_dirty = 0;
    u16 *m = SCREENBLOCK(LAYER_SBB);
    for (int i = 0; i < 32 * 32; i++) m[i] = 0;
    REG_DISPCNT &= ~DCNT_BG2;
    REG_BG2CNT = BG_PRIO(3) | BG_CBB(LAYER_CBB) | BG_SBB(LAYER_SBB);
}
