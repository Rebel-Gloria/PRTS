import AVKit
import SwiftUI
import UIKit

/// UIKit touch cancellation avoids sending a photo when a finger leaves the button.
struct PhotoCaptureButton: UIViewRepresentable {
    var down: () -> Void
    var up: () -> Void
    var cancel: () -> Void
    /// VoiceOver label, hint and custom action names in the interface language.
    var strings = Strings.chinese

    struct Strings: Equatable {
        var label, hint, ask, send: String
        static let chinese = Strings(label: "拍照描述", hint: "轻点描述画面；按住半秒后提问，松手发送",
                                  ask: "开始语音提问", send: "发送语音提问")
    }

    func makeUIView(context: Context) -> Control { Self.makeControl() }

    static func makeControl() -> Control {
        let button = Control(type: .custom)
        button.setImage(UIImage(systemName: "camera.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 80)), for: .normal)
        button.tintColor = .white
        button.accessibilityIdentifier = "photoCaptureButton"
        button.addTarget(button, action: #selector(Control.pressed), for: .touchDown)
        button.addTarget(button, action: #selector(Control.released), for: .touchUpInside)
        button.addTarget(button, action: #selector(Control.cancelled), for: [.touchCancel, .touchUpOutside, .touchDragExit])
        button.apply(.chinese)
        button.applyVisibility(highContrast: UIAccessibility.isDarkerSystemColorsEnabled || UIAccessibility.isReduceTransparencyEnabled)
        return button
    }

    func updateUIView(_ uiView: Control, context: Context) {
        uiView.down = down; uiView.up = up; uiView.cancel = cancel
        uiView.apply(strings)
        uiView.applyVisibility(highContrast: UIAccessibility.isDarkerSystemColorsEnabled || UIAccessibility.isReduceTransparencyEnabled)
    }

    final class Control: UIButton {
        var down: (() -> Void)?
        var up: (() -> Void)?
        var cancel: (() -> Void)?

        private var applied: Strings?

        func apply(_ text: Strings) {
            // SwiftUI updates this view on every poll; keep VoiceOver's actions stable.
            guard applied != text else { return }
            applied = text
            accessibilityLabel = text.label
            accessibilityHint = text.hint
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: text.ask, target: self, selector: #selector(accessibleBegin)),
                UIAccessibilityCustomAction(name: text.send, target: self, selector: #selector(accessibleEnd))
            ]
        }

        /// The faint default keeps the camera view clear. Increase Contrast or Reduce
        /// Transparency make it findable for low-vision users.
        func applyVisibility(highContrast: Bool) {
            // UIButton resets imageView.alpha during layout/state updates. Apply opacity
            // to the control instead; the separate SwiftUI status overlay remains readable.
            alpha = highContrast ? 0.85 : 0.25
            backgroundColor = highContrast ? UIColor.black.withAlphaComponent(0.55) : nil
            layer.cornerRadius = highContrast ? 40 : 0
        }

        @objc func accessibleBegin() -> Bool { down?(); return true }
        @objc func accessibleEnd() -> Bool { up?(); return true }
        @objc func pressed() { down?() }
        @objc func released() { up?() }
        @objc func cancelled() { cancel?() }
        override func accessibilityActivate() -> Bool { down?(); up?(); return true }
    }
}

/// Camera Control, or the volume buttons standing in for it, pressed like the photo button while
/// guidance runs: press to describe, hold to ask. The system only sends these while the camera is on.
struct PhotoHardwareButtons: UIViewRepresentable {
    var down: () -> Void
    var up: () -> Void
    var cancel: () -> Void
    var enabled: Bool
    /// Settings: the volume buttons as the photo button, on phones without Camera Control.
    static let volumeKey = "photo.hardwareButtons"

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
        uiView.down = down; uiView.up = up; uiView.cancel = cancel
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
