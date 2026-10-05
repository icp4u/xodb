/* Private-display Vulkan fault and lifetime shim (LD_PRELOAD).
 *
 * xodb links libvulkan.so.1 directly and calls the loader's exported
 * trampolines, so a preloaded definition of the same symbol is reached first.
 * Faults and accounting are active only on an owned private test display (the
 * same gate as tests/vulkan-stall.c); otherwise every call passes through.
 *
 * XODB_VKFAULT is a ';'-separated rule list:
 *   devices=N|err|incomplete   physical device count (N>real repeats real devices)
 *   families=N                 queue family count (N>real repeats family 0)
 *   support=err:SUB|false:SUB  surface support query for devices named *SUB*
 *   noswap=SUB                 hide VK_KHR_swapchain on devices named *SUB*
 *   formats=0|err              surface formats
 *   alpha=0                    supportedCompositeAlpha
 *   minimages=N                minImageCount
 *   minextent=WxH maxextent=WxH curextent=WxH  surface extents
 *   memtypes=N[,nodevlocal]    memory properties
 *   fail=FUNC@N[xK|x*]:RESULT  the Nth call (K calls, or all from N) returns RESULT
 *   poison=1                   a failed create writes an invalid handle, which
 *                              the Vulkan spec permits ("undefined contents")
 * RESULT: lost oodm oohm init ext surface_lost out_of_date suboptimal timeout
 *         not_ready incomplete, or a number.
 *
 * Accounting (always on behind the gate): live handles by type, leaks at
 * vkDestroyDevice/vkDestroyInstance, destruction while a submission has no
 * observed completion, acquire into a still-pending semaphore and command
 * buffer reset while in flight. Lines begin "vkfault:"; a JSON summary is
 * printed at exit. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_wayland.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int gate = -1;
static int active(void) {
    if (gate < 0) {
        const char *p = getenv("XODB_TEST_PRIVATE_DISPLAY"), *r = getenv("XDG_RUNTIME_DIR");
        gate = p && !strcmp(p, "1") && r && strstr(r, "/.work/");
    }
    return gate;
}
static const char *rules(void) { const char *s = getenv("XODB_VKFAULT"); return s ? s : ""; }
/* Value of KEY in the rule list, copied to out; 0 when absent. */
static int rule(const char *key, char *out, size_t size) {
    const char *s = rules();
    size_t n = strlen(key);
    while (*s) {
        if (!strncmp(s, key, n) && s[n] == '=') {
            const char *v = s + n + 1, *e = strchr(v, ';');
            size_t len = e ? (size_t)(e - v) : strlen(v);
            if (len >= size) len = size - 1;
            memcpy(out, v, len); out[len] = 0;
            return 1;
        }
        s = strchr(s, ';');
        if (!s) break;
        ++s;
    }
    return 0;
}
static VkResult parse_result(const char *s) {
    static const struct { const char *name; VkResult r; } names[] = {
        {"lost", VK_ERROR_DEVICE_LOST}, {"oodm", VK_ERROR_OUT_OF_DEVICE_MEMORY}, {"oohm", VK_ERROR_OUT_OF_HOST_MEMORY},
        {"init", VK_ERROR_INITIALIZATION_FAILED}, {"ext", VK_ERROR_EXTENSION_NOT_PRESENT}, {"surface_lost", VK_ERROR_SURFACE_LOST_KHR},
        {"out_of_date", VK_ERROR_OUT_OF_DATE_KHR}, {"suboptimal", VK_SUBOPTIMAL_KHR}, {"timeout", VK_TIMEOUT},
        {"not_ready", VK_NOT_READY}, {"incomplete", VK_INCOMPLETE}, {"feature", VK_ERROR_FEATURE_NOT_PRESENT}};
    for (size_t i = 0; i < sizeof names / sizeof *names; ++i) if (!strcmp(s, names[i].name)) return names[i].r;
    return (VkResult)strtol(s, NULL, 0);
}

