import SwiftUI

struct PhotoInteractionView: View {
    @ObservedObject var photo: PhotoDescriptionCoordinator
    let volumeButtons: Bool
    let snapshot: () -> FrameSnapshot?
    let silence: () -> Void
    let strings: PhotoCaptureButton.Strings

    var body: some View {
        let hardware = PhotoHardwareButtons.inUse(volume: volumeButtons)
        ZStack {
            // Camera Control or the volume buttons replace the on-screen button.
            if !hardware {
                PhotoCaptureButton(
                    down: { photo.down(snapshot: snapshot, silence: silence) },
                    up: { photo.up() },
                    cancel: { photo.cancel() },
                    strings: strings
                )
            }
        }
        .frame(width: 160, height: 160)
        .background(
            PhotoHardwareButtons(
                down: { photo.down(snapshot: snapshot, silence: silence) },
                up: { photo.up() },
                cancel: { photo.cancel() },
                enabled: hardware
            )
        )
        .overlay(alignment: .bottom) {
            if !photo.message.isEmpty {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        if photo.busy { ProgressView().controlSize(.small) }
                        Text(photo.message).font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .readableGlassPanel()
                    if photo.busy {
                        Button {
                            photo.cancel()
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
