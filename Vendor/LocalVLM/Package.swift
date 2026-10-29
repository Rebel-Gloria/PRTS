// swift-tools-version: 5.9
import PackageDescription

// The binary target is built by prepare.sh; it is not checked in.
let package = Package(
    name: "LocalVLM",
    platforms: [.iOS(.v17)],
    products: [.library(name: "LocalVLM", targets: ["LocalVLM"])],
    targets: [
        .binaryTarget(name: "CPRTSLocalVLM", path: "PRTSLocalVLM.xcframework"),
        .target(name: "LocalVLM", dependencies: ["CPRTSLocalVLM"],
                linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Metal"), .linkedFramework("Accelerate")]),
    ]
)
