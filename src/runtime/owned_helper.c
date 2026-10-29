/* The only way to create a child this process will wait for.
 * Noting happens before the parent runs another instruction of its own,
 * so a call site cannot spawn and forget. */
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>

bool xrt_note_owned_helper(int32_t pid);

int xrt_spawn_owned_helper(int32_t *pid, int (*create)(int32_t *pid, void *context), void *context)
{
    int rc;
    if (!pid || !create)
        return EINVAL;
    *pid = 0;
    rc = create(pid, context);
    if (rc == 0 && *pid > 1)
        xrt_note_owned_helper(*pid);
    return rc;
}
