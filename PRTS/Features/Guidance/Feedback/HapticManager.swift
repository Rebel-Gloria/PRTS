//
//  HapticManager.swift
//  PRTS
//

import Combine
import UIKit

@MainActor
/// Vibration is always on: it carries direction cues, so there is no setting to turn it off.
final class HapticManager: ObservableObject {
    private var holdFeedbackTimer: Timer?

    func buttonTapped() {
        impact(style: .light)
    }

    func cameraStarted() {
        impact(style: .medium)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.impact(style: .medium)
        }
    }

    /// Direction cues are continuous buzzes; the system error pattern is a run of sharp taps,
    /// so "do not walk on" cannot be mistaken for "turn left".
    func guidanceAlert() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }

    func startHoldFeedback() {
        guard holdFeedbackTimer == nil else { return }

        impact(style: .light)
        holdFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.impact(style: .light)
            }
        }
    }

    func stopHoldFeedback() {
        holdFeedbackTimer?.invalidate()
        holdFeedbackTimer = nil
    }

    private func impact(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    deinit {
        holdFeedbackTimer?.invalidate()
    }
}
