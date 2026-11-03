import Foundation
import Testing

@testable import PRTS

struct IntelligenceFeatureTests {
    @Test func unsetFeaturesFollowDefaultProviderChanges() {
        let name = "IntelligenceFeatureTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for feature in IntelligenceFeature.allCases {
            #expect(feature.provider(defaults) == .onDevice)
            #expect(defaults.object(forKey: feature.selectionKey) == nil)
        }
        for provider in PhotoChatProvider.allCases {
            defaults.set(provider.rawValue, forKey: PhotoChatProvider.selectionKey)
            for feature in IntelligenceFeature.allCases {
                #expect(feature.provider(defaults) == provider)
            }
        }
    }

    @Test(arguments: IntelligenceFeature.allCases)
    func featureOverridesRemainIndependentOfDefault(feature: IntelligenceFeature) {
        let name = "IntelligenceFeatureTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("qwen", forKey: PhotoChatProvider.selectionKey)
        defaults.set("deepseek", forKey: feature.selectionKey)
        #expect(feature.provider(defaults) == .deepseek)
        defaults.set("custom", forKey: PhotoChatProvider.selectionKey)
        for other in IntelligenceFeature.allCases {
            #expect(other.provider(defaults) == (other == feature ? .deepseek : .custom))
        }
        defaults.removeObject(forKey: feature.selectionKey)
        #expect(feature.provider(defaults) == .custom)
    }

    @Test func visionHasNoModelProviderAndVLMFollowsDefault() {
        let name = "IntelligenceFeatureTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("qwen", forKey: PhotoChatProvider.selectionKey)
        defaults.set("vision", forKey: TextReadingService.selectionKey)
        #expect(IntelligenceFeature.textReading.provider(defaults) == nil)
        defaults.set("vlm", forKey: TextReadingService.selectionKey)
        #expect(IntelligenceFeature.textReading.provider(defaults) == .qwen)
    }

    @Test func questionThinkingIsStoredPerProvider() {
        let name = "IntelligenceFeatureTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!PhotoChatProvider.qwen.questionThinking(defaults))
        #expect(!PhotoChatProvider.deepseek.questionThinking(defaults))
        #expect(PhotoChatProvider.qwen.questionThinkingKey == "photoDescription.questionThinking")
        #expect(
            PhotoChatProvider.deepseek.questionThinkingKey
                == "photoDescription.questionThinking.deepseek"
        )
        defaults.set(true, forKey: PhotoPrompts.questionThinkingKey)
        #expect(PhotoChatProvider.qwen.questionThinking(defaults))
        #expect(!PhotoChatProvider.deepseek.questionThinking(defaults))
        defaults.set(true, forKey: PhotoChatProvider.deepseek.questionThinkingKey)
        defaults.set(false, forKey: PhotoPrompts.questionThinkingKey)
        #expect(!PhotoChatProvider.qwen.questionThinking(defaults))
        #expect(PhotoChatProvider.deepseek.questionThinking(defaults))
        #expect(!PhotoChatProvider.onDevice.questionThinking(defaults))
        #expect(!PhotoChatProvider.custom.questionThinking(defaults))
    }
}
