# Ready-made prefabs

Add them with **Hierarchy ▸ +** (places one in the scene) or **Project ▸ Create ▸ Ready-made Prefab** (just creates the prefab). The first time, TacoMaker adds their art to `assets/premade/` and their scripts to `scripts/`. After that it reuses the same prefab, so changing it changes every copy. Swap the placeholder art by editing the PNGs.

| Prefab | What it does | Scripts |
|---|---|---|
| **Level End** | A waving flag. When the player touches it: "CLEAR!", fade out, load the **next** scene (none = replay this one). | LevelEnd |
| **Enemy** | Walks from where you place it (point A) to point B and back, waiting at each end. Hurts the player on touch. | Patroller, Hazard |
| **Spikes** | Hurt the player on touch. | Hazard |

## Setting the enemy's path

Select the enemy in the Scene view: an orange dashed line runs to its point B. Drag the **B** handle, or type **toX / toY** (pixels from point A) in the Inspector. **speed** is pixels per frame and **wait** is frames to pause at each end. Paths can be diagonal or vertical too.

## Getting hurt: the Respawn script

Hazards send `MSG_HURT` to whatever has the **Player** tag. The **Respawn** script reacts: the player blinks, the screen fades, and the player comes back to its respawn point.

- The respawn point starts where the player was placed. In *screen by screen* scenes, entering a new screen moves it there (turn off **newScreenSaves** to stop that).
- Falling below the scene also counts as getting hurt (**fallDeath**).
- Tiles with the first tile flag (Hazard by default) hurt too (**hazardTiles**).

Players made with **Platformer Player** include Respawn. Placing an Enemy or Spikes also gives Respawn to a preset-made player that has no scripts yet.

To react to damage your own way, handle `MSG_HURT` in your player script instead of using Respawn:

```c
void MyPlayer_OnMessage(MyPlayer *self, Entity *e, int msg, int arg) {
    if (msg == MSG_HURT) { self->health -= arg; ... }
}
```

To make your own hazards, add the **Hazard** script and a trigger collider to anything.
