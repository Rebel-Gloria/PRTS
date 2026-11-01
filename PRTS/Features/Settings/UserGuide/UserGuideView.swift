import AVFoundation
import Combine
import SwiftUI

/// The user guide window: the guide for this iPhone in the system language, with a read-aloud
/// button in the bottom-right corner.
struct UserGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var speech: SpeechManager
    @StateObject private var reader = UserGuideReader()
    private let language = SpeechLanguage.fromSystemLanguage()
    private let document: UserGuideDocument

    init() {
        document = UserGuideDocument(
            markdown: UserGuide.current.markdown(language: SpeechLanguage.fromSystemLanguage())
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 96)  // Room for the read-aloud button.
            }
            .navigationTitle("userGuide.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("userGuide.done") { dismiss() }
                }
            }
            .overlay(alignment: .bottomTrailing) { readButton }
        }
        .onDisappear { reader.stop() }
    }

    @ViewBuilder
    private func blockView(_ block: UserGuideDocument.Block) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.title3.weight(.semibold))
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(inline(text))
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•").accessibilityHidden(true)
                Text(inline(text))
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private var readButton: some View {
        Button {
            if reader.isReading {
                reader.stop()
            } else {
                speech.stopCurrentSpeech()
                reader.read(document.spokenText, rate: speech.rateOption, language: language)
            }
        } label: {
            Image(systemName: reader.isReading ? "stop.fill" : "play.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.appButtonText)
                .frame(width: 60, height: 60)
                .background(Color.appAccent, in: Circle())
                .shadow(radius: 4, y: 2)
        }
        .padding(20)
        .accessibilityLabel(reader.isReading ? "userGuide.stop" : "userGuide.read")
        .accessibilityIdentifier("userGuideReadButton")
    }
}

/// Reads the guide with the system voice. A synthesizer of its own, so the voice-announcement
/// switch never mutes a reading the user asked for, and the button returns to play when done.
@MainActor
final class UserGuideReader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isReading = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func read(_ text: String, rate: SpeechRateOption, language: SpeechLanguage) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [.notifyOthersOnDeactivation])
        synthesizer.speak(
            SpeechManager.announcementUtterance(text, rate: rate, language: language)
        )
        isReading = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isReading = false
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isReading = false }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isReading = false }
    }
}
