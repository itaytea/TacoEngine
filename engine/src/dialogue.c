// Dialogue box: typewriter text with bold / italic / wave / shake / rainbow / colors,
// a speaker name plate and an animated portrait. Text is drawn pixel by pixel into a
// RAM canvas that's uploaded to tiles, so every character can have its own effect. The box is
// drawn on BG0, the HUD text layer: while it's open, BG0 shows the box's own screenblock, which
// starts as a copy of the HUD text.
//
// Text control codes (written by the editor's exporter, which also wraps lines into pages):
//   0x01 bold  0x02 italic  0x03 wave  0x04 rainbow  0x05 shake   (each toggles)
//   0x06 n  color (0 = default, 11-15 = named colors)     0x07 n  pause n frames
//   0x08 n  print variable n     0x0A new line     0x0C new page     0x00 end of line
#include "internal.h"

#define DLG_CBB        2
#define DLG_SBB        28
#define FRAME_TILE     100        // 9 frame tiles
#define CANVAS_TILE    112        // canvas tiles follow
#define PAL_FRAME      12
#define PAL_TEXT       13
#define MAX_CANVAS     288        // tiles
#define MAX_CHARS      160


enum { F_BOLD = 1, F_ITALIC = 2, F_WAVE = 4, F_RAINBOW = 8, F_SHAKE = 16 };
enum { COL_TEXT = 1, COL_SHADOW = 2, COL_NAME = 3, COL_RAINBOW = 4, COL_FILL = 10 };

typedef struct { s16 x; u8 y, ch, flags, color, pause; } Glyph;

static EWRAM_BSS u32 canvas[MAX_CANVAS * 8];
static int canvas_dirty;

static const Dialogue *dlg;
static const TextBoxStyle *st;
static int active, line_index;
static const u8 *page;          // start of the current page's text
static const u8 *next_page;     // where the next page starts (or NULL at the end of the line)
static Glyph glyphs[MAX_CHARS];
static int glyph_count, revealed, reveal_fx, wait_frames, page_done, frame;
static int box_cw, box_ch, name_cw;     // canvas sizes in tiles
static int text_x0;                      // left edge of the text, px (after the portrait)

// Portrait
static const SpriteAsset *portrait;
static int portrait_tile = -1, portrait_tiles, portrait_pal, portrait_anim, portrait_frame, portrait_timer, portrait_shown = -1;
static int portrait_dirty;

bool dialogue_active(void) { return active; }
bool dialogue_blocks_world(void) { return active && st && st->pauseGame; }

// ---- Canvas drawing ----

static void pset(int base, int cw, int ch, int x, int y, int c) {
    if (x < 0 || y < 0 || x >= cw * 8 || y >= ch * 8) return;
    u32 *t = canvas + (base + (y >> 3) * cw + (x >> 3)) * 8 + (y & 7);
    int sh = (x & 7) * 4;
    *t = (*t & ~(15u << sh)) | ((u32)c << sh);
}

static void fill_rect(int base, int cw, int ch, int x, int y, int w, int h, int c) {
    for (int yy = y; yy < y + h; yy++)
        for (int xx = x; xx < x + w; xx++) pset(base, cw, ch, xx, yy, c);
}

static int advance_of(const Glyph *g) {
    if (g->ch < 32 || g->ch > 127) return 0;
    return st->font->widths[g->ch - 32] + ((g->flags & F_BOLD) ? 1 : 0);
}

static void draw_char(int base, int cw, int chh, int x, int y, int ch, int flags, int color) {
    if (ch < 32 || ch > 127) return;
    const Font *f = st->font;
    const u16 *rows = f->bits[ch - 32];
    for (int pass = st->shadow ? 0 : 1; pass < 2; pass++) {
        int ox = pass == 0 ? 1 : 0, oy = pass == 0 ? 1 : 0;
        int c = pass == 0 ? COL_SHADOW : color;
        for (int r = 0; r < f->height; r++) {
            u32 bits = rows[r];
            if (flags & F_BOLD) bits |= bits << 1;
            if (!bits) continue;
            int slant = (flags & F_ITALIC) ? (f->height - 1 - r) / 4 : 0;
            for (int b = 0; bits; b++, bits >>= 1)
                if (bits & 1) pset(base, cw, chh, x + b + slant + ox, y + r + oy, c);
        }
    }
}

static int glyph_color(const Glyph *g, int index) {
    if (g->flags & F_RAINBOW) return COL_RAINBOW + index % 6;
    return g->color ? g->color : COL_TEXT;
}

