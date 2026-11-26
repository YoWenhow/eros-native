// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "ErosNetworking", platforms: [.iOS("27.0")],
    products: [.library(name: "ErosNetworking",targets: ["ErosNetworking"])],
    dependencies: [.package(path: "../ErosCore")],
    targets: [.target(name: "ErosNetworking",dependencies: [.product(name: "ErosCore",package: "ErosCore")]),
              .testTarget(name: "ErosNetworkingTests",dependencies: ["ErosNetworking"])])
