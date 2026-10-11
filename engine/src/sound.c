// Sound: one music channel and four sound-effect channels, mixed in software into 8-bit samples and
// played through Direct Sound A. Timer 0 runs the output at 13379 Hz, which is exactly 224 samples
// per frame, so each vblank the DMA is pointed at the buffer mixed during the previous frame while
// the next one is mixed. Sounds are already at that rate (the editor converts them), so mixing is
// just adding samples.
#include "internal.h"

#define BUF          224        // samples per frame at 13379 Hz
#define SFX_CHANNELS 4

typedef struct {
    const s8 *data;
    u32 pos, length;
    u8 loop, active;
} Channel;

static Channel music, sfx[SFX_CHANNELS];
static int next_sfx;
static int music_vol = 16, sfx_vol = 16;
static s8 buffers[2][BUF] __attribute__((aligned(4)));
static int which;               // the buffer being mixed this frame
static int idle;                // both buffers are silent

void sound_init(void) {
    REG_SOUNDCNT_X = 0x0080;    // sound on
    REG_SOUNDCNT_H = 0x0B06;    // Direct Sound A at full volume, both speakers, timer 0, FIFO reset
    REG_TM0CNT_H = 0;
    REG_TM0CNT_L = (u16)(65536 - 1254);   // 16.78 MHz / 1254 = 13379 Hz
    REG_TM0CNT_H = 0x0080;
    for (int i = 0; i < BUF; i++) buffers[0][i] = buffers[1][i] = 0;
    idle = 1;
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

// In vblank: start playing the buffer mixed last frame
void sound_commit(void) {
    REG_DMA1CNT_H = 0;
    REG_DMA1SAD = (u32)buffers[which];
    REG_DMA1DAD = REG_FIFO_A;
    REG_DMA1CNT_H = 0xB640;     // on, FIFO timing, 32-bit, repeat, fixed destination
    which ^= 1;
}

// Once per frame: mix the next buffer
void sound_update(void) {
    bool any = music.active;
    for (int i = 0; i < SFX_CHANNELS; i++) any |= sfx[i].active;
    if (!any) {
        if (idle >= 2) return;              // both buffers are already silent
        for (int i = 0; i < BUF; i++) buffers[which][i] = 0;
        idle++;
        return;
    }
    idle = 0;
    mix(buffers[which]);
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
