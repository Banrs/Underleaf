#if TEXPRESSO
import Foundation
import Texpresso

/// TeX in the app's own process, as iPadOS starts no others: TeXpresso's engines, their tree in the bundle, and what
/// they make (formats, font caches) in the container's caches.
enum Engine {
    /// Before the core opens: the engines read their variables then, and the core asks for them from its first build.
    static func start() {
        guard let tree = Bundle.main.url(forResource: "texmf", withExtension: nil),
              let icu = Bundle.main.url(forResource: "icu", withExtension: nil) else { return }
        let dist = tree.appending(path: "texmf-dist")
        let caches = URL.cachesDirectory.appending(path: "TeX")
        let variables = [
            "TEXMFROOT": tree, "TEXMFDIST": dist, "TEXMFCNF": dist.appending(path: "web2c"),
            "TEXPRESSO_LSR": dist.appending(path: "ls-R"), "ICU_DATA": icu,
            "TEXMFVAR": caches.appending(path: "texmf-var"), "TEXPRESSO_CACHE": caches,
        ]
        for (name, url) in variables {
            if url.path().hasPrefix(caches.path()) { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            setenv(name, url.path(percentEncoded: false), 1)
        }
        var engine = tl_engine(
            live_start: { argc, argv, pdf, commands, messages, log in
                UnsafeMutableRawPointer(txp_live_start(argc, argv, pdf, commands, messages, log))
            },
            session_wait: { txp_session_wait(OpaquePointer($0)) },
            run: { txp_run($0, $1, $2, $3, $4, $5, $6) })
        tl_set_engine(&engine)
    }
}
#endif
