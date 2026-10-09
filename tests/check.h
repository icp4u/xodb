/* Fixture checks must survive release flags and runtime SDK headers. */
#ifndef XODB_TEST_CHECK_H
#define XODB_TEST_CHECK_H
#include <stdio.h>
#include <stdlib.h>
#define CHECK(expression) do { \
    if (!(expression)) { \
        fprintf(stderr, "CHECK failed: %s (%s:%d)\n", #expression, __FILE__, __LINE__); \
        abort(); \
    } \
} while (0)
#endif
