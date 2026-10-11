// Tile collision for entities, and the built-in Platformer body: run, jump, wall jump,
// coyote time, jump buffer, variable jump height, apex hang, fast fall, one-way platforms.
#include "internal.h"

static EWRAM_BSS Body bodies[MAX_BODIES];
static u8 body_used[MAX_BODIES];

Body *body_alloc(const PlatformerSettings *s, u8 flags) {
    for (int i = 0; i < MAX_BODIES; i++) {
        if (body_used[i]) continue;
        body_used[i] = 1;
        Body *b = &bodies[i];
        for (unsigned k = 0; k < sizeof(Body); k++) ((u8 *)b)[k] = 0;
        b->s = s;
        b->joypad = (flags & BODY_JOYPAD) != 0;
        b->autoAnimate = s && s->autoAnimate;
        b->facing = 1;
        return b;
    }
    return NULL;
}

void body_free(Body *b) {
    for (int i = 0; i < MAX_BODIES; i++)
        if (&bodies[i] == b) body_used[i] = 0;
}

void body_reset_all(void) {
    for (int i = 0; i < MAX_BODIES; i++) body_used[i] = 0;
}

// ---- Box vs tiles ----

static int phased(const Body *b, int cx, int cy) {
    if (!b) return 0;
    for (int i = 0; i < b->phaseCount; i++)
        if (b->phase[i].cx == cx && b->phase[i].cy == cy) return 1;
    return 0;
}

static int box_solid(const Body *b, int x, int y, int w, int h) {
    for (int cy = y >> 4; cy <= (y + h - 1) >> 4; cy++)
        for (int cx = x >> 4; cx <= (x + w - 1) >> 4; cx++)
            if (tilemap_collision(cx, cy) == COLL_SOLID && !phased(b, cx, cy)) return 1;
    return 0;
}

// One-way platforms only stop you when your feet cross their top edge from above
static int box_lands_oneway(int x, int oldBottom, int newBottom, int w) {
    for (int cy = oldBottom >> 4; cy <= (newBottom - 1) >> 4; cy++) {
        int top = cy * CELL;
        if (oldBottom > top || newBottom <= top) continue;
        for (int cx = x >> 4; cx <= (x + w - 1) >> 4; cx++)
            if (tilemap_collision(cx, cy) == COLL_ONEWAY) return top;
    }
    return -1;
}

// Entities with a platform collider: one-way, landed on from above. Returns the highest top
// edge crossed while the feet moved from oldBottom to newBottom, or -1.
static int platform_land(const Entity *self, int x, int oldBottom, int newBottom, int w) {
    int best = -1;
    for (int i = 0, n = entity_count(); i < n; i++) {
        const Entity *o = &entities[i];
        if (!o->alive || o->dying || o == self || !(o->colFlags & COLLIDER_PLATFORM)) continue;
        int ox = FX_INT(o->x) + o->colX, top = FX_INT(o->y) + o->colY;
        if (x >= ox + o->colW || ox >= x + w) continue;
        if (oldBottom <= top && newBottom >= top && (best < 0 || top < best)) best = top;
    }
    return best;
}

static void hitbox(const Entity *e, int *x, int *y, int *w, int *h) {
    if (e->colFlags & COLLIDER_ON) {
        *x = FX_INT(e->x) + e->colX;
        *y = FX_INT(e->y) + e->colY;
        *w = e->colW;
        *h = e->colH;
    } else {
        *x = FX_INT(e->x);
        *y = FX_INT(e->y);
        *w = *h = 1;
    }
}

static int move_x(Entity *e, fixed dx, const Body *b) {
    if (!dx) return 0;
    int x, y, w, h;
    e->x += dx;
    hitbox(e, &x, &y, &w, &h);
    if (!box_solid(b, x, y, w, h)) return 0;
    int offset = x - FX_INT(e->x);
    if (dx > 0) {
        int nx = (((x + w - 1) >> 4) << 4) - w;
        e->x = (nx - offset) << 8;
        return HIT_RIGHT;
    }
    int nx = ((x >> 4) + 1) << 4;
    e->x = (nx - offset) << 8;
    return HIT_LEFT;
}

