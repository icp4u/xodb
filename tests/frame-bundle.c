#define _GNU_SOURCE
#include "../src/frames/bundle.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    struct xfb_view source = {.count = 1}, read;
    const uint8_t metadata[] = "{\"algorithm\":\"historical-v0\"}";
    const uint8_t input[] = "owned synthetic source\n";
    source.sources[0] = (struct xfb_source){.kind = XFB_LOGICAL, .stability = XLF_STABILITY_LEASED,
        .metadata = metadata, .metadata_size = sizeof metadata - 1, .bytes = input, .size = sizeof input - 1};
    uint8_t *bytes = NULL; size_t size = 0;
    assert(xfb_encode(&source, NULL, &bytes, &size) == XFB_OK);
    assert(xfb_decode(bytes, size, NULL, &read) == XFB_OK);
    assert(read.count == 1 && read.input_bytes == sizeof input - 1);
    assert(read.sources[0].metadata_size == sizeof metadata - 1 && !memcmp(read.sources[0].metadata, metadata, sizeof metadata - 1));
    assert(read.sources[0].size == sizeof input - 1 && !memcmp(read.sources[0].bytes, input, sizeof input - 1));
    uint8_t *again; size_t again_size;
    assert(xfb_encode(&read, NULL, &again, &again_size) == XFB_OK);
    assert(again_size == size && !memcmp(again, bytes, size)); free(again);
    for (size_t n = 0; n < size; ++n) { assert(xfb_decode(bytes, n, NULL, &read) != XFB_OK); assert(!read.count); }
    bytes[size - 1] ^= 1; assert(xfb_decode(bytes, size, NULL, &read) == XFB_CHECKSUM); bytes[size - 1] ^= 1;
    bytes[8] = 2; assert(xfb_decode(bytes, size, NULL, &read) == XFB_VERSION); bytes[8] = 1;
    struct xlf_cancel *cancel = xlf_cancel_create(); assert(cancel); xlf_cancel_request(cancel);
    assert(xfb_decode(bytes, size, cancel, &read) == XFB_CANCELLED);
    assert(xfb_encode(&source, cancel, &again, &again_size) == XFB_CANCELLED && !again && !again_size);
    struct xfb_input owned;
    assert(xfb_read("does-not-exist", XFB_MAX_INPUT, cancel, &owned) == XFB_CANCELLED);
    xlf_cancel_destroy(cancel);
    char folder[] = ".work/frame-bundle-XXXXXX"; assert(mkdtemp(folder)); assert(!chmod(folder, 0755));
    char path[128]; assert(snprintf(path, sizeof path, "%s/source", folder) > 0);
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644); assert(fd >= 0);
    assert(write(fd, bytes, size) == (ssize_t)size); assert(!close(fd));
    assert(xfb_read(path, XFB_MAX_BYTES, NULL, &owned) == XFB_OK);
    assert(owned.size == size && !memcmp(bytes, owned.bytes, size));
    assert(xfb_read(path, size - 1, NULL, &(struct xfb_input){0}) == XFB_LIMIT);
    assert(!unlink(path));
    assert(xfb_decode(owned.bytes, owned.size, NULL, &read) == XFB_OK); xfb_input_free(&owned);
    assert(!mkfifo(path, 0644)); assert(xfb_read(path, XFB_MAX_INPUT, NULL, &owned) == XFB_IO && !owned.bytes);
    assert(!unlink(path) && !rmdir(folder)); free(bytes);
    source.count = XFB_MAX_SOURCES;
    for (size_t i = 1; i < source.count; ++i) source.sources[i] = source.sources[0];
    assert(xfb_encode(&source, NULL, &bytes, &size) == XFB_OK);
    assert(xfb_decode(bytes, size, NULL, &read) == XFB_OK && read.count == XFB_MAX_SOURCES); free(bytes);
    source.sources[0].metadata_size = 0;
    assert(xfb_encode(&source, NULL, &bytes, &size) == XFB_FORMAT && !bytes);
    source.sources[0].metadata_size = sizeof metadata - 1;
    source.count++; assert(xfb_encode(&source, NULL, &bytes, &size) == XFB_LIMIT && !bytes);
    source.count = 1;
    uint8_t *big = calloc(1, XFB_MAX_INPUT); assert(big);
    source.sources[0].bytes = big; source.sources[0].size = XFB_MAX_INPUT;
    assert(xfb_encode(&source, NULL, &bytes, &size) == XFB_OK);
    assert(xfb_decode(bytes, size, NULL, &read) == XFB_OK && read.input_bytes == XFB_MAX_INPUT); free(bytes);
    source.sources[0].size++; assert(xfb_encode(&source, NULL, &bytes, &size) == XFB_LIMIT && !bytes);
    source.sources[0].size = XFB_MAX_INPUT; source.sources[1] = source.sources[0]; source.sources[1].size = 1; source.count = 2;
    assert(xfb_encode(&source, NULL, &bytes, &size) == XFB_LIMIT && !bytes); free(big);
    puts("Frame bundle: exact round trip, unknown analysis label, input/source boundaries, truncation, checksum, cancellation and FIFO refusal passed");
}
