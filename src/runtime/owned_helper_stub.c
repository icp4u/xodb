/* macOS has no in-session orphan reap and does not link family.c.
 * These definitions keep that link satisfied. A noted pid is not tracked. */
#include <stdbool.h>
#include <stdint.h>

bool xrt_note_owned_helper(int32_t pid)
{
    return pid > 1;
}

void xrt_drop_owned_helper(int32_t pid)
{
    (void)pid;
}