/* Per-function call counters. */
#define MAXF 96
static struct { const char *name; unsigned long calls, injected; } fns[MAXF];
static int nfns;
static unsigned long *counter(const char *name, unsigned long **inj) {
    for (int i = 0; i < nfns; ++i) if (!strcmp(fns[i].name, name)) { *inj = &fns[i].injected; return &fns[i].calls; }
    if (nfns == MAXF) abort();
    fns[nfns].name = name;
    *inj = &fns[nfns].injected;
    return &fns[nfns++].calls;
}
/* Returns 1 and sets *out when this call of FUNC is scheduled to fail. */
static int scheduled(const char *func, VkResult *out) {
    if (!active()) return 0;
    pthread_mutex_lock(&lock);
    unsigned long *inj, call = ++*counter(func, &inj);
    int hit = 0;
    const char *s = rules();
    size_t n = strlen(func);
    while ((s = strstr(s, "fail="))) {
        s += 5;
        if (!strncmp(s, func, n) && s[n] == '@') {
            char *e;
            unsigned long first = strtoul(s + n + 1, &e, 10), count = 1;
            if (*e == 'x') { if (e[1] == '*') { count = (unsigned long)-1; e += 2; } else count = strtoul(e + 1, &e, 10); }
            if (*e == ':' && call >= first && call - first < count) {
                char value[32]; size_t len = strcspn(e + 1, ";");
                if (len >= sizeof value) len = sizeof value - 1;
                memcpy(value, e + 1, len); value[len] = 0;
                *out = parse_result(value);
                hit = 1;
                ++*inj;
                fprintf(stderr, "vkfault: inject %s call %lu -> %d\n", func, call, *out);
                break;
            }
        }
    }
    pthread_mutex_unlock(&lock);
    return hit;
}
static int poison(void) { char v[8]; return rule("poison", v, sizeof v) && v[0] == '1'; }
#define POISON(ptr) do { if (poison()) memset((ptr), 0xb5, sizeof *(ptr)); } while (0)
#define REAL(name) static PFN_##name real; if (!real) real = (PFN_##name)dlsym(RTLD_NEXT, #name)

/* Object accounting. */
enum kind { K_INSTANCE, K_SURFACE, K_DEVICE, K_POOL, K_SEMAPHORE, K_FENCE, K_BUFFER, K_MEMORY, K_IMAGE, K_VIEW, K_SAMPLER,
            K_SETLAYOUT, K_DESCPOOL, K_LAYOUT, K_SWAPCHAIN, K_PASS, K_SHADER, K_PIPELINE, K_FRAMEBUFFER, K_KINDS };
static const char *kind_names[K_KINDS] = {"instance", "surface", "device", "command_pool", "semaphore", "fence", "buffer", "memory",
    "image", "image_view", "sampler", "descriptor_set_layout", "descriptor_pool", "pipeline_layout", "swapchain", "render_pass",
    "shader_module", "pipeline", "framebuffer"};
#define MAXO 8192
static struct { uint64_t h; int kind; int pending; } objs[MAXO];
static unsigned long created[K_KINDS], destroyed[K_KINDS], violations, leaks;
static int gpu_pending; /* a submission without observed completion */
static uint64_t pending_fence;
static VkCommandBuffer inflight_cb;
static void violation(const char *what, uint64_t h) {
    ++violations;
    fprintf(stderr, "vkfault: violation %s 0x%llx\n", what, (unsigned long long)h);
}
static void track(int kind, uint64_t h) {
    if (!active() || !h) return;
    pthread_mutex_lock(&lock);
    ++created[kind];
    for (int i = 0; i < MAXO; ++i) if (!objs[i].h) { objs[i].h = h; objs[i].kind = kind; objs[i].pending = 0; break; }
    pthread_mutex_unlock(&lock);
}
static int find(uint64_t h) { for (int i = 0; i < MAXO; ++i) if (objs[i].h == h) return i; return -1; }
static void untrack(int kind, uint64_t h) {
    if (!active() || !h) return;
    pthread_mutex_lock(&lock);
    int i = find(h);
    if (i < 0) violation("destroy of unknown or already destroyed handle", h);
    else {
        ++destroyed[kind];
        if (kind != K_INSTANCE && kind != K_SURFACE && kind != K_DEVICE && kind != K_SWAPCHAIN && kind != K_SHADER && gpu_pending)
            violation(kind_names[kind], h), fprintf(stderr, "vkfault: ^ destroyed while submitted work has no observed completion\n");
        objs[i].h = 0;
    }
    pthread_mutex_unlock(&lock);
}
static void complete(void) { gpu_pending = 0; inflight_cb = NULL; pending_fence = 0; }
static void leak_check(int device_children) {
    for (int i = 0; i < MAXO; ++i) {
        if (!objs[i].h) continue;
        int k = objs[i].kind;
        if (device_children ? (k != K_INSTANCE && k != K_SURFACE && k != K_DEVICE) : (k == K_SURFACE || k == K_DEVICE)) {
            ++leaks;
            fprintf(stderr, "vkfault: leak %s 0x%llx at %s\n", kind_names[k], (unsigned long long)objs[i].h, device_children ? "vkDestroyDevice" : "vkDestroyInstance");
            objs[i].h = 0;
        }
    }
}
__attribute__((destructor)) static void summary(void) {
    if (!active()) return;
    unsigned long live = 0;
    for (int i = 0; i < MAXO; ++i) if (objs[i].h) ++live;
    fprintf(stderr, "vkfault: summary {\"live_at_exit\":%lu,\"leaks\":%lu,\"violations\":%lu,\"created\":{", live, leaks, violations);
    for (int k = 0; k < K_KINDS; ++k) fprintf(stderr, "%s\"%s\":%lu", k ? "," : "", kind_names[k], created[k]);
    fprintf(stderr, "},\"calls\":{");
    for (int i = 0; i < nfns; ++i) fprintf(stderr, "%s\"%s\":[%lu,%lu]", i ? "," : "", fns[i].name, fns[i].calls, fns[i].injected);
    fprintf(stderr, "}}\n");
}

