import SwiftUI

struct TextReadingStatusView: View {
    let framesSeen: Int

    var body: some View {
        VStack(spacing: 6) {
            if framesSeen == 0 {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                    .symbolEffect(.pulse)
                    .accessibilityHidden(true)
            }
            Text("home.ocr.status").font(.headline)
            Text("home.ocr.status.hint").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .readableGlassPanel()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ocrStatus")
    }
}
