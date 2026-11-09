#if PRTS_DEV_CAPTURE
import SwiftUI

struct RecordingsSection: View {
    @ObservedObject var model: ProbeViewModel
    @State private var recordings: [SavedRecording] = []
    @State private var error: String?
    @State private var refresh = 0
    @State private var deletions: [SavedRecording] = []
    @State private var storageQueue = DispatchQueue(label: "prts.recording.list", qos: .utility)

    var body: some View {
        Section("录制") {
            if recordings.isEmpty { Text("暂无录制") }
            ForEach(recordings) { recording in
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        recording.startedAt,
                        format: .dateTime.year().month().day().hour().minute().second()
                    )
                    Text(
                        verbatim: "\(Int(recording.duration)) 秒 · "
                            + ByteCountFormatter.string(
                                fromByteCount: Int64(recording.bytes),
                                countStyle: .file
                            )
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ShareLink(item: recording.url) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Button("删除", role: .destructive) { delete(recording) }
                            .buttonStyle(.borderless)
                    }
                }
                .accessibilityElement(children: .contain)
                .swipeActions {
                    Button("删除", role: .destructive) { delete(recording) }
                }
            }
            if let error { Text(verbatim: error).foregroundStyle(.red) }
        }
        .task(id: refresh) {
            let pending = deletions
            deletions = []
            do {
                // Serialize deletes and reloads so a newer list cannot precede an accepted delete.
                let loaded: [SavedRecording] = try await withCheckedThrowingContinuation { done in
                    storageQueue.async {
                        do {
                            let store = RecordingStore.application
                            for recording in pending { try store.delete(recording) }
                            done.resume(returning: try store.list())
                        } catch { done.resume(throwing: error) }
                    }
                }
                guard !Task.isCancelled else { return }
                recordings = loaded
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
        .onChange(of: model.recordingStatus.archiveRevision) { _, _ in refresh += 1 }
    }

    private func delete(_ recording: SavedRecording) {
        deletions.append(recording)
        refresh += 1
    }
}
#endif
