import ARKit
import Foundation
import SpatialCore
import simd

extension RigidPose {
    nonisolated init(_ matrix: simd_float4x4) {
        self.init(
            right: V3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
            up: V3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
            back: V3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z),
            position: V3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
        )
    }
}

/// Retains immutable ARFrame pixel buffers until CPU reads/GPU commands finish. No buffer is mutated.
final class FrameSnapshot: @unchecked Sendable {
    let frame: ARFrame
    let usesMonocular: Bool
    let orientation: ImageOrientation
    let epoch: UInt64
    let id: UInt64
    let receivedAt: Double
    let directionDiagnostics: DirectionDiagnostics?
    let directionStable: Bool
    let trackingNormal: Bool
    let tracking: String
    let parameters: ProbeParameters
    let parameterVersion: UInt64
    let captureMilliseconds: Double
    let pose: RigidPose
    let intrinsics: CameraIntrinsics
    init(
        frame: ARFrame,
        epoch: UInt64,
        id: UInt64,
        receivedAt: Double,
        directionStable: Bool,
        parameters: ProbeParameters,
        parameterVersion: UInt64,
        directionDiagnostics: DirectionDiagnostics? = nil,
        usesMonocular: Bool = false,
        orientation: ImageOrientation = .portrait
    ) {
        self.usesMonocular = usesMonocular
        self.orientation = orientation
        self.frame = frame
        self.epoch = epoch
        self.id = id
        self.receivedAt = receivedAt
        self.directionStable = directionStable
        self.directionDiagnostics = directionDiagnostics
        self.parameters = parameters
        self.parameterVersion = parameterVersion
        pose = RigidPose(frame.camera.transform)
        let k = frame.camera.intrinsics
        let s = frame.camera.imageResolution
        intrinsics = CameraIntrinsics(
            fx: k[0][0],
            fy: k[1][1],
            cx: k[2][0],
            cy: k[2][1],
            width: Int(s.width),
            height: Int(s.height)
        )
        switch frame.camera.trackingState {
        case .normal:
            trackingNormal = true
            tracking = "正常"
        case .notAvailable:
            trackingNormal = false
            tracking = "不可用"
        case .limited(let reason):
            trackingNormal = false
            switch reason {
            case .initializing: tracking = "受限：初始化"
            case .excessiveMotion: tracking = "受限：移动过快"
            case .insufficientFeatures: tracking = "受限：特征不足"
            case .relocalizing: tracking = "受限：重定位"
            @unknown default: tracking = "受限：未知原因"
            }
        }
        captureMilliseconds = (ProcessInfo.processInfo.systemUptime - receivedAt) * 1000
    }
    struct DepthRead {
        var observation: DepthObservation?
        var status: String
        var confidenceStatus: String = "not_read"
    }
    func depthObservation() -> DepthObservation? { readDepth().observation }
    func readDepth() -> DepthRead {
        guard !usesMonocular else { return .init(status: "monocular_backend_no_scene_depth_read") }
        guard let data = frame.sceneDepth else { return .init(status: "scene_depth_missing") }
        let buffer = data.depthMap
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else {
            return .init(status: "unsupported_depth_format")
        }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return .init(status: "depth_lock_failed")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return .init(status: "depth_base_address_missing")
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: w * h)
        for row in 0..<h {
            let ptr = base.advanced(by: row * stride).assumingMemoryBound(to: Float.self)
            values.replaceSubrange(
                row * w..<(row + 1) * w,
                with: UnsafeBufferPointer(start: ptr, count: w)
            )
        }
        var confidence: [UInt8]?
        var confidenceStatus = data.confidenceMap == nil ? "missing" : "size_or_format_mismatch"
        if let cb = data.confidenceMap, CVPixelBufferGetWidth(cb) == w,
            CVPixelBufferGetHeight(cb) == h,
            CVPixelBufferGetPixelFormatType(cb) == kCVPixelFormatType_OneComponent8
        {
            guard CVPixelBufferLockBaseAddress(cb, .readOnly) == kCVReturnSuccess else {
                return .init(
                    observation: .init(
                        width: w,
                        height: h,
                        depth: values,
                        confidence: nil,
                        intrinsics: intrinsics.scaled(width: w, height: h),
                        pose: pose,
                        timestamp: frame.timestamp,
                        frameID: id,
                        epoch: epoch
                    ),
                    status: "available",
                    confidenceStatus: "confidence_lock_failed"
                )
            }
            confidenceStatus = "base_address_missing"
            if let cbase = CVPixelBufferGetBaseAddress(cb) {
                let cs = CVPixelBufferGetBytesPerRow(cb)
                var bytes = [UInt8](repeating: 0, count: w * h)
                for row in 0..<h {
                    bytes.replaceSubrange(
                        row * w..<(row + 1) * w,
                        with: UnsafeBufferPointer(
                            start: cbase.advanced(by: row * cs).assumingMemoryBound(to: UInt8.self),
                            count: w
                        )
                    )
                }
                confidence = bytes
                confidenceStatus = "available"
            }
            CVPixelBufferUnlockBaseAddress(cb, .readOnly)
        }
        return .init(
            observation: .init(
                width: w,
                height: h,
                depth: values,
                confidence: confidence,
                intrinsics: intrinsics.scaled(width: w, height: h),
                pose: pose,
                timestamp: frame.timestamp,
                frameID: id,
                epoch: epoch
            ),
            status: "available",
            confidenceStatus: confidenceStatus
        )
    }
}