static void draw_glyph(int i, int dx, int dy) {
    const Glyph *g = &glyphs[i];
    draw_char(0, box_cw, box_ch, text_x0 + g->x + dx, st->padY + g->y + dy, g->ch, g->flags, glyph_color(g, i));
}

static void clear_glyph(int i) {
    const Glyph *g = &glyphs[i];
    fill_rect(0, box_cw, box_ch, text_x0 + g->x, st->padY + g->y - 3, advance_of(g) + 3, st->font->height + 6, COL_FILL);
}

// ---- Box layout (its own screenblock, shown on BG0) ----

static void put_tile(int tx, int ty, u16 entry) {
    if (tx < 0 || ty < 0 || tx >= 32 || ty >= 32) return;
    SCREENBLOCK(DLG_SBB)[ty * 32 + tx] = entry;
}

static void draw_frame(int x, int y, int w, int h, int canvasBase, int cw) {
    for (int ty = 0; ty < h; ty++)
        for (int tx = 0; tx < w; tx++) {
            int sx = tx == 0 ? 0 : tx == w - 1 ? 2 : 1, sy = ty == 0 ? 0 : ty == h - 1 ? 2 : 1;
            u16 e;
            if (sx == 1 && sy == 1) e = (u16)((CANVAS_TILE + canvasBase + (ty - 1) * cw + (tx - 1)) | SE_PAL(PAL_TEXT));
            else e = (u16)((FRAME_TILE + sy * 3 + sx) | SE_PAL(PAL_FRAME));
            put_tile(x + tx, y + ty, e);
        }
}

// Start from the HUD text, so it stays visible around the box
static void copy_hud(void) {
    dma_copy32(SCREENBLOCK(DLG_SBB), SCREENBLOCK(TEXT_SBB), 32 * 32 / 2);
}

static void show_box(bool on) {
    REG_BG0CNT = BG_PRIO(0) | BG_CBB(TEXT_CBB) | BG_SBB(on ? DLG_SBB : TEXT_SBB);
}

// ---- Portrait ----

static void portrait_release(void) {
    if (portrait_tile >= 0) vram_free(portrait_tile, portrait_tiles);
    if (portrait) pal_release(portrait_pal);
    portrait = NULL;
    portrait_tile = -1;
}

static void portrait_set(const SpriteAsset *s) {
    if (s == portrait) return;
    portrait_release();
    if (!s || s->pieceCount) return;      // portraits are a single sprite (up to 64x64)
    portrait_tiles = s->frameWords / 8;
    portrait_tile = vram_alloc(portrait_tiles);
    if (portrait_tile < 0) return;
    portrait = s;
    portrait_pal = pal_acquire(s);
    portrait_shown = -1;
}

static void portrait_play(int anim) {
    if (anim != portrait_anim) { portrait_anim = anim; portrait_frame = 0; portrait_timer = 0; }
}

static int portrait_current_frame(void) {
    if (!portrait || portrait_anim >= portrait->animCount) return 0;
    const SpriteAnim *a = &portrait->anims[portrait_anim];
    return a->count ? a->frames[portrait_frame % a->count] : 0;
}

void dialogue_render_portrait(u16 *oam) {
    oam[0] = ATTR0_HIDE;
    if (!active || !portrait || portrait_tile < 0) return;
    int interiorW = (st->boxW - 2) * 8;
    int px = (st->boxX + 1) * 8 + (st->portraitRight ? interiorW - portrait->w - 4 : 4);
    int py = (st->boxY + 1) * 8 + ((st->boxH - 2) * 8 - portrait->h) / 2;
    int f = portrait_current_frame();
    if (f != portrait_shown) { portrait_shown = f; portrait_dirty = 1; }
    oam[0] = (u16)((py & 0xFF) | (portrait->objShape << 14));
    oam[1] = (u16)((px & 0x1FF) | (portrait->objSize << 14));
    oam[2] = (u16)(portrait_tile | (0 << 10) | (portrait_pal << 12));
}

// ---- Pages ----

