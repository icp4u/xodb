volatile int library_value;
__attribute__((noinline)) int late_function(int input) {
    library_value=input+1; // LATE_STOP
    return library_value;
}
