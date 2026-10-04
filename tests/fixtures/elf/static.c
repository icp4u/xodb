// Static executable fixture: libc contributes IFUNC, TLS, and zero-size symbols.
#include <string.h>

__thread int static_tls = 3;
int static_global = 9;

int main(int argc, char **argv) {
    return (int)strlen(argv[0]) + static_tls + static_global + argc == 0;
}
