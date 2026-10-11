// Shared declarations for the owned corpus fixture (C++).
#pragma once
#include <string>
#include <vector>
namespace xf {
enum class Kind : unsigned char { Plain, Fancy = 4 };
class Base {
public:
    explicit Base(int id) : id_(id) {}
    virtual ~Base();
    virtual long weigh() const;
    int id() const { return id_; }
protected:
    int id_;
};
class Derived : public Base {
public:
    Derived(int id, std::string label);
    long weigh() const override;
    static int made;
private:
    std::string label_;
    std::vector<int> history_;
    Kind kind_ = Kind::Fancy;
};
template <class T> struct Box {
    T value;
    T twice() const { return value + value; }
};
long library_total(const std::vector<Base *> &items);
}
