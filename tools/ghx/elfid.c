/* Strict, bounded ELF64 snapshot and identity. C01 candidate, GPLv3 as xodb.
 * Every header, table and segment offset is validated against the snapshot
 * size before use; all arithmetic on file-controlled values is overflow
 * checked.  See elfid.h. */
#define _GNU_SOURCE 1
#include "elfid.h"
#include "sha256.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static uint16_t g16(const unsigned char *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t g32(const unsigned char *p) { return g16(p) | (uint32_t)g16(p + 2) << 16; }
static uint64_t g64(const unsigned char *p) { return g32(p) | (uint64_t)g32(p + 4) << 32; }

static int inrange(uint64_t off, uint64_t len, uint64_t size)
{
	return off <= size && len <= size - off;
}

/* ------------------------------------------------------------ snapshot */

static int same_file(const struct stat *a, const struct stat *b)
{
	return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_size == b->st_size &&
	       a->st_nlink == b->st_nlink &&
	       a->st_mtim.tv_sec == b->st_mtim.tv_sec && a->st_mtim.tv_nsec == b->st_mtim.tv_nsec &&
	       a->st_ctim.tv_sec == b->st_ctim.tv_sec && a->st_ctim.tv_nsec == b->st_ctim.tv_nsec;
}

int ghx_snapshot_read(const char *path, uint64_t max_size, struct ghx_snapshot *s,
		      char *err, unsigned errlen, ghx_snapshot_hook mid, void *arg)
{
	struct stat a, b;
	uint64_t got = 0, half;
	unsigned char extra;
	int fd, rc = 0;

	memset(s, 0, sizeof *s);
	fd = open(path, O_RDONLY | O_CLOEXEC | O_NOCTTY);
	if (fd < 0) { snprintf(err, errlen, "cannot open: %s", strerror(errno)); return 1; }
	if (fstat(fd, &a) != 0 || !S_ISREG(a.st_mode)) {
		snprintf(err, errlen, "not a regular file");
		close(fd);
		return 1;
	}
	if ((uint64_t)a.st_size > max_size) {
		snprintf(err, errlen, "file size %llu exceeds limit %llu",
			 (unsigned long long)a.st_size, (unsigned long long)max_size);
		close(fd);
		return 4;
	}
	s->size = (uint64_t)a.st_size;
	s->bytes = malloc(s->size + 1);
	if (!s->bytes) { snprintf(err, errlen, "out of memory"); close(fd); return 1; }
	half = s->size / 2;
	while (got < s->size) {
		uint64_t want = s->size - got;
		ssize_t k;
		if (mid && got < half && want > half - got) want = half - got;
		k = read(fd, s->bytes + got, want > (1u << 30) ? (1u << 30) : (size_t)want);
		if (k < 0) {
			if (errno == EINTR) continue;
			snprintf(err, errlen, "read failed: %s", strerror(errno));
			rc = 1;
			goto out;
		}
		if (k == 0) { snprintf(err, errlen, "file shrank while being read"); rc = 5; goto out; }
		got += (uint64_t)k;
		if (mid && got == half) { mid(arg); mid = NULL; }
	}
	if (mid) mid(arg);	/* zero-length or tiny file: still honour the barrier */
	for (;;) {
		ssize_t k = read(fd, &extra, 1);
		if (k < 0 && errno == EINTR) continue;
		if (k != 0) { snprintf(err, errlen, "file grew while being read"); rc = 5; goto out; }
		break;
	}
	if (fstat(fd, &b) != 0 || !same_file(&a, &b)) {
		snprintf(err, errlen, "file changed while being read (size/inode/mtime/ctime differ)");
		rc = 5;
		goto out;
	}
	s->bytes[s->size] = 0;
	s->dev = (uint64_t)a.st_dev;
	s->ino = (uint64_t)a.st_ino;
	ghx_sha256_hex(s->bytes, s->size, s->sha256);
out:
	close(fd);
	if (rc) { free(s->bytes); s->bytes = NULL; s->size = 0; }
	return rc;
}

void ghx_snapshot_free(struct ghx_snapshot *s)
{
	free(s->bytes);
	memset(s, 0, sizeof *s);
}

