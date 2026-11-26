// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "F21ArchiveExtraction",
    platforms: [.iOS("27.0")],
    products: [.library(name: "F21ArchiveExtraction", targets: ["F21ArchiveExtraction"])],
    dependencies: [
        .package(path: "../../Vendor/ZIPFoundation")
    ],
    targets: [
        .target(name: "F21ArchiveExtraction", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        .testTarget(name: "F21ArchiveExtractionTests", dependencies: ["F21ArchiveExtraction", .product(name: "ZIPFoundation", package: "ZIPFoundation")])
    ]
)
