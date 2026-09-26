import Foundation
import CoreVideo

struct PRTSNavigationEngine {
    var planner = PRTSPathPlanner()
    var depthEstimator = PRTSDepthObstacleEstimator()
    var obstacleDilationPixels = 5

    func process(semantic: PRTSSemanticGrid, detections: [PRTSObjectDetection], depthMap: CVPixelBuffer?, imageSize: CGSize, previousPath: [CGPoint] = []) -> PRTSNavigationObservation {
        let start = ProcessInfo.processInfo.systemUptime
        var walkable = semantic.walkable
        let obstacles = depthEstimator.estimate(detections: detections, depthMap: depthMap, imageSize: imageSize)
        for obstacle in obstacles where obstacle.distanceMeters <= depthEstimator.maxDistanceMeters {
            let rect = obstacle.box
            let x0 = max(0, Int(rect.minX * CGFloat(walkable.width)) - obstacleDilationPixels)
            let x1 = min(walkable.width - 1, Int(rect.maxX * CGFloat(walkable.width)) + obstacleDilationPixels)
            let y0 = max(0, Int(rect.minY * CGFloat(walkable.height)) - obstacleDilationPixels)
            let y1 = min(walkable.height - 1, Int(rect.maxY * CGFloat(walkable.height)) + obstacleDilationPixels)
            if x0 <= x1 && y0 <= y1 {
                for y in y0...y1 { for x in x0...x1 { walkable[x, y] = 0 } }
            }
        }
        let result = planner.plan(mask: walkable, previous: previousPath)
        let confidence = semantic.confidence.isEmpty ? 0 : semantic.confidence.reduce(0, +) / Float(semantic.confidence.count)
        return PRTSNavigationObservation(walkableMask: walkable, paths: result.paths, branches: result.branches, obstacles: obstacles, nearestObstacle: obstacles.min { $0.distanceMeters < $1.distanceMeters }, confidence: confidence, processingSeconds: ProcessInfo.processInfo.systemUptime - start)
    }
}
