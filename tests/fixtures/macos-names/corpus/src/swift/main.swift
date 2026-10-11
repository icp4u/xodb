// swiftprog: owned Swift fixture. Prints its pid and loops through bp_target.
import Darwin
import XFDep
var swiftMarker: UInt = 0x7377
@_cdecl("bp_target") @inline(never) public func bpTarget(_ total: Int) { swiftMarker &+= UInt(bitPattern: total) }
final class Fancy: Thing {
    var extra: Int? = 5
    override func weigh() -> Int { super.weigh() + (extra ?? 0) }
}
setvbuf(stdout, nil, _IONBF, 0)
let thing = Fancy(name: "thing")
thing.kind = .sized(width: 3, height: 4)
let points = [Point(x: 1, y: 2.5), Point(x: 3, y: 4.5)]
let table: [String: Int] = ["limit": 9]
let scale: (Int) -> Int = { $0 * (table["limit"] ?? 1) }
print("pid=\(getpid())\nready")
while true {
    let sum = scale(thing.bump()) + thing.weigh() + total(points)
    bpTarget(sum)
    usleep(1000)
}
