#if PRTS_DEV_CAPTURE
import SwiftUI

struct RecordingControl: View {
    @ObservedObject var model: ProbeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("录制模式", isOn: $model.recordingMode)
                .accessibilityIdentifier("recordingModeToggle")
            if model.recordingStatus.phase == .recording,
                let start = model.recordingStatus.startedAt
            {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(start)))
                    let elapsed = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                    Text(verbatim: "录制中 \(elapsed)")
                        .accessibilityLabel("录制状态")
                        .accessibilityValue(Text(verbatim: "录制中，\(elapsed)"))
                }
            } else if !model.recordingStatus.text.isEmpty {
                Text(verbatim: model.recordingStatus.text)
                    .accessibilityLabel("录制状态")
                    .accessibilityValue(Text(verbatim: model.recordingStatus.text))
            }
        }
        .font(.subheadline)
        .padding(12)
        .readableGlassPanel()
    }
}
#endif
