//
//  HapticManager.swift
//  PRTS
//

import Combine
import UIKit

@MainActor
final class HapticManager: ObservableObject {
    @Published private(set) var isEnabled: Bool

    private let defaultsKey = "hapticFeedbackEnabled"
    private var holdFeedbackTimer: Timer?

    init() {
        isEnabled = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: defaultsKey)

        if enabled {
            buttonTapped()
        } else {
            stopHoldFeedback()
        }
    }

    func buttonTapped() {
        impact(style: .light)
    }

    func cameraStarted() {
        guard isEnabled else { return }

        impact(style: .medium)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.impact(style: .medium)
        }
    }

    func startHoldFeedback() {
        guard isEnabled, holdFeedbackTimer == nil else { return }

        impact(style: .light)
        holdFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
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
        guard isEnabled else { return }

        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    deinit {
        holdFeedbackTimer?.invalidate()
    }
}
