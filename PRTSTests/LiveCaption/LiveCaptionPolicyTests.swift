import Testing

@testable import PRTS

struct LiveCaptionPolicyTests {
    @Test(arguments: ["无", "无。", " 无。 \n一个人走过。", "", "\n一个人走过。"])
    func silence(response: String) {
        #expect(LiveCaptionPolicy.answer(response, previous: nil) == nil)
    }

    @Test func lengthBoundary() {
        let twenty = String(repeating: "字", count: 20)
        #expect(LiveCaptionPolicy.answer(twenty, previous: nil) == twenty)
        #expect(LiveCaptionPolicy.answer(twenty + "字", previous: nil) == nil)
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

    @Test func startsBeforeEstimatedSpeechEnd() {
        #expect(
            LiveCaptionPolicy.requestTime(
                now: 12,
                lastRequest: 10,
                speechEnd: 18,
                modelDuration: 3
            ) == 15
        )
    }

    @Test func minimumTwoSecondsBetweenRequests() {
        #expect(
            LiveCaptionPolicy.requestTime(
                now: 10.5,
                lastRequest: 10,
                speechEnd: 12,
                modelDuration: 3
            ) == 12
        )
        #expect(
            LiveCaptionPolicy.requestTime(
                now: 15,
                lastRequest: 10,
                speechEnd: nil,
                modelDuration: 3
            ) == 15
        )
    }

    @Test func actualCompletionUpdatesSpeechEstimate() {
        #expect(LiveCaptionPolicy.initialCharactersPerSecond == 4.5)
        #expect(
            LiveCaptionPolicy.updatedSpeechRate(4.5, characters: 18, duration: 3) == 4.875
        )
    }
}
