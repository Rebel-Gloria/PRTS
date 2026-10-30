import CoreImage
import Testing
import UIKit
@testable import PRTS

/// Apple's Vision runs on the device; the page is drawn here so the test needs no photos.
struct TextRecognizerTests {
    private func pageOnTable() -> CIImage {
        let size = CGSize(width: 1200, height: 1600)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.25, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 200, y: 300, width: 800, height: 1000))
            let font = UIFont.systemFont(ofSize: 64, weight: .medium)
            for (row, line) in ["使用说明书", "第二页", "Model A 15KG"].enumerated() {
                (line as NSString).draw(at: CGPoint(x: 260, y: 400 + CGFloat(row) * 160),
                                        withAttributes: [.font: font, .foregroundColor: UIColor.black])
            }
        }
        return CIImage(cgImage: image.cgImage!)
    }

    @Test func readsThePhotoInOrder() throws {
        let text = try TextRecognizer.read(pageOnTable())
        let first = try #require(text.range(of: "说明书")), second = try #require(text.range(of: "第二页"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(text.contains("15KG"))
    }
}
