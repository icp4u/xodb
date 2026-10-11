/* Owned public-but-unexported function and source-line fixture. */
volatile int pdb_value;
__declspec(noinline) int pdb_twice(int value) {
    volatile int local = value + 7;
    pdb_value = local;
    return local * 2;
}
__declspec(dllexport) __declspec(noinline) int pdb_outer(int value) {
    int result = pdb_twice(value);
    return result + pdb_value;
}
