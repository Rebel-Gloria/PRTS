import SwiftUI
import UIKit

/// Three fingers held anywhere on the screen. The recognizer sits on the window and never
/// cancels touches, so the controls underneath keep working. VoiceOver takes multi-finger
/// touches for itself, so callers also offer a custom action.
struct ThreeFingerHold: UIViewRepresentable {
    /// Shorter than the one-second stop hold on the main button, so a finger resting there
    /// does not stop guidance first.
    static let duration: TimeInterval = 0.8
    var action: () -> Void

    func makeUIView(context: Context) -> Installer { Installer() }
    func updateUIView(_ uiView: Installer, context: Context) { uiView.action = action }

    final class Installer: UIView {
        var action: (() -> Void)?
        private let recognizer = UILongPressGestureRecognizer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            recognizer.numberOfTouchesRequired = 3
            recognizer.minimumPressDuration = ThreeFingerHold.duration
            recognizer.cancelsTouchesInView = false
            recognizer.addTarget(self, action: #selector(held))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }

        @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { action?() }
        }
    }
}
