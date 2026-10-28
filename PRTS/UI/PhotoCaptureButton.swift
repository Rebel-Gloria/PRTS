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
    /// Camera Control and the volume buttons press the same control while the camera runs.
    var hardwareButtons = false
    static let hardwareButtonsKey = "photo.hardwareButtons"

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
        uiView.applyHardwareButtons(hardwareButtons)
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

        private var hardwareInteraction: UIInteraction?

        /// While enabled the system routes the volume buttons here, so they stop changing the
        /// volume; Settings lets the user turn this off.
        func applyHardwareButtons(_ enabled: Bool) {
            guard #available(iOS 17.2, *) else { return }
            if hardwareInteraction == nil, enabled {
                let interaction = AVCaptureEventInteraction { [weak self] event in
                    switch event.phase {
                    case .began: self?.down?()
                    case .ended: self?.up?()
                    case .cancelled: self?.cancel?()
                    @unknown default: break
                    }
                }
                addInteraction(interaction)
                hardwareInteraction = interaction
            }
            (hardwareInteraction as? AVCaptureEventInteraction)?.isEnabled = enabled
        }

        @objc func accessibleBegin() -> Bool { down?(); return true }
        @objc func accessibleEnd() -> Bool { up?(); return true }
        @objc func pressed() { down?() }
        @objc func released() { up?() }
        @objc func cancelled() { cancel?() }
        override func accessibilityActivate() -> Bool { down?(); up?(); return true }
    }
}
