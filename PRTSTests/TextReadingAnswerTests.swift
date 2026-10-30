import Foundation
import Testing
@testable import PRTS

struct TextReadingAnswerTests {
    @Test func leadsWithWhatTheTextIsOnThenSpeaksLineByLine() {
        var answer = TextReadingAnswer(lead: "你面前的路标上写着")
        #expect(answer.append("人民") == [])
        #expect(answer.append("路\n地铁站") == ["你面前的路标上写着：人民路"])
        #expect(answer.append(" 200 米 →") == [])
        #expect(answer.finish() == ["地铁站 200 米 →"])
        #expect(answer.spokeText)
    }

    @Test func splitsLongTextAtSentenceEnds() {
        var answer = TextReadingAnswer(lead: "你面前的纸张上写着")
        #expect(answer.append("一日三次，饭后服用。注意") == ["你面前的纸张上写着：一日三次，饭后服用。"])
        #expect(answer.append("事项：过敏者禁用。") == ["注意事项：过敏者禁用。"])
        #expect(answer.finish() == [])
    }

    @Test func noTextSaysNothing() {
        var bare = TextReadingAnswer(lead: "你面前的物体上写着")
        #expect(bare.append("无") == [])
        #expect(bare.finish() == [])
        #expect(!bare.spokeText)
        var stop = TextReadingAnswer(lead: "你面前的物体上写着")
        #expect(stop.append("无。\n人民路\n") == [])
        #expect(!stop.spokeText)
    }

    @Test func dropsAMadeUpTurnAfterAStrayTag() {
        var answer = TextReadingAnswer(lead: "你面前的牌子上写着")
        #expect(answer.append("幸福便利店\n24小时营业</thi") == ["你面前的牌子上写着：幸福便利店"])
        #expect(answer.append("nk>\n\n牌子\n幸福便利店") == [])
        #expect(answer.finish() == ["24小时营业"])
    }

    @Test func surfaceIsTheFirstOfTheFourWords() {
        typealias Surface = TextReadingPrompt.Surface
        #expect(Surface(answer: "路标") == .roadSign)
        #expect(Surface(answer: "牌子：店铺招牌、门牌、") == .sign)
        #expect(Surface(answer: "纸张。") == .paper)
        #expect(Surface(answer: "无") == .object)
        #expect(Surface(answer: "药物") == .object)
    }

    @Test func remoteAnswerSplitsIntoSurfaceAndText() {
        #expect(TextReadingPrompt.split("路标\n人民路\n地铁站 200米") == (.roadSign, "\n人民路\n地铁站 200米"))
        #expect(TextReadingPrompt.split("无") == (.object, "无"))
        // No surface word in the first line: it is already text.
        #expect(TextReadingPrompt.split("幸福便利店\n24小时营业") == (.object, "幸福便利店\n24小时营业"))
        var answer = TextReadingAnswer(lead: "你面前的路标上写着")
        #expect(answer.append(TextReadingPrompt.split("路标\n人民路").1) == [])
        #expect(answer.finish() == ["你面前的路标上写着：人民路"])
    }

    @Test func readsWithTheBundledModelUnlessChosenOtherwise() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        #expect(TextReadingService.current(defaults) == .onDevice)
        defaults.set(TextReadingService.remote.rawValue, forKey: TextReadingService.selectionKey)
        #expect(TextReadingService.current(defaults) == .remote)
    }
}
