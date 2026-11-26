// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "ErosSession", platforms: [.iOS("27.0")],
    products: [.library(name: "ErosSession", targets: ["ErosSession"])],
    dependencies: [.package(path: "../ErosCore"), .package(path: "../ErosNetworking"), .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3")],
    targets: [.target(name: "ErosSession", dependencies: [.product(name: "ErosCore", package: "ErosCore"), .product(name: "ErosNetworking", package: "ErosNetworking"), .product(name: "SwiftSoup", package: "SwiftSoup")]),
              .testTarget(name: "ErosSessionTests", dependencies: ["ErosSession"])])