static void layout_page(void) {
    glyph_count = 0;
    int x = 0, y = 0, flags = 0, color = 0;
    const u8 *p = page;
    next_page = NULL;
    while (*p && glyph_count < MAX_CHARS) {
        u8 c = *p++;
        if (c == 0x0C) { next_page = p; break; }
        if (c == 0x0A) { x = 0; y += st->font->height; continue; }
        if (c >= 0x01 && c <= 0x05) { flags ^= 1 << (c - 1); continue; }
        if (c == 0x06) { color = *p++; continue; }
        if (c == 0x07) { Glyph g = {(s16)x, (u8)y, 0, 0, 0, *p++}; glyphs[glyph_count++] = g; continue; }
        if (c == 0x08) {
            char num[12];
            text_itoa(vars[*p++], num);
            for (char *n = num; *n && glyph_count < MAX_CHARS; n++) {
                Glyph g = {(s16)x, (u8)y, (u8)*n, (u8)flags, (u8)color, 0};
                glyphs[glyph_count++] = g;
                x += advance_of(&g);
            }
            continue;
        }
        Glyph g = {(s16)x, (u8)y, c, (u8)flags, (u8)color, 0};
        glyphs[glyph_count++] = g;
        x += advance_of(&g);
    }
}

static void start_page(void) {
    fill_rect(0, box_cw, box_ch, 0, 0, box_cw * 8, box_ch * 8, COL_FILL);
    canvas_dirty = 1;
    layout_page();
    revealed = 0;
    reveal_fx = 0;
    wait_frames = 0;
    page_done = 0;
}

static void start_line(void) {
    const DialogueLine *l = &dlg->lines[line_index];
    const Speaker *sp = l->speaker;
    // Name plate
    int nameBase = box_cw * box_ch;
    if (st->nameW && sp && sp->name[0]) {
        draw_frame(st->nameX, st->nameY, st->nameW, 4, nameBase, name_cw);
        fill_rect(nameBase, name_cw, 2, 0, 0, name_cw * 8, 16, COL_FILL);
        int x = 2;
        for (const char *n = sp->name; *n; n++) {
            draw_char(nameBase, name_cw, 2, x, (16 - st->font->height) / 2, (u8)*n, 0, COL_NAME);
            if ((u8)*n >= 32 && (u8)*n <= 127) x += st->font->widths[(u8)*n - 32];
        }
        PAL_BG[PAL_TEXT * 16 + COL_NAME] = sp->nameColor;
    } else if (st->nameW) {
        for (int ty = 0; ty < 4; ty++)
            for (int tx = 0; tx < st->nameW; tx++) put_tile(st->nameX + tx, st->nameY + ty, 0);
    }
    // Portrait
    portrait_set(sp ? sp->portrait : NULL);
    portrait_anim = -1;
    portrait_play(l->talkAnim);
    text_x0 = st->padX + (portrait && !st->portraitRight ? portrait->w + 6 : 0);
    page = l->text;
    start_page();
}

static void close_box(void) {
    active = 0;
    show_box(false);
    portrait_release();
    input_pressed &= (u16)~(KEY_A | KEY_B);   // the closing press shouldn't also make the player jump
    broadcast(MSG_DIALOGUE_END, 0);
}

void dialogue_reset(void) {
    if (active) { active = 0; show_box(false); }
    portrait_release();
}

void dialogue_start(DialogueRef d) {
    if (!d || !d->lineCount || !d->style || !d->style->font) return;
    dlg = d;
    st = d->style;
    active = 1;
    line_index = 0;
    box_cw = st->boxW - 2;
    box_ch = st->boxH - 2;
    name_cw = st->nameW ? st->nameW - 2 : 0;
    if (box_cw * box_ch + name_cw * 2 > MAX_CANVAS) box_ch = (MAX_CANVAS - name_cw * 2) / box_cw;
    for (int i = 0; i < 16; i++) {
        PAL_BG[PAL_FRAME * 16 + i] = st->framePal[i];
        PAL_BG[PAL_TEXT * 16 + i] = st->colors[i];
    }
    dma_copy32(CHARBLOCK(DLG_CBB) + FRAME_TILE * 8, st->frameGfx, 9 * 8);
    copy_hud();
    draw_frame(st->boxX, st->boxY, st->boxW, st->boxH, 0, box_cw);
    show_box(true);
    input_pressed &= (u16)~(KEY_A | KEY_B);   // the press that started talking shouldn't skip the first page
    start_line();
}

// ---- Per frame ----

static void reveal_one(void) {
    Glyph *g = &glyphs[revealed];
    if (!g->ch && g->pause) wait_frames = g->pause;
    else draw_glyph(revealed, 0, 0);
    revealed++;
    canvas_dirty = 1;
}

