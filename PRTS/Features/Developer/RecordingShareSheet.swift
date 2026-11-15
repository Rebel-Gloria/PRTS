#if PRTS_DEV
import SwiftUI
import UIKit

/// The system share sheet supports AirDrop and saving the same archive to Files.
struct RecordingShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.view.accessibilityIdentifier = "recordingShareSheet"
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in onFinish() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
