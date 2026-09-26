import Foundation

struct PRTSPathBranch: Identifiable {
    let id = UUID()
    let direction: PRTSPathDirection
    let endpoint: CGPoint
}
