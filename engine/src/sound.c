// Sound: one music channel and four sound-effect channels, mixed in software into 8-bit samples and
// played through Direct Sound A. Timer 0 runs the output at 13379 Hz, exactly 224 samples per frame.
//
// Timer 1 counts the samples actually played and interrupts every 224 of them; the handler starts the
// next buffer. So buffer changes follow the audio itself, not the main loop: a long frame (loading a
// scene) can't let the DMA run on into unrelated memory, which plays as loud noise. The FIFO is
// cleared and pre-filled at each change, so bytes the DMA read ahead past the old buffer are never
// heard. Two buffers: one playing, the other mixed while it plays; the mixer only writes when no
// buffer is waiting, so it never touches one the interrupt might switch to. Sounds are already at the output rate (the editor converts
// them), so mixing is just adding samples.
#include "internal.h"

#define BUF          224        // samples per frame at 13379 Hz
#define NBUF         2
#define SFX_CHANNELS 4

typedef struct {
    const s8 *data;
    u32 pos, length;
    u8 loop, active;
} Channel;

static Channel music, sfx[SFX_CHANNELS];
static int next_sfx;
static int music_vol = 16, sfx_vol = 16;
static s8 buffers[NBUF][BUF] __attribute__((aligned(4)));
static u8 silent[NBUF];                 // the buffer holds only zeros
static volatile int playing;            // the buffer the DMA is reading
static volatile int ready = -1;         // mixed and waiting to play (-1 = none yet)

// Start playing buffer b from its first sample
IWRAM_CODE static void start_buffer(int b) {
    REG_DMA1CNT_H = 0;
    REG_SOUNDCNT_H = 0x0B06;            // Direct Sound A, full volume, both speakers, timer 0, FIFO reset
    const u32 *src = (const u32 *)buffers[b];
    for (int i = 0; i < 4; i++) FIFO_A_DATA = src[i];   // first 16 bytes now, the DMA does the rest
    REG_DMA1SAD = (u32)(src + 4);
    REG_DMA1DAD = REG_FIFO_A;
    REG_DMA1CNT_H = 0xB640;             // on, FIFO timing, 32-bit, repeat, fixed destination
}

// Timer 1 interrupt: the playing buffer's 224 samples have all been heard
IWRAM_CODE void sound_irq(void) {
    int next = ready >= 0 ? ready : playing;   // nothing new mixed (a long frame): play the last one again
    ready = -1;
    playing = next;
    start_buffer(next);
}

void sound_init(void) {
    REG_SOUNDCNT_X = 0x0080;    // sound on
    for (int b = 0; b < NBUF; b++) {
        for (int i = 0; i < BUF; i++) buffers[b][i] = 0;
        silent[b] = 1;
    }
    playing = 0;
    ready = -1;
    REG_TM0CNT_H = 0;
    REG_TM1CNT_H = 0;
    REG_TM0CNT_L = (u16)(65536 - 1254);   // 16.78 MHz / 1254 = 13379 Hz
    REG_TM1CNT_L = (u16)(65536 - BUF);    // counts timer 0 overflows: one interrupt per buffer
    start_buffer(0);
    REG_TM1CNT_H = 0x00C4;                // on, interrupt, count up with timer 0
    REG_TM0CNT_H = 0x0080;
}

// Mixing, run from fast internal RAM
IWRAM_CODE static void mix(s8 *out) {
    int acc[BUF];
    for (int i = 0; i < BUF; i++) acc[i] = 0;
    Channel *chans[1 + SFX_CHANNELS] = { &music, &sfx[0], &sfx[1], &sfx[2], &sfx[3] };
    for (int c = 0; c < 1 + SFX_CHANNELS; c++) {
        Channel *ch = chans[c];
        if (!ch->active) continue;
        int vol = c == 0 ? music_vol : sfx_vol;
        for (int i = 0; i < BUF; i++) {
            acc[i] += ch->data[ch->pos] * vol;
            if (++ch->pos >= ch->length) {
                if (ch->loop) ch->pos = 0;
                else { ch->active = 0; break; }
            }
        }
    }
    for (int i = 0; i < BUF; i++) {
        int v = acc[i] >> 4;
        out[i] = (s8)(v > 127 ? 127 : v < -128 ? -128 : v);
    }
}

// Once per frame: mix the next buffer, unless one is already waiting to play
void sound_update(void) {
    if (ready >= 0) return;
    int target = 0;
    while (target == playing) target++;   // never the one playing (the interrupt only switches to `ready`)
    bool any = music.active;
    for (int i = 0; i < SFX_CHANNELS; i++) any |= sfx[i].active;
    if (any) {
        mix(buffers[target]);
        silent[target] = 0;
    } else if (!silent[target]) {
        for (int i = 0; i < BUF; i++) buffers[target][i] = 0;
        silent[target] = 1;
    }
    ready = target;
}

void play_sound(SoundRef s) {
    if (!s || !s->length) return;
    Channel *ch = &sfx[next_sfx];
    next_sfx = (next_sfx + 1) % SFX_CHANNELS;
    ch->data = s->data;
    ch->length = s->length;
    ch->pos = 0;
    ch->loop = 0;
    ch->active = 1;
}

static const SoundAsset *music_playing;

void play_music(SoundRef s) {
    if (s == music_playing && music.active) return;
    music_playing = s;
    if (!s || !s->length) { music.active = 0; return; }
    music.data = s->data;
    music.length = s->length;
    music.pos = 0;
    music.loop = 1;
    music.active = 1;
}

void stop_music(void) { play_music(NULL); }

void set_volume(int m, int s) {
    music_vol = clamp(m, 0, 16);
    sfx_vol = clamp(s, 0, 16);
}
