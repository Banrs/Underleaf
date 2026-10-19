import CoreGraphics
let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
print("locked:", d["CGSSessionScreenIsLocked"] ?? "no key", "onConsole:", d["kCGSSessionOnConsoleKey"] ?? "-")
