import Foundation
import Testing

@testable import PRTS

@MainActor
struct UserGuideTests {
    @Test func picksTheGuideForThePhonesButtons() {
        #expect(UserGuide.kind(hasCameraControl: true, model: "iPhone18,2") == .cameraControl)
        #expect(UserGuide.kind(hasCameraControl: false, model: "iPhone16,1") == .actionButton)
        #expect(UserGuide.kind(hasCameraControl: false, model: "iPhone16,2") == .actionButton)
        #expect(UserGuide.kind(hasCameraControl: false, model: "iPhone17,5") == .actionButton)
        #expect(UserGuide.kind(hasCameraControl: false, model: "iPhone15,4") == .basic)
        #expect(UserGuide.kind(hasCameraControl: false, model: "iPhone16,3") == .basic)
        #expect(UserGuide.kind(hasCameraControl: false, model: "iPad16,3") == .basic)
    }

    @Test func everyGuideIsBundledInBothLanguages() {
        for guide in UserGuide.allCases {
            for language in [SpeechLanguage.chinese, .english] {
                let document = UserGuideDocument(markdown: guide.markdown(language: language))
                #expect(document.blocks.contains { if case .heading = $0 { true } else { false } })
                #expect(document.blocks.contains { if case .bullet = $0 { true } else { false } })
            }
        }
    }

    @Test func readsWithoutMarkdownMarks() {
        let document = UserGuideDocument(
            markdown: "# 使用说明\n\n文字。\n\n## 怎么用\n\n- **开始避障**：按操作按钮。\n"
        )
        #expect(
            document.blocks == [.paragraph("文字。"), .heading("怎么用"), .bullet("**开始避障**：按操作按钮。")]
        )
        #expect(document.spokenText == "文字。\n怎么用\n开始避障：按操作按钮。")
    }
}
