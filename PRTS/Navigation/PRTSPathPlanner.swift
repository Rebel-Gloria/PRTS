import Foundation

struct PRTSPathPlanner {
    var bandStep: Int = 12
    var minimumSegmentWidth: Int = 8

    func plan(mask: PRTSBinaryMask, previous: [CGPoint] = []) -> (paths: [PRTSGuidancePath], branches: [PRTSPathBranch]) {
        guard mask.width > 0, mask.height > 0 else { return ([], []) }
        var primary: [CGPoint] = []
        var previousX = mask.width / 2
        var clearances: [Float] = []
        var y = mask.height - 1
        while y >= 0 {
            let segments = contiguousSegments(mask: mask, y: y)
            if let selected = segments.min(by: { abs((($0.lowerBound + $0.upperBound) / 2) - previousX) < abs((($1.lowerBound + $1.upperBound) / 2) - previousX) }) {
                let center = (selected.lowerBound + selected.upperBound) / 2
                previousX = center
                primary.append(CGPoint(x: CGFloat(center) / CGFloat(mask.width), y: CGFloat(y) / CGFloat(mask.height)))
                clearances.append(Float(selected.count))
            }
            y -= bandStep
        }
        guard !primary.isEmpty else { return ([], []) }
        let smoothed = smooth(primary, previous: previous)
        let clearance = clearances.reduce(0, +) / Float(max(1, clearances.count))
        let path = PRTSGuidancePath(points: smoothed, clearance: clearance, direction: direction(for: smoothed.first?.x ?? 0.5))
        let branchModels = findBranches(mask: mask, primaryX: previousX).map { PRTSPathBranch(direction: $0.direction, endpoint: $0.endpoint) }
        return ([path], branchModels)
    }

    private func contiguousSegments(mask: PRTSBinaryMask, y: Int) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = [], start: Int?
        for x in 0..<mask.width {
            if mask[x, y] != 0 { if start == nil { start = x } }
            else if let begin = start {
                if x - begin >= minimumSegmentWidth { result.append(begin...(x - 1)) }
                start = nil
            }
        }
        if let begin = start, mask.width - begin >= minimumSegmentWidth { result.append(begin...(mask.width - 1)) }
        return result
    }

    private func smooth(_ points: [CGPoint], previous: [CGPoint]) -> [CGPoint] {
        guard !previous.isEmpty else { return points }
        var output = points
        for i in 0..<min(points.count, previous.count) {
            output[i] = CGPoint(x: previous[i].x * 0.65 + points[i].x * 0.35, y: previous[i].y * 0.65 + points[i].y * 0.35)
        }
        return output
    }

    private func direction(for x: CGFloat) -> PRTSPathDirection { x < 0.38 ? .left : x > 0.62 ? .right : .straight }

    private func findBranches(mask: PRTSBinaryMask, primaryX: Int) -> [(direction: PRTSPathDirection, endpoint: CGPoint)] {
        let y = max(0, mask.height / 3)
        return contiguousSegments(mask: mask, y: y).compactMap { segment in
            let center = (segment.lowerBound + segment.upperBound) / 2
            guard abs(center - primaryX) > mask.width / 8 else { return nil }
            return (center < primaryX ? .left : .right, CGPoint(x: CGFloat(center) / CGFloat(mask.width), y: CGFloat(y) / CGFloat(mask.height)))
        }
    }
}
