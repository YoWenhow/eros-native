// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "ErosPersistence",
    platforms: [.iOS("27.0")],
    products: [.library(name: "ErosPersistence", targets: ["ErosPersistence"])],
    dependencies: [.package(path: "../ErosCore")],
    targets: [
        // No host pkg-config: its Linux library search path must not leak into iOS cross-linking.
        .systemLibrary(name: "CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "ErosPersistence", dependencies: ["CSQLite", .product(name: "ErosCore", package: "ErosCore")]),
        .testTarget(name: "ErosPersistenceTests", dependencies: ["ErosPersistence", "CSQLite"])
    ]
)
