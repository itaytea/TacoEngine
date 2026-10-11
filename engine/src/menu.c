// Menus, set up in the editor's Project Settings (menu_settings, generated):
//   title menu: shown when the game starts, over a scene of your choice: NEW GAME / CONTINUE
//   pause menu: Start during play: RESUME / SAVE / QUIT TO TITLE; the game freezes and dims behind it
// Menus are drawn with the HUD text layer and take the buttons while they're open.
#include "internal.h"

enum { MENU_NONE, MENU_TITLE, MENU_PAUSE };
enum { ACT_NEW, ACT_CONTINUE, ACT_RESUME, ACT_SAVE, ACT_TITLE };

static int mode, cursor, count, message_timer, pending_title;
static const char *labels[4];
static int actions[4];

#define FIRST_ROW 12   // menu items start here (two rows apart)

static void add(const char *label, int action) { labels[count] = label; actions[count] = action; count++; }

static void clear_rows(void) {
    for (int r = 3; r < 19; r++) text_clear_row(r);
}

static void draw(void) {
    clear_rows();
    if (mode == MENU_TITLE) {
        if (menu_settings.title) text_print_centered(5, menu_settings.title);
        if (menu_settings.subtitle) text_print_centered(7, menu_settings.subtitle);
    } else {
        text_print_centered(7, "PAUSED");
    }
    for (int i = 0; i < count; i++) {
        int len = 0;
        while (labels[i][len]) len++;
        int col = (30 - len) / 2;
        text_print(col, FIRST_ROW + i * 2, labels[i]);
        if (i == cursor) text_print(col - 2, FIRST_ROW + i * 2, ">");
    }
    if (message_timer) text_print_centered(FIRST_ROW + count * 2, "SAVED!");
}

static void open_title(void) {
    int scene = menu_settings.titleScene >= 0 ? menu_settings.titleScene : menu_settings.startScene;
    scene_start(scene);
    if (menu_settings.music) play_music(menu_settings.music);
    mode = MENU_TITLE;
    cursor = count = 0;
    add("NEW GAME", ACT_NEW);
    if (save_exists(0)) { add("CONTINUE", ACT_CONTINUE); cursor = 1; }
    draw();
}

static void open_pause(void) {
    mode = MENU_PAUSE;
    cursor = count = message_timer = 0;
    add("RESUME", ACT_RESUME);
    add("SAVE", ACT_SAVE);
    if (menu_settings.titleEnabled) add("QUIT TO TITLE", ACT_TITLE);
    REG_BLDCNT = 0x00FE;   // darken everything but the HUD text layer
    REG_BLDY = 9;
    draw();
}

static void close_menu(void) {
    mode = MENU_NONE;
    clear_rows();
    REG_BLDCNT = 0;
    REG_BLDY = 0;
}

void menu_boot(void) { open_title(); }

void go_to_title(void) { pending_title = 1; }

bool menu_open(void) { return mode != MENU_NONE; }

// Every frame, after reading the buttons. Returns true when the world should stay frozen.
bool menu_update(void) {
    if (mode == MENU_NONE) {
        if (menu_settings.pauseEnabled && key_pressed(KEY_START) && !dialogue_active()) {
            open_pause();
            input_pressed = input_held = 0;
            return true;
        }
        return false;
    }
    if (message_timer && --message_timer == 0) draw();
    int moved = 0;
    if (key_pressed(KEY_UP)) { cursor = (cursor + count - 1) % count; moved = 1; }
    if (key_pressed(KEY_DOWN)) { cursor = (cursor + 1) % count; moved = 1; }
    if (moved) { play_sound(menu_settings.cursorSound); draw(); }
    bool back = mode == MENU_PAUSE && key_pressed(KEY_START | KEY_B);
    bool pick = key_pressed(KEY_A) || (mode == MENU_TITLE && key_pressed(KEY_START));
    input_pressed = input_held = 0;   // the menu has the buttons
    if (back) { close_menu(); return false; }
    if (pick) {
        play_sound(menu_settings.confirmSound);
        switch (actions[cursor]) {
        case ACT_NEW:
            close_menu();
            for (int i = 0; i < var_count; i++) vars[i] = 0;
            load_scene(menu_settings.startScene);
            return false;
        case ACT_CONTINUE:
            close_menu();
            load_game(0);
            return false;
        case ACT_RESUME:
            close_menu();
            return false;
        case ACT_SAVE:
            save_game(0);
            message_timer = 60;
            draw();
            break;
        case ACT_TITLE:
            close_menu();
            go_to_title();
            return false;
        }
    }
    return mode == MENU_PAUSE;
}

// End of frame
void menu_apply_pending(void) {
    if (!pending_title) return;
    pending_title = 0;
    open_title();
}
