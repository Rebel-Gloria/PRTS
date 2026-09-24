// swift-tools-version: 5.9
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let contractsOnly = ProcessInfo.processInfo.environment["PRTS_CONTRACTS_ONLY"] == "1"
let hasVLMArtifact = FileManager.default.fileExists(atPath: root.appendingPathComponent("Artifacts/prts_vlm.xcframework").path)

let package: Package
if contractsOnly {
    package = Package(
        name: "PRTSCore",
        platforms: [.iOS(.v16), .macOS(.v13)],
        products: [.library(name: "PRTSContracts", targets: ["PRTSContracts"])],
        targets: [
            .target(name: "PRTSContracts"),
            .testTarget(name: "PRTSContractsTests", dependencies: ["PRTSContracts"], resources: [.process("Resources")])
        ]
    )
} else if hasVLMArtifact {
    package = Package(
        name: "PRTSCore",
        platforms: [.iOS(.v16), .macOS(.v13)],
        products: [
            .library(name: "PRTSContracts", targets: ["PRTSContracts"]),
            .library(name: "PRTSAppleModels", targets: ["PRTSAppleModels"])
        ],
        dependencies: [
            .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.8"),
            .package(url: "https://github.com/csukuangfj/onnxruntime-libs", exact: "1.28.2")
        ],
        targets: [
            .target(name: "PRTSContracts"),
            .testTarget(name: "PRTSContractsTests", dependencies: ["PRTSContracts"], resources: [.process("Resources")]),
            .binaryTarget(name: "prts_vlm", path: "Artifacts/prts_vlm.xcframework"),
            .target(name: "PRTSAppleModels", dependencies: [
                "PRTSContracts", "prts_vlm",
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
                .product(name: "onnxruntime-ios", package: "onnxruntime-libs")
            ], resources: [.copy("Resources/cues")], linkerSettings: [
                .linkedFramework("CoreML"), .linkedFramework("CoreFoundation"), .linkedLibrary("c++")
            ])
        ]
    )
} else {
    // Keep contracts and real BGRA conversion buildable until private/large model artifacts arrive.
    package = Package(
        name: "PRTSCore",
        platforms: [.iOS(.v16), .macOS(.v13)],
        products: [
            .library(name: "PRTSContracts", targets: ["PRTSContracts"]),
            .library(name: "PRTSAppleModels", targets: ["PRTSAppleModels"])
        ],
        targets: [
            .target(name: "PRTSContracts"),
            .target(name: "PRTSAppleModels", dependencies: ["PRTSContracts"], path: "Sources/PRTSAppleModelsLite"),
            .testTarget(name: "PRTSContractsTests", dependencies: ["PRTSContracts"], resources: [.process("Resources")])
        ]
    )
}
