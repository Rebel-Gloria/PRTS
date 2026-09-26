import Foundation

struct PRTSObjectDetection: Identifiable {
    let id = UUID()
    let classID: Int
    let label: String
    let score: Float
    let box: CGRect
    let mask: PRTSBinaryMask?
    let blocking: Bool
}
