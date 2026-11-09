/// Main-actor presentation state for the home screen and spatial settings.
/// This is the app's runtime implementation; the same-named type in Experiments/SpatialProbe/
/// is a frozen reference excluded from the app build.

import AVFoundation
import Combine
import SpatialCore
import SwiftUI

@MainActor
final class ProbeViewModel: ObservableObject {
    let engine: ProbeEngine
    #if PRTS_DEV_CAPTURE
    @Published var recordingStatus = RecordingRecorder.Status()
    func recordingAudioInterrupted() {
        engine.stopRecording(reason: "音频中断")
        recordingStatus = engine.recording.status()
    }
    var recordingMode: Bool {
        get { recordingStatus.mode }
        set {
            engine.setRecordingMode(newValue)
            recordingStatus = engine.recording.status()
        }
    }
    #endif
    @Published var snapshot = SharedSnapshot()
    @Published var options = RenderOptions() {
        didSet { engine.updateOptions(options) }
    }
    /// Settings → Display → Scan mesh, the one picture option release builds offer.
    static let scanMeshKey = "display.scanMesh"
    var scanMesh: Bool {
        get { options.showMesh }
        set {
            var updated = options
            updated.showMesh = newValue
            if newValue { updated.showPath = false }
            options = updated
            UserDefaults.standard.set(newValue, forKey: Self.scanMeshKey)
        }
    }
    var supportsScanMesh: Bool { engine.capabilities.meshClassification }
    private let parameters = ProbeParameters()
    var feedbackSuspended = false
    private let feedback: any SpatialFeedback
    @Published var permissionMessage: String?
    @Published var requestingPermission = false
    @Published var errorMessage: String?
    private var lastThermal = -1
    private var lastHeartbeat: Double = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    init(engine: ProbeEngine, feedback: any SpatialFeedback) {
        self.engine = engine
        self.feedback = feedback
        options = .product(scanMesh: UserDefaults.standard.bool(forKey: Self.scanMeshKey))
        engine.updateOptions(options)
        UIDevice.current.isBatteryMonitoringEnabled = true
        engine.diagnostics.event(
            "launch_environment",
            details: deviceMetadata.description,
            epoch: 0
        )
        engine.diagnostics.event(
            "camera_permission_initial",
            details: String(AVCaptureDevice.authorizationStatus(for: .video).rawValue),
            epoch: 0
        )
    }
    func lifecycle(_ phase: ScenePhase) {
        engine.diagnostics.event(
            "scene_phase",
            details: String(describing: phase),
            epoch: engine.store.read().epoch
        )
        if phase != .active {
            feedback.reset()
            engine.stop(reason: "已切到后台，回来后请重新开始")
        }
        if phase == .background {
            endBackgroundFlush()
            backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "Flush diagnostic measurements"
            ) { [weak self] in self?.endBackgroundFlush() }
            let requestedTask = backgroundTask
            engine.flushDiagnostics(lifecycle: "background") { [weak self] in
                Task { @MainActor [weak self] in
                    if self?.backgroundTask == requestedTask { self?.endBackgroundFlush() }
                }
            }
        } else if phase == .active {
            poll()
        }
    }
    private func endBackgroundFlush() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    var capabilities: DeviceCapabilities { engine.capabilities }
    func poll() {
        #if PRTS_DEV_CAPTURE
        recordingStatus = engine.recording.status()
        #endif
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal.rawValue != lastThermal {
            lastThermal = thermal.rawValue
            let name: String
            switch thermal {
            case .nominal: name = "nominal"
            case .fair: name = "fair"
            case .serious: name = "serious（分析降至≤5 Hz）"
            case .critical: name = "critical（暂停分析）"
            @unknown default: name = "unknown"
            }
            engine.setThermal(raw: thermal.rawValue, name: name)
        }
        let uiOrientation =
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?
            .interfaceOrientation ?? .portrait
        let orientation: ImageOrientation
        switch uiOrientation {
        case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        default: orientation = .portrait
        }
        engine.store.update { $0.orientation = orientation }
        snapshot = engine.store.read()
        feedback.tick(snapshot, diagnostics: engine.diagnostics, suspended: feedbackSuspended)
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastHeartbeat >= 1 {
            lastHeartbeat = now
            engine.diagnostics.heartbeat(
                snapshot,
                permission: String(AVCaptureDevice.authorizationStatus(for: .video).rawValue),
                batteryLevel: UIDevice.current.batteryLevel,
                batteryState: UIDevice.current.batteryState.rawValue,
                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                appState: String(UIApplication.shared.applicationState.rawValue)
            )
        }
    }
    func start(allowed: Bool, isActive: Bool) async {
        engine.diagnostics.event(
            "camera_permission_result",
            details: allowed ? "authorized" : "denied_or_restricted",
            epoch: snapshot.epoch
        )
        if allowed && isActive {
            permissionMessage = nil
            engine.updateParameters(parameters)
            engine.updateOptions(options)
            await withCheckedContinuation { done in
                engine.start(device: deviceMetadata) { done.resume() }
            }
        } else if allowed {
            permissionMessage = "已授权，回到 PRTS 后点“开始”。"
        } else {
            permissionMessage = "没有相机权限。请到“设置”里打开。"
        }
    }
    var deviceMetadata: [String: String] {
        var info = utsname()
        uname(&info)
        let hardware = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        return [
            "hardwareIdentifier": hardware, "deviceModel": UIDevice.current.model,
            "system": UIDevice.current.systemVersion,
            "applicationVersion": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "capabilities": capabilities.description,
        ]
    }
}
