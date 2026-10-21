// post <notification name> [object]: posts a distributed notification, delivered at once (QA hooks of Debug builds).
import Foundation
let a = CommandLine.arguments
DistributedNotificationCenter.default().postNotificationName(.init(a[1]), object: a.count > 2 ? a[2] : nil, userInfo: nil, deliverImmediately: true)
