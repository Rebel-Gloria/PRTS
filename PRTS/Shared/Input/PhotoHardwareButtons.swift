import AVKit
import SwiftUI
import UIKit

/// Camera Control, or the volume buttons standing in for it, pressed like the photo button while
/// guidance runs: press to describe, hold to ask. The system only sends these while the camera is on.
struct PhotoHardwareButtons: UIViewRepresentable {
    var down: () -> Void
    var up: () -> Void
    var cancel: () -> Void
    var enabled: Bool
    /// iPhone 16 and later. Camera Control always takes photos there and is not a setting.
    static let hasCameraControl: Bool = {
        guard #available(iOS 18, *) else { return false }
        return AVCaptureSession().supportsControls
    }()

    /// Capture events from hardware buttons arrived in iOS 17.2.
    static var volumeAvailable: Bool {
        guard #available(iOS 17.2, *) else { return false }
        return !hasCameraControl
    }

    /// Whether a hardware button takes photos, which also hides the on-screen button.
    static func inUse(volume: Bool) -> Bool { hasCameraControl || (volumeAvailable && volume) }

    func makeUIView(context: Context) -> Host { Host() }

    func updateUIView(_ uiView: Host, context: Context) {
        uiView.down = down
        uiView.up = up
        uiView.cancel = cancel
        uiView.apply(enabled)
    }

    /// A transparent view that never takes touches; it only carries the interaction.
    final class Host: UIView {
        var down: (() -> Void)?
        var up: (() -> Void)?
        var cancel: (() -> Void)?
        private var interaction: UIInteraction?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        /// While enabled the system routes the volume buttons here too, so they stop changing the
        /// volume. On phones with Camera Control there is no way to take only Camera Control.
        func apply(_ enabled: Bool) {
            guard #available(iOS 17.2, *) else { return }
            if interaction == nil, enabled {
                let interaction = AVCaptureEventInteraction { [weak self] event in
                    switch event.phase {
                    case .began: self?.down?()
                    case .ended: self?.up?()
                    case .cancelled: self?.cancel?()
                    @unknown default: break
                    }
                }
                addInteraction(interaction)
                self.interaction = interaction
            }
            (interaction as? AVCaptureEventInteraction)?.isEnabled = enabled
        }
    }
}
