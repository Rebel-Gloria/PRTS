import SwiftUI

struct PhotoInteractionView: View {
    let message: String
    let busy: Bool
    let volumeButtons: Bool
    let down: () -> Void
    let up: () -> Void
    let cancel: () -> Void
    let strings: PhotoCaptureButton.Strings

    var body: some View {
        let hardware = PhotoHardwareButtons.inUse(volume: volumeButtons)
        ZStack {
            // Camera Control or the volume buttons replace the on-screen button.
            if !hardware {
                PhotoCaptureButton(
                    down: down,
                    up: up,
                    cancel: cancel,
                    strings: strings
                )
            }
        }
        .frame(width: 160, height: 160)
        .background(
            PhotoHardwareButtons(
                down: down,
                up: up,
                cancel: cancel,
                enabled: hardware
            )
        )
        .overlay(alignment: .bottom) {
            if !message.isEmpty {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(message).font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .readableGlassPanel()
                    if busy {
                        Button {
                            cancel()
                        } label: {
                            Text("home.photo.cancel").frame(minWidth: 44, minHeight: 44)
                        }
                        .glassButtonStyle()
                    }
                }
                .frame(width: 320)
                .multilineTextAlignment(.center)
                .offset(y: 70)
            }
        }
    }
}
