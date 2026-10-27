import Foundation
import os
import TeXLocalCore

nonisolated extension CoreError: LocalizedError {
    var errorDescription: String? { message }
}

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
    private static let unavailable = CoreError(kind: .unavailable, message: "TeXLocal can’t open its projects folder. \(libraryAdvice)")

    private init() {
        Task {
            for await (said, json) in Self.heard.stream {
                switch said {
                case .reply(let id): pending.removeValue(forKey: id)?(json)
                case .event(let session, let heard): observers[session]?(heard)
                }
            }
        }
    }

    private static func open() -> OpaquePointer? {
        libraryFolder.withUnsafeFileSystemRepresentation { tl_open($0, listener, nil) }
    }

    func reopen() { if handle == nil { handle = Self.open() } }

    private func prepared<R: WireRequest>(_ request: R) throws -> (OpaquePointer, String) {
        guard let handle else { throw Self.unavailable }
        return (handle, String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
    }

    private var pending: [UInt64: (Data) -> Void] = [:]
    private var asked: UInt64 = 0

    private func ask(_ sent: (UInt64) -> Void, _ answered: @escaping (Data) -> Void) {
        asked += 1
        pending[asked] = answered
        sent(asked)
    }

    private nonisolated struct Envelope<T: Decodable>: Decodable {
        let answer: Result<T, CoreError>

        private enum Keys: CodingKey { case ok, error }

        init(from decoder: any Decoder) throws {
            let envelope = try decoder.container(keyedBy: Keys.self)
            if let error = try envelope.decodeIfPresent(CoreError.self, forKey: .error) {
                answer = .failure(error)
            } else {
                answer = .success(try envelope.decode(T.self, forKey: .ok))
            }
        }
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
        return CoreError(kind: .internal, message: "Something went wrong inside TeXLocal. Try again, or quit TeXLocal and open it again.")
    }

    @discardableResult
    func call<R: LibraryRequest>(_ request: R) async throws -> R.Reply {
        let (handle, json) = try prepared(request)
        return try await answer(R.self) { tl_send(handle, $0, R.command, json) }
    }

    @discardableResult
    func call<R: SessionRequest>(_ request: R, in session: UInt64) async throws -> R.Reply {
        let (handle, json) = try prepared(request)
        return try await answer(R.self) { tl_session_send(handle, $0, session, R.command, json) }
    }

    private func answer<R: WireRequest>(_: R.Type, _ sent: (UInt64) -> Void) async throws -> R.Reply {
        try await withCheckedThrowingContinuation { done in
            ask(sent) { envelope in
                done.resume(with: Result { try Self.decoded(R.command, envelope) })
            }
        }
    }

    func send<R: SessionRequest>(_ request: R, in session: UInt64) {
        let logged = { (error: any Error) in
            Self.log.error("\(R.command, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        do {
            let (handle, json) = try prepared(request)
            ask({ tl_session_send(handle, $0, session, R.command, json) }) { envelope in
                do { let _: R.Reply = try Self.decoded(R.command, envelope) } catch { logged(error) }
            }
        } catch {
            logged(error)
        }
    }

    func source(session: UInt64, path: String) -> OpaquePointer? { handle.flatMap { tl_session_source($0, session, path) } }

    private nonisolated enum Said: Decodable {
        case reply(UInt64)
        case event(UInt64, Heard)

        private enum Keys: CodingKey { case reply }

        init(from decoder: any Decoder) throws {
            if let id = try decoder.container(keyedBy: Keys.self).decodeIfPresent(UInt64.self, forKey: .reply) {
                self = .reply(id)
            } else {
                let said = try SessionEvent(from: decoder)
                self = .event(said.session, Heard(said.event))
            }
        }
    }

    private nonisolated static let heard = AsyncStream.makeStream(of: (Said, Data).self)

    private nonisolated static let listener: TlCallback = { _, json in
        let said = Data(bytes: json, count: strlen(json))
        do {
            Core.heard.continuation.yield((try JSONDecoder().decode(Said.self, from: said), said))
        } catch {
            Core.log.error("Something from the core the app can't read: \(String(describing: error), privacy: .public)")
        }
    }

    private var observers: [UInt64: (Heard) -> Void] = [:]
    private var numbered: UInt64 = 0

    func observe(_ observer: @escaping (Heard) -> Void) -> UInt64 {
        numbered += 1
        observers[numbered] = observer
        return numbered
    }

    func forget(_ session: UInt64) { observers[session] = nil }
}

final class SessionClient {
    let id: UInt64
    private let core = Core.shared

    init(_ observer: @escaping (Heard) -> Void) { id = core.observe(observer) }

    @discardableResult
    func call<R: SessionRequest>(_ request: R) async throws -> R.Reply { try await core.call(request, in: id) }

    func send<R: SessionRequest>(_ request: R) { core.send(request, in: id) }

    func close() async throws -> Bool {
        guard try await call(CloseProject()) else { return false }
        core.forget(id)
        return true
    }

    func discard() {
        core.forget(id)
        send(CloseProject())
    }
}

nonisolated enum Heard: Sendable {
    case event(Event)
    case live(LiveRead)

    init(_ event: Event) {
        switch event {
        case .liveDocument(let live): self = .live(LiveRead(live))
        case .livePage(let live): self = .live(LiveRead(live))
        default: self = .event(event)
        }
    }
}
