/* Strict, bounded ELF64 snapshot and identity. C01 candidate, GPLv3 as xodb.
 *
 * All parsing works on one immutable in-memory snapshot of the file.  A
 * snapshot is taken through a single open file descriptor and is rejected if
 * the file changed while it was read.  Nothing here reopens a path. */
#ifndef GHX_ELFID_H
#define GHX_ELFID_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define GHX_MAX_LOAD 32

/* ---- snapshot ---------------------------------------------------------- */

struct ghx_snapshot {
	unsigned char *bytes;	/* owned; size bytes (+1 NUL guard) */
	uint64_t size;
	char sha256[65];	/* of exactly bytes[0..size) */
	uint64_t dev, ino;	/* diagnostic only, never identity */
};

/* Optional test barrier, called once after the first half of the file has
 * been read (NULL in production). */
typedef void (*ghx_snapshot_hook)(void *arg);

/* returns 0 ok; otherwise writes reason and returns:
 * 1 io error, 4 too large, 5 unstable (changed while being read) */
int ghx_snapshot_read(const char *path, uint64_t max_size, struct ghx_snapshot *s,
		      char *err, unsigned errlen, ghx_snapshot_hook mid, void *arg);
void ghx_snapshot_free(struct ghx_snapshot *s);

/* ---- ELF identity ------------------------------------------------------ */

struct ghx_elfid {
	char sha256[65];
	uint64_t file_size;
	int elf_class;		/* 64 */
	int little_endian;
	unsigned machine;	/* e_machine */
	unsigned type;		/* e_type */
	uint64_t entry;
	char build_id[129];	/* hex, "" if none */
	int has_symtab;		/* .symtab section present */
	int has_dynsym;
	int has_debug_info;	/* .debug_info present */
	unsigned nsections;
	unsigned nload;		/* PT_LOAD segments (all of them; more than GHX_MAX_LOAD is rejected) */
	struct { uint64_t vaddr, memsz, filesz, offset; unsigned flags; } load[GHX_MAX_LOAD];
};

/* 1 if [addr, addr+len) lies inside the file-backed part [vaddr, vaddr+filesz)
 * of one PT_LOAD with PF_X; len 0 is treated as 1.  Overflow safe. */
int ghx_elfid_exec_range(const struct ghx_elfid *e, uint64_t addr, uint64_t len);

/* Parse a snapshot.  returns 0 ok; otherwise writes reason and returns:
 * 2 not ELF / malformed, 3 unsupported class/endian/machine/layout */
int ghx_elfid_parse(const unsigned char *b, uint64_t size, const char *sha256,
		    struct ghx_elfid *out, char *err, unsigned errlen);

/* Compatibility wrapper: snapshot + parse.  returns 0 ok; otherwise:
 * 1 io error, 2 malformed, 3 unsupported, 4 too large, 5 unstable */
int ghx_elfid_probe(const char *path, uint64_t max_size, struct ghx_elfid *out, char *err, unsigned errlen);

/* Byte at virtual address addr: 1 file byte (*v set), 0 bss (memsz tail, *v=0),
 * -1 unmapped. */
int ghx_elf_byte(const struct ghx_elfid *e, const unsigned char *b, uint64_t addr, unsigned char *v);
/* 1 if addr lies in a PT_LOAD without PF_W */
int ghx_elf_readonly(const struct ghx_elfid *e, uint64_t addr);

/* Defined STT_FUNC/STT_GNU_IFUNC symbols of .symtab, in table order.
 * Invalid tables are reported through err and yield -1; 0 otherwise. */
typedef void (*ghx_sym_cb)(void *arg, const char *name, uint64_t addr, uint64_t size);
int ghx_elf_symbols(const unsigned char *b, uint64_t size, ghx_sym_cb cb, void *arg,
		    char *err, unsigned errlen);

/* PLT stubs resolved through JUMP_SLOT/GLOB_DAT relocations and .dynsym.
 * Calls cb(arg, name, stub_addr, got_addr) in address order of the scan.
 * Returns number found, or -1 on a malformed table (err set). */
typedef void (*ghx_import_cb)(void *arg, const char *name, uint64_t stub, uint64_t got, const char *section);
int ghx_elf_plt_imports(const unsigned char *b, uint64_t size, ghx_import_cb cb, void *arg,
			char *err, unsigned errlen);

#ifdef __cplusplus
}
#endif
#endif
