import CoreServices
import Foundation

/// Watching the folder survives editors that atomically replace files on save.
final class FolderWatcher {
    struct Change {
        let path: String
        let structural: Bool
    }

    let folder: String
    private let changed: @MainActor ([Change]) -> Void
    private var stream: FSEventStreamRef?

    private static let settle: CFTimeInterval = 0.25
    private static let structuralFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
            | kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)

    init(folder: URL, changed: @escaping @MainActor ([Change]) -> Void) {
        self.folder = Self.realPath(folder)
        self.changed = changed
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
            nil, callback, &context, [self.folder] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
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

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    func relativePath(_ path: String) -> String? {
        let prefix = folder + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// Spelt as the disk spells it (`realpath` gives the disk's case): what a save leaves, renaming a new file over the old.
    func hasFile(_ path: String) -> Bool {
        let full = folder + "/" + path
        var info = stat()
        return lstat(full, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && Self.realPath(URL(filePath: full)) == full
    }

    /// `resolvingSymlinksInPath` would take /private off /private/var and /private/tmp, which FSEvents keeps.
    static func realPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
