import CoreServices
import Foundation

/// Recursive FSEvents watch for external changes. Watching the folder survives
/// editors that atomically replace files on save.
final class FolderWatcher {
    struct Change {
        /// Symlinks resolved, as FSEvents gives it.
        let path: String
        /// Added, removed or renamed; or FSEvents lost count, and anything may have.
        let structural: Bool
    }

    /// Symlinks resolved, as the changes' paths are.
    let folder: String
    private let changed: @MainActor ([Change]) -> Void
    private var stream: FSEventStreamRef?

    /// A write arrives as several events.
    private static let settle: CFTimeInterval = 0.25
    private static let structuralFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
            | kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)

    init(folder: URL, changed: @escaping @MainActor ([Change]) -> Void) {
        self.folder = Self.realPath(folder)
        self.changed = changed
        start()
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// `path` from the folder ("chapters/one.tex"); nil for the folder itself
    /// or anything outside it.
    func relativePath(_ path: String) -> String? {
        let prefix = folder + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// Resolved as FSEvents resolves it. `resolvingSymlinksInPath` would take
    /// /private off /private/var and /private/tmp, which FSEvents keeps.
    static func realPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func start() {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        // Called on the main queue (below); `info` stays valid until deinit stops the stream.
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let changes = zip(paths, UnsafeBufferPointer(start: flags, count: count)).map {
                Change(path: $0, structural: $1 & FolderWatcher.structuralFlags != 0)
            }
            MainActor.assumeIsolated {
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().changed(changes)
            }
        }
        // WatchRoot reports the folder itself moving or going (RootChanged).
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [folder] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.settle, FSEventStreamCreateFlags(flags))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }
}
