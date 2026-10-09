/* Owned public-API oracle; only the fixture invokes interpreter APIs. */
#define _GNU_SOURCE
#define Py_BUILD_CORE 1
#include <Python.h>
#include "internal/pycore_frame.h"
#include "internal/pycore_dict.h"
#include "../../../src/language/python.h"
#include <assert.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/uio.h>
#include <unistd.h>

static struct xpy_layout layout;
static size_t checks, faults;
struct patch { uint64_t address; const char *data; size_t size; };
struct reader { size_t calls, fail_at; struct patch patches[8]; size_t count; };
static int owned_read(void *context, uint64_t address, void *out, size_t size) {
    struct reader *r = context;
    if (++r->calls == r->fail_at) return -1;
    struct iovec local = {out, size}, remote = {(void *)(uintptr_t)address, size};
    if (process_vm_readv(getpid(), &local, 1, &remote, 1, 0) != (ssize_t)size) return -1;
    for (size_t i = 0; i < r->count; ++i) {
        const struct patch *p = &r->patches[i];
        uint64_t begin = address > p->address ? address : p->address;
        uint64_t end = address + size < p->address + p->size ? address + size : p->address + p->size;
        if (begin < end) memcpy((char *)out + begin - address, p->data + begin - p->address, end - begin);
    }
    return 0;
}
static const char *sample(struct reader *reader, PyFrameObject *frame, PyCodeObject *code,
                          const char *expression, struct xpy_locals *out,
                          unsigned char *bytes, size_t *length, enum xpy_sample_kind *kind) {
    struct xpy_reader r = {.read = owned_read, .context = reader};
    xpy_local_find(&layout, &r, (uintptr_t)frame->f_frame, (uintptr_t)code, expression, out);
    if (out->reason) return out->reason;
    if (out->count != 1) return "OracleMissingRow";
    return xpy_local_sample(&layout, &r, &out->items[0], bytes, XPY_SAMPLE_BYTES, length, kind);
}
static PyObject *check(PyObject *self, PyObject *args) {
    (void)self;
    PyObject *frame_object, *expected, *wire, *patches;
    const char *expression, *reason; int expected_kind, inject;
    if (!PyArg_ParseTuple(args, "OsOOizOp", &frame_object, &expression, &expected, &wire,
                          &expected_kind, &reason, &patches, &inject)) return NULL;
    assert(PyFrame_Check(frame_object) && PyBytes_Check(wire) && PyList_Check(patches));
    PyFrameObject *frame = (PyFrameObject *)frame_object;
    PyCodeObject *code = PyFrame_GetCode(frame); assert(code);
    struct reader reader = {0};
    assert(PyList_GET_SIZE(patches) <= 8);
    for (Py_ssize_t i = 0; i < PyList_GET_SIZE(patches); ++i) {
        PyObject *pair = PyList_GET_ITEM(patches, i), *data = PyTuple_GET_ITEM(pair, 1);
        assert(PyBytes_Check(data));
        reader.patches[reader.count++] = (struct patch){PyLong_AsUnsignedLongLong(PyTuple_GET_ITEM(pair, 0)),
            PyBytes_AS_STRING(data), (size_t)PyBytes_GET_SIZE(data)};
    }
    struct xpy_locals *out = calloc(1, sizeof *out); assert(out);
    unsigned char bytes[XPY_SAMPLE_BYTES]; size_t length = 0; enum xpy_sample_kind kind = XPY_SAMPLE_NONE;
    const char *why = sample(&reader, frame, code, expression, out, bytes, &length, &kind);
    if (reason ? !why || strcmp(reason, why) : why != NULL) {
        fprintf(stderr, "%s: wanted %s, got %s\n", expression, reason ? reason : "value", why ? why : "value"); abort();
    }
    uint64_t address = 0;
    if (!why) {
        address = out->items[0].address;
        assert(address == (uintptr_t)expected && out->items[0].slot_address && !out->items[0].immediate);
        assert((int)kind == expected_kind && length == (size_t)PyBytes_GET_SIZE(wire));
        assert(!memcmp(bytes, PyBytes_AS_STRING(wire), length));
        assert(!strcmp(out->items[0].name, expression));
        size_t reads = reader.calls;
        if (inject) for (size_t i = 1; i <= reads; ++i) {
            reader.calls = 0; reader.fail_at = i;
            why = sample(&reader, frame, code, expression, out, bytes, &length, &kind);
            if (!why) { fprintf(stderr, "%s: masked read failure %zu/%zu\n", expression, i, reads); abort(); }
            assert(reader.calls >= i); ++faults;
        }
    }
    free(out); Py_DECREF(code); ++checks;
    return PyLong_FromUnsignedLongLong(address);
}
static PyObject *dict_info(PyObject *self, PyObject *object) {
    (void)self; assert(PyDict_CheckExact(object));
    PyDictObject *d = (PyDictObject *)object; PyDictKeysObject *k = d->ma_keys;
    return Py_BuildValue("{s:K,s:K,s:K,s:K,s:K,s:K,s:i,s:n,s:n}",
        "used_address", (unsigned long long)(uintptr_t)&d->ma_used,
        "kind_address", (unsigned long long)(uintptr_t)&k->dk_kind,
        "count_address", (unsigned long long)(uintptr_t)&k->dk_nentries,
        "log2_address", (unsigned long long)(uintptr_t)&k->dk_log2_size,
        "entries", (unsigned long long)(uintptr_t)(k->dk_indices + ((size_t)1 << k->dk_log2_index_bytes)),
        "values", (unsigned long long)(uintptr_t)(d->ma_values ? d->ma_values->values : NULL),
        "kind", (int)k->dk_kind, "count", k->dk_nentries, "used", d->ma_used);
}
static PyObject *finished(PyObject *self, PyObject *unused) {
    (void)self; (void)unused;
    printf("Python paths: %zu API oracles/refusals, %zu every-read faults passed\n", checks, faults);
    Py_RETURN_NONE;
}
static PyMethodDef methods[] = {{"check", check, METH_VARARGS, NULL}, {"dict_info", dict_info, METH_O, NULL},
    {"finished", finished, METH_NOARGS, NULL}, {NULL, NULL, 0, NULL}};
static struct PyModuleDef definition = {PyModuleDef_HEAD_INIT, "xodb_paths", NULL, -1, methods, NULL, NULL, NULL, NULL};
PyMODINIT_FUNC PyInit_xodb_paths(void) {
    void *runtime = dlsym(RTLD_DEFAULT, "_PyRuntime"); assert(runtime);
    Dl_info image; assert(dladdr(runtime, &image));
    int fd = open(image.dli_fname, O_RDONLY | O_CLOEXEC); assert(fd >= 0);
    Dwarf *dw = dwarf_begin(fd, DWARF_C_READ); const uint8_t id[] = {1};
    const char *why = xpy_layout_build(runtime, XPY_DEBUG_OFFSETS_BYTES, dw, id, sizeof id, &layout);
    if (why) { fprintf(stderr, "%s\n", why); abort(); }
    if (dw) dwarf_end(dw);
    close(fd); layout.runtime = (uintptr_t)runtime;
    for (unsigned i = 0; i < XPY_TYPE_COUNT; ++i) {
        layout.types[i] = (uintptr_t)dlsym(RTLD_DEFAULT, xpy_type_symbols[i]); assert(layout.types[i]);
    }
    return PyModule_Create(&definition);
}
