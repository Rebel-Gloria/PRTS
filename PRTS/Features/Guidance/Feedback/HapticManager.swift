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
    private var feedbackEnabled = true
    private var feedbackGeneration: UInt64 = 0

    func setFeedbackEnabled(_ enabled: Bool) {
        guard feedbackEnabled != enabled else { return }
        feedbackEnabled = enabled
        feedbackGeneration &+= 1
        if !enabled { stopHoldFeedback() }
    }

    func buttonTapped() {
        impact(style: .light)
    }

    func cameraStarted() {
        impact(style: .medium)
        let generation = feedbackGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard self?.feedbackGeneration == generation else { return }
            self?.impact(style: .medium)
        }
    }

    /// Direction cues are continuous buzzes; the system error pattern is a run of sharp taps,
    /// so "do not walk on" cannot be mistaken for "turn left".
    func guidanceAlert() {
        guard feedbackEnabled, UIApplication.shared.applicationState == .active else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }

    func startHoldFeedback() {
        guard feedbackEnabled, holdFeedbackTimer == nil else { return }

        impact(style: .light)
        let generation = feedbackGeneration
        holdFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.feedbackGeneration == generation else { return }
                self?.impact(style: .light)
            }
        }
    }

    func stopHoldFeedback() {
        holdFeedbackTimer?.invalidate()
        holdFeedbackTimer = nil
    }

    private func impact(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard feedbackEnabled, UIApplication.shared.applicationState == .active else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    deinit {
        holdFeedbackTimer?.invalidate()
    }
}
