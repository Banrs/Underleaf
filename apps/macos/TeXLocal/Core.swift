import Foundation
import os
import TeXLocalCore

nonisolated struct CoreError: LocalizedError {
    let message: String
    var status: Int?
    var errorDescription: String? { message }
}

/// The Rust core (docs/core-api.md). Commands answer on a core thread (`tl_call_async`), so nothing waits on the main actor,
/// and a session takes them in the order sent. Events are decoded on the core's thread and reach their session's observer
/// on the main actor in order.
final class Core {
    static let shared = Core()

    static let libraryFolder = if let dir = ProcessInfo.processInfo.environment["TEXLOCAL_DATA"], !dir.isEmpty {
        URL(filePath: dir, directoryHint: .isDirectory)
    } else {
        defaultLibrary
    }

    private static var defaultLibrary: URL {
        (ProcessInfo.processInfo.environment["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) } ?? .homeDirectory)
            .appending(path: "TeXLocal", directoryHint: .isDirectory)
    }

    private var handle: OpaquePointer? = Core.open()
    var isOpen: Bool { handle != nil }

    static let libraryPath = (libraryFolder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    static let libraryAdvice = "Make sure you can create and write to \(libraryPath), then try again."
    private static let unavailable = CoreError(message: "TeXLocal can’t open its projects folder. \(libraryAdvice)")

    private init() { Task { for await (session, event) in Self.events.stream { observers[session]?(event) } } }

    private static func open() -> OpaquePointer? {
        guard let handle = libraryFolder.withUnsafeFileSystemRepresentation({ tl_open($0) }) else { return nil }
        listen(handle)
        return handle
    }

    func reopen() { if handle == nil { handle = Self.open() } }

    // MARK: - Commands

    /// A value JSON can't hold (a NaN) is a fault: JSONSerialization would raise an exception `try` can't catch.
    private func prepared(_ command: String, _ args: [String: any Sendable]) throws -> (OpaquePointer, String) {
        guard let handle else { throw Self.unavailable }
        guard JSONSerialization.isValidJSONObject(args) else { throw Self.fault(command, "Arguments that aren't JSON") }
        return (handle, String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
    }

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

    /// An optional `T` takes a null answer.
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

    private nonisolated struct Ignored: Decodable, Sendable { init(from decoder: any Decoder) {} }

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

    /// Sent before this first suspends, so a session takes it in the order called, beside `send`'s.
    func call<T: Decodable & Sendable>(_ command: String, _ args: [String: any Sendable] = [:], as: T.Type) async throws -> T {
        let (handle, json) = try prepared(command, args)
        return try await withCheckedThrowingContinuation { done in
            Self.start(handle, command, json) { envelope in
                done.resume(with: Result { try Self.decoded(command, envelope) })
            }
        }
    }

    func call(_ command: String, _ args: [String: any Sendable]) async throws {
        _ = try await call(command, args, as: Ignored?.self)
    }

    /// Not waited for: a failure is only logged.
    func send(_ command: String, _ args: [String: any Sendable]) {
        let logged = { @Sendable (error: any Error) in
            Self.log.error("\(command, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        do {
            let (handle, json) = try prepared(command, args)
            Self.start(handle, command, json) { envelope in
                do { let _: Ignored? = try Self.decoded(command, envelope) } catch { logged(error) }
            }
        } catch {
            logged(error)
        }
    }

    /// Blocking, for an answer the interface needs at once (a drag over the window asks where a file is); only for quick commands.
    func now<T: Decodable>(_ command: String, _ args: [String: any Sendable], as: T.Type) throws -> T {
        let (handle, json) = try prepared(command, args)
        let out = command.withCString { c in json.withCString { j in tl_call(handle, c, j) } }
        defer { tl_free(out) }
        return try Self.decoded(command, Data(bytes: out, count: strlen(out)))
    }

    /// The session's open document at `path`, for the editor; nil if it isn't open.
    func source(session: UInt64, path: String) -> OpaquePointer? { handle.flatMap { tl_session_source($0, session, path) } }

    // MARK: - Events

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

    /// A number for a session about to open: its first events can come before `session_open` has answered.
    func observe(_ observer: @escaping (SessionEvent) -> Void) -> UInt64 {
        numbered += 1
        observers[numbered] = observer
        return numbered
    }

    func forget(_ session: UInt64) { observers[session] = nil }
}

nonisolated struct EventRead: Decodable {
    let session: UInt64
    let event: SessionEvent?

    private enum Keys: CodingKey { case type, session }

    init(from decoder: any Decoder) throws {
        let head = try decoder.container(keyedBy: Keys.self)
        session = try head.decode(UInt64.self, forKey: .session)
        event = try SessionEvent(head.decode(String.self, forKey: .type), decoder)
    }
}
