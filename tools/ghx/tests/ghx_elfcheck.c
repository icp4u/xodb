/* ghx_elfcheck: ELF snapshot/identity regression harness (C01-R2, GPLv3).
 *
 *   ghx_elfcheck PATH [ADDR [LEN]]   probe one file; prints probe_rc, nload,
 *                                    exec_range(ADDR or e_entry, LEN or 1)
 *   ghx_elfcheck --selftest DIR      crafted-image and snapshot-race cases;
 *                                    DIR is an owned scratch directory
 * Exit 0 when every assertion holds. */
#define _GNU_SOURCE 1
#include "elfid.h"
#include "sha256.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fails, checks;

#define CHECK(cond, ...) do { checks++; if (!(cond)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void p16(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; }
static void p32(unsigned char *p, uint32_t v) { p16(p, v & 0xffff); p16(p + 2, v >> 16); }
static void p64(unsigned char *p, uint64_t v) { p32(p, (uint32_t)v); p32(p + 4, (uint32_t)(v >> 32)); }

/* ELF64 x86-64 header with phnum program headers at offset 64 */
static size_t header(unsigned char *b, unsigned phnum)
{
	memset(b, 0, 64);
	memcpy(b, "\177ELF", 4);
	b[4] = 2; b[5] = 1; b[6] = 1;
	p16(b + 16, 2); p16(b + 18, 62); p32(b + 20, 1);
	p64(b + 24, 0x400000); p64(b + 32, 64); p64(b + 40, 0);
	p16(b + 52, 64); p16(b + 54, 56); p16(b + 56, phnum);
	p16(b + 58, 64); p16(b + 60, 0); p16(b + 62, 0);
	return 64 + 56u * phnum;
}

static void phdr(unsigned char *b, unsigned i, uint32_t type, uint32_t flags, uint64_t off,
		 uint64_t va, uint64_t fsz, uint64_t msz)
{
	unsigned char *p = b + 64 + 56u * i;
	p32(p, type); p32(p + 4, flags); p64(p + 8, off); p64(p + 16, va); p64(p + 24, va);
	p64(p + 32, fsz); p64(p + 40, msz); p64(p + 48, 0x1000);
}

static int parse(const unsigned char *b, size_t n, struct ghx_elfid *e, char *err)
{
	return ghx_elfid_parse(b, n, NULL, e, err, 256);
}

