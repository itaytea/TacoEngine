// Respawn: when this entity gets hurt (MSG_HURT) or falls out of the scene, it blinks and
// comes back to its respawn point. The respawn point starts where it was placed.
#include "engine.h"

SCRIPT(Respawn) {
    bool fallDeath;        // = true Respawn when falling below the scene
    bool newScreenSaves;   // = true Entering a new screen (screen-by-screen camera) sets the respawn point
    int duration;          // = 40 Frames from getting hurt to respawning
    bool hazardTiles;      // = true Tiles with the Hazard flag hurt too
    int x;                 // @hide
    int y;                 // @hide
    int timer;             // @hide
};

void Respawn_Start(Respawn *self, Entity *e) {
    self->x = ex(e);
    self->y = ey(e);
}

static void hurt(Respawn *self, Entity *e) {
    if (self->timer) return;
    self->timer = self->duration > 8 ? self->duration : 8;
    e->paused = 1;
    camera_shake(8, 2);
}

void Respawn_Update(Respawn *self, Entity *e) {
    if (self->timer) {
        self->timer--;
        e->hidden = (self->timer & 4) != 0;
        if (self->timer < 8) screen_fade(16 - self->timer * 2);
        if (self->timer == 0) {
            set_position(e, self->x, self->y);
            e->vx = e->vy = 0;
            e->hidden = 0;
            e->paused = 0;
            screen_fade(0);
        }
        return;
    }
    if (self->fallDeath && ey(e) > scene_height() + 32) hurt(self, e);
    if (self->hazardTiles && e->body && (e->body->touchedFlags & 1)) hurt(self, e);   // first tile flag ("Hazard")
}

void Respawn_OnMessage(Respawn *self, Entity *e, int msg, int arg) {
    if (msg == MSG_HURT) hurt(self, e);
    if (msg == MSG_CAMERA_MOVED && self->newScreenSaves) { self->x = ex(e); self->y = ey(e); }
}