/* Generic create/destroy pairs on a device. */
#define CREATE(name, kind, Info, Handle) \
VKAPI_ATTR VkResult VKAPI_CALL name(VkDevice d, const Info *i, const VkAllocationCallbacks *a, Handle *out) { \
    REAL(name); VkResult r; \
    if (scheduled(#name, &r)) { POISON(out); return r; } \
    r = real(d, i, a, out); if (r == VK_SUCCESS) track(kind, (uint64_t)*out); return r; }
#define DESTROY(name, kind, Handle) \
VKAPI_ATTR void VKAPI_CALL name(VkDevice d, Handle h, const VkAllocationCallbacks *a) { \
    REAL(name); untrack(kind, (uint64_t)h); real(d, h, a); }
CREATE(vkCreateCommandPool, K_POOL, VkCommandPoolCreateInfo, VkCommandPool)
DESTROY(vkDestroyCommandPool, K_POOL, VkCommandPool)
CREATE(vkCreateSemaphore, K_SEMAPHORE, VkSemaphoreCreateInfo, VkSemaphore)
CREATE(vkCreateFence, K_FENCE, VkFenceCreateInfo, VkFence)
DESTROY(vkDestroyFence, K_FENCE, VkFence)
CREATE(vkCreateBuffer, K_BUFFER, VkBufferCreateInfo, VkBuffer)
DESTROY(vkDestroyBuffer, K_BUFFER, VkBuffer)
CREATE(vkCreateImage, K_IMAGE, VkImageCreateInfo, VkImage)
DESTROY(vkDestroyImage, K_IMAGE, VkImage)
CREATE(vkCreateImageView, K_VIEW, VkImageViewCreateInfo, VkImageView)
DESTROY(vkDestroyImageView, K_VIEW, VkImageView)
CREATE(vkCreateSampler, K_SAMPLER, VkSamplerCreateInfo, VkSampler)
DESTROY(vkDestroySampler, K_SAMPLER, VkSampler)
CREATE(vkCreateDescriptorSetLayout, K_SETLAYOUT, VkDescriptorSetLayoutCreateInfo, VkDescriptorSetLayout)
DESTROY(vkDestroyDescriptorSetLayout, K_SETLAYOUT, VkDescriptorSetLayout)
CREATE(vkCreateDescriptorPool, K_DESCPOOL, VkDescriptorPoolCreateInfo, VkDescriptorPool)
DESTROY(vkDestroyDescriptorPool, K_DESCPOOL, VkDescriptorPool)
CREATE(vkCreatePipelineLayout, K_LAYOUT, VkPipelineLayoutCreateInfo, VkPipelineLayout)
DESTROY(vkDestroyPipelineLayout, K_LAYOUT, VkPipelineLayout)
CREATE(vkCreateRenderPass, K_PASS, VkRenderPassCreateInfo, VkRenderPass)
DESTROY(vkDestroyRenderPass, K_PASS, VkRenderPass)
CREATE(vkCreateShaderModule, K_SHADER, VkShaderModuleCreateInfo, VkShaderModule)
DESTROY(vkDestroyShaderModule, K_SHADER, VkShaderModule)
CREATE(vkCreateFramebuffer, K_FRAMEBUFFER, VkFramebufferCreateInfo, VkFramebuffer)
DESTROY(vkDestroyFramebuffer, K_FRAMEBUFFER, VkFramebuffer)
DESTROY(vkDestroyPipeline, K_PIPELINE, VkPipeline)

/* Semaphores additionally track a pending signal from acquire or submit. */
VKAPI_ATTR void VKAPI_CALL vkDestroySemaphore(VkDevice d, VkSemaphore h, const VkAllocationCallbacks *a) {
    REAL(vkDestroySemaphore);
    untrack(K_SEMAPHORE, (uint64_t)h);
    real(d, h, a);
}
static void semaphore_state(VkSemaphore s, int pending, const char *where) {
    if (!active() || !s) return;
    pthread_mutex_lock(&lock);
    int i = find((uint64_t)s);
    if (i >= 0) {
        if (pending && objs[i].pending) violation(where, (uint64_t)s);
        objs[i].pending = pending;
    }
    pthread_mutex_unlock(&lock);
}

VKAPI_ATTR VkResult VKAPI_CALL vkCreateInstance(const VkInstanceCreateInfo *i, const VkAllocationCallbacks *a, VkInstance *out) {
    REAL(vkCreateInstance); VkResult r;
    if (scheduled("vkCreateInstance", &r)) { POISON(out); return r; }
    r = real(i, a, out); if (r == VK_SUCCESS) track(K_INSTANCE, (uint64_t)*out); return r;
}
VKAPI_ATTR void VKAPI_CALL vkDestroyInstance(VkInstance h, const VkAllocationCallbacks *a) {
    REAL(vkDestroyInstance);
    if (active() && h) { pthread_mutex_lock(&lock); leak_check(0); pthread_mutex_unlock(&lock); }
    untrack(K_INSTANCE, (uint64_t)h); real(h, a);
}
VKAPI_ATTR VkResult VKAPI_CALL vkCreateWaylandSurfaceKHR(VkInstance n, const VkWaylandSurfaceCreateInfoKHR *i, const VkAllocationCallbacks *a, VkSurfaceKHR *out) {
    REAL(vkCreateWaylandSurfaceKHR); VkResult r;
    if (scheduled("vkCreateWaylandSurfaceKHR", &r)) { POISON(out); return r; }
    r = real(n, i, a, out); if (r == VK_SUCCESS) track(K_SURFACE, (uint64_t)*out); return r;
}
VKAPI_ATTR void VKAPI_CALL vkDestroySurfaceKHR(VkInstance n, VkSurfaceKHR h, const VkAllocationCallbacks *a) {
    REAL(vkDestroySurfaceKHR); untrack(K_SURFACE, (uint64_t)h); real(n, h, a);
}
static int device_named(VkPhysicalDevice p, const char *sub) {
    PFN_vkGetPhysicalDeviceProperties props = (PFN_vkGetPhysicalDeviceProperties)dlsym(RTLD_NEXT, "vkGetPhysicalDeviceProperties");
    VkPhysicalDeviceProperties v;
    props(p, &v);
    return strstr(v.deviceName, sub) != NULL;
}
VKAPI_ATTR VkResult VKAPI_CALL vkCreateDevice(VkPhysicalDevice p, const VkDeviceCreateInfo *i, const VkAllocationCallbacks *a, VkDevice *out) {
    REAL(vkCreateDevice); VkResult r; char sub[128];
    if (scheduled("vkCreateDevice", &r)) { POISON(out); return r; }
    if (active() && rule("noswap", sub, sizeof sub) && device_named(p, sub))
        for (uint32_t e = 0; e < i->enabledExtensionCount; ++e)
            if (!strcmp(i->ppEnabledExtensionNames[e], VK_KHR_SWAPCHAIN_EXTENSION_NAME)) {
                fprintf(stderr, "vkfault: vkCreateDevice on device without VK_KHR_swapchain -> EXTENSION_NOT_PRESENT\n");
                POISON(out);
                return VK_ERROR_EXTENSION_NOT_PRESENT;
            }
    r = real(p, i, a, out);
    if (r == VK_SUCCESS) {
        track(K_DEVICE, (uint64_t)*out);
        if (active()) {
            PFN_vkGetPhysicalDeviceProperties props = (PFN_vkGetPhysicalDeviceProperties)dlsym(RTLD_NEXT, "vkGetPhysicalDeviceProperties");
            VkPhysicalDeviceProperties v; props(p, &v);
            fprintf(stderr, "vkfault: device created on \"%s\" type %d vendor 0x%x driver 0x%x api 0x%x\n", v.deviceName, v.deviceType, v.vendorID, v.driverVersion, v.apiVersion);
        }
    }
    return r;
}
VKAPI_ATTR void VKAPI_CALL vkDestroyDevice(VkDevice h, const VkAllocationCallbacks *a) {
    REAL(vkDestroyDevice);
    if (active() && h) { pthread_mutex_lock(&lock); leak_check(1); complete(); pthread_mutex_unlock(&lock); }
    untrack(K_DEVICE, (uint64_t)h); real(h, a);
}
VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateDeviceExtensionProperties(VkPhysicalDevice p, const char *layer, uint32_t *count, VkExtensionProperties *out) {
    REAL(vkEnumerateDeviceExtensionProperties); VkResult r; char sub[128];
    if (scheduled("vkEnumerateDeviceExtensionProperties", &r)) return r;
    r = real(p, layer, count, out);
    if (active() && !layer && rule("noswap", sub, sizeof sub) && device_named(p, sub) && out && (r == VK_SUCCESS || r == VK_INCOMPLETE)) {
        for (uint32_t e = 0; e < *count; ++e)
            if (!strcmp(out[e].extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME)) strcpy(out[e].extensionName, "VK_XODB_hidden_swapchain");
    }
    return r;
}
VKAPI_ATTR VkResult VKAPI_CALL vkCreateSwapchainKHR(VkDevice d, const VkSwapchainCreateInfoKHR *i, const VkAllocationCallbacks *a, VkSwapchainKHR *out) {
    REAL(vkCreateSwapchainKHR); VkResult r;
    if (active()) fprintf(stderr, "vkfault: swapchain request %ux%u images=%u alpha=0x%x old=%s\n", i->imageExtent.width, i->imageExtent.height, i->minImageCount, i->compositeAlpha, i->oldSwapchain ? "yes" : "no");
    if (scheduled("vkCreateSwapchainKHR", &r)) { POISON(out); return r; }
    r = real(d, i, a, out); if (r == VK_SUCCESS) track(K_SWAPCHAIN, (uint64_t)*out); return r;
}
VKAPI_ATTR void VKAPI_CALL vkDestroySwapchainKHR(VkDevice d, VkSwapchainKHR h, const VkAllocationCallbacks *a) {
    REAL(vkDestroySwapchainKHR); untrack(K_SWAPCHAIN, (uint64_t)h); real(d, h, a);
}
VKAPI_ATTR VkResult VKAPI_CALL vkAllocateMemory(VkDevice d, const VkMemoryAllocateInfo *i, const VkAllocationCallbacks *a, VkDeviceMemory *out) {
    REAL(vkAllocateMemory); VkResult r;
    if (scheduled("vkAllocateMemory", &r)) { POISON(out); return r; }
    r = real(d, i, a, out); if (r == VK_SUCCESS) track(K_MEMORY, (uint64_t)*out); return r;
}
VKAPI_ATTR void VKAPI_CALL vkFreeMemory(VkDevice d, VkDeviceMemory h, const VkAllocationCallbacks *a) {
    REAL(vkFreeMemory); untrack(K_MEMORY, (uint64_t)h); real(d, h, a);
}
static VkDeviceMemory mapped_memory;
VKAPI_ATTR VkResult VKAPI_CALL vkMapMemory(VkDevice d, VkDeviceMemory m, VkDeviceSize o, VkDeviceSize s, VkMemoryMapFlags f, void **out) {
    REAL(vkMapMemory); VkResult r;
    if (scheduled("vkMapMemory", &r)) { POISON(out); return r; }
    r = real(d, m, o, s, f, out); if (r == VK_SUCCESS) mapped_memory = m; return r;
}
VKAPI_ATTR void VKAPI_CALL vkUnmapMemory(VkDevice d, VkDeviceMemory m) {
    REAL(vkUnmapMemory);
    if (active() && m != mapped_memory) violation("unmap of memory that is not mapped", (uint64_t)m);
    mapped_memory = VK_NULL_HANDLE;
    real(d, m);
}
VKAPI_ATTR VkResult VKAPI_CALL vkCreateGraphicsPipelines(VkDevice d, VkPipelineCache c, uint32_t n, const VkGraphicsPipelineCreateInfo *i, const VkAllocationCallbacks *a, VkPipeline *out) {
    REAL(vkCreateGraphicsPipelines); VkResult r;
    if (scheduled("vkCreateGraphicsPipelines", &r)) { for (uint32_t k = 0; k < n; ++k) out[k] = VK_NULL_HANDLE; return r; }
    r = real(d, c, n, i, a, out);
    if (r == VK_SUCCESS) for (uint32_t k = 0; k < n; ++k) track(K_PIPELINE, (uint64_t)out[k]);
    return r;
}
VKAPI_ATTR VkResult VKAPI_CALL vkAllocateCommandBuffers(VkDevice d, const VkCommandBufferAllocateInfo *i, VkCommandBuffer *out) {
    REAL(vkAllocateCommandBuffers); VkResult r;
    if (scheduled("vkAllocateCommandBuffers", &r)) { for (uint32_t k = 0; k < i->commandBufferCount; ++k) out[k] = NULL; return r; }
    return real(d, i, out);
}
VKAPI_ATTR VkResult VKAPI_CALL vkAllocateDescriptorSets(VkDevice d, const VkDescriptorSetAllocateInfo *i, VkDescriptorSet *out) {
    REAL(vkAllocateDescriptorSets); VkResult r;
    if (scheduled("vkAllocateDescriptorSets", &r)) { for (uint32_t k = 0; k < i->descriptorSetCount; ++k) out[k] = VK_NULL_HANDLE; return r; }
    return real(d, i, out);
}
#define SIMPLE(name, Params, Args) \
VKAPI_ATTR VkResult VKAPI_CALL name Params { REAL(name); VkResult r; if (scheduled(#name, &r)) return r; return real Args; }
SIMPLE(vkBindBufferMemory, (VkDevice d, VkBuffer b, VkDeviceMemory m, VkDeviceSize o), (d, b, m, o))
SIMPLE(vkBindImageMemory, (VkDevice d, VkImage b, VkDeviceMemory m, VkDeviceSize o), (d, b, m, o))
SIMPLE(vkBeginCommandBuffer, (VkCommandBuffer b, const VkCommandBufferBeginInfo *i), (b, i))
SIMPLE(vkEndCommandBuffer, (VkCommandBuffer b), (b))

VKAPI_ATTR VkResult VKAPI_CALL vkResetCommandBuffer(VkCommandBuffer b, VkCommandBufferResetFlags f) {
    REAL(vkResetCommandBuffer); VkResult r;
    if (active() && b == inflight_cb && gpu_pending) violation("command buffer reset while in flight", (uint64_t)(uintptr_t)b);
    if (scheduled("vkResetCommandBuffer", &r)) return r;
    return real(b, f);
}
VKAPI_ATTR VkResult VKAPI_CALL vkResetFences(VkDevice d, uint32_t n, const VkFence *f) {
    REAL(vkResetFences); VkResult r;
    if (scheduled("vkResetFences", &r)) return r;
    return real(d, n, f);
}
VKAPI_ATTR VkResult VKAPI_CALL vkWaitForFences(VkDevice d, uint32_t n, const VkFence *f, VkBool32 all, uint64_t t) {
    REAL(vkWaitForFences); VkResult r;
    if (scheduled("vkWaitForFences", &r)) return r;
    r = real(d, n, f, all, t);
    if (active() && r == VK_SUCCESS) { pthread_mutex_lock(&lock); for (uint32_t k = 0; k < n; ++k) if ((uint64_t)f[k] == pending_fence) complete(); pthread_mutex_unlock(&lock); }
    return r;
}
VKAPI_ATTR VkResult VKAPI_CALL vkDeviceWaitIdle(VkDevice d) {
    REAL(vkDeviceWaitIdle); VkResult r;
    if (scheduled("vkDeviceWaitIdle", &r)) return r;
    r = real(d);
    if (active() && (r == VK_SUCCESS || r == VK_ERROR_DEVICE_LOST)) { pthread_mutex_lock(&lock); complete(); pthread_mutex_unlock(&lock); }
    return r;
}
VKAPI_ATTR VkResult VKAPI_CALL vkQueueSubmit(VkQueue q, uint32_t n, const VkSubmitInfo *s, VkFence f) {
    REAL(vkQueueSubmit); VkResult r;
    if (scheduled("vkQueueSubmit", &r)) return r;
    r = real(q, n, s, f);
    if (active() && r == VK_SUCCESS) {
        for (uint32_t k = 0; k < n; ++k) {
            for (uint32_t w = 0; w < s[k].waitSemaphoreCount; ++w) semaphore_state(s[k].pWaitSemaphores[w], 0, "");
            for (uint32_t w = 0; w < s[k].signalSemaphoreCount; ++w) semaphore_state(s[k].pSignalSemaphores[w], 1, "submit signals a semaphore with a pending signal");
        }
        pthread_mutex_lock(&lock);
        gpu_pending = 1; pending_fence = (uint64_t)f;
        if (n && s[0].commandBufferCount) inflight_cb = s[0].pCommandBuffers[0];
        pthread_mutex_unlock(&lock);
    }
    return r;
}
VKAPI_ATTR VkResult VKAPI_CALL vkAcquireNextImageKHR(VkDevice d, VkSwapchainKHR sw, uint64_t t, VkSemaphore s, VkFence f, uint32_t *index) {
    REAL(vkAcquireNextImageKHR); VkResult r;
    if (scheduled("vkAcquireNextImageKHR", &r)) {
        /* An injected SUBOPTIMAL is a successful acquire with a hint. */
        if (r != VK_SUBOPTIMAL_KHR) return r;
        r = real(d, sw, t, s, f, index);
        if (r == VK_SUCCESS) r = VK_SUBOPTIMAL_KHR;
    } else r = real(d, sw, t, s, f, index);
    if (r == VK_SUCCESS || r == VK_SUBOPTIMAL_KHR) semaphore_state(s, 1, "acquire into a semaphore with a pending signal");
    return r;
}
VKAPI_ATTR VkResult VKAPI_CALL vkQueuePresentKHR(VkQueue q, const VkPresentInfoKHR *p) {
    REAL(vkQueuePresentKHR); VkResult r;
    for (uint32_t w = 0; w < p->waitSemaphoreCount; ++w) semaphore_state(p->pWaitSemaphores[w], 0, "");
    if (scheduled("vkQueuePresentKHR", &r)) {
        if (r != VK_SUBOPTIMAL_KHR) return r;
        r = real(q, p);
        return r == VK_SUCCESS ? VK_SUBOPTIMAL_KHR : r;
    }
    return real(q, p);
}

/* Startup queries. */
VKAPI_ATTR VkResult VKAPI_CALL vkEnumeratePhysicalDevices(VkInstance n, uint32_t *count, VkPhysicalDevice *out) {
    REAL(vkEnumeratePhysicalDevices); VkResult r; char v[32];
    if (scheduled("vkEnumeratePhysicalDevices", &r)) return r;
    if (!active() || !rule("devices", v, sizeof v)) return real(n, count, out);
    if (!strcmp(v, "err")) return VK_ERROR_INITIALIZATION_FAILED;
    uint32_t actual = 0;
    if ((r = real(n, &actual, NULL)) != VK_SUCCESS) return r;
    if (!strcmp(v, "incomplete")) {
        if (!out) { *count = actual + 1; return VK_SUCCESS; }
        if (*count > actual) *count = actual;
        r = real(n, count, out);
        return r == VK_SUCCESS ? VK_INCOMPLETE : r;
    }
    uint32_t want = (uint32_t)strtoul(v, NULL, 0);
    if (!actual) { *count = 0; return VK_SUCCESS; }
    if (!out) { *count = want; return VK_SUCCESS; }
    VkPhysicalDevice real_devices[16];
    if (actual > 16) actual = 16;
    if ((r = real(n, &actual, real_devices)) != VK_SUCCESS && r != VK_INCOMPLETE) return r;
    uint32_t written = *count < want ? *count : want;
    for (uint32_t i = 0; i < written; ++i) out[i] = real_devices[i % actual];
    *count = written;
    return written < want ? VK_INCOMPLETE : VK_SUCCESS;
}
VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice p, uint32_t *count, VkQueueFamilyProperties *out) {
    REAL(vkGetPhysicalDeviceQueueFamilyProperties); char v[32];
    if (!active() || !rule("families", v, sizeof v)) { real(p, count, out); return; }
    uint32_t want = (uint32_t)strtoul(v, NULL, 0);
    if (!out) { *count = want; return; }
    VkQueueFamilyProperties first; uint32_t one = 1;
    real(p, &one, &first);
    uint32_t written = *count < want ? *count : want;
    for (uint32_t i = 0; i < written; ++i) out[i] = first;
    *count = written;
}
/* Record actual graphics+present candidates during a healthy baseline. The
 * renderer queries these only after confirming swapchain extension support. */
static void present_candidate(VkPhysicalDevice p, uint32_t family) {
    if (!active() || family >= 4096) return;
    PFN_vkGetPhysicalDeviceQueueFamilyProperties families = (PFN_vkGetPhysicalDeviceQueueFamilyProperties)dlsym(RTLD_NEXT, "vkGetPhysicalDeviceQueueFamilyProperties");
    PFN_vkGetPhysicalDeviceProperties properties = (PFN_vkGetPhysicalDeviceProperties)dlsym(RTLD_NEXT, "vkGetPhysicalDeviceProperties");
    uint32_t count = family + 1;
    VkQueueFamilyProperties *list = calloc(count, sizeof *list);
    if (!list) return;
    families(p, &count, list);
    if (count > family && (list[family].queueFlags & VK_QUEUE_GRAPHICS_BIT) && list[family].queueCount) {
        VkPhysicalDeviceProperties props;
        properties(p, &props);
        fprintf(stderr, "vkfault: present candidate %s\n", props.deviceName);
    }
    free(list);
}
VKAPI_ATTR VkResult VKAPI_CALL vkGetPhysicalDeviceSurfaceSupportKHR(VkPhysicalDevice p, uint32_t family, VkSurfaceKHR s, VkBool32 *out) {
    REAL(vkGetPhysicalDeviceSurfaceSupportKHR); VkResult r; char v[160];
    if (scheduled("vkGetPhysicalDeviceSurfaceSupportKHR", &r)) return r;
    if (active() && rule("support", v, sizeof v)) {
        char *colon = strchr(v, ':');
        if (colon && device_named(p, colon + 1)) {
            if (!strncmp(v, "err", 3)) { fprintf(stderr, "vkfault: surface support query fails on %s\n", colon + 1); return VK_ERROR_SURFACE_LOST_KHR; }
            *out = VK_FALSE;
            return VK_SUCCESS;
        }
    }
    r = real(p, family, s, out);
    if (r == VK_SUCCESS && *out) present_candidate(p, family);
    return r;
}
static void parse_extent(const char *key, VkExtent2D *e) {
    char v[32];
    if (!rule(key, v, sizeof v)) return;
    if (!strcmp(v, "max")) { e->width = e->height = UINT32_MAX; return; }
    char *x;
    e->width = (uint32_t)strtoul(v, &x, 0);
    e->height = *x == 'x' ? (uint32_t)strtoul(x + 1, NULL, 0) : e->width;
}
VKAPI_ATTR VkResult VKAPI_CALL vkGetPhysicalDeviceSurfaceCapabilitiesKHR(VkPhysicalDevice p, VkSurfaceKHR s, VkSurfaceCapabilitiesKHR *c) {
    REAL(vkGetPhysicalDeviceSurfaceCapabilitiesKHR); VkResult r; char v[32];
    if (scheduled("vkGetPhysicalDeviceSurfaceCapabilitiesKHR", &r)) return r;
    r = real(p, s, c);
    if (!active() || r != VK_SUCCESS) return r;
    static int traced;
    if (!traced++) fprintf(stderr, "vkfault: surface caps current=%ux%u min=%ux%u max=%ux%u images=%u..%u alpha=0x%x usage=0x%x transform=0x%x\n",
        c->currentExtent.width, c->currentExtent.height, c->minImageExtent.width, c->minImageExtent.height, c->maxImageExtent.width,
        c->maxImageExtent.height, c->minImageCount, c->maxImageCount, c->supportedCompositeAlpha, c->supportedUsageFlags, c->currentTransform);
    if (rule("alpha", v, sizeof v)) c->supportedCompositeAlpha = (uint32_t)strtoul(v, NULL, 0);
    if (rule("minimages", v, sizeof v)) c->minImageCount = (uint32_t)strtoul(v, NULL, 0);
    parse_extent("minextent", &c->minImageExtent);
    parse_extent("maxextent", &c->maxImageExtent);
    parse_extent("curextent", &c->currentExtent);
    return r;
}
VKAPI_ATTR VkResult VKAPI_CALL vkGetPhysicalDeviceSurfaceFormatsKHR(VkPhysicalDevice p, VkSurfaceKHR s, uint32_t *count, VkSurfaceFormatKHR *out) {
    REAL(vkGetPhysicalDeviceSurfaceFormatsKHR); VkResult r; char v[32];
    if (scheduled("vkGetPhysicalDeviceSurfaceFormatsKHR", &r)) return r;
    if (active() && rule("formats", v, sizeof v)) {
        if (!strcmp(v, "err")) return VK_ERROR_SURFACE_LOST_KHR;
        *count = 0;
        return VK_SUCCESS;
    }
    return real(p, s, count, out);
}
VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceMemoryProperties(VkPhysicalDevice p, VkPhysicalDeviceMemoryProperties *m) {
    REAL(vkGetPhysicalDeviceMemoryProperties); char v[32];
    real(p, m);
    if (!active() || !rule("memtypes", v, sizeof v)) return;
    /* N, nodevlocal, or N,nodevlocal. A count above VK_MAX_MEMORY_TYPES
     * is a driver fault; only the first 32 entries exist in the structure. */
    if (v[0] >= '0' && v[0] <= '9') m->memoryTypeCount = (uint32_t)strtoul(v, NULL, 0);
    if (strstr(v, "nodevlocal"))
        for (uint32_t i = 0; i < m->memoryTypeCount && i < VK_MAX_MEMORY_TYPES; ++i) m->memoryTypes[i].propertyFlags &= ~VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
}
