#ifndef XODB_MAPPED_FILE_H
#define XODB_MAPPED_FILE_H
#include <stdint.h>

/* Return 1 only for a verified backing file, 0 for mismatch/unavailable.
 * strict requires an exact kernel-held file on filesystems whose maps identity
 * is not unique across subvolumes; privileged probe creation uses this mode. */
int xodb_mapped_file_matches(int fd, int pid, uint64_t start, uint64_t end,
                             uint64_t device_major, uint64_t device_minor,
                             uint64_t inode, int strict);
#endif
