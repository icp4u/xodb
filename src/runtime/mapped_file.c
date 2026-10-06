#define _GNU_SOURCE
#include "mapped_file.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#define XODB_BTRFS_SUPER_MAGIC 0x9123683e

/* Obtain the same device/inode representation as proc maps without reading
 * any file bytes. Btrfs getattr substitutes a per-subvolume st_dev, whereas
 * maps reports inode->i_sb->s_dev. Inode alone is not unique across subvolumes. */
static int mapping_identity(int fd, uint64_t ma, uint64_t mi, uint64_t ino)
{
    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0)
        return 0;
    void *address = mmap(NULL, (size_t)page, PROT_NONE, MAP_PRIVATE, fd, 0);
    if (address == MAP_FAILED)
        return 0;
    FILE *maps = fopen("/proc/self/maps", "re");
    int match = 0;
    if (maps) {
        char line[8192];
        for (unsigned i = 0; i < 65536 && fgets(line, sizeof line, maps); ++i) {
            unsigned long long start, end, offset, inode;
            unsigned major_number, minor_number;
            char permissions[5];
            if (sscanf(line, "%llx-%llx %4s %llx %x:%x %llu", &start, &end, permissions, &offset,
                       &major_number, &minor_number, &inode) != 7)
                continue;
            if (start <= (uintptr_t)address && (uintptr_t)address < end) {
                match = major_number == ma && minor_number == mi && inode == ino;
                break;
            }
        }
        fclose(maps);
    }
    munmap(address, (size_t)page);
    return match;
}

/* The candidate descriptor is already open and pins its inode while maps is
 * read. A matching live VMA therefore cannot refer to a freed inode whose
 * number the candidate later reused. This is an identity check at observation
 * time, not a promise that a running target keeps the mapping afterwards. */
static int mapping_present(int pid, uint64_t start, uint64_t end, uint64_t ma, uint64_t mi,
                           uint64_t ino)
{
    if (start >= end)
        return 0;
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/maps", pid);
    FILE *maps = fopen(path, "re");
    if (!maps)
        return 0;
    int match = 0;
    char line[8192];
    for (unsigned i = 0; i < 65536 && !match && fgets(line, sizeof line, maps); ++i) {
        unsigned long long s, e, offset, inode;
        unsigned major_number, minor_number;
        char permissions[5];
        if (sscanf(line, "%llx-%llx %4s %llx %x:%x %llu", &s, &e, permissions, &offset,
                   &major_number, &minor_number, &inode) == 7)
            match = s < end && start < e && major_number == ma && minor_number == mi &&
                    inode == ino;
    }
    fclose(maps);
    return match;
}

int xodb_mapped_file_matches(int fd, int pid, uint64_t start, uint64_t end, uint64_t ma,
                             uint64_t mi, uint64_t inode, int strict)
{
    struct stat candidate;
    if (fstat(fd, &candidate) || !S_ISREG(candidate.st_mode) || candidate.st_ino != inode)
        return 0;
    struct statfs fs;
    if (fstatfs(fd, &fs))
        return 0;
    if ((unsigned long)fs.f_type != XODB_BTRFS_SUPER_MAGIC)
        return major(candidate.st_dev) == ma && minor(candidate.st_dev) == mi &&
               (pid <= 0 || mapping_present(pid, start, end, ma, mi, inode));
    if (pid <= 0 || start >= end || !mapping_identity(fd, ma, mi, inode))
        return 0;

    char map_path[128];
    snprintf(map_path, sizeof map_path, "/proc/%d/map_files/%llx-%llx", pid,
             (unsigned long long)start, (unsigned long long)end);
    /* Pin the actual VMA backing object when permitted. This also works for
     * unlinked files and paths hidden by mount namespaces. */
    int mapped = open(map_path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (mapped >= 0) {
        struct stat actual;
        int match = !fstat(mapped, &actual) && actual.st_dev == candidate.st_dev &&
                    actual.st_ino == candidate.st_ino;
        close(mapped);
        return match;
    }
    if (strict)
        return 0;

    /* Unprivileged map_files readlink is permitted independently of opening
     * the link. Compare kernel-rendered paths, not a caller's filename, in
     * addition to normalized device and inode. In particular, a clone in a
     * different subvolume with the same inode must not pass this check. Reject
     * inaccessible/renamed/deleted paths rather than guessing from inode alone. */
    char fd_path[64], actual_path[8192], candidate_path[8192];
    snprintf(fd_path, sizeof fd_path, "/proc/self/fd/%d", fd);
    ssize_t a = readlink(map_path, actual_path, sizeof actual_path);
    ssize_t b = readlink(fd_path, candidate_path, sizeof candidate_path);
    return a > 0 && a < (ssize_t)sizeof actual_path && a == b &&
           !memcmp(actual_path, candidate_path, (size_t)a);
}
