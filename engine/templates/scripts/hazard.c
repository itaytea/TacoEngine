// Hazard: hurts the player on touch (sends MSG_HURT). Needs a trigger collider.
#include "engine.h"

SCRIPT(Hazard) {
    int damage;   // = 1 Passed along with MSG_HURT
};

void Hazard_OnTrigger(Hazard *self, Entity *e, Entity *other) {
    if (has_tag(other, TAG_Player)) send_message(other, MSG_HURT, self->damage);
}
