import Foundation
import Testing
@testable import PRTS

/// Puts test keys into the app on a phone so the cloud services can be tried by hand: both keys
/// saved, Qwen chosen, photo upload allowed, text read by the remote API. Runs only with
/// PRTS_INSTALL_KEYS=1 and the keys passed in (TEST_RUNNER_ prefix on xcodebuild); the keys are
/// never in the repo. Run it alone: other tests reset the provider choice.
struct TrialKeysTests {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["PRTS_INSTALL_KEYS"] == "1"))
    func installsTrialKeys() throws {
        let qwen = try #require(Self.env["PRTS_QWEN_KEY"]), deepseek = try #require(Self.env["PRTS_DEEPSEEK_KEY"])
        try PhotoCredentialStore.save(qwen, account: PhotoChatProvider.qwen.keyAccount)
        try PhotoCredentialStore.save(deepseek, account: PhotoChatProvider.deepseek.keyAccount)
        let defaults = UserDefaults.standard
        defaults.set(PhotoChatProvider.qwen.rawValue, forKey: PhotoChatProvider.selectionKey)
        defaults.set(true, forKey: "photoDescription.uploadAllowed")
        defaults.set(TextReadingService.remote.rawValue, forKey: TextReadingService.selectionKey)
        #expect(try PhotoCredentialStore.read(account: PhotoChatProvider.qwen.keyAccount) == qwen)
        #expect(try PhotoCredentialStore.read(account: PhotoChatProvider.deepseek.keyAccount) == deepseek)
    }
}
