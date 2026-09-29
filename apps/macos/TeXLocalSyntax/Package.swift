// swift-tools-version: 6.0
import PackageDescription

// The core's editor API (crates/texlocal-syntax) as UniFFI generates it
// (scripts/generate-bindings.sh), in a module of its own: the app's
// main-actor default isolation would make the bindings' own functions
// main-actor ones, which their nonisolated parts can't call. The app links
// the core itself (libtexlocal_ffi.a).
let package = Package(
    name: "TeXLocalSyntax",
    platforms: [.macOS("27.0")],
    products: [.library(name: "TeXLocalSyntax", targets: ["TeXLocalSyntax"])],
    targets: [
        .systemLibrary(name: "texlocal_syntaxFFI"),
        .target(name: "TeXLocalSyntax", dependencies: ["texlocal_syntaxFFI"]),
    ]
)
