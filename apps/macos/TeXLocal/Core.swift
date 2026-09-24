import Foundation
import TeXLocalCore

/// A command the Rust core refused, with the status it gave (400 for a bad
/// request, 404 for something missing, 500 for an I/O failure).
struct CoreError: LocalizedError {
    let message: String
    let status: Int
    var errorDescription: String? { message }
}

/// The Rust core through its C ABI (crates/texlocal-ffi): JSON in, JSON out,
/// the same command names the browser version uses. `tl_call` blocks for as
/// long as the command runs — minutes, for a compile — so every call runs on a
/// detached task and the main actor only encodes and decodes.
@MainActor
final class Core {
    static let shared = Core()

    /// The Rust side accepts concurrent calls from any thread.
    private final class Handle: @unchecked Sendable {
        let raw: OpaquePointer
        init(_ raw: OpaquePointer) { self.raw = raw }
    }

    private let handle: Handle

    private init() {
        guard let raw = tl_open(nil) else {
            fatalError("TeXLocal could not open its library folder (~/TeXLocal).")
        }
        handle = Handle(raw)
    }

    private nonisolated static func run(_ handle: Handle, _ command: String, _ json: String) -> Data {
        let out = command.withCString { c in json.withCString { j in tl_call(handle.raw, c, j) } }
        guard let out else { return Data() }
        defer { tl_free(out) }
        return Data(bytes: out, count: strlen(out))
    }

    private struct Envelope<T: Decodable>: Decodable {
        let ok: T?
        let error: String?
        let status: Int?
    }

    /// Accepts any JSON, for commands whose result is not needed.
    private struct Ignored: Decodable {
        init(from decoder: Decoder) throws {}
    }

    private func send(_ command: String, _ args: [String: Any]) async throws -> Data {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        let handle = handle
        return await Task.detached { Core.run(handle, command, json) }.value
    }

    func call<T: Decodable>(_ command: String, _ args: [String: Any] = [:], as: T.Type = T.self) async throws -> T {
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: try await send(command, args))
        if let error = envelope.error {
            throw CoreError(message: error, status: envelope.status ?? 500)
        }
        guard let ok = envelope.ok else {
            throw CoreError(message: "The core returned nothing for \(command)", status: 500)
        }
        return ok
    }

    func perform(_ command: String, _ args: [String: Any] = [:]) async throws {
        let envelope = try JSONDecoder().decode(Envelope<Ignored>.self, from: try await send(command, args))
        if let error = envelope.error {
            throw CoreError(message: error, status: envelope.status ?? 500)
        }
    }

    /// Stop running compiles. Synchronous on purpose: it runs as the app quits.
    func killAll() {
        _ = Core.run(handle, "kill_all", "{}")
    }
}
