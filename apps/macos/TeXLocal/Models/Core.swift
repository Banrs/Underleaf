import Foundation
import Observation
import os
import TeXLocalCore

nonisolated extension CoreError: LocalizedError {
    var errorDescription: String? { message.text }
}

nonisolated extension Answered {
    func get() throws -> Payload {
        switch self {
        case .ok(let value): value
        case .error(let error): throw error
        }
    }
}

nonisolated extension Lifecycle {
    var stopped: Stopped? { if case .stopped(let stopped) = self { stopped } else { nil } }
}

nonisolated extension LogLevel {
    var type: OSLogType {
        switch self {
        case .error: .error
        case .fault: .fault
        }
    }
}

nonisolated struct AppFailure: LocalizedError {
    let errorDescription: String?

    init(_ text: String) { errorDescription = text }
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

    static let stateFolder = if let dir = ProcessInfo.processInfo.environment["TEXLOCAL_STATE"], !dir.isEmpty {
        URL(filePath: dir, directoryHint: .isDirectory)
    } else {
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "TeXLocal", directoryHint: .isDirectory)
    }

    static let helpersFolder = Bundle.main.bundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory)

    private var handle: OpaquePointer? = Core.open()
    var isOpen: Bool { handle != nil }
    let library = LibraryStore()

    static let libraryPath = shown(libraryFolder)
    private static var unavailable: AppFailure { AppFailure("TeXLocal can’t open its folders. \(advice())") }

    static func advice(_ folders: [URL] = [Core.libraryFolder, Core.stateFolder]) -> String {
        let unwritable = folders.first { !FileManager.default.isWritableFile(atPath: $0.path(percentEncoded: false)) }
        return "Make sure you can create and write to \(shown(unwritable ?? folders[0])), then try again."
    }

    private static func shown(_ folder: URL) -> String {
        (folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    private init() {
        Task {
            for await (said, json) in Self.heard.stream {
                switch said {
                case .reply(let reply): pending.removeValue(forKey: reply.id)?(json)
                case .event(let event): observers[event.session]?(event.event)
                case .library(let section): library.apply(section)
                case .log(let log): Self.log.log(level: log.level.type, "\(log.text, privacy: .public)")
                }
            }
        }
    }

    private static func open() -> OpaquePointer? {
        libraryFolder.withUnsafeFileSystemRepresentation { data in
            stateFolder.withUnsafeFileSystemRepresentation { state in
                helpersFolder.withUnsafeFileSystemRepresentation { tl_open(data, state, $0, listener, nil) }
            }
        }
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

    nonisolated static func decoded<T: Decodable & Sendable>(_ command: String, _ read: () throws -> Answered<T>) throws -> T {
        let answer: Answered<T>
        do {
            answer = try read()
        } catch {
            throw fault(command, String(describing: error))
        }
        return try answer.get()
    }

    private nonisolated static func replied<T: Decodable & Sendable>(_ command: String, _ said: Data) throws -> T {
        try decoded(command) {
            guard case .reply(let reply) = try JSONDecoder().decode(Said<T>.self, from: said) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a reply"))
            }
            return reply.answer
        }
    }

    private nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TeXLocal", category: "core")

    private nonisolated static func fault(_ command: String, _ problem: String) -> AppFailure {
        log.error("\(command, privacy: .public): \(problem, privacy: .public)")
        return AppFailure("Something went wrong inside TeXLocal. Try again, or quit TeXLocal and open it again.")
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
            ask(sent) { said in
                done.resume(with: Result { try Self.replied(R.command, said) })
            }
        }
    }

    func send<R: SessionRequest>(_ request: R, in session: UInt64, failed: @escaping (any Error) -> Void) {
        let failed = { (error: any Error) in
            Self.log.error("\(R.command, privacy: .public): \(error.localizedDescription, privacy: .public)")
            failed(error)
        }
        do {
            let (handle, json) = try prepared(request)
            ask({ tl_session_send(handle, $0, session, R.command, json) }) { said in
                do { let _: R.Reply = try Self.replied(R.command, said) } catch { failed(error) }
            }
        } catch {
            failed(error)
        }
    }

    func source(session: UInt64, path: String) -> OpaquePointer? { handle.flatMap { tl_session_source($0, session, path) } }

    private nonisolated struct Unread: Decodable, Sendable {
        init(from decoder: any Decoder) {}
    }

    private nonisolated static let heard = AsyncStream.makeStream(of: (Said<Unread>, Data).self)

    private nonisolated static let listener: TlCallback = { _, json in
        let said = Data(bytes: json, count: strlen(json))
        do {
            Core.heard.continuation.yield((try JSONDecoder().decode(Said<Unread>.self, from: said), said))
        } catch {
            Core.log.error("Something from the core the app can't read: \(String(describing: error), privacy: .public)")
        }
    }

    private var observers: [UInt64: (Event) -> Void] = [:]
    private var numbered: UInt64 = 0

    func session() -> UInt64 {
        numbered += 1
        return numbered
    }

    func observe(_ session: UInt64, _ observer: @escaping (Event) -> Void) { observers[session] = observer }

    func forget(_ session: UInt64) { observers[session] = nil }
}

@Observable
final class SessionClient {
    let id: UInt64
    private(set) var closed = false
    @ObservationIgnored private var lifecycle: Lifecycle?
    @ObservationIgnored var heard: (Event) -> Void
    @ObservationIgnored private let core: Core
    @ObservationIgnored private var tasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var started = 0

    init(core: Core, _ heard: @escaping (Event) -> Void = { _ in }) {
        (self.core, self.heard, id) = (core, heard, core.session())
        core.observe(id) { [weak self] in self?.hear($0) }
    }

    private func hear(_ event: Event) {
        if case .section(.lifecycle(let now)) = event { lifecycle = now }
        heard(event)
    }

    @discardableResult
    func call<R: SessionRequest>(_ request: R) async throws -> R.Reply {
        guard !closed else { throw CancellationError() }
        do {
            let reply = try await core.call(request, in: id)
            guard !closed else { throw CancellationError() }
            return reply
        } catch {
            throw ending ? CancellationError() : error
        }
    }

    func send<R: SessionRequest>(_ request: R, else failed: @escaping (any Error) -> Void = { _ in }) {
        guard !closed else { return }
        core.send(request, in: id) { [weak self] in if self?.ending == false { failed($0) } }
    }

    private var ending: Bool { closed || lifecycle == .closing || lifecycle == .closed }

    func source(_ path: String) -> OpaquePointer? { closed ? nil : core.source(session: id, path: path) }

    func task(_ work: @escaping @MainActor () async -> Void) {
        guard !closed else { return }
        started += 1
        let number = started
        tasks[number] = Task { [weak self] in
            await work()
            self?.tasks[number] = nil
        }
    }

    func close() async throws -> Bool {
        do {
            guard try await call(CloseProject()) else { return false }
        } catch let error where error is CancellationError || lifecycle?.stopped != nil {}
        end()
        return true
    }

    func discard() {
        send(CloseProject())
        end()
    }

    private func end() {
        closed = true
        core.forget(id)
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }
}