static int move_y(Entity *e, fixed dy, const Body *b) {
    if (!dy) return 0;
    int x, y, w, h;
    hitbox(e, &x, &y, &w, &h);
    int oldBottom = y + h;
    e->y += dy;
    hitbox(e, &x, &y, &w, &h);
    int offset = y - FX_INT(e->y);
    if (box_solid(b, x, y, w, h)) {
        if (dy > 0) {
            int ny = (((y + h - 1) >> 4) << 4) - h;
            e->y = (ny - offset) << 8;
            return HIT_BOTTOM;
        }
        int ny = ((y >> 4) + 1) << 4;
        e->y = (ny - offset) << 8;
        return HIT_TOP;
    }
    if (dy > 0) {
        int top = box_lands_oneway(x, oldBottom, y + h, w);
        int ptop = platform_land(e, x, oldBottom, y + h, w);
        if (ptop >= 0 && (top < 0 || ptop < top)) top = ptop;
        if (top >= 0) {
            e->y = (top - h - offset) << 8;
            return HIT_BOTTOM;
        }
    }
    return 0;
}

int move_and_collide(Entity *e, fixed dx, fixed dy) {
    return move_x(e, dx, e->body) | move_y(e, dy, e->body);
}

static int standing(const Entity *e) {
    int x, y, w, h;
    hitbox(e, &x, &y, &w, &h);
    if (box_solid(e->body, x, y + h, w, 1)) return 1;
    if (platform_land(e, x, y + h, y + h, w) >= 0) return 1;
    if (((y + h) & 15) == 0) {
        int cy = (y + h) >> 4;
        for (int cx = x >> 4; cx <= (x + w - 1) >> 4; cx++)
            if (tilemap_collision(cx, cy) == COLL_ONEWAY) return 1;
    }
    return 0;
}

// ---- Script API ----

void body_jump(Entity *e, fixed velocity) {
    Body *b = e->body;
    e->vy = -velocity;
    if (!b) return;
    b->onGround = 0;
    b->jumpCuttable = 0;
    b->sustain = 0;
    b->coyote = 0;
    b->buffer = 0;
    b->lockTimer = 0;
}

void body_unstick(Entity *e) {
    Body *b = e->body;
    if (!b) return;
    int x, y, w, h;
    hitbox(e, &x, &y, &w, &h);
    b->phaseCount = 0;
    for (int cy = y >> 4; cy <= (y + h - 1) >> 4; cy++)
        for (int cx = x >> 4; cx <= (x + w - 1) >> 4; cx++)
            if (tilemap_collision(cx, cy) == COLL_SOLID && b->phaseCount < 8) {
                b->phase[b->phaseCount].cx = (s16)cx;
                b->phase[b->phaseCount].cy = (s16)cy;
                b->phaseCount++;
            }
}

// ---- Platformer step ----

static fixed approach(fixed v, fixed target, fixed step) {
    if (v < target) return v + step > target ? target : v + step;
    if (v > target) return v - step < target ? target : v - step;
    return v;
}

static void do_jump(Entity *e, fixed vy, int msg) {
    Body *b = e->body;
    e->vy = -vy;
    b->onGround = 0;
    b->coyote = 0;
    b->wallCoyote = 0;
    b->buffer = 0;
    b->jumpCuttable = 1;
    b->sustain = b->s->jumpSustainFrames;
    b->sustainSpeed = -vy;
    send_message(e, msg, 0);
}

static void auto_animate(Entity *e, Body *b) {
    if (!e->sprite) return;
    if (b->onGround) play(e, (e->vx > 64 || e->vx < -64) ? "run" : "idle");
    else if (b->wallSliding) play(e, "wall");
    else play(e, e->vy < 0 ? "jump" : "fall");
}