static void draw_arrow(int on) {
    int x = box_cw * 8 - 9, y = box_ch * 8 - 6;
    for (int r = 0; r < 3; r++) fill_rect(0, box_cw, box_ch, x + r, y + r, 5 - 2 * r, 1, on ? COL_TEXT : COL_FILL);
    canvas_dirty = 1;
}

void dialogue_update(void) {
    if (!active) return;
    frame++;
    int advance = (input_pressed & (KEY_A | KEY_B)) != 0;

    if (!page_done) {
        if (advance) {
            while (revealed < glyph_count) { if (glyphs[revealed].ch) draw_glyph(revealed, 0, 0); revealed++; }
            canvas_dirty = 1;
            wait_frames = 0;
            advance = 0;
        } else if (wait_frames) {
            wait_frames--;
        } else {
            reveal_fx += (st->speed << 8) / 60;
            while (reveal_fx >= 256 && revealed < glyph_count && !wait_frames) { reveal_fx -= 256; reveal_one(); }
        }
        if (revealed >= glyph_count) { page_done = 1; portrait_play(dlg->lines[line_index].idleAnim); }
    } else {
        draw_arrow((frame & 16) != 0);
        if (advance) {
            if (next_page) { page = next_page; start_page(); portrait_play(dlg->lines[line_index].talkAnim); }
            else if (line_index + 1 < dlg->lineCount) { line_index++; start_line(); }
            else { close_box(); return; }
        }
    }

    // Wavy and shaky characters move every frame: clear them, repair still neighbors they overlapped, redraw
    int anyAnimated = 0;
    for (int i = 0; i < revealed; i++)
        if (glyphs[i].ch && (glyphs[i].flags & (F_WAVE | F_SHAKE))) { clear_glyph(i); anyAnimated = 1; }
    if (anyAnimated) {
        int h = st->font->height;
        for (int j = 0; j < revealed; j++) {
            const Glyph *s2 = &glyphs[j];
            if (!s2->ch || (s2->flags & (F_WAVE | F_SHAKE))) continue;
            for (int i = 0; i < revealed; i++) {
                const Glyph *a = &glyphs[i];
                if (!a->ch || !(a->flags & (F_WAVE | F_SHAKE))) continue;
                int ax = a->x, aw = advance_of(a) + 3, ay = a->y - 3, ah = h + 6;
                int sx = s2->x, sw = advance_of(s2) + 3, sy = s2->y, sh = h + 1;
                if (ax < sx + sw && sx < ax + aw && ay < sy + sh && sy < ay + ah) { draw_glyph(j, 0, 0); break; }
            }
        }
        for (int i = 0; i < revealed; i++) {
            Glyph *g = &glyphs[i];
            if (!g->ch || !(g->flags & (F_WAVE | F_SHAKE))) continue;
            int dy = 0, dx = 0;
            if (g->flags & F_WAVE) dy = FX_INT(fx_sin(frame * 6 + i * 24) * 2);
            if (g->flags & F_SHAKE) {   // jitter, changing every 4 frames so it stays readable
                u32 h = (u32)(frame / 4) * 2654435761u + (u32)i * 40503u;
                dx = (int)((h >> 13) % 3) - 1;
                dy += (int)((h >> 17) % 3) - 1;
            }
            draw_glyph(i, dx, dy);
        }
        canvas_dirty = 1;
    }

    // Portrait animation
    if (portrait && portrait_anim < portrait->animCount) {
        const SpriteAnim *a = &portrait->anims[portrait_anim];
        if (a->count > 1 && a->fps) {
            portrait_timer += a->fps;
            while (portrait_timer >= 60) { portrait_timer -= 60; portrait_frame++; }
        }
    }
}

void dialogue_commit(void) {
    if (!active) return;
    if (canvas_dirty) {
        dma_copy32(CHARBLOCK(DLG_CBB) + CANVAS_TILE * 8, canvas, (u32)(box_cw * box_ch + name_cw * 2) * 8);
        canvas_dirty = 0;
    }
    // Rainbow: rotate palette entries 4-9
    if ((frame & 3) == 0) {
        for (int i = 0; i < 6; i++) PAL_BG[PAL_TEXT * 16 + COL_RAINBOW + i] = st->colors[COL_RAINBOW + (i + frame / 4) % 6];
    }
    if (portrait_dirty && portrait && portrait_tile >= 0) {
        dma_copy32(OBJ_VRAM + portrait_tile * 8, portrait->gfx + portrait_shown * portrait->frameWords, portrait->frameWords);
        portrait_dirty = 0;
    }
}
