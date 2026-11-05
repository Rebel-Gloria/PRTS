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
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom])
                }
                // A bar of its own, so the button never covers the last lines of the guide.
                HStack {
                    Spacer()
                    readButton
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                // Opaque: text half-showing through a translucent bar fails the contrast audit.
                .background(Color(uiColor: .systemBackground))
                // A container, so the button keeps its own frame; VoiceOver reaches it first
                // instead of after the whole guide.
                .accessibilityElement(children: .contain)
                .accessibilitySortPriority(1)
            }
            .accessibilityElement(children: .contain)
            .navigationTitle("userGuide.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("userGuide.done") { dismiss() }
                }
            }
            // A two-finger double-tap starts or stops reading from anywhere in the window.
            .accessibilityAction(.magicTap) { toggleReading() }
        }
        .onDisappear { reader.stop() }
    }

    private func toggleReading() {
        if reader.isReading {
            reader.stop()
        } else {
            speech.stopCurrentSpeech()
            reader.read(document.spokenText, rate: speech.rateOption, language: language)
        }
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
        Button(action: toggleReading) {
            Image(systemName: reader.isReading ? "stop.fill" : "play.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.appButtonText)
                .frame(width: 60, height: 60)
                .background(Color.appAccent, in: Circle())
                .shadow(radius: 4, y: 2)
        }
        .accessibilityLabel(reader.isReading ? "userGuide.stop" : "userGuide.read")
        .accessibilityIdentifier("userGuideReadButton")
    }
}
