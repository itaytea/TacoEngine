// Minimal GBA hardware definitions (no external library needed).
#ifndef GBA_H
#define GBA_H

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned int   u32;
typedef signed char    s8;
typedef signed short   s16;
typedef signed int     s32;
typedef volatile u16   vu16;
typedef volatile u32   vu32;

#define IO16(o) (*(vu16*)(0x04000000 + (o)))
#define IO32(o) (*(vu32*)(0x04000000 + (o)))
#define PAL_BG        ((u16*)0x05000000)
#define PAL_OBJ       ((u16*)0x05000200)
#define VRAM          0x06000000
#define CHARBLOCK(n)  ((u32*)(VRAM + (n) * 0x4000))
#define SCREENBLOCK(n) ((u16*)(VRAM + (n) * 0x800))
#define OBJ_VRAM      ((u32*)0x06010000)
#define OAM           ((u16*)0x07000000)

#define REG_DISPCNT   IO16(0x000)
#define REG_VCOUNT    IO16(0x006)
#define REG_BG0CNT    IO16(0x008)
#define REG_BG1CNT    IO16(0x00A)
#define REG_BG0HOFS   IO16(0x010)
#define REG_BG0VOFS   IO16(0x012)
#define REG_BG1HOFS   IO16(0x014)
#define REG_BG1VOFS   IO16(0x016)
#define REG_BLDCNT    IO16(0x050)
#define REG_BLDALPHA  IO16(0x052)
#define REG_BLDY      IO16(0x054)
#define REG_KEYINPUT  IO16(0x130)
#define REG_WAITCNT   IO16(0x204)
// Sound
#define REG_SOUNDCNT_L IO16(0x080)
#define REG_SOUNDCNT_H IO16(0x082)
#define REG_SOUNDCNT_X IO16(0x084)
#define REG_FIFO_A     0x040000A0
#define REG_DMA1SAD    IO32(0x0BC)
#define REG_DMA1DAD    IO32(0x0C0)
#define REG_DMA1CNT_H  IO16(0x0C6)
#define REG_TM0CNT_L   IO16(0x100)
#define REG_TM0CNT_H   IO16(0x102)

#define REG_DMA3SAD   IO32(0x0D4)
#define REG_DMA3DAD   IO32(0x0D8)
#define REG_DMA3CNT   IO32(0x0DC)
#define DMA_ENABLE    0x80000000
#define DMA_32        0x04000000

#define DCNT_MODE0    0x0000
#define DCNT_OBJ_1D   0x0040
#define DCNT_BG0      0x0100
#define DCNT_BG1      0x0200
#define DCNT_OBJ      0x1000

#define BG_PRIO(n)    (n)
#define BG_CBB(n)     ((n) << 2)
#define BG_SBB(n)     ((n) << 8)

#define SE_HFLIP      0x0400
#define SE_VFLIP      0x0800
#define SE_PAL(n)     ((n) << 12)

#define ATTR0_HIDE    0x0200
#define ATTR0_SQUARE  0x0000
#define ATTR1_HFLIP   0x1000
#define ATTR1_SIZE16  0x4000
#define ATTR1_SIZE32  0x8000

#define KEY_A      0x0001
#define KEY_B      0x0002
#define KEY_SELECT 0x0004
#define KEY_START  0x0008
#define KEY_RIGHT  0x0010
#define KEY_LEFT   0x0020
#define KEY_UP     0x0040
#define KEY_DOWN   0x0080
#define KEY_R      0x0100
#define KEY_L      0x0200
#define KEY_MASK   0x03FF

#define EWRAM_BSS __attribute__((section(".sbss")))   // zero-initialized, in the 256 KB work RAM

// Hot code: compiled as ARM and run from the fast 32 KB internal RAM instead of the cartridge
#define IWRAM_CODE __attribute__((section(".iwram.code"), target("arm"), long_call, noinline))

#define RGB15(r, g, b) ((r) | ((g) << 5) | ((b) << 10))

static inline void dma_copy32(void *dst, const void *src, u32 words) {
    REG_DMA3CNT = 0;
    REG_DMA3SAD = (u32)src;
    REG_DMA3DAD = (u32)dst;
    REG_DMA3CNT = words | DMA_ENABLE | DMA_32;
}

static inline void vsync(void) {
    while (REG_VCOUNT >= 160) {}
    while (REG_VCOUNT < 160) {}
}

#endif