/* ------------------------------------------------------------ identity */

static void notes(const unsigned char *b, uint64_t off, uint64_t len, struct ghx_elfid *o)
{
	uint64_t p = off, end = off + len;	/* caller checked inrange(off, len) */
	while (end - p >= 12) {
		uint32_t nsz = g32(b + p), dsz = g32(b + p + 4), typ = g32(b + p + 8);
		uint64_t nameo = p + 12, desco = nameo + ((nsz + 3ull) & ~3ull);
		uint64_t next = desco + ((dsz + 3ull) & ~3ull);
		if (next > end || next <= p) return;
		if (typ == 3 && nsz == 4 && memcmp(b + nameo, "GNU", 4) == 0 && dsz > 0 && dsz <= 64) {
			static const char x[] = "0123456789abcdef";
			for (uint32_t i = 0; i < dsz; i++) {
				o->build_id[2 * i] = x[b[desco + i] >> 4];
				o->build_id[2 * i + 1] = x[b[desco + i] & 15];
			}
			o->build_id[2 * dsz] = 0;
			return;
		}
		p = next;
	}
}

int ghx_elfid_parse(const unsigned char *b, uint64_t size, const char *sha256,
		    struct ghx_elfid *o, char *err, unsigned errlen)
{
	memset(o, 0, sizeof *o);
	o->file_size = size;
	if (sha256) snprintf(o->sha256, sizeof o->sha256, "%s", sha256);
	else ghx_sha256_hex(b, size, o->sha256);
	if (size < 64) { snprintf(err, errlen, "too small for ELF64 header"); return 2; }
	if (memcmp(b, "\177ELF", 4) != 0) { snprintf(err, errlen, "bad ELF magic"); return 2; }
	o->elf_class = b[4] == 2 ? 64 : b[4] == 1 ? 32 : 0;
	o->little_endian = b[5] == 1;
	if (o->elf_class != 64 || !o->little_endian) {
		snprintf(err, errlen, "unsupported ELF class/data (%u/%u)", b[4], b[5]);
		return 3;
	}
	o->type = g16(b + 16);
	o->machine = g16(b + 18);
	o->entry = g64(b + 24);
	if (o->machine != 62) { snprintf(err, errlen, "unsupported e_machine %u", o->machine); return 3; }

