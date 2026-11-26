import AVFoundation
import Testing
import UIKit

@testable import PRTS

@MainActor
struct CaptureSessionPreviewTests {
    @Test func emptySessionCanLayOutBeforeTheCameraConnects() {
        let session = AVCaptureSession()
        let view = CaptureSessionPreview.PreviewView(session: session, rotation: .interface)
        #expect(view.previewLayer.connection == nil)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(view.previewLayer.connection == nil)
        #expect(view.previewLayer.session === session)
        #expect(view.previewLayer.videoGravity == .resizeAspectFill)
    }

    @Test func rotationMatchesEachPreviewPolicy() {
        let angles: [(UIInterfaceOrientation?, CGFloat)] = [
            (nil, 90), (.unknown, 90), (.portrait, 90), (.portraitUpsideDown, 270),
            (.landscapeLeft, 180), (.landscapeRight, 0),
        ]
        for (orientation, angle) in angles {
            #expect(CaptureSessionPreview.Rotation.interface.angle(for: orientation) == angle)
            #expect(CaptureSessionPreview.Rotation.portrait.angle(for: orientation) == 90)
        }
    }
}
