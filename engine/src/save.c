// Saving to the cartridge's battery-backed SRAM (32 KB, byte access only).
//   0 .. 4095      four 1 KB save slots: scene, player position, variables
//   4096 .. 32767  free space for scripts (save_write / save_read, offset 0 = byte 4096)
// The "SRAM_V113" string tells emulators and flash carts which kind of save memory the game uses.
#include <stddef.h>
#include "internal.h"

#define SRAM        ((volatile u8 *)0x0E000000)
#define SLOT_SIZE   1024
#define SLOTS       4
#define FREE_START  (SLOTS * SLOT_SIZE)
#define SRAM_SIZE   32768
#define MAGIC       0x4F434154u   // "TACO"

static const char save_type[] __attribute__((aligned(4))) = "SRAM_V113";

static void sram_write(int at, const void *src, int n) {
    const u8 *s = (const u8 *)src;
    for (int i = 0; i < n; i++) SRAM[at + i] = s[i];
}

static void sram_read(int at, void *dst, int n) {
    u8 *d = (u8 *)dst;
    for (int i = 0; i < n; i++) d[i] = SRAM[at + i];
}

typedef struct {
    u32 magic;
    u16 scene;
    u16 varCount;
    s16 playerX, playerY;
    u16 hasPlayer, pad;
    u32 checksum;       // over the rest of the header and the variables
} SaveHeader;

// FNV-1a over the header (minus magic and checksum) and the variables that follow it in SRAM
static u32 slot_checksum(int slot, const SaveHeader *h, int varBytes) {
    u32 sum = 2166136261u;
    const u8 *b = (const u8 *)h + 4;
    for (int i = 4; i < (int)offsetof(SaveHeader, checksum); i++) sum = (sum ^ *b++) * 16777619u;
    int at = slot * SLOT_SIZE + (int)sizeof(SaveHeader);
    for (int i = 0; i < varBytes; i++) sum = (sum ^ SRAM[at + i]) * 16777619u;
    return sum;
}

static int var_bytes(int count) {
    int n = count;
    if ((int)sizeof(SaveHeader) + n * 4 > SLOT_SIZE) n = (SLOT_SIZE - (int)sizeof(SaveHeader)) / 4;
    return n * 4;
}

static int pending_slot = -1;   // load_game waits for the end of the frame

void save_init(void) {
    volatile const char *keep = save_type;   // keep the save-type string in the ROM
    (void)keep[0];
}

static Entity *player(void) { return player_tag ? find_with_tag(player_tag) : NULL; }

bool save_game(int slot) {
    if (slot < 0 || slot >= SLOTS) return false;
    SaveHeader h = { MAGIC, (u16)current_scene(), (u16)var_count, 0, 0, 0, 0, 0 };
    Entity *p = player();
    if (p) { h.hasPlayer = 1; h.playerX = (s16)ex(p); h.playerY = (s16)ey(p); }
    int bytes = var_bytes(var_count);
    h.varCount = (u16)(bytes / 4);
    // Invalidate the slot first, then write the body, then the header with its checksum last: a save
    // cut off by power loss reads as no save instead of an old header over new variables
    u32 zero = 0;
    sram_write(slot * SLOT_SIZE, &zero, 4);
    sram_write(slot * SLOT_SIZE + (int)sizeof h, vars, bytes);
    h.checksum = slot_checksum(slot, &h, bytes);
    sram_write(slot * SLOT_SIZE + 4, (const u8 *)&h + 4, (int)sizeof h - 4);
    sram_write(slot * SLOT_SIZE, &h, 4);
    return true;
}

static bool read_header(int slot, SaveHeader *h) {
    if (slot < 0 || slot >= SLOTS) return false;
    sram_read(slot * SLOT_SIZE, h, sizeof *h);
    if (h->magic != MAGIC || h->scene >= scene_count || h->varCount * 4 > SLOT_SIZE - (int)sizeof *h) return false;
    return h->checksum == slot_checksum(slot, h, h->varCount * 4);
}

bool save_exists(int slot) {
    SaveHeader h;
    return read_header(slot, &h);
}

void save_erase(int slot) {
    if (slot < 0 || slot >= SLOTS) return;
    u32 zero = 0;
    sram_write(slot * SLOT_SIZE, &zero, 4);
}

bool load_game(int slot) {
    if (!save_exists(slot)) return false;
    pending_slot = slot;
    return true;
}

// End of frame: load a saved game (variables first, so scripts see them in Start)
bool save_apply_pending(void) {
    if (pending_slot < 0) return false;
    SaveHeader h;
    int slot = pending_slot;
    pending_slot = -1;
    if (!read_header(slot, &h)) return false;
    for (int i = 0; i < var_count; i++) vars[i] = 0;
    int n = h.varCount < var_count ? h.varCount : var_count;
    sram_read(slot * SLOT_SIZE + (int)sizeof h, vars, n * 4);
    scene_start(h.scene);
    Entity *p = player();
    if (p && h.hasPlayer) {
        set_position(p, h.playerX, h.playerY);
        camera_reset(scene_current, p);
    }
    return true;
}

void save_write(int offset, const void *data, int size) {
    if (offset < 0 || size <= 0 || FREE_START + offset + size > SRAM_SIZE) return;
    sram_write(FREE_START + offset, data, size);
}

void save_read(int offset, void *data, int size) {
    if (offset < 0 || size <= 0 || FREE_START + offset + size > SRAM_SIZE) return;
    sram_read(FREE_START + offset, data, size);
}