	uint64_t phoff = g64(b + 32), shoff = g64(b + 40);
	unsigned phentsize = g16(b + 54), phnum = g16(b + 56);
	unsigned shentsize = g16(b + 58), shnum = g16(b + 60), shstrndx = g16(b + 62);
	if (phnum == 0xffff) { snprintf(err, errlen, "extended program header numbering unsupported"); return 3; }
	if (phnum && (phentsize != 56 || !inrange(phoff, (uint64_t)phnum * 56, size))) {
		snprintf(err, errlen, "program header table out of bounds"); return 2;
	}
	if (shnum && (shentsize != 64 || !inrange(shoff, (uint64_t)shnum * 64, size))) {
		snprintf(err, errlen, "section header table out of bounds"); return 2;
	}
	if (phnum == 0 && shnum == 0) { snprintf(err, errlen, "no program or section headers"); return 2; }
	o->nsections = shnum;
	for (unsigned i = 0; i < phnum; i++) {
		const unsigned char *ph = b + phoff + 56ull * i;
		uint32_t type = g32(ph);
		if (type == 1) {	/* PT_LOAD */
			uint64_t off = g64(ph + 8), va = g64(ph + 16), fsz = g64(ph + 32), msz = g64(ph + 40);
			if (o->nload >= GHX_MAX_LOAD) {
				snprintf(err, errlen, "more than %d PT_LOAD segments", GHX_MAX_LOAD); return 3;
			}
			if (!inrange(off, fsz, size)) {
				snprintf(err, errlen, "PT_LOAD %u file range [0x%llx,+0x%llx) exceeds image size 0x%llx",
					 i, (unsigned long long)off, (unsigned long long)fsz, (unsigned long long)size);
				return 2;
			}
			if (fsz > msz) { snprintf(err, errlen, "PT_LOAD %u filesz > memsz", i); return 2; }
			if (va > UINT64_MAX - msz) { snprintf(err, errlen, "PT_LOAD %u vaddr+memsz overflows", i); return 2; }
			o->load[o->nload].flags = g32(ph + 4);
			o->load[o->nload].offset = off;
			o->load[o->nload].vaddr = va;
			o->load[o->nload].filesz = fsz;
			o->load[o->nload].memsz = msz;
			o->nload++;
		} else if (type == 4) {	/* PT_NOTE */
			uint64_t off = g64(ph + 8), sz = g64(ph + 32);
			if (inrange(off, sz, size) && !o->build_id[0]) notes(b, off, sz, o);
		}
	}
	for (unsigned i = 0; i < o->nload; i++)
		for (unsigned j = i + 1; j < o->nload; j++) {
			uint64_t a0 = o->load[i].vaddr, a1 = a0 + o->load[i].memsz;
			uint64_t b0 = o->load[j].vaddr, b1 = b0 + o->load[j].memsz;
			if (a0 < a1 && b0 < b1 && a0 < b1 && b0 < a1) {
				snprintf(err, errlen, "PT_LOAD %u and %u overlap", i, j); return 2;
			}
		}
	if (shnum && shstrndx < shnum) {
		const unsigned char *ss = b + shoff + 64ull * shstrndx;
		uint64_t stro = g64(ss + 24), strsz = g64(ss + 32);
		if (!inrange(stro, strsz, size)) { snprintf(err, errlen, "shstrtab out of bounds"); return 2; }
		for (unsigned i = 0; i < shnum; i++) {
			const unsigned char *sh = b + shoff + 64ull * i;
			uint32_t nm = g32(sh), typ = g32(sh + 4);
			const char *name;
			if (nm >= strsz) continue;
			name = (const char *)b + stro + nm;
			if (memchr(name, 0, strsz - nm) == NULL) continue;
			if (typ == 2) o->has_symtab = 1;
			if (typ == 11) o->has_dynsym = 1;
			if (strcmp(name, ".debug_info") == 0) o->has_debug_info = 1;
			if (typ == 7 && !o->build_id[0]) {
				uint64_t off = g64(sh + 24), sz = g64(sh + 32);
				if (inrange(off, sz, size)) notes(b, off, sz, o);
			}
		}
	}
	return 0;
}

int ghx_elfid_probe(const char *path, uint64_t max_size, struct ghx_elfid *o, char *err, unsigned errlen)
{
	struct ghx_snapshot s;
	int rc = ghx_snapshot_read(path, max_size, &s, err, errlen, NULL, NULL);
	if (rc) { memset(o, 0, sizeof *o); return rc; }
	rc = ghx_elfid_parse(s.bytes, s.size, s.sha256, o, err, errlen);
	if (rc) {
		/* a rejected image has no usable segment table */
		uint64_t fs = o->file_size;
		char h[65];
		memcpy(h, o->sha256, sizeof h);
		memset(o, 0, sizeof *o);
		o->file_size = fs;
		memcpy(o->sha256, h, sizeof h);
	}
	ghx_snapshot_free(&s);
	return rc;
}

int ghx_elfid_exec_range(const struct ghx_elfid *e, uint64_t addr, uint64_t len)
{
	if (len == 0) len = 1;
	for (unsigned i = 0; i < e->nload; i++) {
		uint64_t v = e->load[i].vaddr, n = e->load[i].filesz;
		if (!(e->load[i].flags & 1)) continue;	/* PF_X */
		if (addr >= v && addr - v < n && len <= n - (addr - v)) return 1;
	}
	return 0;
}

int ghx_elf_byte(const struct ghx_elfid *e, const unsigned char *b, uint64_t addr, unsigned char *v)
{
	for (unsigned i = 0; i < e->nload; i++) {
		uint64_t va = e->load[i].vaddr;
		if (addr < va || addr - va >= e->load[i].memsz) continue;
		if (addr - va < e->load[i].filesz) { *v = b[e->load[i].offset + (addr - va)]; return 1; }
		*v = 0;
		return 0;
	}
	return -1;
}

