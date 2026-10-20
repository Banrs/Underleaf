import AppKit

#if DEBUG
/// QA without the screen: with TEXLOCAL_QA_SNAPSHOT set to a folder, "com.texlocal.qa.snapshot" (its object a name) writes
/// each visible window as drawn (<name>-<n>.png) and its views' frames (<name>-<n>.txt); "com.texlocal.qa.resize"
/// ("<width>x<height>") sets the main window's content size.
enum QASnapshot {
    static func install() {
        guard let folder = ProcessInfo.processInfo.environment["TEXLOCAL_QA_SNAPSHOT"] else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.texlocal.qa.snapshot"), object: nil, queue: .main) { note in
            let name = note.object as? String ?? "snapshot"
            MainActor.assumeIsolated { write(to: URL(filePath: folder), name: name) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.texlocal.qa.resize"), object: nil, queue: .main) { note in
            let size = (note.object as? String ?? "").split(separator: "x").compactMap { Double($0) }
            guard size.count == 2 else { return }
            MainActor.assumeIsolated {
                NSApp.windows.first { $0.isVisible && $0.toolbar != nil }?.setContentSize(NSSize(width: size[0], height: size[1]))
            }
        }
    }

    private static func write(to folder: URL, name: String) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let frame = window.contentView?.superview ?? window.contentView,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name)-\(index).png"))
            var lines = ["\(type(of: window)) \(window.frame) scale \(window.backingScaleFactor)"]
            func walk(_ view: NSView, _ depth: Int) {
                let rect = view.convert(view.bounds, to: nil)
                let extra = (view as? NSControl).map { " font \($0.font?.fontName ?? "-") \($0.font?.pointSize ?? 0)" } ?? ""
                lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) \(rect)\(view.isHidden ? " hidden" : "")\(extra)")
                view.subviews.forEach { walk($0, depth + 1) }
            }
            walk(frame, 0)
            try? lines.joined(separator: "\n").write(to: folder.appending(path: "\(name)-\(index).txt"), atomically: true, encoding: .utf8)
        }
    }
}
#endif
