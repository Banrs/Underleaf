import Foundation
import os
import TeXLocalCore

nonisolated struct CoreError: LocalizedError {
    let message: String
    var status: Int?
    var errorDescription: String? { message }
}

/// The Rust core (docs/core-api.md). A command runs on a core thread and answers there (`tl_call_async`), so nothing waits on
/// the main actor or the cooperative pool, and a session takes its commands in the order they were sent. Events come in on
/// the core's own thread, are decoded there, and reach their session's observer on the main actor in the order sent.
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

    private var handle: OpaquePointer? = Core.open()
    var isOpen: Bool { handle != nil }

    static let libraryPath = (libraryFolder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    static let libraryAdvice = "Make sure you can create and write to \(libraryPath), then try again."
    private static let unavailable = CoreError(message: "TeXLocal can’t open its projects folder. \(libraryAdvice)")

    private init() {
        // For the app's life: each event goes to its session's observer, one at a time, in the order the core sent them.
        Task {
            for await (session, event) in Self.events.stream { observers[session]?(event) }
        }
    }

    private static func open() -> OpaquePointer? {
        guard let handle = libraryFolder.withUnsafeFileSystemRepresentation({ tl_open($0) }) else { return nil }
        listen(handle)
        return handle
    }

    func reopen() {
        if handle == nil { handle = Self.open() }
    }

    // MARK: - Commands

    private nonisolated static func json(_ args: [String: any Sendable]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
    }

    /// What a call's `done` gets back: the answer's envelope, read on the core's thread.
    private nonisolated final class Answer: Sendable {
        let take: @Sendable (Data) -> Void
        init(_ take: @escaping @Sendable (Data) -> Void) { self.take = take }
    }

    /// Nonisolated, so the C callback formed here is too: one formed in a main-actor context would be taken as the main
    /// actor's and trap on the core's thread. The envelope, valid only during the callback, is copied.
    private nonisolated static func start(_ handle: OpaquePointer, _ command: String, _ json: String,
                                          _ answered: @escaping @Sendable (Data) -> Void) {
        let context = Unmanaged.passRetained(Answer(answered)).toOpaque()
        command.withCString { command in
            json.withCString { json in
                tl_call_async(handle, command, json, { context, envelope in
                    guard let context else { return }
                    Unmanaged<Answer>.fromOpaque(context).takeRetainedValue().take(Data(bytes: envelope, count: strlen(envelope)))
                }, context)
            }
        }
    }

    /// The answer, or the error, a command's envelope holds; an optional `T` takes a null answer.
    private nonisolated struct Envelope<T: Decodable>: Decodable {
        let answer: Result<T, CoreError>

        private enum Keys: CodingKey { case ok, error, status }

        init(from decoder: any Decoder) throws {
            let envelope = try decoder.container(keyedBy: Keys.self)
            if let error = try envelope.decodeIfPresent(String.self, forKey: .error) {
                answer = .failure(CoreError(message: error, status: try envelope.decodeIfPresent(Int.self, forKey: .status)))
            } else {
                answer = .success(try envelope.decode(T.self, forKey: .ok))
            }
        }
    }

    private nonisolated struct Ignored: Decodable, Sendable {
        init(from decoder: any Decoder) throws {}
    }

    private nonisolated static func decoded<T: Decodable>(_ command: String, _ envelope: Data) throws -> T {
        let answer: Result<T, CoreError>
        do {
            answer = try JSONDecoder().decode(Envelope<T>.self, from: envelope).answer
        } catch {
            throw fault(command, String(describing: error))
        }
        return try answer.get()
    }

    private nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TeXLocal", category: "core")

    private nonisolated static func fault(_ command: String, _ problem: String) -> CoreError {
        log.error("\(command, privacy: .public): \(problem, privacy: .public)")
        return CoreError(message: "Something went wrong inside TeXLocal. Try again, or quit TeXLocal and open it again.")
    }

    /// The command's answer. It is sent before this first suspends, so a session takes it in the order called, beside
    /// `send`'s; the answer is decoded on the core's thread.
    func call<T: Decodable & Sendable>(_ command: String, _ args: [String: any Sendable] = [:], as: T.Type) async throws -> T {
        guard let handle else { throw Self.unavailable }
        let json = try Self.json(args)
        return try await withCheckedThrowingContinuation { done in
            Self.start(handle, command, json) { envelope in
                done.resume(with: Result { try Self.decoded(command, envelope) })
            }
        }
    }

    /// For a command whose answer says nothing but that it was done.
    func call(_ command: String, _ args: [String: any Sendable]) async throws {
        _ = try await call(command, args, as: Ignored?.self)
    }

    /// Not waited for: a failure is only logged.
    func send(_ command: String, _ args: [String: any Sendable]) {
        guard let handle else { return }
        do {
            Self.start(handle, command, try Self.json(args)) { envelope in
                do {
                    let _: Ignored? = try Self.decoded(command, envelope)
                } catch {
                    Self.log.error("\(command, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            Self.log.error("\(command, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func run(_ handle: OpaquePointer, _ command: String, _ json: String) -> Data {
        let out = command.withCString { c in json.withCString { j in tl_call(handle, c, j) } }
        defer { tl_free(out) }
        return Data(bytes: out, count: strlen(out))
    }

    /// Blocking, for an answer the interface needs at once (a drag over the window asks where a file is); only for quick commands.
    func now<T: Decodable>(_ command: String, _ args: [String: any Sendable], as: T.Type) throws -> T {
        guard let handle else { throw Self.unavailable }
        return try Self.decoded(command, Self.run(handle, command, try Self.json(args)))
    }

    /// Synchronous: it runs as the app quits.
    func killAll() {
        guard let handle else { return }
        _ = Core.run(handle, "kill_all", "{}")
    }

    /// The session's open document at `path`, for the editor: its edits are the session's. Nil if it isn't open.
    func source(session: UInt64, path: String) -> OpaquePointer? {
        guard let handle else { return nil }
        return tl_session_source(handle, session, path)
    }

    // MARK: - Events

    /// What the listener reads, in the order the core sent it.
    private nonisolated static let events = AsyncStream.makeStream(of: (UInt64, SessionEvent).self)

    /// The text, valid only during the call, is decoded on the core's thread, and Live Preview's PDF read there, so its
    /// page reaches the main actor ready to draw. Nonisolated for the C callback, as `start`'s.
    private nonisolated static func listen(_ handle: OpaquePointer) {
        tl_set_listener(handle, { _, json in
            let event = Data(bytes: json, count: strlen(json))
            do {
                let read = try JSONDecoder().decode(EventRead.self, from: event)
                if let said = read.event { Core.events.continuation.yield((read.session, said)) }
            } catch {
                Core.log.error("An event the app can't read: \(String(describing: error), privacy: .public)")
            }
        }, nil)
    }

    private var observers: [UInt64: (SessionEvent) -> Void] = [:]
    private var numbered: UInt64 = 0

    /// A number for a session about to open, whose events go to `observer` from now on. The app numbers its sessions, so
    /// it listens for one before it opens: a session's first events can come before `session_open` has answered.
    func observe(_ observer: @escaping (SessionEvent) -> Void) -> UInt64 {
        numbered += 1
        observers[numbered] = observer
        return numbered
    }

    func forget(_ session: UInt64) {
        observers[session] = nil
    }
}

/// An event as the listener reads it: the session it names, and what it says, or nil for one the app has no use for.
private nonisolated struct EventRead: Decodable {
    let session: UInt64
    let event: SessionEvent?

    private enum Keys: CodingKey { case type, session }

    init(from decoder: any Decoder) throws {
        let head = try decoder.container(keyedBy: Keys.self)
        session = try head.decode(UInt64.self, forKey: .session)
        event = try SessionEvent(head.decode(String.self, forKey: .type), decoder)
    }
}
