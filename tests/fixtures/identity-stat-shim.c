/* Exercise the Btrfs device-number representation on any test filesystem.
 * Only the candidate's stat view changes; proc maps remains kernel supplied. */
#define _GNU_SOURCE
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/sysmacros.h>
int xodb_test_stat(int fd, struct stat *value) {
    int result = fstat(fd, value);
    if (!result) value->st_dev = makedev(major(value->st_dev), minor(value->st_dev) + 128);
    return result;
}
int xodb_test_statfs(int fd, struct statfs *value) {
    int result = fstatfs(fd, value);
    if (!result) value->f_type = 0x9123683e;
    return result;
}
