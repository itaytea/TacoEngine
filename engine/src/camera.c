// Camera: smooth follow with a dead zone, screen-by-screen slides (Celeste/Zelda style), or fixed.
#include "internal.h"

#define SLIDE_FRAMES 22

int cam_x, cam_y;
static int base_x, base_y;          // camera position before shake
static Entity *target;
static int mode;
static int shake_frames, shake_strength;
static int slide_t, slide_fx, slide_fy, slide_tx, slide_ty, slide_dir;

static void clamp_to_scene(int *x, int *y) {
    int w = scene_width(), h = scene_height();
    *x = w <= SCREEN_W ? (w - SCREEN_W) / 2 : clamp(*x, 0, w - SCREEN_W);
    *y = h <= SCREEN_H ? (h - SCREEN_H) / 2 : clamp(*y, 0, h - SCREEN_H);
}

static void target_point(int *x, int *y) {
    *x = FX_INT(target->x);
    *y = FX_INT(target->y);
    if (target->colFlags & COLLIDER_ON) {
        *x += target->colX + target->colW / 2;
        *y += target->colY + target->colH / 2;
    }
}

static void screen_of_target(int *x, int *y) {
    int tx, ty;
    target_point(&tx, &ty);
    int sx = tx >= 0 ? tx / SCREEN_W : -1, sy = ty >= 0 ? ty / SCREEN_H : -1;
    *x = sx * SCREEN_W;
    *y = sy * SCREEN_H;
    clamp_to_scene(x, y);
}

void camera_reset(const Scene *s, Entity *t) {
    target = t;
    mode = s->cameraMode;
    shake_frames = 0;
    slide_t = 0;
    base_x = base_y = 0;
    if (target) {
        if (mode == CAM_SCREENS) screen_of_target(&base_x, &base_y);
        else if (mode == CAM_FOLLOW) {
            int tx, ty;
            target_point(&tx, &ty);
            base_x = tx - SCREEN_W / 2;
            base_y = ty - SCREEN_H / 2;
        }
    }
    clamp_to_scene(&base_x, &base_y);
    cam_x = base_x;
    cam_y = base_y;
}

bool camera_paused_world(void) { return slide_t > 0; }
bool camera_moving(void) { return slide_t > 0; }

void camera_update(void) {
    if (target && (!target->alive || target->dying)) target = NULL;

    if (slide_t > 0) {
        int t = ((SLIDE_FRAMES - slide_t + 1) << 8) / SLIDE_FRAMES;
        int e = (t * t * (768 - 2 * t)) >> 16;          // smoothstep 0..256
        base_x = slide_fx + (((slide_tx - slide_fx) * e) >> 8);
        base_y = slide_fy + (((slide_ty - slide_fy) * e) >> 8);
        if (--slide_t == 0) {
            base_x = slide_tx;
            base_y = slide_ty;
            broadcast(MSG_CAMERA_MOVED, slide_dir);
        }
    } else if (target && mode == CAM_FOLLOW) {
        int tx, ty;
        target_point(&tx, &ty);
        int cx = base_x + SCREEN_W / 2, cy = base_y + SCREEN_H / 2;
        // dead zone, then ease toward the target
        int dx = 0, dy = 0;
        if (tx > cx + 16) dx = tx - (cx + 16);
        if (tx < cx - 16) dx = tx - (cx - 16);
        if (ty > cy + 16) dy = ty - (cy + 16);
        if (ty < cy - 28) dy = ty - (cy - 28);
        base_x += dx > 0 ? (dx + 3) / 4 : -((-dx + 3) / 4);
        base_y += dy > 0 ? (dy + 3) / 4 : -((-dy + 3) / 4);
        clamp_to_scene(&base_x, &base_y);
    } else if (target && mode == CAM_SCREENS) {
        int nx, ny;
        screen_of_target(&nx, &ny);
        if (nx != base_x || ny != base_y) {
            slide_fx = base_x;
            slide_fy = base_y;
            slide_tx = nx;
            slide_ty = ny;
            slide_dir = nx < base_x ? 0 : nx > base_x ? 1 : ny < base_y ? 2 : 3;
            slide_t = SLIDE_FRAMES;
        }
    }

    cam_x = base_x;
    cam_y = base_y;
    if (shake_frames > 0) {
        shake_frames--;
        cam_x += rand_int(-shake_strength, shake_strength);
        cam_y += rand_int(-shake_strength, shake_strength);
    }
}

void camera_follow(Entity *e) { target = e; }
void camera_shake(int frames, int strength) { shake_frames = frames; shake_strength = strength; }
int camera_x(void) { return cam_x; }
int camera_y(void) { return cam_y; }
