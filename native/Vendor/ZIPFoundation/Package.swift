// swift-tools-version: 6.0
import PackageDescription

// ZIPFoundation 0.9.20, commit 22787ffb59de99e5dc1fbfe80b19c97a904ad48d.
// Its upstream manifest selects CZLib by the Linux *host* compiler even when
// SwiftPM cross-builds the iOS app. Target-conditional dependency keeps the
// Linux tests on zlib and the iOS build on Apple's Compression framework.
let package = Package(
    name: "ZIPFoundation",
    platforms: [.iOS(.v12), .macOS(.v10_13)],
    products: [.library(name: "ZIPFoundation", targets: ["ZIPFoundation"])],
    targets: [
        .systemLibrary(name: "CZLib", pkgConfig: "zlib", providers: [.apt(["zlib"])]),
        .target(name: "ZIPFoundation", dependencies: [
            .target(name: "CZLib", condition: .when(platforms: [.linux]))
        ], resources: [.copy("Resources/PrivacyInfo.xcprivacy")],
        cSettings: [.define("_GNU_SOURCE", to: "1", .when(platforms: [.linux]))])
    ],
    swiftLanguageModes: [.v5]
)
