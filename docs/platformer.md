# Platformer movement

The **Platformer Body** component gives an entity running, jumping and wall jumping with tile collision. The D-pad moves and **A** jumps; **B** is left free for your own abilities. Its Collider is the hitbox. The values live in a **Platformer Settings** asset that many entities can share.

Fastest way to get one: **Hierarchy ▸ + ▸ Platformer Player**, or **Add Component ▸ Platformer Controller (preset)**.

## Tuning

Open the settings asset (or **Tune Movement…** in the Inspector) to get the movement editor:

- **Running**: a speed-over-time graph. Drag the left point (time to reach top speed), the middle point (top speed) and the right point (time to stop).
- **Jumping**: the real jump arc. Drag the peak (height and time to the top) and the landing point (how fast you fall).
- **Assists**: coyote time, jump buffer and the other small helpers.
- **Walls**: wall jumping and sliding.
- **Presets**: Standard, Celeste Classic 2, Floaty, Snappy and Double Jump.

The graphs are drawn by simulating the same math the engine runs, so they match the game.

## All settings

Speeds are in pixels per frame at 60 fps (a tile is 16 px).

| Setting | |
|---|---|
| Run speed | top speed |
| Ground accel / decel / turn | how fast you speed up, stop, and reverse on the ground |
| Air accel / brake / control | the same in the air |
| Jump velocity, gravity | together set height and timing (drag the peak instead) |
| Fall gravity × | heavier gravity while falling |
| Apex hang, apex threshold | lighter gravity near the peak while jump is held |
| Variable height / release cut | letting go of jump multiplies upward speed |
| Hold jump | Celeste-style: hold full jump speed for this many frames while held |
| Max fall speed | terminal velocity |
| Fast fall | faster max fall while holding Down |
| Jump side boost | extra sideways speed when jumping while holding a direction |
| Keep momentum | above run speed (after a wall jump or a launch), slow down gently while still holding that way |
| Coyote time | frames you can still jump after leaving a ledge |
| Jump buffer | frames an early jump press is remembered (only while the button stays held) |
| Double jump | extra jumps in the air |
| Wall jumps, wall reach | allow wall jumps, and from how many pixels away |
| Wall jump push / height | sideways and upward speed of a wall jump |
| Wall slide speed | max fall speed while holding toward a wall |
| Wall coyote time | frames you can still wall jump after leaving a wall |
| Steering lock | frames of weaker steering right after a wall jump |
| Auto-animate | plays the sprite's `idle`, `run`, `jump`, `fall` and `wall` animations automatically |

## Tiles

- **Solid** tiles block from every side. **One-way** tiles only stop you from above, so you can jump up through them.
- Entities with a **Platform** collider work like one-way tiles that can move.
- The left and right edges of a scene act as walls; the top and bottom are open.
- Tile **flags** (e.g. Hazard) are reported in `e->body->touchedFlags` every frame. Each tile can have a smaller hitbox for its flags, like the pointy part of spikes.

## Driving a body from a script

Turn off **D-pad control** in the component, then set `e->body->inputX` (-1, 0 or 1), `jumpHeld` and `jumpPressed` each frame. That's how you make enemies that walk and jump with the same physics as the player.

To play your own animation for a while (sleeping, a cutscene), set `e->body->autoAnimate = 0`, and set it back to 1 to hand animation back to the body.

## Messages

The body sends `MSG_JUMPED`, `MSG_WALL_JUMPED` and `MSG_LANDED` to its own entity's scripts.
