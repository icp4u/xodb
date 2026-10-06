// Writes deterministic fuzz seeds (mode byte, flags byte, body) to a directory.
#include "jitmap_build.h"
#include "adversary.h"
#include <stdio.h>
#include <string.h>

static void save(const char *dir, const char *name, uint8_t mode, uint8_t flags, const void *p, size_t n)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(&mode, 1, 1, f) != 1 || fwrite(&flags, 1, 1, f) != 1 || fwrite(p, 1, n, f) != n || fclose(f)) {
        perror(path);
        exit(1);
    }
}

static void lifetime(struct jb *b, int swap)
{
    jb_init(b, swap);
    jb_header(b, 77, 50, 0);
    jb_debug_begin(b, 90, 0x1000, 2);
    jb_debug_entry(b, 0x1000, 10, 0, "a.js");
    jb_debug_entry(b, 0x1004, 11, 0, "\xff");
    jb_load(b, 100, 77, 1, 0x1000, 0x40, 1, "alpha", 0xcc);
    jb_unwind(b, 110, 24, 8, 0x1000);
    jb_load(b, 120, 77, 1, 0x3000, 0x10, 3, "gamma", 0x90);
    jb_move(b, 200, 77, 1, 0x1000, 0x2000, 0x40, 1);
    jb_load(b, 300, 77, 1, 0x1000, 0x20, 2, "beta", 0x90);
    jb_raw_record(b, 9, 24, 310);
    jb_close(b, 1000);
}

/* C07-R4: `lines` perf-map lines "9000 1 <name>" at one address; when
 * `differs` the last line's last name byte differs. */
static uint8_t *long_map(int lines, size_t name, int differs, size_t *len)
{
    size_t row = 7 + name + 1;
    uint8_t *p = malloc(lines * row);
    if (!p)
        exit(1);
    for (int i = 0; i < lines; ++i) {
        uint8_t *r = p + i * row;
        memcpy(r, "9000 1 ", 7);
        memset(r + 7, 'n', name);
        if (differs && i == lines - 1)
            r[7 + name - 1] = 'm';
        r[row - 1] = '\n';
    }
    *len = lines * row;
    return p;
}

/* Long-name perf maps (classification-work bound, contract v4 section 2):
 * alone, and after a one-LOAD jitdump elsewhere, declared once (flags 0x10)
 * or added twice (0x30). Mode 2 splits the body in halves, so the jitdump is
 * padded with spaces to the map's length. Inputs over 64 KiB are replayed
 * as seeds; the smoke run's -max_len truncates them. */
static void long_names(const char *dir)
{
    static const struct {
        const char *name;
        int lines, differs;
        size_t len;
    } maps[] = {
        {"perfmap-long-13x8192", 13, 0, 8192},     {"perfmap-long-15x8192", 15, 0, 8192},
        {"perfmap-long-16x8192", 16, 0, 8192},     {"perfmap-long-17x8192", 17, 0, 8192},
        {"perfmap-long-16x8192-last-differs", 16, 1, 8192}, {"perfmap-long-16x65500", 16, 0, 65500},
        {"perfmap-long-4x16000", 4, 0, 16000},
    };
    for (size_t i = 0; i < sizeof maps / sizeof *maps; ++i) {
        size_t n;
        uint8_t *map = long_map(maps[i].lines, maps[i].len, maps[i].differs, &n);
        save(dir, maps[i].name, 1, 0, map, n);
        free(map);
    }
    size_t n;
    uint8_t *map = long_map(16, 65500, 0, &n);
    struct jb b;
    jb_init(&b, 0);
    jb_header(&b, 77, 1, 0);
    jb_load(&b, 10, 77, 1, 0x5000, 0x10, 1, "elsewhere", 0x90);
    jb_close(&b, 1000);
    uint8_t *both = malloc(2 * n);
    if (!both)
        exit(1);
    memcpy(both, b.bytes, b.len);
    memset(both + b.len, ' ', n - b.len);
    memcpy(both + n, map, n);
    save(dir, "both-long-16x65500-one-dump", 2, 0x10, both, 2 * n);
    save(dir, "both-long-16x65500-two-dumps", 2, 0x30, both, 2 * n);
    free(both);
    free(map);
    jb_free(&b);
}

int main(int argc, char **argv)
{
    if (argc != 2)
        return 2;
    struct jb b;
    lifetime(&b, 0);
    save(argv[1], "jitdump-lifetime-le", 0, 3, b.bytes, b.len);
    save(argv[1], "jitdump-lifetime-budget", 3, 0, b.bytes, b.len);
    jb_free(&b);
    lifetime(&b, 1);
    save(argv[1], "jitdump-lifetime-swapped", 0, 0, b.bytes, b.len);
    save(argv[1], "jitdump-truncated", 0, 0, b.bytes, b.len - 5);
    jb_free(&b);
    jb_init(&b, 0);
    jb_header(&b, 77, 1, 1);
    jb_load(&b, 10, 77, 1, 0xffffffffff600000ull, 0x100, 1, "high", 0x90);
    jb_load(&b, 11, 77, 1, 0xfffffffffffff000ull, 0x2000, 2, "wrap", 0x90);
    jb_raw_record(&b, 0, 8, 12);
    save(argv[1], "jitdump-edges", 0, 0, b.bytes, b.len);
    jb_free(&b);
    static const char map[] = "1000 40 alpha with spaces\n0x1000 40 beta \xe2\x98\x83\n2000 0 zero\n"
                              "ffffffffffffff00 200 wrap\n1ffffffffffffffff 1 over\nzz 1 bad\n3000 10 tail";
    save(argv[1], "perfmap-mixed", 1, 8, map, sizeof map - 1);
    lifetime(&b, 0);
    size_t n = b.len + sizeof map - 1;
    uint8_t *both = malloc(2 * n);
    memcpy(both, b.bytes, b.len);
    memset(both + b.len, ' ', n - b.len);
    memcpy(both + n, map, sizeof map - 1);
    memset(both + n + sizeof map - 1, '\n', n - (sizeof map - 1));
    save(argv[1], "both", 2, 9, both, 2 * n);
    free(both);
    jb_free(&b);
    long_names(argv[1]);
    /* C07-R2 adversarial families (small n) with and without a work limit. */
    for (int f = 0; f < ADV_COUNT; ++f) {
        char name[64];
        adv_build(&b, (enum adv_family)f, 40);
        snprintf(name, sizeof name, "r2-%s", adv_names[f]);
        save(argv[1], name, 0, (uint8_t)(f & 7), b.bytes, b.len);
        snprintf(name, sizeof name, "r2-%s-worklimit", adv_names[f]);
        save(argv[1], name, (uint8_t)(30 << 2), 0, b.bytes, b.len);
        jb_free(&b);
    }
    return 0;
}
