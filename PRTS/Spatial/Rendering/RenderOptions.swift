import ARKit
import Foundation
import SpatialCore
import simd

enum SensorLayer: Int, CaseIterable, Identifiable, Codable, Sendable {
    case rgb, depth, confidence
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .rgb: "RGB"
        case .depth: "深度"
        case .confidence: "置信度"
        }
    }
}
nonisolated struct RenderOptions: Codable, Sendable, Equatable {
    // Optional backing keys preserve decoding of older diagnostic records.
    var cameraImageVisible: Bool? = nil
    var geometryOverlaysVisible: Bool? = nil
    var pathVisible: Bool? = nil
    var legendsVisible: Bool? = nil
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
    var showLegends: Bool {
        get { legendsVisible ?? true }
        set { legendsVisible = newValue }
    }
    var layer: SensorLayer = .rgb
    var overlayDepth = false
    var overlayAlpha: Float = 0.45
    var smoothedDisplay = false
    var showMesh = false
    var showFloor = true
    var showSurfaceModel = true
    var showBlockingColumns = true
    var showGrid = true
    var showChannels = true
    var showHUD = true
    var heatMax: Float = 5
    /// Release builds: the camera picture and, if the user turns it on, the scan mesh. The planned
    /// route is not drawn. Floor, obstacle and grid layers are for checking the algorithm in dev
    /// builds.
    static func product(scanMesh: Bool) -> RenderOptions {
        var o = RenderOptions()
        o.showPath = false
        o.showLegends = false
        o.showFloor = false
        o.showSurfaceModel = false
        o.showBlockingColumns = false
        o.showGrid = false
        o.showChannels = false
        o.showHUD = false
        o.showMesh = scanMesh
        return o
    }
}
