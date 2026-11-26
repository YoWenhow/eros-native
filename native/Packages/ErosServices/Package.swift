// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "ErosServices", platforms: [.iOS("27.0")],
    products: [.library(name: "ErosServices",targets: ["ErosServices"]), .library(name: "ErosOfflineDemo",targets: ["ErosOfflineDemo"])],
    dependencies: [.package(path: "../ErosCore"), .package(path: "../ErosNetworking"), .package(path: "../ErosPersistence"), .package(path: "../../Prototypes/F21ArchiveExtraction")],
    targets: [
        .target(name: "ErosServices",dependencies: [.product(name: "ErosCore",package: "ErosCore"), .product(name: "ErosNetworking",package: "ErosNetworking"), .product(name: "ErosPersistence",package: "ErosPersistence"), .product(name: "F21ArchiveExtraction",package: "F21ArchiveExtraction")]),
        .target(name: "ErosOfflineDemo",dependencies: ["ErosServices"],resources: [.copy("Resources")]),
        .testTarget(name: "ErosServicesTests",dependencies: ["ErosServices","ErosOfflineDemo",.product(name: "F21ArchiveExtraction",package: "F21ArchiveExtraction")],resources: [.copy("Fixtures")])
    ])
