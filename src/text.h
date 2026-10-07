#ifndef XODB_TEXT_H
#define XODB_TEXT_H
#include <stdint.h>

/* Format characters can hide or reorder field contents. Keep the same
 * classification for clipboard input and stopped-runtime value display. */
static inline int xtext_format(uint32_t cp) {
    return cp == 0xad || (cp >= 0x600 && cp <= 0x605) || cp == 0x61c || cp == 0x6dd || cp == 0x70f ||
           cp == 0x890 || cp == 0x891 || cp == 0x8e2 || cp == 0x180e || (cp >= 0x200b && cp <= 0x200f) ||
           (cp >= 0x202a && cp <= 0x202e) || (cp >= 0x2060 && cp <= 0x2064) || (cp >= 0x2066 && cp <= 0x206f) ||
           cp == 0xfeff || (cp >= 0xfff9 && cp <= 0xfffb) || cp == 0x110bd || cp == 0x110cd ||
           (cp >= 0x13430 && cp <= 0x1343f) || (cp >= 0x1bca0 && cp <= 0x1bca3) || (cp >= 0x1d173 && cp <= 0x1d17a) ||
           cp == 0xe0001 || (cp >= 0xe0020 && cp <= 0xe007f);
}

/* str.__repr__ also escapes non-ASCII space and line/paragraph separators. */
static inline int xtext_invisible(uint32_t cp) {
    return xtext_format(cp) || cp == 0xa0 || cp == 0x1680 || (cp >= 0x2000 && cp <= 0x200a) ||
           cp == 0x2028 || cp == 0x2029 || cp == 0x202f || cp == 0x205f || cp == 0x3000;
}
#endif
