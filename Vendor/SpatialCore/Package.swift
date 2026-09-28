// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Keep sensor-loop math fast even when the UI is built with Debug.
// Opt out only for source-level math debugging; not for live sensor acceptance.
let optimizeSensorMath = ProcessInfo.processInfo.environment["PRTS_SPATIAL_UNOPTIMIZED"] != "1"
let package = Package(
    name: "SpatialCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SpatialCore", targets: ["SpatialCore"])],
    targets: [.target(name: "SpatialCore", swiftSettings: optimizeSensorMath ? [.unsafeFlags(["-O"], .when(configuration: .debug))] : []), .testTarget(name: "SpatialCoreTests", dependencies: ["SpatialCore"])]
)
