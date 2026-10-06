#ifndef XODB_XSQ_INTERNAL_H
#define XODB_XSQ_INTERNAL_H
/* Library-internal allocation entry points.  Every allocation of the loader
 * and the query engine goes through these, so budgets can charge them and
 * tests can inject a failure at any one of them (xsq_test_alloc_fail_at). */
#include <stddef.h>

void *xsq__malloc(size_t size);
void *xsq__calloc(size_t count, size_t size);
void *xsq__realloc(void *pointer, size_t size);
#define xsq__free free

/* Counted work for tests: bytes hashed by the loader. */
void xsq__count_hashed(size_t bytes);

#endif
