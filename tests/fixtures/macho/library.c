/* Owned library cross-compiled to a Mach-O dylib; never loaded by the tests. */
int macho_shared_counter = 5;
static int macho_hidden(int x) { return x - macho_shared_counter; }
int macho_exported(int x) { return macho_hidden(x) * 3; }
int macho_other(int x) { return macho_exported(x) + 1; }
