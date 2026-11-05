import Foundation
import Testing

@testable import PRTS

struct PhotoPromptSelectionTests {
    @Test func localEnhancementIsOffByDefaultAndCanBeDisabledAgain() throws {
        let name = "PhotoPromptSelectionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!defaults.bool(forKey: PhotoChatProvider.localEnhancedKey))
        #expect(
            try PhotoDescriptionConfiguration(feature: .question, defaults: defaults).system
                == PhotoPrompts.localQuestionSystem
        )
        defaults.set(true, forKey: PhotoChatProvider.localEnhancedKey)
        #expect(
            try PhotoDescriptionConfiguration(feature: .question, defaults: defaults).system
                == PhotoPrompts.questionSystem
        )
        defaults.set(false, forKey: PhotoChatProvider.localEnhancedKey)
        #expect(
            try PhotoDescriptionConfiguration(feature: .question, defaults: defaults).system
                == PhotoPrompts.localQuestionSystem
        )
    }

    @Test func localEnhancementDoesNotChangeShortDescriptionsOrThinking() throws {
        let name = "PhotoPromptSelectionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for enabled in [false, true] {
            defaults.set(enabled, forKey: PhotoChatProvider.localEnhancedKey)
            #expect(
                try PhotoDescriptionConfiguration(feature: .description, defaults: defaults).system
                    == PhotoPrompts.system
            )
            #expect(!defaults.bool(forKey: PhotoChatProvider.qwen.questionThinkingKey))
        }
        defaults.set(false, forKey: PhotoChatProvider.localEnhancedKey)
        defaults.set(true, forKey: PhotoChatProvider.qwen.questionThinkingKey)
        #expect(
            try PhotoDescriptionConfiguration(feature: .question, defaults: defaults).system
                == PhotoPrompts.localQuestionSystem
        )
    }
}
