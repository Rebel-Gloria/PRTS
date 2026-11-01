import Testing

@testable import PRTS

struct HomeFeedbackPolicyTests {
    @Test func guidanceRequiresBothLowVisionAndGuideToBeOff() {
        #expect(
            !HomeFeedbackPolicy.suppressesGuidance(lowVisionMode: false, showingUserGuide: false)
        )
        #expect(HomeFeedbackPolicy.suppressesGuidance(lowVisionMode: true, showingUserGuide: false))
        #expect(HomeFeedbackPolicy.suppressesGuidance(lowVisionMode: false, showingUserGuide: true))
        #expect(HomeFeedbackPolicy.suppressesGuidance(lowVisionMode: true, showingUserGuide: true))
    }
}
