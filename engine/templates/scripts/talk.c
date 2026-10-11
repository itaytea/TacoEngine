// Talk: shows a dialogue when the player stands here and presses Up (or as soon as they touch it).
// Give this entity a trigger collider.
#include "engine.h"

SCRIPT(Talk) {
    DialogueRef dialogue;   // What to say
    bool onTouch;           // Start as soon as the player touches it
    bool once;              // Only the first time
    bool touching;          // @hide
    bool done;              // @hide
};

void Talk_Update(Talk *self, Entity *e) {
    if (!self->touching || dialogue_active() || (self->once && self->done)) return;
    if (self->onTouch || key_pressed(KEY_UP)) {
        dialogue_start(self->dialogue);
        self->done = true;
        if (self->onTouch) self->touching = false;   // don't restart until touched again
    }
}

void Talk_OnTrigger(Talk *self, Entity *e, Entity *other) {
    if (has_tag(other, TAG_Player)) self->touching = true;
}

void Talk_OnTriggerExit(Talk *self, Entity *e, Entity *other) {
    if (has_tag(other, TAG_Player)) self->touching = false;
}
