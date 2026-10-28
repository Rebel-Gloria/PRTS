import CoreGraphics
import Foundation
import Testing
@testable import PRTS

struct DocumentFramingTests {
    /// Axis-aligned page outline in normalized top-left coordinates.
    private func page(_ minX: CGFloat, _ minY: CGFloat, _ maxX: CGFloat, _ maxY: CGFloat) -> [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
    }

    @Test func hintsPointTowardTheCutOffSide() {
        #expect(DocumentFraming.hint(for: nil) == .searching)
        #expect(DocumentFraming.hint(for: page(0, 0.2, 0.7, 0.8)) == .moveLeft)
        #expect(DocumentFraming.hint(for: page(0.3, 0.2, 1, 0.8)) == .moveRight)
        #expect(DocumentFraming.hint(for: page(0.2, 0, 0.8, 0.7)) == .moveUp)
        #expect(DocumentFraming.hint(for: page(0.2, 0.3, 0.8, 1)) == .moveDown)
        #expect(DocumentFraming.hint(for: page(0, 0.1, 1, 0.9)) == .farther)
        #expect(DocumentFraming.hint(for: page(0.4, 0.4, 0.6, 0.6)) == .closer)
        #expect(DocumentFraming.hint(for: page(0.1, 0.1, 0.9, 0.9)) == .hold)
    }

    @Test func capturesOnlyAfterTheOutlineStaysStill() {
        var framing = DocumentFraming()
        let still = page(0.1, 0.1, 0.9, 0.9)
        #expect(framing.update(corners: still, at: 0) == .hint(.hold))
        #expect(framing.update(corners: still, at: 0.4) == .wait)
        // A jump restarts the steady window.
        #expect(framing.update(corners: page(0.2, 0.1, 0.95, 0.9), at: 0.6) == .wait)
        #expect(framing.update(corners: page(0.2, 0.1, 0.95, 0.9), at: 1.3) == .wait)
        #expect(framing.update(corners: page(0.21, 0.1, 0.95, 0.9), at: 1.45) == .capture)
    }

    @Test func losingThePageResetsCaptureAndSpeaksAtOnce() {
        var framing = DocumentFraming()
        let still = page(0.1, 0.1, 0.9, 0.9)
        _ = framing.update(corners: still, at: 0)
        #expect(framing.update(corners: nil, at: 0.5) == .hint(.searching))
        #expect(framing.update(corners: still, at: 0.7) == .hint(.hold))
        #expect(framing.update(corners: still, at: 1.4) == .wait)
        #expect(framing.update(corners: still, at: 1.5) == .capture)
    }

    @Test func repeatsAnUnchangedHintSparingly() {
        var framing = DocumentFraming()
        #expect(framing.update(corners: nil, at: 0) == .hint(.searching))
        #expect(framing.update(corners: nil, at: 2) == .wait)
        #expect(framing.update(corners: nil, at: 2.5) == .hint(.searching))
    }

    @Test func readingOrderGroupsRowsLeftToRight() {
        // Vision boxes: normalized, origin bottom-left.
        let lines: [(box: CGRect, text: String)] = [
            (CGRect(x: 0.55, y: 0.80, width: 0.3, height: 0.04), "右栏"),
            (CGRect(x: 0.10, y: 0.81, width: 0.3, height: 0.04), "左栏"),
            (CGRect(x: 0.10, y: 0.60, width: 0.6, height: 0.04), "Second line"),
            (CGRect(x: 0.10, y: 0.70, width: 0.6, height: 0.04), "第一行"),
        ]
        #expect(TextRecognizer.ordered(lines) == ["左栏", "右栏", "第一行", "Second line"])
        #expect(TextRecognizer.joined(["说明书", "第二页", "Model A", "15KG"]) == "说明书第二页 Model A 15KG")
    }
}
