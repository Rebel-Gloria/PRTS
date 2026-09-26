import Testing
@testable import PRTS

struct PRTSNavigationTests {
    @Test func plannerFindsCenteredWalkablePath() {
        var mask = PRTSBinaryMask(width: 40, height: 80)
        for y in 0..<mask.height {
            for x in 10..<30 { mask[x, y] = 1 }
        }
        let result = PRTSPathPlanner().plan(mask: mask)
        #expect(result.paths.count == 1)
        #expect(result.paths[0].direction == .straight)
        #expect(result.paths[0].points.count > 2)
    }

    @Test func plannerReportsSideBranch() {
        var mask = PRTSBinaryMask(width: 60, height: 80)
        for y in 0..<mask.height {
            for x in 20..<40 { mask[x, y] = 1 }
        }
        for y in 20..<35 {
            for x in 42..<58 { mask[x, y] = 1 }
        }
        let result = PRTSPathPlanner().plan(mask: mask)
        #expect(result.paths.count == 1)
        #expect(result.branches.contains { $0.direction == .right })
    }
}
