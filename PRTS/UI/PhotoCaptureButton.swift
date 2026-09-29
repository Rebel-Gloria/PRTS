import SwiftUI
import UIKit

/// UIKit touch cancellation avoids sending a photo when a finger leaves the button.
struct PhotoCaptureButton: UIViewRepresentable {
    var down: () -> Void
    var up: () -> Void
    var cancel: () -> Void

    func makeUIView(context: Context) -> Control {
        let button = Control(type: .custom)
        button.setImage(UIImage(systemName: "camera.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 80)), for: .normal)
        button.tintColor = .white
        button.imageView?.alpha = 0.25
        button.accessibilityLabel = "拍照描述"
        button.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "开始语音提问", target: button, selector: #selector(Control.accessibleBegin)),
            UIAccessibilityCustomAction(name: "结束语音提问并发送", target: button, selector: #selector(Control.accessibleEnd))
        ]
        button.accessibilityHint = "轻点描述画面；按住半秒后说话，松手发送"
        button.addTarget(button, action: #selector(Control.pressed), for: .touchDown)
        button.addTarget(button, action: #selector(Control.released), for: .touchUpInside)
        button.addTarget(button, action: #selector(Control.cancelled), for: [.touchCancel, .touchUpOutside, .touchDragExit])
        return button
    }

    func updateUIView(_ uiView: Control, context: Context) {
        uiView.down = down; uiView.up = up; uiView.cancel = cancel
    }

    final class Control: UIButton {
        var down: (() -> Void)?
        var up: (() -> Void)?
        var cancel: (() -> Void)?
        @objc func accessibleBegin() -> Bool { down?(); return true }
        @objc func accessibleEnd() -> Bool { up?(); return true }
        @objc func pressed() { down?() }
        @objc func released() { up?() }
        @objc func cancelled() { cancel?() }
        override func accessibilityActivate() -> Bool { down?(); up?(); return true }
    }
}
