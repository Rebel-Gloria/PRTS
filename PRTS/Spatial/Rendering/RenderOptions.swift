enum SensorLayer: Int, Codable, Sendable {
    case rgb, depth, confidence
}
nonisolated struct RenderOptions: Codable, Sendable, Equatable {
    // Optional backing keys preserve decoding of older diagnostic records.
    var cameraImageVisible: Bool? = nil
    var geometryOverlaysVisible: Bool? = nil
    var pathVisible: Bool? = nil
    var showCameraImage: Bool {
        get { cameraImageVisible ?? true }
        set { cameraImageVisible = newValue }
    }
    var showOverlays: Bool {
        get { geometryOverlaysVisible ?? true }
        set { geometryOverlaysVisible = newValue }
    }
    var showPath: Bool {
        get { pathVisible ?? true }
        set { pathVisible = newValue }
    }
    var layer: SensorLayer = .rgb
    var needsDepthImage: Bool { layer != .rgb || overlayDepth }
    var overlayDepth = false
    var overlayAlpha: Float = 0.45
    var smoothedDisplay = false
    var showMesh = false
    var showFloor = true
    var showSurfaceModel = true
    var showBlockingColumns = true
    var showGrid = true
    var showChannels = true
    var heatMax: Float = 5
    /// Both builds display the camera and optional scan mesh with the same product settings.
    static func product(scanMesh: Bool) -> RenderOptions {
        var o = RenderOptions()
        o.showPath = false
        o.showFloor = false
        o.showSurfaceModel = false
        o.showBlockingColumns = false
        o.showGrid = false
        o.showChannels = false
        o.showMesh = scanMesh
        return o
    }
}
