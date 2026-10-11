// libcxxdep.dylib
#include "dep.hpp"
namespace xf {
int Derived::made;
Base::~Base() {}
long Base::weigh() const { return id_; }
Derived::Derived(int id, std::string label) : Base(id), label_(std::move(label)), history_{1, 2, 3} { made++; }
long Derived::weigh() const { return id_ * 10 + static_cast<long>(label_.size()) + history_.back(); }
long library_total(const std::vector<Base *> &items)
{
    long total = 0;
    for (const Base *item : items) total += item->weigh();
    return total;
}
}
