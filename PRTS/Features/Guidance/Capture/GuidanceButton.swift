import SwiftUI

struct GuidanceButton<StopGesture: Gesture>: View {
    let state: CameraState
    let pointerCannotHold: Bool
    let isLargeText: Bool
    let threeFingerReading: Bool
    let stopGesture: StopGesture
    let start: () -> Void
    let stop: () -> Void
    let readText: () -> Void
    var body: some View {
        Button {
            if state == .running && pointerCannotHold { stop() } else { start() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: state == .running ? "stop.fill" : "play.fill")
                    .accessibilityHidden(true)

                Text(
                    LocalizedStringKey(
                        state != .running
                            ? "home.camera.button.start"
                            : pointerCannotHold
                                ? "home.camera.input.stop" : "home.camera.button.stopLongPress"
                    )
                )
                .multilineTextAlignment(.center)
            }
            .font(.title2.weight(.bold))
            .padding(.vertical, isLargeText ? 12 : 0)
            .foregroundStyle(Color.appButtonText)
            .frame(maxWidth: .infinity, minHeight: 76)
            // Solid accent keeps the dark label at full contrast; the glass adds the system
            // press response and edge highlight without making the control translucent.
            .background(Color.appAccent, in: Capsule())
            .glassSurface(in: Capsule(), tint: .appAccent, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy)
        .opacity(state.isBusy ? 0.65 : 1)
        .accessibilityLabel(
            LocalizedStringKey(
                state != .running
                    ? "home.camera.button.start.label"
                    : pointerCannotHold
                        ? "home.camera.input.stop" : "home.camera.button.stopLongPress"
            )
        )
        .accessibilityHint(
            LocalizedStringKey(
                state != .running
                    ? "home.camera.button.start.hint"
                    : pointerCannotHold
                        ? "home.camera.button.stopTap.hint"
                        : "home.camera.button.stopLongPress.hint"
            )
        )
        .accessibilityIdentifier("cameraButton")
        // Touch keeps the one-second hold. VoiceOver, Voice Control and Switch Control
        // cannot hold, so their activation stops directly.
        .accessibilityAction { state == .running ? stop() : start() }
        .accessibilityAction(named: Text("home.camera.action.stop")) { stop() }
        .accessibilityActions {
            if threeFingerReading { Button("home.ocr.action") { readText() } }
        }
        .accessibilityInputLabels(
            state == .running
                ? [Text("home.camera.input.stop"), Text("home.camera.button.stopLongPress")]
                : [Text("home.camera.input.start"), Text("home.camera.button.start.label")]
        )
        .highPriorityGesture(
            stopGesture,
            including: state == .running && !pointerCannotHold ? .all : .subviews
        )
    }
}
