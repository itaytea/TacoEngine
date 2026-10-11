// Entities: spawning from templates, scripts, triggers, animation, sprite rendering.
#include "internal.h"

EWRAM_BSS Entity entities[MAX_ENTITIES];
static int high;   // slots in use are all below this: loops over entities stop here

extern const ScriptType *const script_types[];   // generated, indexed by SCRIPT_ID_*

// ---- Sprite VRAM (1024 4bpp tiles) and palette banks ----

static u32 vram_used[1024 / 32];
static const SpriteAsset *pal_owner[16];
static u8 pal_refs[16];

int vram_alloc(int tiles) {
    int run = 0;
    for (int i = 0; i < 1024; i++) {
        if (vram_used[i >> 5] & (1u << (i & 31))) { run = 0; continue; }
        if (++run == tiles) {
            int start = i - tiles + 1;
            for (int k = start; k <= i; k++) vram_used[k >> 5] |= 1u << (k & 31);
            return start;
        }
    }
    return -1;
}

// Big frames come from the top of sprite memory, so the small ones that come and go at the bottom
// (animation frames) don't break up the space big ones need
static int vram_alloc_high(int tiles) {
    int run = 0;
    for (int i = 1023; i >= 0; i--) {
        if (vram_used[i >> 5] & (1u << (i & 31))) { run = 0; continue; }
        if (++run == tiles) {
            for (int k = i; k < i + tiles; k++) vram_used[k >> 5] |= 1u << (k & 31);
            return i;
        }
    }
    return -1;
}

void vram_free(int start, int tiles) {
    for (int k = start; k < start + tiles; k++) vram_used[k >> 5] &= ~(1u << (k & 31));
}

int pal_acquire(const SpriteAsset *s) {
    for (int i = 0; i < 16; i++)
        if (pal_refs[i] && pal_owner[i] == s) { pal_refs[i]++; return i; }
    for (int i = 0; i < 16; i++)
        if (!pal_refs[i]) {
            pal_owner[i] = s;
            pal_refs[i] = 1;
            for (int c = 0; c < 16; c++) PAL_OBJ[i * 16 + c] = s->palette[c];
            return i;
        }
    return 0;
}

void pal_release(int bank) {
    if (pal_refs[bank]) pal_refs[bank]--;
}

// ---- Shared sprite frames ----
// Entities showing the same frame of the same sprite share one copy in sprite memory, and only
// entities on screen hold one. So many copies of a big sprite (like 128x128 hands) fit, as long as
// the frames actually on screen at once fit in the 1024 tiles.

#define MAX_FRAMES 96
static struct { const SpriteAsset *s; s16 frame; u16 tile, tiles; u8 refs; } frames[MAX_FRAMES];

#define MAX_DMA 48
static struct { const u32 *src; u32 *dst; u16 words; } dma_queue[MAX_DMA];
static int dma_count;

// A slot holding this frame (shared if another entity already shows it), or -1 if memory is full
static int frame_acquire(const SpriteAsset *s, int frame) {
    int empty = -1;
    for (int i = 0; i < MAX_FRAMES; i++) {
        if (frames[i].refs && frames[i].s == s && frames[i].frame == frame) { frames[i].refs++; return i; }
        if (!frames[i].refs && empty < 0) empty = i;
    }
    if (empty < 0 || dma_count >= MAX_DMA) return -1;
    int tiles = s->frameWords / 8;
    int at = tiles >= 64 ? vram_alloc_high(tiles) : vram_alloc(tiles);
    if (at < 0) return -1;
    frames[empty].s = s;
    frames[empty].frame = (s16)frame;
    frames[empty].tile = (u16)at;
    frames[empty].tiles = (u16)tiles;
    frames[empty].refs = 1;
    dma_queue[dma_count].src = s->gfx + frame * s->frameWords;
    dma_queue[dma_count].dst = OBJ_VRAM + at * 8;
    dma_queue[dma_count].words = s->frameWords;
    dma_count++;
    return empty;
}

static void frame_release(int slot) {
    if (slot < 0 || !frames[slot].refs) return;
    if (--frames[slot].refs == 0) vram_free(frames[slot].tile, frames[slot].tiles);
}

// ---- Triggers ----

#define MAX_CONTACTS 64
static struct { u8 a, b; } contacts[MAX_CONTACTS];
static int contact_count;

// ---- Lifecycle ----

void entities_reset(void) {
    for (int i = 0; i < MAX_ENTITIES; i++) entities[i].alive = 0;
    high = 0;
    for (int i = 0; i < MAX_FRAMES; i++) frames[i].refs = 0;
    for (int i = 0; i < 1024 / 32; i++) vram_used[i] = 0;
    for (int i = 0; i < 16; i++) pal_refs[i] = 0;
    contact_count = 0;
    body_reset_all();
}

