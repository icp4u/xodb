/* Owned cooperating fixture. Python takes its own f_locals snapshot before
 * stopping; the debugger reader never invokes these interpreter APIs. */
#define _GNU_SOURCE
#define Py_BUILD_CORE 1
#include <Python.h>
#include "internal/pycore_frame.h"
#ifdef XODB_PYTHON_LUA
#include <lua.h>
#include <lauxlib.h>
#endif
#ifdef XODB_PYTHON_ORACLE
#include "../../../src/language/python.h"
#include <assert.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/uio.h>
#include <unistd.h>
static struct xpy_layout layout;
static size_t bindings_checked, frames_checked, snapshots;
static int owned_read(void *unused, uint64_t address, void *out, size_t n) {
    (void)unused;
    struct iovec local = {out, n}, remote = {(void *)(uintptr_t)address, n};
    return process_vm_readv(getpid(), &local, 1, &remote, 1, 0) == (ssize_t)n ? 0 : -1;
}
static void verify(PyObject *expected) {
    struct xpy_locals *out = calloc(1, sizeof *out), *found = calloc(1, sizeof *found);
    assert(out && found && PyList_Check(expected));
    for (Py_ssize_t i = 0; i < PyList_GET_SIZE(expected); ++i) {
        PyObject *pair = PyList_GET_ITEM(expected, i);
        PyFrameObject *pyframe = (PyFrameObject *)PyTuple_GET_ITEM(pair, 0);
        PyObject *oracle = PyTuple_GET_ITEM(pair, 1);
        PyCodeObject *code = PyFrame_GetCode(pyframe);
        assert(PyFrame_Check(pyframe) && PyDict_Check(oracle) && code);
        size_t start = 0, matched = 0;
        do {
            struct xpy_reader r = {.read = owned_read};
            xpy_locals_read(&layout, &r, (uintptr_t)pyframe->f_frame, (uintptr_t)code, start, 7, out);
            if (out->reason) { fprintf(stderr, "%s\n", out->reason); abort(); }
            for (size_t j = 0; j < out->count; ++j) {
                struct xpy_local *row = &out->items[j];
                assert(!row->name_reason);
                PyObject *want = PyDict_GetItemString(oracle, row->name);
                if (!want) { assert(row->reason && !strcmp(row->reason, "PythonUnboundLocal")); continue; }
                if (row->reason && !strcmp(row->reason, "PythonUnboundLocal")) continue;
                assert(!row->reason);
                if (row->immediate) {
                    char text[128]; snprintf(text, sizeof text, "int %lld", PyLong_AsLongLong(want));
                    assert(!strcmp(text, row->value.display) && !row->address);
                } else assert(row->address == (uintptr_t)want);
                struct xpy_reader find_reader = {.read = owned_read};
                xpy_local_find(&layout, &find_reader, (uintptr_t)pyframe->f_frame, (uintptr_t)code, row->name, found);
                assert(!found->reason && found->count == 1 && found->items[0].address == row->address);
                if (PyLong_CheckExact(want)) {
                    char text[128]; snprintf(text, sizeof text, "int %lld", PyLong_AsLongLong(want));
                    assert(!strcmp(text, row->value.display));
                }
                ++matched; ++bindings_checked;
            }
            start += out->count;
            assert(!out->truncated || out->count);
        } while (out->truncated);
        assert(matched == (size_t)PyDict_Size(oracle));
        Py_DECREF(code); ++frames_checked;
    }
    free(found); free(out); ++snapshots;
}
#endif
__attribute__((noinline)) void xodb_python_named_stop(PyObject *expected) {
    __asm__ volatile("" : : "r"(expected) : "memory"); /* NAMED_STOP */
}
static PyObject *snapshot(PyObject *self, PyObject *expected) {
    (void)self;
#ifdef XODB_PYTHON_ORACLE
    verify(expected);
#endif
    xodb_python_named_stop(expected);
    Py_RETURN_NONE;
}
static PyObject *finished(PyObject *self, PyObject *unused) {
    (void)self; (void)unused;
#ifdef XODB_PYTHON_ORACLE
    printf("Python named locals: %zu bindings, %zu frames, %zu snapshots passed\n", bindings_checked, frames_checked, snapshots);
#endif
    Py_RETURN_NONE;
}
#ifdef XODB_PYTHON_LUA
static int lua_callback(lua_State *L) {
    PyObject *callback = lua_touserdata(L, lua_upvalueindex(1));
    PyObject *result = PyObject_CallFunction(callback, "i", 49);
    if (!result) return luaL_error(L, "owned Python callback failed");
    Py_DECREF(result);
    return 0;
}
static PyObject *call_through_lua(PyObject *self, PyObject *callback) {
    (void)self;
    lua_State *L = luaL_newstate();
    if (!L) return PyErr_NoMemory();
    lua_pushlightuserdata(L, callback);
    lua_pushcclosure(L, lua_callback, 1);
    lua_setglobal(L, "owned_callback");
    const char *code = "local lua_owned = 73; owned_callback(); return lua_owned";
    int failed = luaL_loadstring(L, code) || lua_pcall(L, 0, 1, 0);
    lua_close(L);
    if (failed) {
        if (!PyErr_Occurred()) PyErr_SetString(PyExc_RuntimeError, "owned Lua callback failed");
        return NULL;
    }
    Py_RETURN_NONE;
}
#endif
static PyMethodDef methods[] = {
    {"snapshot", snapshot, METH_O, NULL}, {"finished", finished, METH_NOARGS, NULL},
#ifdef XODB_PYTHON_LUA
    {"lua_call", call_through_lua, METH_O, NULL},
#endif
    {NULL, NULL, 0, NULL}
};
static struct PyModuleDef definition = {PyModuleDef_HEAD_INIT, "xodb_named", NULL, -1, methods, NULL, NULL, NULL, NULL};
PyMODINIT_FUNC PyInit_xodb_named(void) {
#ifdef XODB_PYTHON_ORACLE
    void *runtime = dlsym(RTLD_DEFAULT, "_PyRuntime"); assert(runtime);
    Dl_info image; assert(dladdr(runtime, &image));
    int fd = open(image.dli_fname, O_RDONLY | O_CLOEXEC); assert(fd >= 0);
    Dwarf *dw = dwarf_begin(fd, DWARF_C_READ);
    const uint8_t id[] = {1};
    const char *why = xpy_layout_build(runtime, XPY_DEBUG_OFFSETS_BYTES, dw, id, sizeof id, &layout);
    if (why) { fprintf(stderr, "%s\n", why); abort(); }
    if (dw) dwarf_end(dw);
    close(fd); layout.runtime = (uintptr_t)runtime;
    for (unsigned i = 0; i < XPY_TYPE_COUNT; ++i) {
        layout.types[i] = (uintptr_t)dlsym(RTLD_DEFAULT, xpy_type_symbols[i]); assert(layout.types[i]);
    }
#endif
    return PyModule_Create(&definition);
}

#ifdef XODB_PYTHON_HOST
int main(int argc, char **argv) {
    if (PyImport_AppendInittab("xodb_named", PyInit_xodb_named) == -1) return 1;
    return Py_BytesMain(argc, argv);
}
#endif
