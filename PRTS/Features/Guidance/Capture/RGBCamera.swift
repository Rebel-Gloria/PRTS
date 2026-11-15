import AVFoundation
import Foundation
import SpatialCore

nonisolated protocol RGBCapturing: AnyObject, Sendable {
    var session: AVCaptureSession { get }
    var running: Bool { get }
    func setOrientation(_ orientation: ImageOrientation)
    func snapshot(orientation: ImageOrientation) -> CameraImageSnapshot?
    func start(completion: @escaping @Sendable (Bool) -> Void)
    func stop(completion: @escaping @Sendable () -> Void)
}

/// The low-vision camera does no world tracking, depth delivery, mesh reconstruction or inference.
/// Session mutations and frame callbacks share one queue; readers retain only the latest image.
nonisolated final class RGBCamera: NSObject, RGBCapturing,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable
{
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "PRTS.RGBCamera", qos: .userInitiated)
    private let lock = NSLock()
    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var requested = false
    private var latest: CVPixelBuffer?
    private var timestamp: TimeInterval = 0
    private var receivedAt: TimeInterval = 0
    private var isRunning = false
    private var orientation: ImageOrientation = .portrait
    private var frameID: UInt64 = 0

    var running: Bool { lock.withLock { isRunning } }

    func setOrientation(_ orientation: ImageOrientation) {
        lock.withLock { self.orientation = orientation }
    }

    func snapshot(orientation: ImageOrientation) -> CameraImageSnapshot? {
        lock.withLock {
            guard isRunning, let latest else { return nil }
            return CameraImageSnapshot(
                pixelBuffer: latest,
                orientation: orientation,
                timestamp: timestamp,
                receivedAt: receivedAt,
                frameID: frameID
            )
        }
    }

    func start(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            requested = true
            guard configured || configure() else {
                completion(false)
                return
            }
            let alreadyRunning = session.isRunning
            if !alreadyRunning { session.startRunning() }
            let started = session.isRunning
            lock.withLock { isRunning = started }
            #if PRTS_DEV
            if !alreadyRunning || !started {
                RecordingStore.shared.event(
                    started ? "rgb_camera_started" : "rgb_camera_start_failed",
                    details: [:]
                )
            }
            #endif
            completion(started)
        }
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            #if PRTS_DEV
            let wasRequested = requested
            #endif
            requested = false
            if session.isRunning { session.stopRunning() }
            lock.withLock {
                isRunning = false
                latest = nil
            }
            #if PRTS_DEV
            if wasRequested { RecordingStore.shared.event("rgb_camera_stopped", details: [:]) }
            RecordingStore.shared.endVideoSegment(source: "rgb")
            #endif
            completion()
        }
    }

    private func configure() -> Bool {
        guard
            let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Keep the camera's native image shape; recording handles compression separately.
        session.sessionPreset = .high
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        configured = true
        return true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard requested, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard time.isFinite else { return }
        let received = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            latest = image
            timestamp = time
            receivedAt = received
            isRunning = true
            frameID &+= 1
        }
        #if PRTS_DEV
        let identity = lock.withLock { (frameID, orientation) }
        RecordingStore.shared.videoFrame(
            pixelBuffer: image,
            timestamp: time,
            metadata: [
                "source": "rgb", "orientation": String(identity.1.rawValue),
                "frameID": String(identity.0),
            ]
        )
        #endif
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        #if PRTS_DEV
        RecordingStore.shared.noteGap("rgb_capture")
        RecordingStore.shared.event(
            "rgb_camera_frame_dropped",
            details: [
                "timestamp": String(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
            ]
        )
        #endif
    }
}
