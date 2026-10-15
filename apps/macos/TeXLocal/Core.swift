import Foundation
import os
import TeXLocalCore

nonisolated struct CoreError: LocalizedError {
    let message: String
    var status: Int?
    var errorDescription: String? { message }
}

/// `tl_call` blocks for as long as the command runs (minutes, for a compile), so calls run on a GCD thread: the cooperative pool must never block.
final class Core {
    static let shared = Core()

    static let libraryFolder: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let dir = environment["TEXLOCAL_DATA"], !dir.isEmpty {
            return URL(filePath: dir, directoryHint: .isDirectory)
        }
        let home = environment["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) } ?? .homeDirectory
        return home.appending(path: "TeXLocal", directoryHint: .isDirectory)
    }()

    /// The core takes concurrent calls from any thread, so the GCD thread reads it.
    private nonisolated final class Handle: @unchecked Sendable {
        let raw: OpaquePointer
        init(_ raw: OpaquePointer) { self.raw = raw }
    }

    private var handle: Handle? = Core.open()
    var isOpen: Bool { handle != nil }

    static let libraryPath = (libraryFolder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    static let libraryAdvice = "Make sure you can create and write to \(libraryPath), then try again."
    private static let unavailable = CoreError(message: "TeXLocal can’t open its projects folder. \(libraryAdvice)")

    private init() {}

    private static func open() -> Handle? {
        guard let raw = libraryFolder.withUnsafeFileSystemRepresentation({ tl_open($0) }) else { return nil }
        listen(raw)
        return Handle(raw)
    }

    /// Nonisolated, so the C callback formed here is too: one formed in a main-actor context would be taken as the main
    /// actor's and trap on the core's thread. The text, valid only during the call, is copied, then taken on the main queue
    /// in the order sent.
    private nonisolated static func listen(_ raw: OpaquePointer) {
        tl_set_listener(raw, { _, json in
            let event = Data(bytes: json, count: strlen(json))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Core.shared.receive(event) }
            }
        }, nil)
    }

    func reopen() {
        if handle == nil { handle = Self.open() }
    }

    private nonisolated static func run(_ handle: Handle, _ command: String, _ json: String) -> Data {
        let out = command.withCString { c in json.withCString { j in tl_call(handle.raw, c, j) } }
        guard let out else { return Data() }
        defer { tl_free(out) }
        return Data(bytes: out, count: strlen(out))
    }

    private nonisolated struct Envelope<T: Decodable>: Decodable {
        let ok: T?
        let error: String?
        let status: Int?
    }

    private nonisolated struct Ignored: Decodable, Sendable {
        init(from decoder: any Decoder) throws {}
    }

    private nonisolated static func decoded<T: Decodable>(_ handle: Handle, _ command: String, _ json: String) throws -> T? {
        do {
            let envelope = try JSONDecoder().decode(Envelope<T>.self, from: run(handle, command, json))
            if let error = envelope.error { throw CoreError(message: error, status: envelope.status) }
            return envelope.ok
        } catch let error as DecodingError {
            throw fault(command, String(describing: error))
        }
    }

    private nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TeXLocal", category: "core")

    private nonisolated static func fault(_ command: String, _ problem: String) -> CoreError {
        log.error("\(command, privacy: .public): \(problem, privacy: .public)")
        return CoreError(message: "Something went wrong inside TeXLocal. Try again, or quit TeXLocal and open it again.")
    }

    private nonisolated static func json(_ args: [String: any Sendable]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
    }

    /// The arguments are encoded on the GCD thread: escaping a whole document's text took 3 ms of the main actor's time per megabyte.
    private func result<T: Decodable & Sendable>(_ command: String, _ args: [String: any Sendable], as: T.Type,
                                                 on queue: DispatchQueue) async throws -> T? {
        guard let handle else { throw Self.unavailable }
        return try await withCheckedThrowingContinuation { done in
            queue.async {
                done.resume(with: Result { try Core.decoded(handle, command, Core.json(args)) })
            }
        }
    }

    /// Blocking, for an answer the interface needs at once (a drag over the window asks where a file is); only for quick commands.
    func now<T: Decodable>(_ command: String, _ args: [String: any Sendable], as: T.Type) throws -> T? {
        guard let handle else { throw Self.unavailable }
        return try Self.decoded(handle, command, try Self.json(args))
    }

    /// Nil for a null answer.
    func answer<T: Decodable & Sendable>(_ command: String, _ args: [String: any Sendable] = [:], as: T.Type) async throws -> T? {
        try await result(command, args, as: T.self, on: .global(qos: .userInitiated))
    }

    func call<T: Decodable & Sendable>(_ command: String, _ args: [String: any Sendable] = [:], as: T.Type) async throws -> T {
        guard let ok = try await answer(command, args, as: T.self) else { throw Self.fault(command, "no answer") }
        return ok
    }

    func perform(_ command: String, _ args: [String: any Sendable]) async throws {
        _ = try await answer(command, args, as: Ignored.self)
    }

    /// Synchronous: it runs as the app quits.
    func killAll() {
        guard let handle else { return }
        _ = Core.run(handle, "kill_all", "{}")
    }

    // MARK: - Sessions

    /// Session commands reach the core in the order they were asked for, one at a time: a caret's move never overtakes the
    /// next, nor a setting the one after it. They are quick (docs/core-api.md), so none holds the others up for long.
    private let lane = DispatchQueue(label: "TeXLocal.session", qos: .userInitiated)

    /// Nil for a null answer.
    func session<T: Decodable & Sendable>(_ command: String, _ args: [String: any Sendable], as: T.Type) async throws -> T? {
        try await result(command, args, as: T.self, on: lane)
    }

    func session(_ command: String, _ args: [String: any Sendable]) async throws {
        _ = try await result(command, args, as: Ignored.self, on: lane)
    }

    /// Not waited for: a failure is only logged.
    func send(_ command: String, _ args: [String: any Sendable]) {
        guard let handle else { return }
        lane.async {
            do {
                let _: Ignored? = try Core.decoded(handle, command, Core.json(args))
            } catch {
                Core.log.error("\(command, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The session's open document at `path`, for the editor: its edits are the session's. Nil if it isn't open.
    func source(session: UInt64, path: String) -> OpaquePointer? {
        guard let handle else { return nil }
        return tl_session_source(handle.raw, session, path)
    }

    // MARK: - Events

    private nonisolated struct EventHead: Decodable {
        let type: String
        let session: UInt64
    }

    private var observers: [UInt64: (String, Data) -> Void] = [:]
    /// A session's first events can come before `session_open` has answered with its number: they wait for its observer.
    private var early: [UInt64: [(String, Data)]] = [:]
    private var newest: UInt64 = 0

    func observe(_ session: UInt64, _ observer: @escaping (_ type: String, _ event: Data) -> Void) {
        observers[session] = observer
        newest = max(newest, session)
        let waiting = early.removeValue(forKey: session) ?? []
        // Sessions are numbered in order: one older than an observed one that has none was closed before it was observed.
        early = early.filter { $0.key > newest }
        for (type, event) in waiting { observer(type, event) }
    }

    func forget(_ session: UInt64) {
        observers[session] = nil
    }

    private func receive(_ event: Data) {
        guard let head = try? JSONDecoder().decode(EventHead.self, from: event) else {
            return Self.log.error("An event the app can't read: \(String(decoding: event.prefix(200), as: UTF8.self), privacy: .public)")
        }
        if let observer = observers[head.session] {
            observer(head.type, event)
        } else if head.session > newest {
            early[head.session, default: []].append((head.type, event))
        }
    }

    /// Nil, logged, for an event in another shape than the app's: a fault of the app's own or the core's.
    static func decode<T: Decodable>(_ type: T.Type, _ event: Data, _ name: String) -> T? {
        do {
            return try JSONDecoder().decode(T.self, from: event)
        } catch {
            log.error("\(name, privacy: .public) event: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
