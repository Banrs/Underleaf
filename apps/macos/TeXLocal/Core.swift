import Foundation
import os
import TeXLocalCore

nonisolated struct CoreError: LocalizedError {
    enum Kind: String, Decodable { case invalid, denied, notFound, conflict, unfit, unavailable, `internal` }

    let message: String
    var kind: Kind?
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
    private static let unavailable = CoreError(message: "TeXLocal can’t open its projects folder. \(libraryAdvice)")

    private init() {
        Task {
            for await (said, json) in Self.heard.stream {
                switch said {
                case .reply(let id): pending.removeValue(forKey: id)?(json)
                case .event(let read): if let event = read.event { observers[read.session]?(event) }
                }
            }
        }
    }

    private static func open() -> OpaquePointer? {
        libraryFolder.withUnsafeFileSystemRepresentation { tl_open($0, listener, nil) }
    }

    func reopen() { if handle == nil { handle = Self.open() } }

    private func prepared(_ command: String, _ args: [String: any Sendable]) throws -> (OpaquePointer, String) {
        guard let handle else { throw Self.unavailable }
        guard JSONSerialization.isValidJSONObject(args) else { throw Self.fault(command, "Arguments that aren't JSON") }
        return (handle, String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
    }

    private var pending: [UInt64: (Data) -> Void] = [:]
    private var asked: UInt64 = 0

    private func ask(_ handle: OpaquePointer, _ command: String, _ json: String, _ answered: @escaping (Data) -> Void) {
        asked += 1
        pending[asked] = answered
        tl_send(handle, asked, command, json)
    }

    private nonisolated struct Envelope<T: Decodable>: Decodable {
        let answer: Result<T, CoreError>

        private enum Keys: CodingKey { case ok, error, kind }

        init(from decoder: any Decoder) throws {
            let envelope = try decoder.container(keyedBy: Keys.self)
            if let error = try envelope.decodeIfPresent(String.self, forKey: .error) {
                answer = .failure(CoreError(message: error, kind: try? envelope.decodeIfPresent(CoreError.Kind.self, forKey: .kind)))
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

    func call<T: Decodable & Sendable>(_ command: String, _ args: [String: any Sendable] = [:], as: T.Type) async throws -> T {
        let (handle, json) = try prepared(command, args)
        return try await withCheckedThrowingContinuation { done in
            ask(handle, command, json) { envelope in
                done.resume(with: Result { try Self.decoded(command, envelope) })
            }
        }
    }

    func call(_ command: String, _ args: [String: any Sendable]) async throws {
        _ = try await call(command, args, as: Ignored?.self)
    }

    func send(_ command: String, _ args: [String: any Sendable]) {
        let logged = { (error: any Error) in
            Self.log.error("\(command, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        do {
            let (handle, json) = try prepared(command, args)
            ask(handle, command, json) { envelope in
                do { let _: Ignored? = try Self.decoded(command, envelope) } catch { logged(error) }
            }
        } catch {
            logged(error)
        }
    }

    func source(session: UInt64, path: String) -> OpaquePointer? { handle.flatMap { tl_session_source($0, session, path) } }

    private nonisolated enum Said: Decodable {
        case reply(UInt64)
        case event(EventRead)

        private enum Keys: CodingKey { case reply }

        init(from decoder: any Decoder) throws {
            if let id = try decoder.container(keyedBy: Keys.self).decodeIfPresent(UInt64.self, forKey: .reply) {
                self = .reply(id)
            } else {
                self = .event(try EventRead(from: decoder))
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

    private var observers: [UInt64: (SessionEvent) -> Void] = [:]
    private var numbered: UInt64 = 0

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
