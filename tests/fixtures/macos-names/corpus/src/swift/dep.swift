// libXFDep.dylib: module XFDep
public protocol Weighing { func weigh() -> Int }
public enum Kind { case plain, tagged(String), sized(width: Int, height: Int) }
public struct Point: Weighing {
    public var x: Int
    public var y: Double
    public init(x: Int, y: Double) { self.x = x; self.y = y }
    public func weigh() -> Int { x + Int(y) }
}
open class Thing: Weighing {
    public var name: String
    public var history: [Int] = []
    public var kind: Kind = .plain
    public init(name: String) { self.name = name }
    @inline(never) public func bump() -> Int {
        history.append(history.count + 1)
        if history.count > 8 { history.removeFirst() }
        return history.last ?? 0
    }
    open func weigh() -> Int { history.count * 2 + name.count }
}
@inline(never) public func total<T: Weighing>(_ items: [T]) -> Int { items.reduce(0) { $0 + $1.weigh() } }
