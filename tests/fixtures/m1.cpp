#include <cstdint>
struct Counter {
    std::int64_t value = 7;
    __attribute__((noinline)) void add(const std::int64_t amount) {
        int values[2] = {3, 4};
        std::int64_t next = value + amount;
        value = next; // CPP_BREAK
        asm volatile("" : : "m"(values) : "memory");
    }
};
int main() { Counter counter; counter.add(5); return counter.value == 12 ? 0 : 1; }
