// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "ErosCore",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "ErosCore", targets: ["ErosCore"]),
        .library(name: "ErosCoreTestSupport", targets: ["ErosCoreTestSupport"])
    ],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3")],
    targets: [
        .target(name: "ErosCore", dependencies: ["SwiftSoup"]),
        .target(name: "ErosCoreTestSupport", dependencies: ["ErosCore"]),
        .testTarget(name: "ErosCoreTests", dependencies: ["ErosCore", "ErosCoreTestSupport"], resources: [.copy("Fixtures")])
    ]
)