int ghx_elf_readonly(const struct ghx_elfid *e, uint64_t addr)
{
	for (unsigned i = 0; i < e->nload; i++) {
		uint64_t va = e->load[i].vaddr;
		if (addr >= va && addr - va < e->load[i].memsz) return !(e->load[i].flags & 2);
	}
	return 0;
}

/* ------------------------------------------------------------ sections */

struct secs {
	const unsigned char *b;
	uint64_t size, shoff, stro, strsz;
	unsigned shnum;
};

static int secs_open(struct secs *s, const unsigned char *b, uint64_t size, char *err, unsigned errlen)
{
	memset(s, 0, sizeof *s);
	s->b = b;
	s->size = size;
	if (size < 64) { snprintf(err, errlen, "too small"); return -1; }
	s->shoff = g64(b + 40);
	s->shnum = g16(b + 60);
	unsigned shstrndx = g16(b + 62);
	if (s->shnum == 0) return 0;
	if (g16(b + 58) != 64 || !inrange(s->shoff, (uint64_t)s->shnum * 64, size)) {
		snprintf(err, errlen, "section header table out of bounds"); return -1;
	}
	if (shstrndx < s->shnum) {
		const unsigned char *ss = b + s->shoff + 64ull * shstrndx;
		s->stro = g64(ss + 24);
		s->strsz = g64(ss + 32);
		if (!inrange(s->stro, s->strsz, size)) { snprintf(err, errlen, "shstrtab out of bounds"); return -1; }
	}
	return 0;
}

static const unsigned char *sh(const struct secs *s, unsigned i) { return s->b + s->shoff + 64ull * i; }

static const char *sec_name(const struct secs *s, unsigned i)
{
	uint32_t nm = g32(sh(s, i));
	if (nm >= s->strsz) return "";
	const char *n = (const char *)s->b + s->stro + nm;
	return memchr(n, 0, s->strsz - nm) ? n : "";
}

/* file-backed contents of section i, validated; NOBITS yields NULL */
static const unsigned char *sec_data(const struct secs *s, unsigned i, uint64_t *len)
{
	const unsigned char *h = sh(s, i);
	uint64_t off = g64(h + 24), sz = g64(h + 32);
	if (g32(h + 4) == 8 || !inrange(off, sz, s->size)) return NULL;
	*len = sz;
	return s->b + off;
}

static const char *strtab_get(const unsigned char *str, uint64_t strsz, uint32_t off)
{
	if (off >= strsz) return NULL;
	const char *n = (const char *)str + off;
	return memchr(n, 0, strsz - off) ? n : NULL;
}

int ghx_elf_symbols(const unsigned char *b, uint64_t size, ghx_sym_cb cb, void *arg,
		    char *err, unsigned errlen)
{
	struct secs s;
	if (secs_open(&s, b, size, err, errlen)) return -1;
	for (unsigned i = 0; i < s.shnum; i++) {
		const unsigned char *h = sh(&s, i);
		uint64_t symlen, strlen_;
		if (g32(h + 4) != 2) continue;	/* SHT_SYMTAB */
		const unsigned char *sym = sec_data(&s, i, &symlen);
		uint32_t link = g32(h + 40);
		uint64_t ent = g64(h + 56);
		if (!sym || (ent != 24 && ent != 0) || link >= s.shnum) {
			snprintf(err, errlen, ".symtab or its link out of bounds"); return -1;
		}
		const unsigned char *str = sec_data(&s, link, &strlen_);
		if (!str) { snprintf(err, errlen, ".strtab out of bounds"); return -1; }
		for (uint64_t k = 0; k + 24 <= symlen; k += 24) {
			const unsigned char *e = sym + k;
			unsigned type = e[4] & 15;
			uint16_t shndx = g16(e + 6);
			uint64_t val = g64(e + 8), sz = g64(e + 16);
			if ((type != 2 && type != 10) || shndx == 0 || val == 0) continue;
			const char *name = strtab_get(str, strlen_, g32(e));
			if (!name || !name[0]) continue;
			cb(arg, name, val, sz);
		}
	}
	return 0;
}

struct gotname { uint64_t got; const char *name; };

static int cmp_got(const void *a, const void *b)
{
	uint64_t x = ((const struct gotname *)a)->got, y = ((const struct gotname *)b)->got;
	return (x > y) - (x < y);
}