static void set_sprite(Entity *e, const SpriteAsset *s) {
    e->sprite = s;
    e->frameSlot = e->shownFrame = -1;   // sprite memory is taken when it's first drawn on screen
    if (s) e->palBank = (u8)pal_acquire(s);
}

Entity *entity_spawn_template(const EntityTemplate *t, int x, int y, u16 id) {
    Entity *e = NULL;
    for (int i = 0; i < MAX_ENTITIES; i++)
        if (!entities[i].alive) { e = &entities[i]; break; }
    if (!e || !t) return NULL;
    if (e - entities + 1 > high) high = (int)(e - entities) + 1;
    u8 *raw = (u8 *)e;
    for (unsigned k = 0; k < sizeof(Entity); k++) raw[k] = 0;
    e->alive = 1;
    e->tmpl = t;
    e->name = t->name;
    e->id = id;
    e->tag = t->tag;
    e->x = x << 8;
    e->y = y << 8;
    e->flipX = (t->flags & ENT_FLIPX) != 0;
    e->hidden = (t->flags & ENT_HIDDEN) != 0;
    e->priority = t->priority;
    e->anim = t->anim;
    e->colX = t->colX;
    e->colY = t->colY;
    e->colW = t->colW;
    e->colH = t->colH;
    e->colFlags = t->colFlags;
    set_sprite(e, t->sprite);
    if (t->platformer) e->body = body_alloc(t->platformer, t->bodyFlags);
    e->scriptCount = t->scriptCount > MAX_SCRIPTS ? MAX_SCRIPTS : t->scriptCount;
    for (int i = 0; i < e->scriptCount; i++) {
        const ScriptInit *si = &t->scripts[i];
        e->scripts[i].type = si->type;
        const u8 *src = si->init;
        u8 *dst = (u8 *)e->scripts[i].data;
        for (int k = 0; k < si->type->size && k < SCRIPT_DATA_BYTES; k++) dst[k] = src ? src[k] : 0;
    }
    return e;
}

Entity *spawn(PrefabRef prefab, int x, int y) { return entity_spawn_template(prefab, x, y, 0); }

void destroy(Entity *e) {
    if (e && e->alive) e->dying = 1;
}

static void contacts_forget(int index) {
    for (int i = 0; i < contact_count;) {
        if (contacts[i].a == index || contacts[i].b == index) contacts[i] = contacts[--contact_count];
        else i++;
    }
}

void set_parent(Entity *child, Entity *parent) {
    if (!child || parent == child) return;
    child->parent = parent;
    if (parent) {
        child->localX = (s16)(FX_INT(child->x) - FX_INT(parent->x));
        child->localY = (s16)(FX_INT(child->y) - FX_INT(parent->y));
    }
}

void entities_flush_destroyed(void) {
    // Children go with their parents (repeat for grandchildren)
    for (int again = 1; again;) {
        again = 0;
        for (int i = 0; i < high; i++) {
            Entity *e = &entities[i];
            if (e->alive && !e->dying && e->parent && (e->parent->dying || !e->parent->alive)) { e->dying = 1; again = 1; }
        }
    }
    for (int i = 0; i < high; i++) {
        Entity *e = &entities[i];
        if (!e->alive || !e->dying) continue;
        for (int s = 0; s < e->scriptCount; s++)
            if (e->scripts[s].type->on_destroy) e->scripts[s].type->on_destroy(e->scripts[s].data, e);
        frame_release(e->frameSlot);
        if (e->sprite) pal_release(e->palBank);
        if (e->body) body_free(e->body);
        e->alive = 0;
        contacts_forget(i);
    }
    while (high && !entities[high - 1].alive) high--;
}

// ---- Queries ----

