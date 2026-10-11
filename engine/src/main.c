// Main loop, input, scene loading, and small utilities.
#include "internal.h"

u16 input_held, input_pressed, input_released;
int frame_counter;
EWRAM_BSS int vars[64];

const Scene *scene_current;
static int scene_index = -1, pending_scene = -1;
static int debug_overlay;

// ---- Input ----

static void read_input(void) {
    u16 keys = (u16)(~REG_KEYINPUT & KEY_MASK);
    input_pressed = keys & ~input_held;
    input_released = input_held & ~keys;
    input_held = keys;
}

bool key_held(u16 k) { return (input_held & k) != 0; }
bool key_pressed(u16 k) { return (input_pressed & k) != 0; }
bool key_released(u16 k) { return (input_released & k) != 0; }

// ---- Scenes ----

void scene_start(int index) {
    if (index < 0 || index >= scene_count) index = 0;
    const Scene *s = scenes[index];
    scene_current = s;
    scene_index = index;
    dialogue_reset();
    draw_reset();
    entities_reset();
    text_clear();
    REG_BLDCNT = 0;
    REG_BLDY = 0;
    tilemap_load(s);
    background_reset();
    Entity *camTarget = NULL;
    Entity *spawned[MAX_ENTITIES];
    for (int i = 0; i < s->entityCount; i++) {
        const SceneEntity *se = &s->entities[i];
        Entity *e = entity_spawn_template(se->tmpl, se->x, se->y, se->id);
        if (i < MAX_ENTITIES) spawned[i] = e;
        if (e && se->id && se->id == s->cameraTarget) camTarget = e;
    }
    for (int i = 0; i < s->entityCount && i < MAX_ENTITIES; i++) {   // children follow their parents
        int pi = s->entities[i].parent - 1;
        if (pi >= 0 && pi < MAX_ENTITIES && spawned[i] && spawned[pi]) set_parent(spawned[i], spawned[pi]);
    }
    camera_reset(s, camTarget);
    play_music(s->music);
    tilemap_draw(cam_x, cam_y);
}

void load_scene(SceneRef scene) { pending_scene = scene; }
SceneRef current_scene(void) { return scene_index; }

void scene_apply_pending(void) {
    if (pending_scene < 0) return;
    int s = pending_scene;
    pending_scene = -1;
    scene_start(s);
}

// ---- Screen ----

void text_print_int(int col, int row, int value) {
    char buf[12];
    text_print(col, row, text_itoa(value, buf));
}

void screen_fade(int level) {
    REG_BLDCNT = 0x00FF;
    REG_BLDY = (u16)clamp(level, 0, 16);
}

void set_background(u16 color) { PAL_BG[0] = color; }

// ---- Utilities ----

static u32 rng = 0x2F6E2B1u;

int rand_int(int lo, int hi) {
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    if (hi <= lo) return lo;
    return lo + (int)(rng % (u32)(hi - lo + 1));
}

int frame_count(void) { return frame_counter; }

// Quarter sine table, 8.8 fixed
static const u16 sin_q[65] = {
    0, 6, 13, 19, 25, 31, 38, 44, 50, 56, 62, 68, 74, 80, 86, 92, 98, 104, 109, 115, 121, 126, 132, 137, 142, 147,
    152, 157, 162, 167, 172, 177, 181, 185, 190, 194, 198, 202, 206, 209, 213, 216, 220, 223, 226, 229, 231, 234,
    237, 239, 241, 243, 245, 247, 248, 250, 251, 252, 253, 254, 255, 255, 256, 256, 256};

fixed fx_sin(int a) {
    a &= 255;
    if (a < 64) return sin_q[a];
    if (a < 128) return sin_q[128 - a];
    if (a < 192) return -sin_q[a - 128];
    return -sin_q[256 - a];
}

fixed fx_cos(int a) { return fx_sin(a + 64); }

// ---- Frame budget: on when Project Settings asks for it, or hold L + R and press Select ----

static int peak, peak_timer;

static void draw_debug(int cpuLines) {
    int pct = cpuLines * 100 / 228;
    if (pct >= peak || --peak_timer <= 0) { peak = pct; peak_timer = 120; }   // peak over the last 2 s
    int alive = 0;
    for (int i = 0; i < MAX_ENTITIES; i++) alive += entities[i].alive;
    text_clear_row(19);
    char buf[12];
    if (pct >= 85) text_print_hi(0, 19, "CPU"); else text_print(0, 19, "CPU");
    text_print(4, 19, text_itoa(pct, buf));
    text_print(7, 19, "%");
    text_print(9, 19, "PEAK");
    text_print(14, 19, text_itoa(peak, buf));
    text_print(17, 19, "%");
    text_print(20, 19, "ENT");
    text_print(24, 19, text_itoa(alive, buf));
}

// ---- Main loop ----

int main(void) {
    REG_WAITCNT = 0x4317;   // faster cartridge access (3/1 wait states) with prefetch, as almost every game does
    REG_DISPCNT = DCNT_MODE0 | DCNT_OBJ_1D | DCNT_BG0 | DCNT_BG1 | DCNT_OBJ;
    for (int i = 0; i < 128; i++) OAM[i * 4] = ATTR0_HIDE;
    text_init();
    sound_init();
    save_init();
    if (boot_title) menu_boot(); else scene_start(boot_scene);
    entities_render(cam_x, cam_y);

    while (1) {
        vsync();
        int start = REG_VCOUNT;
        sound_commit();
        entities_commit();
        dialogue_commit();
        draw_commit();
        background_commit();
        tilemap_draw(cam_x, cam_y);

        read_input();
        frame_counter++;
        if (key_held(KEY_L) && key_held(KEY_R) && key_pressed(KEY_SELECT)) {
            debug_overlay ^= 1;
            text_clear_row(19);
        }
        bool frozen = menu_update();
        dialogue_update();
        if (!frozen && !camera_paused_world() && !dialogue_blocks_world()) { draw_begin(); entities_update(); }
        entities_flush_destroyed();
        camera_update();
        scene_apply_pending();
        save_apply_pending();
        menu_apply_pending();
        entities_render(cam_x, cam_y);
        draw_render(cam_x, cam_y);
        sound_update();

        if (debug_overlay || show_frame_budget) {
            int lines = REG_VCOUNT - start;
            if (lines < 0) lines += 228;
            draw_debug(lines);
        }
    }
}
