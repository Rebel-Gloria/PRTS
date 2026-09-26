import Foundation

struct PRTSGuidancePath: Identifiable {
    let id = UUID()
    let points: [CGPoint]
    let clearance: Float
    let direction: PRTSPathDirection
}
