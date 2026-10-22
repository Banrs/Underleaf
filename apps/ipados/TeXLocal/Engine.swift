#if TEXPRESSO
import Foundation
import TeXLocalCore
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
        // Formats made by another build of the engines don't load in this one: a new app starts them again.
        let stamp = caches.appending(path: "app"), built = Bundle.main.executableURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }?.timeIntervalSince1970.description ?? ""
        if (try? String(contentsOf: stamp, encoding: .utf8)) != built {
            try? FileManager.default.removeItem(at: caches)
            try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            try? built.write(to: stamp, atomically: true, encoding: .utf8)
        }
        let variable = caches.appending(path: "texmf-var")
        try? FileManager.default.createDirectory(at: variable, withIntermediateDirectories: true)
        let variables = [
            "TEXMFROOT": tree, "TEXMFDIST": dist, "TEXMFCNF": dist.appending(path: "web2c"),
            "TEXPRESSO_LSR": dist.appending(path: "ls-R"), "ICU_DATA": icu, "TEXMFVAR": variable, "TEXPRESSO_CACHE": caches,
        ]
        for (name, url) in variables { setenv(name, url.path(percentEncoded: false), 1) }
        var engine = tl_engine(live_start: txp_live_start, session_wait: txp_session_wait, run: txp_run)
        tl_set_engine(&engine)
    }
}
#endif
