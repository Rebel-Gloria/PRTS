import Foundation

/// Explicit capability report for checkouts that do not contain the model runtime artifacts.
public enum PRTSAppleRuntimeCapability {
    public static let coreSessionAvailable = false
    public static let unavailableReason = "PRTSCoreSession is not built: prts_vlm.xcframework and model runtime artifacts are missing."
    public static let missingArtifacts = [
        "Artifacts/prts_vlm.xcframework",
        "semantic segmentation model and manifest",
        "detector model and manifest",
        "language model and projector",
        "SenseVoice model and tokens"
    ]
}
