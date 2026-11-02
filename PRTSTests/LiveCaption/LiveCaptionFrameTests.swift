import CoreImage
import Foundation
import Testing
import UIKit

@testable import PRTS

struct LiveCaptionFrameTests {
    private func frames(_ values: [UInt8]) -> [LiveCaptionFrame] {
        values.enumerated().map { index, value in
            LiveCaptionFrame(
                sampledAt: Double(index) * 0.25,
                jpeg: Data([UInt8(index)]),
                grayscale: [UInt8](repeating: value, count: 48 * 64)
            )
        }
    }

    @Test func selectsEquallySpacedCumulativeMotion() {
        let uniform = frames([0, 1, 2, 3, 4, 5, 6, 7])
        #expect(LiveCaptionFrame.select(uniform).map(\.sampledAt) == [0, 0.5, 1.25, 1.75])
        let uneven = frames([0, 1, 2, 30, 31, 60, 61, 90])
        #expect(LiveCaptionFrame.select(uneven).map(\.sampledAt) == [0, 0.75, 1.25, 1.75])
    }

    @Test func skipsFramesWithZeroMotion() {
        let input = frames([0, 0, 30, 30, 60, 60, 90, 90])
        #expect(LiveCaptionFrame.select(input).map(\.sampledAt) == [0, 0.5, 1, 1.5])
    }

    @Test func fewerThanFourDistinctFramesReturnsEmpty() {
        let inputs: [[UInt8]] = [
            [], [0], [0, 10, 20], [0, 0, 10, 10, 20, 20, 20, 20],
            [0, 0, 0, 0, 0, 0, 0, 0],
        ]
        for values in inputs {
            #expect(LiveCaptionFrame.select(frames(values)).isEmpty)
        }
    }

    @Test func collidingTargetsSelectUnusedFramesInTimeOrder() {
        let input = frames([0, 1, 2, 3, 4, 5, 6, 200])
        let selected = LiveCaptionFrame.select(input)
        #expect(selected.map(\.sampledAt) == [0, 1.25, 1.5, 1.75])
        #expect(selected.map(\.jpeg) == [Data([0]), Data([5]), Data([6]), Data([7])])
    }

    @Test func motionIsMeanAbsolutePixelDifference() {
        #expect(LiveCaptionFrame.motion([0, 255, 40, 100], [255, 0, 50, 90]) == 132.5)
        #expect(LiveCaptionFrame.motion([0, 128, 255], [0, 128, 255]) == 0)
        #expect(LiveCaptionFrame.motion([255, 255], [0, 0]) == 255)
    }

    @Test func captureStoresJPEGAndGrayscaleThumbnail() throws {
        let image = CIImage(color: .white).cropped(
            to: CGRect(x: 0, y: 0, width: 1920, height: 2560)
        )
        let frame = try LiveCaptionFrame.capture(image: image, sampledAt: 1.25)
        let jpeg = try #require(UIImage(data: frame.jpeg)?.cgImage)
        #expect(jpeg.width == 960)
        #expect(jpeg.height == 1280)
        #expect(frame.sampledAt == 1.25)
        #expect(frame.grayscale.count == 48 * 64)
        #expect(frame.grayscale.allSatisfy { $0 == 255 })
    }
}
