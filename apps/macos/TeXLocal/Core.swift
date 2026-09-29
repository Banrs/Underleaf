import Foundation
import TeXLocalCore

/// A command the Rust core refused.
nonisolated struct CoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The Rust core through its C ABI (crates/texlocal-ffi), JSON in and out.
/// `tl_call` blocks for as long as the command runs (minutes, for a compile),
/// so calls run on a GCD thread: the cooperative pool must never block.
final class Core {
    static let shared = Core()

    /// Where projects live: crates/texlocal-core `default_data_dir`'s rule,
    /// `TEXLOCAL_DATA` when set and non-empty, else ~/TeXLocal.
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

    /// Nil when the library folder can't be opened; the window says so.
    private let handle: Handle?
    var isOpen: Bool { handle != nil }

    private init() {
        handle = Self.libraryFolder.withUnsafeFileSystemRepresentation { tl_open($0) }.map(Handle.init)
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
    }

    /// Accepts any JSON, for commands whose result is not needed.
    private nonisolated struct Ignored: Decodable, Sendable {
        init(from decoder: Decoder) throws {}
    }

    private func result<T: Decodable & Sendable>(_ command: String, _ args: [String: Any], as: T.Type) async throws -> T? {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        guard let handle else {
            throw CoreError(message: "TeXLocal can’t open its library folder.")
        }
        let result = await withCheckedContinuation { (done: CheckedContinuation<Result<T?, Error>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(returning: Result {
                    let envelope = try JSONDecoder().decode(Envelope<T>.self, from: Core.run(handle, command, json))
                    if let error = envelope.error { throw CoreError(message: error) }
                    return envelope.ok
                })
            }
        }
        return try result.get()
    }

    func call<T: Decodable & Sendable>(_ command: String, _ args: [String: Any] = [:], as: T.Type = T.self) async throws -> T {
        guard let ok = try await result(command, args, as: T.self) else {
            throw CoreError(message: "The core returned nothing for \(command)")
        }
        return ok
    }

    func perform(_ command: String, _ args: [String: Any] = [:]) async throws {
        _ = try await result(command, args, as: Ignored.self)
    }

    /// Stops running compiles. Synchronous: it runs as the app quits.
    func killAll() {
        guard let handle else { return }
        _ = Core.run(handle, "kill_all", "{}")
    }
}
