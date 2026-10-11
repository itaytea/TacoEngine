// Patroller: moves back and forth between where it was placed (point A) and point B.
// Drag the point B handle in the Scene view, or type the offset here.
#include "engine.h"

SCRIPT(Patroller) {
    int toX;        // = 64 Point B, in pixels from point A
    int toY;        // = 0
    fixed speed;    // = 0.75 Pixels per frame
    int wait;       // = 20 Frames to wait at each end
    int ax;         // @hide
    int ay;         // @hide
    s32 progress;   // @hide  0..65536 from A to B
    s32 step;       // @hide
    int dir;        // @hide
    int pause;      // @hide
};

static int isqrt(int v) {
    int r = 0;
    while ((r + 1) * (r + 1) <= v) r++;
    return r;
}

void Patroller_Start(Patroller *self, Entity *e) {
    self->ax = ex(e);
    self->ay = ey(e);
    int len = isqrt(self->toX * self->toX + self->toY * self->toY);
    // progress per frame = speed / length (in 1/65536ths of the path)
    self->step = len > 0 ? (s32)(((long long)self->speed << 8) / len) : 0;
    self->dir = 1;
}

void Patroller_Update(Patroller *self, Entity *e) {
    if (self->pause) { self->pause--; return; }
    self->progress += self->dir * self->step;
    if (self->progress >= 65536) { self->progress = 65536; self->dir = -1; self->pause = self->wait; }
    if (self->progress <= 0) { self->progress = 0; self->dir = 1; self->pause = self->wait; }
    int x = self->ax + (int)(((long long)self->toX * self->progress) >> 16);
    int y = self->ay + (int)(((long long)self->toY * self->progress) >> 16);
    set_position(e, x, y);
    if (self->toX) set_flip(e, (self->dir > 0) != (self->toX > 0));
}
