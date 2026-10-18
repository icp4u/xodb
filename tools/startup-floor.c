/* The startup floor: the least a Wayland + Vulkan program can do before its
 * first frame. Connect, one registry roundtrip, an xdg toplevel and its first
 * configure, then a Vulkan instance, surface, device and swapchain; clear one
 * image, present it, and wait for the compositor's presentation feedback.
 *
 * It writes the same XODB_STARTUP_TRACE lines as xodb (see
 * src/startup_phases.zig), so scripts/startup-bench measures both the same
 * way. FLOOR_DEVICE=TEXT picks the first device whose name contains TEXT;
 * otherwise the first device that can present. FLOOR_IMAGES=N asks for N
 * swapchain images (default: the surface minimum).
 *
 * Build: scripts/startup-bench builds it (wayland-scanner for xdg-shell and
 * presentation-time, then cc -O2 ... -lwayland-client -lvulkan). */
#define _GNU_SOURCE
#define VK_USE_PLATFORM_WAYLAND_KHR 1
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <vulkan/vulkan.h>
#include "xdg-shell-client-protocol.h"
#include "presentation-time-client-protocol.h"

static uint64_t now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static void die(const char *what, int code)
{
    fprintf(stderr, "startup-floor: %s failed (%d)\n", what, code);
    exit(1);
}

static void trace(const char *line)
{
    const char *path = getenv("XODB_STARTUP_TRACE");
    if (!path) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return;
    if (write(fd, line, strlen(line)) < 0) {}
    close(fd);
}

static struct wl_compositor *compositor;
static struct xdg_wm_base *wm;
static struct wp_presentation *presentation;
static uint32_t clock_id;
static int configured, shown;

