// cgwin <pid>: the window server's windows of a process: number, layer, bounds, on screen, name.
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let keys = [kCGWindowNumber, kCGWindowLayer, kCGWindowBounds, kCGWindowIsOnscreen]
    print(keys.map { "\(w[$0 as String] ?? "-")" }.joined(separator: " "), w[kCGWindowName as String] ?? "")
}
