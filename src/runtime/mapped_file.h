#ifndef XODB_MAPPED_FILE_H
#define XODB_MAPPED_FILE_H
#include <stddef.h>
#include <stdint.h>

/* File-backed rows of one whole /proc/PID/maps read. A snapshot may stand in
 * for a fresh read only while the process has stayed stopped since it was
 * taken: its VMAs then keep every listed inode alive, so a later descriptor
 * with the same device and inode is the same file. */
struct xodb_maps_row { uint64_t start, end, device_major, device_minor, inode; };
struct xodb_maps { struct xodb_maps_row *rows; size_t count; };
int xodb_maps_read(int pid, struct xodb_maps *out); /* 1 on success */
void xodb_maps_free(struct xodb_maps *);
/* Whole-file /proc/PID/maps reads made for another process so far. */
uint64_t xodb_maps_reads(void);

/* Return 1 for a matching backing file, 0 for mismatch/unavailable.
 * A positive pid requires an observable live mapping; exited or unreadable
 * address spaces are unavailable. With pid <= 0, non-btrfs callers get only a
 * device/inode comparison, which cannot authenticate a historical mapping.
 * strict requires an exact kernel-held file on filesystems whose maps identity
 * is not unique across subvolumes; privileged probe creation uses this mode. */
int xodb_mapped_file_matches(int fd, int pid, uint64_t start, uint64_t end, uint64_t device_major,
                             uint64_t device_minor, uint64_t inode, int strict);
/* Same, but a non-null snapshot of pid's maps replaces the per-call read. */
int xodb_mapped_file_matches_in(int fd, int pid, const struct xodb_maps *, uint64_t start,
                                uint64_t end, uint64_t device_major, uint64_t device_minor,
                                uint64_t inode, int strict);
#endif
