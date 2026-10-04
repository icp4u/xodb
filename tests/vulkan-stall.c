/* Owned private-display tests: trace real waits or withhold readiness without
 * touching Vulkan state. An infinite timeout blocks until the gate is removed. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <vulkan/vulkan.h>
static int gated(void) {
    const char *private = getenv("XODB_TEST_PRIVATE_DISPLAY");
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    const char *gate = getenv("XODB_TEST_VULKAN_GATE");
    return private && !strcmp(private,"1") && runtime && strstr(runtime,"/.work/") && gate && access(gate,F_OK)==0;
}
static const char *mode(void) { const char *s=getenv("XODB_TEST_VULKAN_MODE");return s?s:"trace"; }
static int inject(const char *operation, uint64_t timeout) {
    if (!gated() || strcmp(mode(),operation)) return 0;
    static int announced;
    if (!announced++) fprintf(stderr,"test: withholding %s readiness; timeout=%llu\n",operation,(unsigned long long)timeout);
    if (timeout==UINT64_MAX) { while(gated()) usleep(1000);return 0; }
    if (timeout>10000000) { fprintf(stderr,"test: excessive frame wait timeout\n");abort(); }
    return 1;
}
static void trace(const char *stage) {
    if (getenv("XODB_TEST_PRIVATE_DISPLAY") && !strcmp(mode(),"trace")) fprintf(stderr,"test: %s\n",stage);
}
VKAPI_ATTR VkResult VKAPI_CALL vkWaitForFences(VkDevice d,uint32_t n,const VkFence *f,VkBool32 all,uint64_t timeout) {
    PFN_vkWaitForFences real=(PFN_vkWaitForFences)dlsym(RTLD_NEXT,"vkWaitForFences");
    if(inject("fence",timeout))return VK_TIMEOUT;
    trace("enter fence");VkResult r=real(d,n,f,all,timeout);trace("leave fence");return r;
}
VKAPI_ATTR VkResult VKAPI_CALL vkAcquireNextImageKHR(VkDevice d,VkSwapchainKHR s,uint64_t timeout,VkSemaphore sem,VkFence f,uint32_t *index) {
    PFN_vkAcquireNextImageKHR real=(PFN_vkAcquireNextImageKHR)dlsym(RTLD_NEXT,"vkAcquireNextImageKHR");
    if(gated()&&!strcmp(mode(),"fence")){fprintf(stderr,"test: acquire after unready frame fence\n");abort();}
    if(inject("acquire",timeout)){static unsigned n;return (++n&1)?VK_TIMEOUT:VK_NOT_READY;}
    trace("enter acquire");VkResult r=real(d,s,timeout,sem,f,index);trace("leave acquire");return r;
}
VKAPI_ATTR VkResult VKAPI_CALL vkQueuePresentKHR(VkQueue q,const VkPresentInfoKHR *p) {
    PFN_vkQueuePresentKHR real=(PFN_vkQueuePresentKHR)dlsym(RTLD_NEXT,"vkQueuePresentKHR");
    trace("enter present");VkResult r=real(q,p);trace("leave present");return r;
}
VKAPI_ATTR VkResult VKAPI_CALL vkDeviceWaitIdle(VkDevice d) {
    PFN_vkDeviceWaitIdle real=(PFN_vkDeviceWaitIdle)dlsym(RTLD_NEXT,"vkDeviceWaitIdle");
    trace("enter device idle");VkResult r=real(d);trace("leave device idle");return r;
}
static void check_reset(void) {
    if(gated()&&strcmp(mode(),"trace")){fprintf(stderr,"test: GPU state reset/submitted while readiness withheld\n");abort();}
}
VKAPI_ATTR VkResult VKAPI_CALL vkResetFences(VkDevice d,uint32_t n,const VkFence *f) {
    PFN_vkResetFences real=(PFN_vkResetFences)dlsym(RTLD_NEXT,"vkResetFences");check_reset();return real(d,n,f);
}
VKAPI_ATTR VkResult VKAPI_CALL vkResetCommandBuffer(VkCommandBuffer b,VkCommandBufferResetFlags flags) {
    PFN_vkResetCommandBuffer real=(PFN_vkResetCommandBuffer)dlsym(RTLD_NEXT,"vkResetCommandBuffer");check_reset();return real(b,flags);
}
VKAPI_ATTR VkResult VKAPI_CALL vkQueueSubmit(VkQueue q,uint32_t n,const VkSubmitInfo *s,VkFence f) {
    PFN_vkQueueSubmit real=(PFN_vkQueueSubmit)dlsym(RTLD_NEXT,"vkQueueSubmit");check_reset();return real(q,n,s,f);
}
