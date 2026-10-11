#ifndef TEXT_H
#define TEXT_H

#include "gba.h"

// HUD text is BG0. While a dialogue box is open, BG0 shows the box's screenblock instead (dialogue.c).
#define TEXT_CBB  2
#define TEXT_SBB  30

void text_init(void);
void text_clear(void);
void text_clear_row(int y);
void text_print(int x, int y, const char *s);
void text_print_hi(int x, int y, const char *s);
void text_print_centered(int y, const char *s);
char *text_itoa(int v, char *buf);
char *text_fixed(int v, char *buf);

#endif
