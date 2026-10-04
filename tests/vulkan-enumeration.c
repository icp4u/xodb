#define _GNU_SOURCE
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* Real driver objects repeated to exercise counts beyond the old fixed arrays.
 * The first format query deliberately underestimates the next enumeration. */
VKAPI_ATTR VkResult VKAPI_CALL vkGetPhysicalDeviceSurfaceFormatsKHR(
    VkPhysicalDevice device, VkSurfaceKHR surface, uint32_t *count, VkSurfaceFormatKHR *out) {
    PFN_vkGetPhysicalDeviceSurfaceFormatsKHR real = dlsym(RTLD_NEXT, "vkGetPhysicalDeviceSurfaceFormatsKHR");
    static unsigned queries;
    if (!out) { *count = queries++ ? 96 : 80; return VK_SUCCESS; }
    VkSurfaceFormatKHR first; uint32_t one = 1;
    VkResult result = real(device, surface, &one, &first);
    if (result != VK_SUCCESS && result != VK_INCOMPLETE) return result;
    if (!one) return VK_ERROR_INITIALIZATION_FAILED;
    uint32_t written = *count < 96 ? *count : 96;
    for (uint32_t i = 0; i < written; ++i) out[i] = first;
    *count = written;
    fprintf(stderr, "enumeration-test: formats=%u %s\n", written, written < 96 ? "incomplete" : "complete");
    return written < 96 ? VK_INCOMPLETE : VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkGetSwapchainImagesKHR(
    VkDevice device, VkSwapchainKHR swapchain, uint32_t *count, VkImage *out) {
    PFN_vkGetSwapchainImagesKHR real = dlsym(RTLD_NEXT, "vkGetSwapchainImagesKHR");
    uint32_t actual = 0;
    VkResult result = real(device, swapchain, &actual, NULL);
    if (result != VK_SUCCESS || !actual) return result;
    uint32_t total = actual > 24 ? actual : 24;
    if (!out) { *count = total; return VK_SUCCESS; }
    VkImage *images = calloc(actual, sizeof *images);
    if (!images) return VK_ERROR_OUT_OF_HOST_MEMORY;
    result = real(device, swapchain, &actual, images);
    if (result == VK_SUCCESS) {
        uint32_t written = *count < total ? *count : total;
        for (uint32_t i = 0; i < written; ++i) out[i] = images[i % actual];
        *count = written;
        fprintf(stderr, "enumeration-test: images=%u\n", written);
        result = written < total ? VK_INCOMPLETE : VK_SUCCESS;
    }
    free(images);
    return result;
}
