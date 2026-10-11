// Follower: waits until the player touches it, then trails behind the player.
// Collect several and they line up behind each other.
// Needs a trigger collider (Add Component ▸ Collider, tick Is Trigger).
#include "engine.h"

SCRIPT(Follower) {
    int distance;     // = 18 How far behind the one it follows to stay (px)
    int lag;          // = 6 Higher = lazier, floatier following (1 = snaps into place)
    int height;       // = -6 Float this many px above the one it follows (negative = up)
    bool bob;         // = true Bob gently up and down while following
    Entity *leader;   // @hide  who it follows: the player, or the follower in front of it
    int phase;        // @hide
};

// The last one in the line behind the player, so new followers queue up instead of piling on
static Entity *end_of_line(Entity *player, Entity *self) {
    Entity *last = player;
    for (int guard = 0; guard < 32; guard++) {
        Entity *next = NULL;
        for (int i = 0; i < entity_count() && !next; i++) {
            Entity *o = entity_at(i);
            if (!o || o == self) continue;
            Follower *f = get_script(o, Follower);
            if (f && f->leader == last) next = o;
        }
        if (!next) return last;
        last = next;
    }
    return last;
}

void Follower_OnTrigger(Follower *self, Entity *e, Entity *other) {
    if (self->leader || !has_tag(other, TAG_Player)) return;
    self->leader = end_of_line(other, e);
    self->phase = rand_int(0, 255);
}

void Follower_Update(Follower *self, Entity *e) {
    Entity *lead = self->leader;
    if (!lead) return;
    if (!lead->alive) { self->leader = NULL; return; }   // leader gone (destroyed): stop here

    // Target: `distance` px behind the leader, on the side we're already on
    int lx = ex(lead), ly = ey(lead) + self->height;
    int dx = ex(e) - lx;
    int side = dx < 0 ? -1 : 1;
    int tx = lx + side * self->distance;
    int ty = ly;
    if (self->bob) {
        self->phase += 3;
        ty += FX_INT(fx_sin(self->phase) * 2);
    }

    // Ease toward the target (a fraction of the remaining distance each frame)
    int lag = self->lag > 0 ? self->lag : 1;
    e->x += ((tx << 8) - e->x) / lag;
    e->y += ((ty << 8) - e->y) / lag;

    // Face the one we follow
    set_flip(e, side > 0);
}
