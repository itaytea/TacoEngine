// Level End: when the player touches it, shows CLEAR!, fades out and loads the next scene.
#include "engine.h"

SCRIPT(LevelEnd) {
    SceneRef next;     // Scene to load (none = play this scene again)
    bool showClear;    // = true Show "CLEAR!" on screen
    int timer;         // @hide
};

void LevelEnd_OnTrigger(LevelEnd *self, Entity *e, Entity *other) {
    if (!has_tag(other, TAG_Player) || self->timer) return;
    self->timer = 1;
    other->paused = 1;
    if (self->showClear) text_print_centered(9, "CLEAR!");
}

void LevelEnd_Update(LevelEnd *self, Entity *e) {
    if (!self->timer) return;
    self->timer++;
    if (self->timer > 30) screen_fade(self->timer - 30);
    if (self->timer == 48) load_scene(self->next >= 0 ? self->next : current_scene());
}
