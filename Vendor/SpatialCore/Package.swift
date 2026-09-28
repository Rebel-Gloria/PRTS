// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SpatialCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SpatialCore", targets: ["SpatialCore"])],
    targets: [.target(name: "SpatialCore"), .testTarget(name: "SpatialCoreTests", dependencies: ["SpatialCore"])]
)
