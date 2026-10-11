# Dialogue

Dialogue has four kinds of assets:

| Asset | What it is |
|---|---|
| **Dialogue** | a list of lines, each with a speaker and text |
| **Speaker** | a name, name color and an optional animated portrait |
| **Text Box Style** | where the box sits, its size, frame image, colors, font and text speed |
| **Font** | optional custom font image (the built-in one has upper- and lowercase) |

## Quick start

1. **Create ▸ Dialogue**. Write lines in the dialogue editor; the preview at the top shows exactly what the GBA will draw (click it to replay).
2. **Create ▸ Speaker** (optional). Give it a name and a portrait sprite.
3. **Hierarchy ▸ + ▸ Talking NPC**, or **Add Component ▸ Talk (preset)** on any entity. Pick the dialogue in the Talk script's field.
4. Play. Stand next to the NPC and press **Up**. **A** or **B** shows the whole page, then goes to the next one.

To start a dialogue from your own script: `dialogue_start(&DIALOGUE_Intro);` or use a `DialogueRef` field.

## Text effects

Select text in a line and use the formatting bar, or type the tags:

| Tag | Effect |
|---|---|
| `[b]…[/b]` | bold |
| `[i]…[/i]` | italic |
| `[wave]…[/wave]` | letters bob up and down |
| `[shake]…[/shake]` | letters jitter |
| `[rainbow]…[/rainbow]` | cycling rainbow colors |
| `[color=red]…[/color]` | red, yellow, green, blue or gray (set per text box style) |
| `[pause=30]` | wait 30 frames (half a second) while typing |
| `[page]` | start a new page |
| `{coins}` | the value of a variable |

Effects can be combined, e.g. `[b][rainbow]WOW[/rainbow][/b]`. Text wraps automatically; a new line in the editor forces a line break.

## The Talk script

`scripts/talk.c` comes with new projects:

| Field | |
|---|---|
| `dialogue` | what to say |
| `onTouch` | start as soon as the player touches the trigger (cutscene-style) |
| `once` | only the first time |

The entity needs a trigger collider; the preset adds one.

## Speakers

- **Portrait**: any sprite up to 64×64 (32×32 works well with three lines of text).
- **Talking** and **Waiting**: animations of the portrait sprite. The talking animation plays while text appears, the waiting one when the page is done.
- **Name color**: the color of the name plate text.
- A line with **No speaker** has no name plate and no portrait (good for narration).

## Text box styles

| Setting | |
|---|---|
| Position | bottom or top of the screen |
| Lines | lines per page (the box height follows) |
| Side / edge margin | space from the screen edges, in tiles |
| Name plate | width in tiles, 0 hides it |
| Portrait on the right | |
| Speed | characters per second |
| Font | built-in, or a Font asset (**Make Editable Copy of Font** saves the built-in one as a PNG to redraw) |
| Shadow | 1-pixel text shadow |
| Pause the game while open | freeze the world while the box is up |
| Colors | text, shadow, box fill, the five named colors and the six rainbow colors |
| Frame | a 24×24 PNG cut into 3×3 pieces of 8×8: corners, edges and the middle |

## Fonts

A font image is a grid of 16 columns × 6 rows, one character per cell, in ASCII order from space (32) to 127. Cells can be up to 12×12 pixels. The width of each character is measured automatically from its rightmost pixel. Any opaque pixel counts as ink.

## Limits

- Up to 160 characters per page.
- The box is drawn on the HUD text layer (HUD text stays visible around it, but changes to it show once the box closes); it uses palette banks 12 and 13.
- The portrait uses one sprite slot (sprite 127).