static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) { (void)data; xdg_wm_base_pong(base, serial); }
static const struct xdg_wm_base_listener wm_listener = { ping };
static void clockId(void *data, struct wp_presentation *p, uint32_t id) { (void)data; (void)p; clock_id = id; }
static const struct wp_presentation_listener presentation_listener = { clockId };

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version)
{
    (void)data; (void)version;
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    if (!strcmp(interface, "xdg_wm_base")) {
        wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    }
    if (!strcmp(interface, "wp_presentation")) {
        presentation = wl_registry_bind(registry, name, &wp_presentation_interface, 1);
        wp_presentation_add_listener(presentation, &presentation_listener, NULL);
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) { (void)data; (void)registry; (void)name; }
static const struct wl_registry_listener registry_listener = { global, removed };

static void surfaceConfigure(void *data, struct xdg_surface *surface, uint32_t serial) { (void)data; xdg_surface_ack_configure(surface, serial); configured = 1; }
static const struct xdg_surface_listener surface_listener = { surfaceConfigure };
static void topConfigure(void *data, struct xdg_toplevel *top, int32_t w, int32_t h, struct wl_array *states) { (void)data; (void)top; (void)w; (void)h; (void)states; }
static void topClose(void *data, struct xdg_toplevel *top) { (void)data; (void)top; }
static const struct xdg_toplevel_listener top_listener = { topConfigure, topClose, NULL, NULL };

static void fbOutput(void *data, struct wp_presentation_feedback *f, struct wl_output *o) { (void)data; (void)f; (void)o; }
static void fbPresented(void *data, struct wp_presentation_feedback *f, uint32_t hi, uint32_t lo, uint32_t nsec, uint32_t refresh, uint32_t shi, uint32_t slo, uint32_t flags)
{
    (void)data; (void)shi; (void)slo; (void)flags;
    char line[160];
    snprintf(line, sizeof line, "onscreen shown=%llu clock=%u refresh=%u received=%llu frame=1\n", (unsigned long long)((((uint64_t)hi << 32) | lo) * 1000000000u + nsec), clock_id, refresh, (unsigned long long)now());
    trace(line);
    wp_presentation_feedback_destroy(f);
    shown = 1;
}
static void fbDiscarded(void *data, struct wp_presentation_feedback *f)
{
    (void)data;
    char line[96];
    snprintf(line, sizeof line, "onscreen shown=0 clock=0 refresh=0 received=%llu frame=0\n", (unsigned long long)now());
    trace(line);
    wp_presentation_feedback_destroy(f);
    shown = 1;
}
static const struct wp_presentation_feedback_listener feedback_listener = { fbOutput, fbPresented, fbDiscarded };

#define CHECK(call) do { VkResult r_ = (call); if (r_ != VK_SUCCESS) die(#call, r_); } while (0)

int main(void)
{
    uint64_t t_main = now(), t[8] = {0};
    t[0] = now();
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) die("wl_display_connect", 0);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !compositor || !wm) die("registry", 0);
    t[1] = now();
    struct wl_surface *surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm, surface);
    xdg_surface_add_listener(xs, &surface_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_title(top, "startup-floor");
    wl_surface_commit(surface);
    while (!configured) if (wl_display_dispatch(display) < 0) die("configure", 0);
    t[2] = now();

    const char *ext[] = { "VK_KHR_surface", "VK_KHR_wayland_surface" };
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "startup-floor", .apiVersion = VK_API_VERSION_1_0 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app, .enabledExtensionCount = 2, .ppEnabledExtensionNames = ext };
    VkInstance instance;
    CHECK(vkCreateInstance(&ici, NULL, &instance));
    t[3] = now();
    VkWaylandSurfaceCreateInfoKHR sci = { .sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR, .display = display, .surface = surface };
    VkSurfaceKHR vs;
    CHECK(vkCreateWaylandSurfaceKHR(instance, &sci, NULL, &vs));
    uint32_t n = 16;
    VkPhysicalDevice devices[16];
    VkResult er = vkEnumeratePhysicalDevices(instance, &n, devices);
    if (er != VK_SUCCESS && er != VK_INCOMPLETE) die("vkEnumeratePhysicalDevices", er);
    const char *want = getenv("FLOOR_DEVICE");
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    uint32_t family = 0;
    for (uint32_t i = 0; i < n && !physical; i++) {
        VkPhysicalDeviceProperties props;
        vkGetPhysicalDeviceProperties(devices[i], &props);
        if (want && !strstr(props.deviceName, want)) continue;
        uint32_t nf = 16;
        VkQueueFamilyProperties families[16];
        vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &nf, families);
        for (uint32_t f = 0; f < nf; f++) {
            VkBool32 ok = 0;
            if (vkGetPhysicalDeviceSurfaceSupportKHR(devices[i], f, vs, &ok) != VK_SUCCESS || !ok || !(families[f].queueFlags & VK_QUEUE_GRAPHICS_BIT)) continue;
            physical = devices[i];
            family = f;
            break;
        }
    }
    if (!physical) die("no presenting device", 0);
    float priority = 1;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority };
    const char *dext[] = { "VK_KHR_swapchain" };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci, .enabledExtensionCount = 1, .ppEnabledExtensionNames = dext };
    VkDevice device;
    CHECK(vkCreateDevice(physical, &dci, NULL, &device));
    VkQueue queue;
    vkGetDeviceQueue(device, family, 0, &queue);
    t[4] = now();

    VkSurfaceCapabilitiesKHR caps;
    CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, vs, &caps));
    uint32_t nfmt = 32;
    VkSurfaceFormatKHR formats[32];
    VkResult fr = vkGetPhysicalDeviceSurfaceFormatsKHR(physical, vs, &nfmt, formats);
    if ((fr != VK_SUCCESS && fr != VK_INCOMPLETE) || nfmt == 0) die("surface formats", fr);
    uint32_t images = caps.minImageCount;
    if (getenv("FLOOR_IMAGES")) images = (uint32_t)atoi(getenv("FLOOR_IMAGES"));
    if (images < caps.minImageCount) images = caps.minImageCount;
    if (caps.maxImageCount && images > caps.maxImageCount) images = caps.maxImageCount;
    VkExtent2D extent = caps.currentExtent.width != UINT32_MAX ? caps.currentExtent : (VkExtent2D){ 1280, 800 };
    VkSwapchainCreateInfoKHR swci = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .surface = vs, .minImageCount = images,
        .imageFormat = formats[0].format, .imageColorSpace = formats[0].colorSpace, .imageExtent = extent,
        .imageArrayLayers = 1, .imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT, .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform, .compositeAlpha = caps.supportedCompositeAlpha & -caps.supportedCompositeAlpha,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR, .clipped = VK_TRUE,
    };
    VkSwapchainKHR swap;
    CHECK(vkCreateSwapchainKHR(device, &swci, NULL, &swap));
    uint32_t count = 8;
    VkImage image[8];
    VkResult ir = vkGetSwapchainImagesKHR(device, swap, &count, image);
    if (ir != VK_SUCCESS && ir != VK_INCOMPLETE) die("vkGetSwapchainImagesKHR", ir);
    t[5] = now();

    VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family };
    VkCommandPool pool;
    CHECK(vkCreateCommandPool(device, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer cmd;
    CHECK(vkAllocateCommandBuffers(device, &cai, &cmd));
    VkSemaphoreCreateInfo semi = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    VkSemaphore acquired, done;
    CHECK(vkCreateSemaphore(device, &semi, NULL, &acquired));
    CHECK(vkCreateSemaphore(device, &semi, NULL, &done));
    uint32_t index;
    CHECK(vkAcquireNextImageKHR(device, swap, UINT64_MAX, acquired, VK_NULL_HANDLE, &index));
    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    CHECK(vkBeginCommandBuffer(cmd, &bi));
    VkImageSubresourceRange range = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    VkImageMemoryBarrier b = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = image[index], .subresourceRange = range };
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b);
    VkClearColorValue color = { .float32 = { 0.043f, 0.059f, 0.086f, 1 } };
    vkCmdClearColorImage(cmd, image[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
    b.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    b.dstAccessMask = 0;
    b.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    b.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1, &b);
    CHECK(vkEndCommandBuffer(cmd));
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1, .pWaitSemaphores = &acquired, .pWaitDstStageMask = &stage, .commandBufferCount = 1, .pCommandBuffers = &cmd, .signalSemaphoreCount = 1, .pSignalSemaphores = &done };
    uint64_t t_draw = now();
    CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
    if (presentation) {
        struct wp_presentation_feedback *f = wp_presentation_feedback(presentation, surface);
        wp_presentation_feedback_add_listener(f, &feedback_listener, NULL);
    }
    VkPresentInfoKHR pi = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .waitSemaphoreCount = 1, .pWaitSemaphores = &done, .swapchainCount = 1, .pSwapchains = &swap, .pImageIndices = &index };
    VkResult pr = vkQueuePresentKHR(queue, &pi);
    if (pr != VK_SUCCESS && pr != VK_SUBOPTIMAL_KHR) die("vkQueuePresentKHR", pr);
    uint64_t t_present = now();
    char line[512];
    /* Same fields as xodb: phases are exclusive microseconds. Here "window"
     * covers surface creation to configure, "device" includes surface and
     * enumeration, "swapchain" the swapchain and its images, "draw" submit and present. */
    snprintf(line, sizeof line, "present main=%llu configured=%llu present=%llu connect=%llu window=%llu instance=%llu device=%llu swapchain=%llu draw=%llu\n",
        (unsigned long long)t_main, (unsigned long long)t[2], (unsigned long long)t_present,
        (unsigned long long)((t[1] - t[0]) / 1000), (unsigned long long)((t[2] - t[1]) / 1000), (unsigned long long)((t[3] - t[2]) / 1000),
        (unsigned long long)((t[4] - t[3]) / 1000), (unsigned long long)((t[5] - t[4]) / 1000), (unsigned long long)((t_present - t_draw) / 1000));
    trace(line);
    uint64_t deadline = now() + 500000000u;
    while (presentation && !shown && now() < deadline) {
        while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
        wl_display_flush(display);
        struct pollfd p = { wl_display_get_fd(display), POLLIN, 0 };
        if (poll(&p, 1, 50) > 0) wl_display_read_events(display); else wl_display_cancel_read(display);
        wl_display_dispatch_pending(display);
    }
    vkDeviceWaitIdle(device);
    vkDestroySemaphore(device, done, NULL);
    vkDestroySemaphore(device, acquired, NULL);
    vkDestroyCommandPool(device, pool, NULL);
    vkDestroySwapchainKHR(device, swap, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroySurfaceKHR(instance, vs, NULL);
    vkDestroyInstance(instance, NULL);
    xdg_toplevel_destroy(top);
    xdg_surface_destroy(xs);
    wl_surface_destroy(surface);
    wl_display_disconnect(display);
    return 0;
}
