// T01 shared-object fixture: exported, protected, hidden, and local symbols.
#include <stdio.h>

int libfix_counter = 3;
static int local_data = 5;
__attribute__((visibility("hidden"))) int libfix_hidden_fn(int x) { return x + local_data; }
__attribute__((visibility("protected"))) int libfix_add(int a, int b) { return libfix_hidden_fn(a) + b + libfix_counter; }
int libfix_plain(int x) { return x + 1; }

// Addresses that cannot be interposed by the executable, so they are libfix's own.
void libfix_report(void) {
    printf("libsym libfix_add %p\n", (void *)libfix_add);
    printf("libsym libfix_hidden_fn %p\n", (void *)libfix_hidden_fn);
    printf("libsym local_data %p\n", (void *)&local_data);
}