int ghx_elf_plt_imports(const unsigned char *b, uint64_t size, ghx_import_cb cb, void *arg,
			char *err, unsigned errlen)
{
	struct secs s;
	struct gotname *map = NULL;
	size_t nmap = 0, cap = 0;
	int found = 0;
	if (secs_open(&s, b, size, err, errlen)) return -1;
	/* GOT slot -> imported symbol name from every RELA table linked to a DYNSYM */
	for (unsigned i = 0; i < s.shnum; i++) {
		const unsigned char *h = sh(&s, i);
		uint64_t rlen, symlen, strl;
		if (g32(h + 4) != 4) continue;	/* SHT_RELA */
		uint32_t link = g32(h + 40);
		if (link >= s.shnum || g32(sh(&s, link) + 4) != 11) continue;	/* not .dynsym */
		const unsigned char *rel = sec_data(&s, i, &rlen);
		const unsigned char *sym = sec_data(&s, link, &symlen);
		uint32_t strlink = g32(sh(&s, link) + 40);
		const unsigned char *str = strlink < s.shnum ? sec_data(&s, strlink, &strl) : NULL;
		if (!rel || !sym || !str) { snprintf(err, errlen, "relocation/dynsym/dynstr out of bounds"); free(map); return -1; }
		for (uint64_t k = 0; k + 24 <= rlen; k += 24) {
			uint64_t off = g64(rel + k), info = g64(rel + k + 8);
			uint32_t type = (uint32_t)info, symi = (uint32_t)(info >> 32);
			if (type != 7 && type != 6) continue;	/* JUMP_SLOT, GLOB_DAT */
			if (symi == 0 || (uint64_t)symi * 24 + 24 > symlen) continue;
			const char *name = strtab_get(str, strl, g32(sym + (uint64_t)symi * 24));
			if (!name || !name[0]) continue;
			if (nmap == cap) {
				size_t nc = cap ? cap * 2 : 64;
				struct gotname *m;
				if (nc > 65536) { snprintf(err, errlen, "too many import relocations"); free(map); return -1; }
				m = realloc(map, nc * sizeof *m);
				if (!m) { snprintf(err, errlen, "out of memory"); free(map); return -1; }
				map = m;
				cap = nc;
			}
			map[nmap].got = off;
			map[nmap].name = name;
			nmap++;
		}
	}
	if (nmap) qsort(map, nmap, sizeof *map, cmp_got);
	static const char *const plts[] = { ".plt", ".plt.sec", ".plt.got" };
	for (unsigned p = 0; p < 3 && nmap; p++)
		for (unsigned i = 0; i < s.shnum; i++) {
			const unsigned char *h = sh(&s, i);
			uint64_t len, ent, addr = g64(h + 16);
			if (strcmp(sec_name(&s, i), plts[p]) != 0) continue;
			const unsigned char *d = sec_data(&s, i, &len);
			if (!d) continue;
			ent = g64(h + 56);
			if (ent != 8 && ent != 16) ent = 16;
			if (addr > UINT64_MAX - len) continue;
			for (uint64_t k = 0; k + ent <= len; k += ent) {
				static const unsigned pos[] = { 0, 1, 4, 5 };
				for (unsigned q = 0; q < 4; q++) {
					uint64_t at = k + pos[q];
					if (at + 6 > k + ent) break;
					if (d[at] != 0xff || d[at + 1] != 0x25) continue;
					if (pos[q] == 1 && d[k] != 0xf2) continue;
					if (pos[q] >= 4 && !(d[k] == 0xf3 && d[k + 1] == 0x0f && d[k + 2] == 0x1e && d[k + 3] == 0xfa)) continue;
					if (pos[q] == 5 && d[k + 4] != 0xf2) continue;
					int32_t disp = (int32_t)g32(d + at + 2);
					uint64_t got = addr + at + 6 + (uint64_t)(int64_t)disp;
					struct gotname key = { got, NULL }, *hit = bsearch(&key, map, nmap, sizeof *map, cmp_got);
					if (hit) { cb(arg, hit->name, addr + k, got, plts[p]); found++; }
					break;
				}
			}
		}
	free(map);
	return found;
}
