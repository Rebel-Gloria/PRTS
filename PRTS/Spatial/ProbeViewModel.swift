import SwiftUI
import Combine
import AVFoundation
import SpatialCore

@MainActor
final class ProbeViewModel: ObservableObject {
    let engine = ProbeEngine()
    @Published var snapshot = SharedSnapshot()
    @Published var options = RenderOptions()
    @Published var parameters = ProbeParameters()
    @Published var pathOptions = PathOptions()
    @Published var hapticStatus = "等待路径"
    var feedbackSuspended = false
    private let pathHaptics = PathHaptics()
    @Published var recorderStatus = RecorderStatus()
    @Published var diagnosticStatus = DiagnosticStatus()
    @Published var diagnosticRuns: [DiagnosticRun] = []
    @Published var permissionMessage: String?
    @Published var requestingPermission = false
    @Published var exporting = false
    @Published var exportURL: URL?
    @Published var errorMessage: String?
    private var lastThermal = -1
    private var lastHeartbeat: Double = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    init() {
        if let data = UserDefaults.standard.data(forKey:"pathOptions"),let options = try? JSONDecoder().decode(PathOptions.self,from:data) { pathOptions = options.validated() }
        engine.store.update { $0.pathOptions = pathOptions }
        UIDevice.current.isBatteryMonitoringEnabled = true
        engine.diagnostics.event("launch_environment",details:deviceMetadata.description,epoch:0)
        engine.diagnostics.event("camera_permission_initial",details:String(AVCaptureDevice.authorizationStatus(for:.video).rawValue),epoch:0)
    }
    func lifecycle(_ phase: ScenePhase) {
        engine.diagnostics.event("scene_phase",details:String(describing:phase),epoch:engine.store.read().epoch)
        if phase != .active { pathHaptics.stop(reset:true); engine.stop(reason:"应用离开前台；请返回后重新开始") }
        if phase == .background {
            endBackgroundFlush()
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName:"Flush diagnostic measurements") { [weak self] in self?.endBackgroundFlush() }
            let requestedTask = backgroundTask
            engine.flushDiagnostics(lifecycle:"background") { [weak self] in Task { @MainActor in
                if self?.backgroundTask == requestedTask { self?.endBackgroundFlush() }
            } }
        } else if phase == .active { poll() }
    }
    private func endBackgroundFlush() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    func refreshDiagnostics() {
        engine.diagnostics.journal.listRuns { [weak self] runs in Task { @MainActor in self?.diagnosticRuns = runs } }
    }
    func exportDiagnostics(runID: String? = nil) {
        guard !exporting else { return }; exporting = true
        engine.diagnostics.journal.export(runID:runID,to:FileManager.default.temporaryDirectory.appendingPathComponent("DiagExports",isDirectory:true)) { [weak self] result in
            Task { @MainActor in
                self?.exporting = false
                switch result { case .success(let url): self?.exportURL = url; case .failure(let error): self?.errorMessage = error.localizedDescription }
            }
        }
    }
    var capabilities: DeviceCapabilities { engine.capabilities }
    func poll() {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal.rawValue != lastThermal {
            lastThermal = thermal.rawValue
            let name: String
            switch thermal { case .nominal: name = "nominal"; case .fair: name = "fair"; case .serious: name = "serious（分析降至≤5 Hz）"; case .critical: name = "critical（暂停分析）"; @unknown default: name = "unknown" }
            engine.setThermal(raw:thermal.rawValue,name:name)
        }
        let uiOrientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.interfaceOrientation ?? .portrait
        let orientation: ImageOrientation
        switch uiOrientation { case .landscapeLeft: orientation = .landscapeLeft; case .landscapeRight: orientation = .landscapeRight; case .portraitUpsideDown: orientation = .portraitUpsideDown; default: orientation = .portrait }
        engine.store.update { $0.orientation = orientation }
        snapshot = engine.store.read(); recorderStatus = engine.recorder.status(); diagnosticStatus = engine.diagnostics.journal.status()
        pathHaptics.tick(snapshot,diagnostics:engine.diagnostics,suspended:feedbackSuspended)
        hapticStatus = pathHaptics.status
        let now = ProcessInfo.processInfo.systemUptime
        if now-lastHeartbeat >= 1 {
            lastHeartbeat = now
            engine.diagnostics.heartbeat(snapshot,permission:String(AVCaptureDevice.authorizationStatus(for:.video).rawValue),batteryLevel:UIDevice.current.batteryLevel,
                batteryState:UIDevice.current.batteryState.rawValue,lowPower:ProcessInfo.processInfo.isLowPowerModeEnabled,appState:String(UIApplication.shared.applicationState.rawValue))
        }
    }
    func setSimulatedNoLiDAR(_ value: Bool) { engine.setSimulatedNoLiDAR(value,device:deviceMetadata); poll() }
    func startOrStop() {
        if snapshot.running { engine.stop(); poll(); return }
        guard !requestingPermission else { return }
        guard capabilities.world else { engine.start(device:deviceMetadata); poll(); return }
        engine.diagnostics.event("camera_start_requested",details:"user_action",epoch:snapshot.epoch)
        requestingPermission = true
        Task {
            defer { requestingPermission = false }
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for:.video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for:.video)
            case .denied,.restricted: allowed = false
            @unknown default: allowed = false
            }
            engine.diagnostics.event("camera_permission_result",details:allowed ? "authorized" : "denied_or_restricted",epoch:snapshot.epoch)
            if allowed && UIApplication.shared.applicationState == .active {
                permissionMessage = nil; engine.updateParameters(parameters); engine.updateOptions(options); engine.start(device:deviceMetadata)
            } else if allowed { permissionMessage = "已授权；请返回前台后点击开始。"
            } else { permissionMessage = "相机权限未授权。请在系统设置中允许相机访问；没有采集传感器数据。" }
            poll()
        }
    }
    var deviceMetadata: [String:String] {
        var info = utsname(); uname(&info)
        let hardware = withUnsafePointer(to:&info.machine) { pointer in
            pointer.withMemoryRebound(to:CChar.self,capacity:256) { String(cString:$0) }
        }
        return ["hardwareIdentifier":hardware,"deviceModel":UIDevice.current.model,"system":UIDevice.current.systemVersion,
         "applicationVersion":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "",
         "build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "",
         "bundleID":Bundle.main.bundleIdentifier ?? "","capabilities":capabilities.description]
    }
    func updatePathSettings() {
        pathOptions = pathOptions.validated()
        if let data = try? JSONEncoder().encode(pathOptions) { UserDefaults.standard.set(data,forKey:"pathOptions") }
        pathHaptics.stop(reset:true); engine.updatePathOptions(pathOptions); poll()
    }
    func updateSettings() { engine.updateParameters(parameters); engine.updateOptions(options); poll() }
    func updateLayers() { engine.updateOptions(options); poll() }
    func sample() {
        engine.manualSample(display:["layer":options.layer.title,"smoothedDisplay":String(options.smoothedDisplay),"surfaceModel":String(options.showSurfaceModel),"blockingColumns":String(options.showBlockingColumns),"viewport":"aspect-fit; raw sample is sensor orientation"])
        poll()
    }
    func export() {
        guard !exporting else { return }; exporting = true
        engine.recorder.export { [weak self] result in
            Task { @MainActor in
                self?.exporting = false
                switch result { case .success(let url): self?.exportURL = url; case .failure(let error): self?.errorMessage = error.localizedDescription }
            }
        }
    }
}