static void crafted(void)
{
	static unsigned char b[8192];
	struct ghx_elfid e;
	char err[256];
	unsigned char v;
	int rc;

	/* (a) the review image: 120 bytes, PF_X PT_LOAD at file offset 4096 */
	memset(b, 0, sizeof b);
	header(b, 1);
	phdr(b, 0, 1, 5, 4096, 0x400000, 16, 16);
	rc = parse(b, 120, &e, err);
	CHECK(rc == 2, "past-EOF PT_LOAD accepted (rc=%d)", rc);

	/* valid: file-backed [0x400000,+120), bss tail to 0x402000 */
	memset(b, 0x90, sizeof b);
	header(b, 1);
	phdr(b, 0, 1, 5, 0, 0x400000, 120, 0x2000);
	rc = parse(b, 120, &e, err);
	CHECK(rc == 0, "valid image rejected: %s", err);
	CHECK(ghx_elfid_exec_range(&e, 0x400000, 1), "first byte not executable");
	CHECK(ghx_elfid_exec_range(&e, 0x400000 + 119, 1), "last file byte not executable");
	CHECK(!ghx_elfid_exec_range(&e, 0x400000 + 120, 1), "non-file-backed tail treated as code");
	CHECK(!ghx_elfid_exec_range(&e, 0x400000 + 100, 21), "range crossing into the tail accepted");
	CHECK(ghx_elfid_exec_range(&e, 0x400000 + 100, 20), "range ending at file end rejected");
	CHECK(!ghx_elfid_exec_range(&e, UINT64_MAX, 2), "wrapping range accepted");
	CHECK(!ghx_elfid_exec_range(&e, 0x3fffff, 2), "range starting before segment accepted");
	CHECK(ghx_elf_byte(&e, b, 0x400000, &v) == 1 && v == 0x7f, "file byte");
	CHECK(ghx_elf_byte(&e, b, 0x400000 + 200, &v) == 0 && v == 0, "bss byte must read as zero");
	CHECK(ghx_elf_byte(&e, b, 0x500000, &v) == -1, "unmapped byte must fail");
	CHECK(ghx_elf_readonly(&e, 0x400010), "r-x segment is read-only");

	/* filesz > memsz */
	header(b, 1);
	phdr(b, 0, 1, 5, 0, 0x400000, 120, 16);
	CHECK(parse(b, 120, &e, err) == 2, "filesz > memsz accepted");
	/* offset + filesz overflow */
	header(b, 1);
	phdr(b, 0, 1, 5, UINT64_MAX - 1, 0x400000, 16, 16);
	CHECK(parse(b, 120, &e, err) == 2, "offset+filesz overflow accepted");
	/* vaddr + memsz overflow */
	header(b, 1);
	phdr(b, 0, 1, 5, 0, UINT64_MAX - 8, 16, 16);
	CHECK(parse(b, 120, &e, err) == 2, "vaddr+memsz overflow accepted");
	/* overlapping PT_LOADs */
	header(b, 2);
	phdr(b, 0, 1, 5, 0, 0x400000, 176, 0x1000);
	phdr(b, 1, 1, 6, 0, 0x400800, 176, 0x1000);
	CHECK(parse(b, 176, &e, err) == 2, "overlapping PT_LOADs accepted");
	/* non-executable segment is never code */
	header(b, 1);
	phdr(b, 0, 1, 4, 0, 0x400000, 120, 120);
	CHECK(parse(b, 120, &e, err) == 0 && !ghx_elfid_exec_range(&e, 0x400000, 1), "PF_R-only segment treated as code");
	/* too many PT_LOADs is rejected, never silently truncated */
	header(b, 33);
	for (unsigned i = 0; i < 33; i++) phdr(b, i, 1, 4, 0, 0x400000 + 0x1000ull * i, 16, 16);
	CHECK(parse(b, 64 + 56 * 33, &e, err) == 3, "33 PT_LOADs accepted");
	/* program header table checks */
	header(b, 1);
	p16(b + 54, 32);
	CHECK(parse(b, 120, &e, err) == 2, "bad phentsize accepted");
	header(b, 1);
	p64(b + 32, 100);
	CHECK(parse(b, 120, &e, err) == 2, "program header table past EOF accepted");
	header(b, 1);
	p16(b + 56, 0xffff);
	CHECK(parse(b, 8192, &e, err) == 3, "PN_XNUM accepted");
	/* identity gates */
	header(b, 1); phdr(b, 0, 1, 5, 0, 0x400000, 120, 120);
	b[4] = 1;
	CHECK(parse(b, 120, &e, err) == 3, "ELFCLASS32 accepted");
	header(b, 1); phdr(b, 0, 1, 5, 0, 0x400000, 120, 120);
	p16(b + 18, 183);
	CHECK(parse(b, 120, &e, err) == 3, "foreign e_machine accepted");
	header(b, 1); b[0] = 0;
	CHECK(parse(b, 120, &e, err) == 2, "bad magic accepted");
	CHECK(parse(b, 63, &e, err) == 2, "short file accepted");
}

/* ---- snapshot stability ---- */

struct race { const char *path, *other; int mode; };

static void write_file(const char *path, const unsigned char *b, size_t n)
{
	FILE *f = fopen(path, "wb");
	if (!f || fwrite(b, 1, n, f) != n || fclose(f) != 0) { perror(path); exit(2); }
}