static int str_eq(const char *a, const char *b) {
    if (!a || !b) return 0;
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

Entity *find_entity(const char *name) {
    for (int i = 0; i < high; i++)
        if (entities[i].alive && !entities[i].dying && str_eq(entities[i].name, name)) return &entities[i];
    return NULL;
}

Entity *find_with_tag(int tag) {
    for (int i = 0; i < high; i++)
        if (entities[i].alive && !entities[i].dying && entities[i].tag == tag) return &entities[i];
    return NULL;
}

Entity *ref_entity(EntityRef ref) {
    if (!ref) return NULL;
    for (int i = 0; i < high; i++)
        if (entities[i].alive && entities[i].id == ref) return &entities[i];
    return NULL;
}

int entity_count(void) { return high; }
Entity *entity_at(int i) { return (i >= 0 && i < MAX_ENTITIES && entities[i].alive && !entities[i].dying) ? &entities[i] : NULL; }
bool has_tag(const Entity *e, int tag) { return e && e->tag == tag; }

void *entity_script(Entity *e, int id) {
    if (!e) return NULL;
    const ScriptType *t = script_types[id];
    for (int i = 0; i < e->scriptCount; i++)
        if (e->scripts[i].type == t) return e->scripts[i].data;
    return NULL;
}

void send_message(Entity *e, int msg, int arg) {
    if (!e || !e->alive) return;
    for (int i = 0; i < e->scriptCount; i++)
        if (e->scripts[i].type->on_message) e->scripts[i].type->on_message(e->scripts[i].data, e, msg, arg);
}

void broadcast(int msg, int arg) {
    for (int i = 0; i < high; i++)
        if (entities[i].alive && !entities[i].dying) send_message(&entities[i], msg, arg);
}

void set_position(Entity *e, int x, int y) {
    e->x = x << 8;
    e->y = y << 8;
}

bool overlaps(const Entity *a, const Entity *b) {
    if (!(a->colFlags & COLLIDER_ON) || !(b->colFlags & COLLIDER_ON)) return 0;
    int ax = FX_INT(a->x) + a->colX, ay = FX_INT(a->y) + a->colY;
    int bx = FX_INT(b->x) + b->colX, by = FX_INT(b->y) + b->colY;
    return ax < bx + b->colW && bx < ax + a->colW && ay < by + b->colH && by < ay + a->colH;
}

// ---- Animation ----

void play_index(Entity *e, int anim) {
    if (!e->sprite || anim < 0 || anim >= e->sprite->animCount || anim == e->anim) return;
    e->anim = (u8)anim;
    e->frame = 0;
    e->frameTimer = 0;
    e->animDone = 0;
}

void play(Entity *e, const char *name) {
    if (!e->sprite) return;
    for (int i = 0; i < e->sprite->animCount; i++)
        if (str_eq(e->sprite->anims[i].name, name)) { play_index(e, i); return; }
}

void set_flip(Entity *e, bool flipX) { e->flipX = flipX != 0; }

static void animate(Entity *e) {
    if (!e->sprite || e->anim >= e->sprite->animCount) return;
    const SpriteAnim *a = &e->sprite->anims[e->anim];
    if (a->count <= 1 || !a->fps) return;
    int t = e->frameTimer + a->fps;
    while (t >= 60) {
        t -= 60;
        if (e->frame + 1 < a->count) e->frame++;
        else if (a->loop) e->frame = 0;
        else e->animDone = 1;
    }
    e->frameTimer = (u8)t;
}

// ---- Update ----

static void call_update(Entity *e) {
    if (!e->started) {
        e->started = 1;
        for (int s = 0; s < e->scriptCount && e->alive && !e->dying; s++)
            if (e->scripts[s].type->start) e->scripts[s].type->start(e->scripts[s].data, e);
    }
    for (int s = 0; s < e->scriptCount && !e->dying; s++)
        if (e->scripts[s].type->update) e->scripts[s].type->update(e->scripts[s].data, e);
}

static void trigger_event(Entity *a, Entity *b, int enter) {
    for (int s = 0; s < a->scriptCount; s++) {
        const ScriptType *t = a->scripts[s].type;
        if (enter && t->on_trigger) t->on_trigger(a->scripts[s].data, a, b);
        if (!enter && t->on_trigger_exit) t->on_trigger_exit(a->scripts[s].data, a, b);
    }
}

static void update_triggers(void) {
    // Ended contacts
    for (int i = 0; i < contact_count;) {
        Entity *a = &entities[contacts[i].a], *b = &entities[contacts[i].b];
        if (!a->alive || !b->alive || a->dying || b->dying || !overlaps(a, b)) {
            if (a->alive && b->alive) { trigger_event(a, b, 0); trigger_event(b, a, 0); }
            contacts[i] = contacts[--contact_count];
        } else {
            i++;
        }
    }
    // New contacts (at least one side must be a trigger), among entities that have colliders
    u8 list[MAX_ENTITIES];
    int n = 0;
    for (int i = 0; i < high; i++)
        if (entities[i].alive && !entities[i].dying && (entities[i].colFlags & COLLIDER_ON)) list[n++] = (u8)i;
    for (int p = 0; p < n; p++) {
        int i = list[p];
        Entity *a = &entities[i];
        for (int q = p + 1; q < n; q++) {
            int j = list[q];
            Entity *b = &entities[j];
            if (!b->alive || b->dying || !a->alive || a->dying) continue;   // a trigger may have destroyed one
            if (!((a->colFlags | b->colFlags) & COLLIDER_TRIGGER)) continue;
            if (!overlaps(a, b)) continue;
            int known = 0;
            for (int c = 0; c < contact_count; c++)
                if (contacts[c].a == i && contacts[c].b == j) { known = 1; break; }
            if (known || contact_count >= MAX_CONTACTS) continue;
            contacts[contact_count].a = (u8)i;
            contacts[contact_count].b = (u8)j;
            contact_count++;
            trigger_event(a, b, 1);
            if (b->alive && !b->dying && a->alive) trigger_event(b, a, 1);
        }
    }
}

void entities_update(void) {
    for (int i = 0; i < high; i++) {      // (scripts may spawn: `high` can grow during this loop)
        Entity *e = &entities[i];
        if (e->alive && !e->dying) call_update(e);
    }
    for (int i = 0; i < high; i++) {
        Entity *e = &entities[i];
        if (e->alive && !e->dying && e->body && !e->paused) body_step(e);
    }
    // Children without a body of their own move with their parent (parents first, so chains work)
    for (int pass = 0; pass < 2; pass++)
        for (int i = 0; i < high; i++) {
            Entity *e = &entities[i];
            if (!e->alive || e->dying || !e->parent || e->body) continue;
            e->x = e->parent->x + (e->localX << 8);
            e->y = e->parent->y + (e->localY << 8);
        }
    for (int i = 0; i < high; i++)
        if (entities[i].alive && !entities[i].paused) animate(&entities[i]);
    update_triggers();
}

// ---- Rendering ----

static u16 oam_shadow[128 * 4];

void entities_render(int camX, int camY) {
    int n = 0;
    for (int i = 0; i < high && n < 127; i++) {   // OAM 127 is the dialogue portrait
        Entity *e = &entities[i];
        if (!e->alive || !e->sprite) continue;
        const SpriteAsset *s = e->sprite;
        int px = FX_INT(e->x) - camX, py = FX_INT(e->y) - camY;
        int sx = e->flipX ? px - (s->w - s->pivotX) : px - s->pivotX;
        int sy = py - s->pivotY;
        if (e->hidden || sx <= -s->w || sx >= SCREEN_W || sy <= -s->h || sy >= SCREEN_H) {
            // Not drawn: give its sprite memory back (it's loaded again when it shows up)
            frame_release(e->frameSlot);
            e->frameSlot = e->shownFrame = -1;
            continue;
        }
        const SpriteAnim *a = e->anim < s->animCount ? &s->anims[e->anim] : NULL;
        int frame = a && a->count ? a->frames[e->frame < a->count ? e->frame : a->count - 1] : 0;
        if (frame != e->shownFrame) {
            int slot = frame_acquire(s, frame);
            if (slot >= 0) {
                frame_release(e->frameSlot);
                e->frameSlot = (s16)slot;
                e->shownFrame = (s16)frame;
                e->vramTile = frames[slot].tile;
            }
            if (e->frameSlot < 0) continue;     // sprite memory is full: skip it this frame
        }
        int prio = e->priority < 1 ? 1 : e->priority > 3 ? 3 : e->priority;
        u16 flip = e->flipX ? ATTR1_HFLIP : 0, attr2 = (u16)((prio << 10) | (e->palBank << 12));
        if (!s->pieceCount) {
            oam_shadow[n * 4 + 0] = (u16)((sy & 0xFF) | (s->objShape << 14));
            oam_shadow[n * 4 + 1] = (u16)((sx & 0x1FF) | (s->objSize << 14) | flip);
            oam_shadow[n * 4 + 2] = (u16)(e->vramTile | attr2);
            n++;
            continue;
        }
        // Big frame: one OBJ per piece, mirrored as a whole when flipped
        for (int k = 0; k < s->pieceCount && n < 127; k++) {
            const SpritePiece *pc = &s->pieces[k];
            int x = sx + (e->flipX ? s->w - pc->x - pc->w : pc->x), y = sy + pc->y;
            if (x <= -pc->w || x >= SCREEN_W || y <= -pc->h || y >= SCREEN_H) continue;
            oam_shadow[n * 4 + 0] = (u16)((y & 0xFF) | (pc->objShape << 14));
            oam_shadow[n * 4 + 1] = (u16)((x & 0x1FF) | (pc->objSize << 14) | flip);
            oam_shadow[n * 4 + 2] = (u16)((e->vramTile + pc->tile) | attr2);
            n++;
        }
    }
    for (int i = n; i < 127; i++) oam_shadow[i * 4] = ATTR0_HIDE;
    dialogue_render_portrait(&oam_shadow[127 * 4]);
}

void entities_commit(void) {
    for (int i = 0; i < dma_count; i++) dma_copy32(dma_queue[i].dst, dma_queue[i].src, dma_queue[i].words);
    dma_count = 0;
    for (int i = 0; i < 128; i++) {
        OAM[i * 4 + 0] = oam_shadow[i * 4 + 0];
        OAM[i * 4 + 1] = oam_shadow[i * 4 + 1];
        OAM[i * 4 + 2] = oam_shadow[i * 4 + 2];
    }
}
