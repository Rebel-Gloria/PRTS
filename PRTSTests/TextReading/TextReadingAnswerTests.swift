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

    @Test func onlyAWholeLocalModelReplyMeansNoText() {
        var model = TextReadingAnswer(lead: "正文", expectsModelEmptyMarker: true)
        #expect(model.append("无。\n") == [])
        var empty = model
        #expect(empty.finish() == [])
        #expect(model.append("请看背面。") == ["正文：无。", "请看背面。"])

        var vision = TextReadingAnswer(lead: "正文")
        #expect(vision.append("无") + vision.finish() == ["正文：无"])
    }

    @Test func preservesComparisonSignsAcrossPieces() {
        var answer = TextReadingAnswer(lead: "你面前的纸张上写着")
        #expect(answer.append("温度") == [])
        #expect(answer.append("<") == [])
        #expect(answer.append("5℃。请冷藏。") == ["你面前的纸张上写着：温度<5℃。", "请冷藏。"])
        #expect(answer.finish() == [])
    }

    @Test(arguments: ["<5℃冷藏", "<div>营业时间</div>", "a<b", "原文</thi"])
    func preservesLiteralRecognizedText(text: String) {
        var answer = TextReadingAnswer(lead: "你面前的物体上写着")
        #expect(answer.append(text) == [])
        #expect(answer.finish() == ["你面前的物体上写着：\(text)"])
        #expect(answer.spokeText)
    }

    @Test func surfaceIsTheFirstOfTheFourWords() {
        typealias Surface = TextReadingAnswer.Surface
        #expect(Surface(answer: "路标") == .roadSign)
        #expect(Surface(answer: "牌子：店铺招牌、门牌、") == .sign)
        #expect(Surface(answer: "纸张。") == .paper)
        #expect(Surface(answer: "无") == .object)
        #expect(Surface(answer: "药物") == .object)
    }

    @Test func remoteHeadingMustMatchTheWholeLine() throws {
        let parse = TextReadingBackend.parseRemoteAnswer
        #expect(try parse("路标\r\n人民路") == (.roadSign, "\r\n人民路"))
        #expect(try parse("纸张回收须知\n请分类投放") == (.object, "纸张回收须知\n请分类投放"))
        #expect(try parse("纸张\n无") == (.paper, "\n无"))
        #expect(try parse("无") == (.object, ""))
    }
}
