/* Private-display regression: fail one submission after the frame fence was
 * reset. This tests renderer recreation, not a real hardware device loss. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <vulkan/vulkan.h>

VKAPI_ATTR VkResult VKAPI_CALL vkQueueSubmit(VkQueue queue, uint32_t count,
                                            const VkSubmitInfo *submits, VkFence fence) {
    static unsigned calls;
    static PFN_vkQueueSubmit real_submit;
    if (!real_submit) real_submit = (PFN_vkQueueSubmit)dlsym(RTLD_NEXT, "vkQueueSubmit");
    if (++calls == 2) {
        fprintf(stderr, "xodb test: injecting submit failure\n");
        return VK_ERROR_DEVICE_LOST;
    }
    return real_submit(queue, count, submits, fence);
}
