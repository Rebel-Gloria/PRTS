import Testing

@testable import PRTS

struct LiveCaptionPolicyTests {
    @Test(arguments: ["无", "无。", " 无。 \n一个人走过。", "", "\n一个人走过。"])
    func silence(response: String) {
        #expect(LiveCaptionPolicy.answer(response, previous: nil) == nil)
    }

    @Test func lengthBoundary() {
        let longest = String(repeating: "字", count: 24)
        #expect(LiveCaptionPolicy.answer(longest, previous: nil) == longest)
        #expect(LiveCaptionPolicy.answer(longest + "字", previous: nil) == nil)
    }

    @Test(arguments: ["照片里有人走过。", "画面里有人走过。", "镜头前有人走过。"])
    func forbiddenWords(response: String) {
        #expect(LiveCaptionPolicy.answer(response, previous: nil) == nil)
    }

    @Test func firstLineAndDuplicate() {
        let sentence = "一个人从右边走过。"
        #expect(LiveCaptionPolicy.answer(" \(sentence) \n无", previous: nil) == sentence)
        #expect(LiveCaptionPolicy.answer(" \(sentence) \n无", previous: sentence) == nil)
        #expect(LiveCaptionPolicy.answer(sentence, previous: "一只手拿起杯子。") == sentence)
    }
}
