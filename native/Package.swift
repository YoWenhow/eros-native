// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "ErosNative",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "ErosNative", targets: ["ErosNative"])
    ],
    dependencies: [.package(path: "Packages/ErosCore"), .package(path: "Packages/ErosPersistence"), .package(path: "Packages/ErosNetworking"), .package(path: "Packages/ErosServices"), .package(path: "Packages/ErosSession")],
    targets: [
        .target(name: "ErosNative", dependencies: [.product(name: "ErosCore", package: "ErosCore"), .product(name: "ErosPersistence", package: "ErosPersistence"), .product(name: "ErosNetworking", package: "ErosNetworking"), .product(name: "ErosServices", package: "ErosServices"), .product(name: "ErosSession", package: "ErosSession")], exclude: ["ContentView.swift", "NativeLibraryView.swift", "NativeDetailView.swift", "NativeReaderView.swift", "NetworkAcceptanceView.swift", "PersistenceAcceptanceView.swift", "PerformanceAcceptanceView.swift", "Probes", "Resources/PerformanceFixtures", "Resources/ProbeBackground.png"], resources: [.copy("Resources/ThirdPartyNotices.txt")], linkerSettings: [.linkedLibrary("sqlite3")])
    ]
)
