__declspec(dllimport) unsigned long GetCurrentProcessId(void);
__declspec(dllexport) volatile long exported_counter;
__declspec(dllexport) __declspec(noinline) long pe_inner(long n) {
    volatile long pad[12];
    pad[0] = n;
    exported_counter += pad[0];
    return pad[0] + (long)GetCurrentProcessId();
}
__declspec(dllexport) __declspec(noinline) long pe_outer(long n) {
    long value = pe_inner(n);
    return value + exported_counter;
}
