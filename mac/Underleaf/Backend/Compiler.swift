import Foundation

// Port of server/compile.js — latexmk compilation, log parsing, SyncTeX.

struct LogItem: Codable { var type: String; var file: String?; var line: Int?; var message: String }

struct CompileResult {
    var ok: Bool
    var killed: Bool
    var durationMs: Double
    var pdf: String?          // project-relative, e.g. "build/main.pdf"
    var errors: [LogItem]
    var warnings: [LogItem]
    var log: String
}

struct SyncInverse { var file: String; var line: Int }

enum Compiler {
    private static let timeout: TimeInterval = 180
    // Cap what we hold from a child; a runaway document can print for the whole
    // timeout window.
    private static let maxOutput = 1_000_000
    private static let engineFlags = ["pdflatex": ["-pdf"], "xelatex": ["-xelatex"], "lualatex": ["-lualatex"]]

    // PATH for spawned TeX tools (GUI apps miss the TeX bins). /Library/TeX/texbin is
    // MacTeX's year-agnostic symlink; also discover /usr/local/texlive/<year>/bin/<arch>.
    private static let texPath: String = {
        var dirs = ["/Library/TeX/texbin", "/usr/local/bin", "/opt/homebrew/bin"]
        if let years = try? FileManager.default.contentsOfDirectory(atPath: "/usr/local/texlive") {
            for y in years.filter({ $0.range(of: #"^\d{4}$"#, options: .regularExpression) != nil }).sorted().reversed() {
                let bin = "/usr/local/texlive/\(y)/bin"
                for arch in (try? FileManager.default.contentsOfDirectory(atPath: bin)) ?? [] { dirs.append("\(bin)/\(arch)") }
            }
        }
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return ([existing] + dirs).filter { !$0.isEmpty }.joined(separator: ":")
    }()

    private static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment; e["PATH"] = texPath; return e
    }

    private struct RunResult { var code: Int32; var killed: Bool; var output: String }

    // Thread-safe, size-capped accumulator for the child's output.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data, cap: Int) {
            lock.lock(); defer { lock.unlock() }
            if data.count < cap { data.append(d) }
        }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @discardableResult
    private static func run(_ cmd: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval = timeout) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")   // resolve cmd via PATH
        p.arguments = [cmd] + args
        p.environment = env
        if let cwd { p.currentDirectoryURL = cwd }
        // Never inherit the app's stdin — a TeX run that drops out of batchmode
        // would otherwise wait on it forever.
        p.standardInput = FileHandle.nullDevice
        // Merge both streams into one pipe and drain it incrementally:
        // readDataToEndOfFile returns only when EVERY writer closes the pipe, so
        // a surviving grandchild (pdflatex under a killed latexmk) would block
        // the read forever, and the whole output would sit in memory uncapped.
        let output = Pipe()
        p.standardOutput = output
        p.standardError = output
        let collected = OutputBuffer()
        output.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            collected.append(d, cap: maxOutput)
        }
        do { try p.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return RunResult(code: -1, killed: false, output: String(describing: error))
        }
        // Kill on timeout; escalate to SIGKILL if SIGTERM is ignored.
        let killed = Flag()
        let pid = p.processIdentifier
        let killer = DispatchWorkItem {
            guard p.isRunning else { return }
            killed.set()
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        output.fileHandleForReading.readabilityHandler = nil
        return RunResult(code: p.terminationStatus, killed: killed.isSet, output: collected.text)
    }

    static func texAvailable() -> (available: Bool, version: String?) {
        let r = run("latexmk", ["-version"], timeout: 10)
        return (r.code == 0, r.code == 0 ? r.output.split(separator: "\n").first.map(String.init) : nil)
    }

    // MARK: log parsing (mirrors parseLog; -file-line-error format)

    static func parseLog(_ log: String, mainFile: String) -> [LogItem] {
        var items: [LogItem] = []
        let lines = log.components(separatedBy: "\n")
        let fileLine = try! NSRegularExpression(pattern: #"^(.+?\.(?:tex|sty|cls|bib|def|clo)):(\d+):\s*(.*)$"#, options: .caseInsensitive)
        for i in 0..<lines.count {
            let line = lines[i]
            let ns = line as NSString
            if let m = fileLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                var message = ns.substring(with: m.range(at: 3))
                var j = i + 1
                while j < min(i + 4, lines.count) {
                    if lines[j].range(of: #"^(l\.\d+|\s*$|!)"#, options: .regularExpression) != nil { break }
                    message += " " + lines[j].trimmingCharacters(in: .whitespaces); j += 1
                }
                let f = ns.substring(with: m.range(at: 2))
                let file = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: #"^\./"#, with: "", options: .regularExpression)
                items.append(LogItem(type: "error", file: file, line: Int(f), message: message.trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix("! ") {
                var lineNo: Int? = nil
                var j = i + 1
                while j < min(i + 12, lines.count) {
                    if let r = lines[j].range(of: #"^l\.(\d+)"#, options: .regularExpression) {
                        lineNo = Int(lines[j][r].dropFirst(2)); break
                    }
                    j += 1
                }
                items.append(LogItem(type: "error", file: mainFile, line: lineNo, message: String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let r = line.range(of: #"Warning:\s*(.*)$"#, options: .regularExpression),
               line.range(of: #"^(LaTeX|Package \S+|Class \S+) Warning:"#, options: .regularExpression) != nil {
                var message = String(line[r].dropFirst("Warning:".count)).trimmingCharacters(in: .whitespaces)
                // Warnings often wrap onto continuation lines (mirrors the JS parser).
                var j = i + 1
                while j < min(i + 3, lines.count) {
                    let next = lines[j]
                    if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    if next.range(of: #"Warning|Error|^!"#, options: .regularExpression) != nil { break }
                    message += " " + next.trimmingCharacters(in: .whitespaces); j += 1
                }
                let lm = message.range(of: #"on input line (\d+)"#, options: .regularExpression)
                let ln = lm.flatMap { Int(message[$0].components(separatedBy: " ").last ?? "") }
                items.append(LogItem(type: "warning", file: nil, line: ln, message: message))
            }
        }
        // De-dup repeated messages.
        var seen = Set<String>()
        return items.filter { seen.insert("\($0.type)|\($0.file ?? "")|\($0.line ?? -1)|\($0.message)").inserted }
    }

    // MARK: compile

    static func compile(_ root: URL) throws -> CompileResult {
        let settings = ProjectStore.readSettings(root)
        guard let flags = engineFlags[settings.engine] else { throw BackendError("Unknown engine: \(settings.engine)") }
        let safeMainFile = try ProjectStore.safeRelativeFile(root, settings.mainFile)
        guard FileManager.default.fileExists(atPath: try ProjectStore.safePath(root, safeMainFile).path) else {
            throw BackendError("Main file not found: \(settings.mainFile)")
        }
        let outdir = root.appendingPathComponent(ProjectStore.buildDir)
        try? FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)

        var args = flags + ["-interaction=batchmode", "-file-line-error", "-synctex=1", "-halt-on-error", "-outdir=\(ProjectStore.buildDir)"]
        if settings.shellEscape { args.append("-shell-escape") }
        args.append("./" + safeMainFile)

        let started = Date()
        let r = run("latexmk", args, cwd: root)
        let base = ((safeMainFile as NSString).lastPathComponent as NSString).deletingPathExtension
        let logURL = outdir.appendingPathComponent(base + ".log")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? r.output
        let issues = parseLog(log, mainFile: safeMainFile)
        let pdfURL = outdir.appendingPathComponent(base + ".pdf")
        let pdfExists = FileManager.default.fileExists(atPath: pdfURL.path)

        return CompileResult(
            ok: r.code == 0 && pdfExists, killed: r.killed,
            durationMs: Date().timeIntervalSince(started) * 1000,
            pdf: pdfExists ? "\(ProjectStore.buildDir)/\(base).pdf" : nil,
            errors: issues.filter { $0.type == "error" }, warnings: issues.filter { $0.type == "warning" },
            log: String(log.suffix(200_000)))
    }

    // MARK: SyncTeX (inverse: PDF click → source)

    static func synctexInverse(_ root: URL, page: Int, x: Double, y: Double) throws -> SyncInverse {
        let pdf = ProjectStore.compiledPdfPath(root)
        guard FileManager.default.fileExists(atPath: pdf.path) else { throw BackendError("No compiled PDF yet") }
        let r = run("synctex", ["edit", "-o", "\(page):\(x):\(y):\(pdf.path)"], cwd: root, timeout: 10)
        guard r.code == 0 else { throw BackendError("synctex edit failed") }
        guard let fileLine = r.output.range(of: #"(?m)^Input:(.*)$"#, options: .regularExpression),
              let lineLine = r.output.range(of: #"(?m)^Line:(\d+)$"#, options: .regularExpression) else {
            throw BackendError("No SyncTeX match")
        }
        let file = String(r.output[fileLine].dropFirst("Input:".count))
        let line = Int(r.output[lineLine].dropFirst("Line:".count)) ?? 0
        let rel = URL(fileURLWithPath: file).standardizedFileURL.path
        let relPath = rel.hasPrefix(root.path + "/") ? String(rel.dropFirst(root.path.count + 1)) : file
        guard !relPath.hasPrefix(".."), !relPath.hasPrefix(ProjectStore.buildDir + "/"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(relPath).path) else {
            throw BackendError("No source file at this location")
        }
        return SyncInverse(file: relPath, line: line)
    }
}
