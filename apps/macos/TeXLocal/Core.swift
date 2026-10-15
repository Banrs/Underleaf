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
        libraryFolder.withUnsafeFileSystemRepresentation { tl_open($0) }.map(Handle.init)
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

    private nonisolated static func answer<T: Decodable>(_ handle: Handle, _ command: String, _ json: String) throws -> T? {
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

    /// The arguments are encoded on the GCD thread: escaping a whole document's text for an autosave took 3 ms of the main actor's time per megabyte.
    private func result<T: Decodable & Sendable>(_ command: String, _ args: [String: any Sendable], as: T.Type) async throws -> T? {
        guard let handle else { throw Self.unavailable }
        return try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Result { try Core.answer(handle, command, Core.json(args)) })
            }
        }
    }

    func now(_ command: String, _ args: [String: any Sendable]) throws {
        guard let handle else { throw Self.unavailable }
        let _: Ignored? = try Self.answer(handle, command, try Self.json(args))
    }

    func waiting<T: Decodable & Sendable>(_ command: String, as: T.Type) -> @Sendable ([String: any Sendable]) throws -> T {
        { [handle, unavailable = Self.unavailable] args in
            guard let handle else { throw unavailable }
            guard let answer: T = try Core.answer(handle, command, try Core.json(args)) else { throw Core.fault(command, "no answer") }
            return answer
        }
    }

    func call<T: Decodable & Sendable>(_ command: String, _ args: [String: any Sendable] = [:], as: T.Type) async throws -> T {
        guard let ok = try await result(command, args, as: T.self) else { throw Self.fault(command, "no answer") }
        return ok
    }

    func perform(_ command: String, _ args: [String: any Sendable]) async throws {
        _ = try await result(command, args, as: Ignored.self)
    }

    /// Synchronous: it runs as the app quits.
    func killAll() {
        guard let handle else { return }
        _ = Core.run(handle, "kill_all", "{}")
    }
}
