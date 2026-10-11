// cxxprog: owned C++ fixture. Prints its pid and loops through bp_target.
#include <cstdio>
#include <stdexcept>
#include <unistd.h>
#include "dep.hpp"
volatile unsigned long cxx_marker = 0x637878;
extern "C" __attribute__((noinline)) void bp_target(long total) { cxx_marker += static_cast<unsigned long>(total); __asm__ volatile("" ::: "memory"); }
namespace {
long risky(int value)
{
    if (value % 2) throw std::runtime_error("odd");
    return value;
}
}
int main()
{
    setvbuf(stdout, nullptr, _IONBF, 0);
    xf::Base plain(1);
    xf::Derived fancy(2, "label");
    std::vector<xf::Base *> items{&plain, &fancy};
    xf::Box<double> box{1.5};
    xf::Box<std::string> words{"ab"};
    auto scale = [&box](long value) { return value * static_cast<long>(box.twice()); };
    std::printf("pid=%d\nbp_target=%p\ncxx_marker=%p\nready\n", static_cast<int>(getpid()), reinterpret_cast<void *>(bp_target), static_cast<void *>(const_cast<unsigned long *>(&cxx_marker)));
    for (int round = 0;; round++) {
        long total = scale(xf::library_total(items)) + static_cast<long>(words.twice().size());
        try { total += risky(round); } catch (const std::runtime_error &error) { total -= error.what()[0]; }
        bp_target(total);
        usleep(1000);
    }
}
