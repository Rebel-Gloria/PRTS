import Foundation
import Testing

@testable import PRTS

struct PhotoPromptSelectionTests {
    @Test func localEnhancementIsOffByDefaultAndCanBeDisabledAgain() {
        let name = "PhotoPromptSelectionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let question = "这是什么，有什么用途？"
        #expect(!defaults.bool(forKey: PhotoPrompts.localEnhancedKey))
        #expect(
            PhotoPrompts.localSystem(question: question, defaults: defaults)
                == PhotoPrompts.localQuestionSystem
        )
        defaults.set(true, forKey: PhotoPrompts.localEnhancedKey)
        #expect(
            PhotoPrompts.localSystem(question: question, defaults: defaults)
                == PhotoPrompts.questionSystem
        )
        defaults.set(false, forKey: PhotoPrompts.localEnhancedKey)
        #expect(
            PhotoPrompts.localSystem(question: question, defaults: defaults)
                == PhotoPrompts.localQuestionSystem
        )
    }

    @Test func localEnhancementDoesNotChangeShortDescriptionsOrThinking() {
        let name = "PhotoPromptSelectionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for enabled in [false, true] {
            defaults.set(enabled, forKey: PhotoPrompts.localEnhancedKey)
            #expect(
                PhotoPrompts.localSystem(question: nil, defaults: defaults) == PhotoPrompts.system
            )
            #expect(!defaults.bool(forKey: PhotoPrompts.questionThinkingKey))
        }
        defaults.set(false, forKey: PhotoPrompts.localEnhancedKey)
        defaults.set(true, forKey: PhotoPrompts.questionThinkingKey)
        #expect(
            PhotoPrompts.localSystem(question: "门在哪？", defaults: defaults)
                == PhotoPrompts.localQuestionSystem
        )
    }
}