static void mid(void *arg)
{
	struct race *r = arg;
	if (r->mode == 1) {	/* in-place same-size modification */
		FILE *f = fopen(r->path, "r+b");
		if (f) { fseek(f, 10, SEEK_SET); fputc('X', f); fclose(f); }
	} else if (r->mode == 2) {	/* rename another file over the path */
		if (rename(r->other, r->path) != 0) perror("rename");
	} else if (r->mode == 3) {	/* append */
		FILE *f = fopen(r->path, "ab");
		if (f) { fputc('Y', f); fclose(f); }
	}
}

static void races(const char *dir)
{
	char path[4096], other[4096], err[256], orig[65];
	unsigned char b[65536];
	struct ghx_snapshot s;
	struct race r;
	int rc;

	for (size_t i = 0; i < sizeof b; i++) b[i] = (unsigned char)(i * 7);
	ghx_sha256_hex(b, sizeof b, orig);
	snprintf(path, sizeof path, "%s/snap.bin", dir);
	snprintf(other, sizeof other, "%s/other.bin", dir);

	write_file(path, b, sizeof b);
	r = (struct race){ path, other, 0 };
	rc = ghx_snapshot_read(path, 1 << 20, &s, err, sizeof err, mid, &r);
	CHECK(rc == 0 && strcmp(s.sha256, orig) == 0 && s.size == sizeof b, "stable snapshot");
	ghx_snapshot_free(&s);

	r.mode = 1;	/* in-place mutation during the read: reject */
	write_file(path, b, sizeof b);
	rc = ghx_snapshot_read(path, 1 << 20, &s, err, sizeof err, mid, &r);
	CHECK(rc == 5, "in-place mutation during read not rejected (rc=%d)", rc);
	ghx_snapshot_free(&s);

	r.mode = 2;	/* rename-over during the read: the descriptor keeps the old inode */
	write_file(path, b, sizeof b);
	b[0] ^= 0xff;
	write_file(other, b, sizeof b);
	b[0] ^= 0xff;
	rc = ghx_snapshot_read(path, 1 << 20, &s, err, sizeof err, mid, &r);
	CHECK(rc == 5 || (rc == 0 && strcmp(s.sha256, orig) == 0),
	      "rename-over during read produced a mixed identity (rc=%d)", rc);
	printf("rename-over during read: rc=%d (%s)\n", rc, rc ? err : "frozen original bytes");
	ghx_snapshot_free(&s);

	r.mode = 3;	/* growth during the read: reject */
	write_file(path, b, sizeof b);
	rc = ghx_snapshot_read(path, 1 << 20, &s, err, sizeof err, mid, &r);
	CHECK(rc == 5, "growth during read not rejected (rc=%d)", rc);
	ghx_snapshot_free(&s);

	CHECK(ghx_snapshot_read(dir, 1 << 20, &s, err, sizeof err, NULL, NULL) == 1, "directory accepted");
	write_file(path, b, sizeof b);
	CHECK(ghx_snapshot_read(path, 100, &s, err, sizeof err, NULL, NULL) == 4, "size limit ignored");
	unlink(path);
	unlink(other);
}

int main(int argc, char **argv)
{
	if (argc == 3 && strcmp(argv[1], "--selftest") == 0) {
		crafted();
		races(argv[2]);
		printf("elfcheck selftest: %d checks, %d failures\n", checks, fails);
		return fails ? 1 : 0;
	}
	if (argc < 2 || argc > 4) {
		fprintf(stderr, "usage: ghx_elfcheck PATH [ADDR [LEN]] | --selftest DIR\n");
		return 2;
	}
	struct ghx_elfid e;
	char err[256] = "";
	int rc = ghx_elfid_probe(argv[1], 512ull << 20, &e, err, sizeof err);
	uint64_t addr = argc > 2 ? strtoull(argv[2], NULL, 0) : e.entry;
	uint64_t len = argc > 3 ? strtoull(argv[3], NULL, 0) : 1;
	printf("probe_rc=%d file_size=%llu sha256=%s nload=%u exec_range=%d error=%s\n", rc,
	       (unsigned long long)e.file_size, e.sha256, e.nload, ghx_elfid_exec_range(&e, addr, len), err);
	return rc;
}
