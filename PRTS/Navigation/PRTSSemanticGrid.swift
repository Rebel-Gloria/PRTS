import Foundation

struct PRTSSemanticGrid {
    let width: Int
    let height: Int
    let classIDs: [UInt8]
    let walkProbability: [Float]
    let confidence: [Float]
    let walkable: PRTSBinaryMask
}
