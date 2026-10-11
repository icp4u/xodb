/* Owned program cross-compiled to Mach-O; never run by the tests. */
#include <stdio.h>
int macho_counter = 3;
static int macho_local(int x) { return x * 2 + macho_counter; }
int macho_target(int x) { return macho_local(x) + 1; }
int main(void) {
    printf("%d\n", macho_target(2));
    return 0;
}
