/* Allocation shim, cancellation primitives and test counters (C02-R3). */
#include "xsq.h"
#include "xsq_internal.h"

#include <stdatomic.h>
#include <stdlib.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "cancellation must be lock-free (signal-safe)");

static atomic_long fail_at = -1;
static atomic_long counter;

long xsq_test_alloc_fail_at(long k)
{
    atomic_store(&fail_at, k);
    return atomic_exchange(&counter, 0);
}

static int injected(void)
{
    long n = atomic_fetch_add(&counter, 1);
    return n == atomic_load(&fail_at);
}

void *xsq__malloc(size_t size)
{
    return injected() ? NULL : malloc(size ? size : 1);
}

void *xsq__calloc(size_t count, size_t size)
{
    return injected() ? NULL : calloc(count ? count : 1, size ? size : 1);
}

void *xsq__realloc(void *pointer, size_t size)
{
    return injected() ? NULL : realloc(pointer, size ? size : 1);
}

static atomic_ullong hashed;

void xsq__count_hashed(size_t bytes)
{
    atomic_fetch_add_explicit(&hashed, bytes, memory_order_relaxed);
}

unsigned long long xsq_test_hashed_bytes(int reset)
{
    return reset ? atomic_exchange(&hashed, 0) : atomic_load(&hashed);
}

void xsq_cancel_init(struct xsq_cancel *c)
{
    atomic_init(&c->requested, 0u);
}

void xsq_cancel_request(struct xsq_cancel *c)
{
    atomic_store_explicit(&c->requested, 1u, memory_order_release);
}

int xsq_cancel_requested(const struct xsq_cancel *c)
{
    return c && atomic_load_explicit((atomic_uint *)&c->requested, memory_order_acquire) != 0;
}