void body_step(Entity *e) {
    Body *b = e->body;
    const PlatformerSettings *s = b->s;
    if (!s) return;
    if (b->joypad) {
        b->inputX = (s8)(((input_held & KEY_RIGHT) != 0) - ((input_held & KEY_LEFT) != 0));
        b->jumpHeld = (input_held & KEY_A) != 0;
        b->jumpPressed = (input_pressed & KEY_A) != 0;
    }
    int dir = b->inputX;
    int x, y, w, h;
    hitbox(e, &x, &y, &w, &h);

    // Surroundings
    int wasGround = b->onGround;
    b->onGround = e->vy >= 0 && standing(e);
    int reach = s->wallReach ? s->wallReach : 1;
    int wallL = box_solid(b, x - reach, y, reach, h), wallR = box_solid(b, x + w, y, reach, h);
    b->wallDir = (s8)(wallR ? 1 : wallL ? -1 : 0);

    // Timers: coyote time, jump buffer, wall coyote
    // (they count down at the end of the frame, so "6 frames" really means 6 frames)
    if (b->onGround) { b->coyote = s->coyoteFrames; b->lockTimer = 0; b->airJumpsLeft = s->airJumps; }
    if (b->jumpPressed) b->buffer = s->bufferFrames;
    else if (!b->jumpHeld) b->buffer = 0;     // a buffered jump only counts while the button is still held
    if (!b->onGround && b->wallDir) { b->wallCoyote = s->wallCoyoteFrames; b->lastWallDir = b->wallDir; }

    // Horizontal
    fixed target = dir * s->runSpeed, accel;
    int turning = dir && e->vx && ((dir > 0) != (e->vx > 0));
    if (b->onGround) accel = turning ? s->groundTurn : dir ? s->groundAccel : s->groundDecel;
    else accel = turning ? s->airTurn : dir ? s->airAccel : s->airDecel;
    // Keep momentum: above run speed and still holding that way, slow down gently
    fixed avx = e->vx < 0 ? -e->vx : e->vx;
    if (s->overspeedDecel && dir && !turning && avx > s->runSpeed) accel = s->overspeedDecel;
    if (b->lockTimer) { b->lockTimer--; accel >>= 2; }
    e->vx = approach(e->vx, target, accel);
    if (dir) b->facing = (s8)dir;

    // Jumping
    if (b->buffer) {
        if (b->coyote) {
            do_jump(e, s->jumpVelocity, MSG_JUMPED);
            e->vx += dir * s->jumpBoostX;
        } else if (s->wallJumps && ((b->wallDir && !b->onGround) || b->wallCoyote)) {   // touching a wall, or just left one
            do_jump(e, s->wallJumpY, MSG_WALL_JUMPED);
            e->vx = -b->lastWallDir * s->wallJumpX;
            b->facing = (s8)-b->lastWallDir;
            b->lockTimer = s->wallJumpLockFrames;
        } else if (b->airJumpsLeft) {
            b->airJumpsLeft--;
            do_jump(e, s->jumpVelocity, MSG_JUMPED);
            e->vx += dir * s->jumpBoostX;
        }
    }
    if (b->jumpCuttable && e->vy < 0 && !b->jumpHeld) {
        e->vy = fx_mul(e->vy, s->jumpCut);
        b->jumpCuttable = 0;
    }
    if (e->vy >= 0) b->jumpCuttable = 0;

    // Gravity: apex hang while holding jump near the peak, heavier when falling
    if (!b->onGround) {
        fixed g = s->gravity;
        fixed avy = e->vy < 0 ? -e->vy : e->vy;
        if (b->jumpHeld && avy < s->apexThreshold) g = fx_mul(g, s->apexGravity);
        else if (e->vy > 0) g = fx_mul(g, s->fallGravity);
        e->vy += g;
    }
    // Celeste-style sustain: keep full jump speed while held, for a few frames
    if (b->sustain) {
        if (b->jumpHeld) { e->vy = b->sustainSpeed; b->sustain--; }
        else b->sustain = 0;
    }
    b->wallSliding = !b->onGround && e->vy > 0 && b->wallDir && s->wallJumps && dir == b->wallDir;
    if (b->wallSliding && e->vy > s->wallSlideMax) e->vy = s->wallSlideMax;
    fixed maxFall = (s->fastFallMax && (input_held & KEY_DOWN) && b->joypad) ? s->fastFallMax : s->maxFall;
    if (e->vy > maxFall) e->vy = maxFall;
    if (b->wallSliding) b->facing = b->wallDir;

    // Move & collide
    if (move_x(e, e->vx, b)) e->vx = 0;
    int hy = move_y(e, e->vy, b);
    if (hy) {
        e->vy = 0;
        if ((hy & HIT_BOTTOM) && !wasGround) send_message(e, MSG_LANDED, 0);
    }

    // Phasing: forget cells we've left
    hitbox(e, &x, &y, &w, &h);
    for (int i = 0; i < b->phaseCount;) {
        int px = b->phase[i].cx * CELL, py = b->phase[i].cy * CELL;
        if (!(x < px + CELL && px < x + w && y < py + CELL && py < y + h)) b->phase[i] = b->phase[--b->phaseCount];
        else i++;
    }
    b->touchedFlags = tile_flags_in(x, y, w, h);
    if (hy & HIT_TOP) b->sustain = 0;
    if (!b->onGround && b->coyote) b->coyote--;
    if (!b->jumpPressed && b->buffer) b->buffer--;
    if (b->wallCoyote && !(b->wallDir && !b->onGround)) b->wallCoyote--;
    b->jumpPressed = 0;
    e->flipX = b->facing < 0;
    if (b->autoAnimate) auto_animate(e, b);
}
