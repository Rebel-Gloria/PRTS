import Foundation
import Testing

@testable import PRTS

@MainActor
struct TextReadingServiceTests {
    @Test func selectionsPreserveProviderAndVisionValues() {
        let name = "TextReadingServiceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(
            TextReadingService.allCases == [.vlm, .onDevice, .qwen, .deepseek, .custom, .vision]
        )
        #expect(TextReadingService.current(defaults) == .vlm)
        for selection in TextReadingService.allCases {
            defaults.set(selection.rawValue, forKey: TextReadingService.selectionKey)
            #expect(TextReadingService.current(defaults) == selection)
        }
    }

    @Test(arguments: TextReadingService.allCases, PhotoChatProvider.allCases)
    func fallbackChainUsesTheSelectedProvider(
        selection: TextReadingService,
        defaultProvider: PhotoChatProvider
    ) async throws {
        let name = "TextReadingServiceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(defaultProvider.rawValue, forKey: PhotoChatProvider.selectionKey)
        defaults.set(selection.rawValue, forKey: TextReadingService.selectionKey)
        let provider = IntelligenceFeature.textReading.provider(defaults)
        let remoteAvailable = provider != nil && provider != .onDevice
        var calls: [TextReadingService.Reader] = []
        try await TextReadingService.current(defaults).read(remoteAvailable: remoteAvailable) {
            calls.append($0)
            if $0 != .vision { throw URLError(.cannotConnectToHost) }
        }
        let expected: [TextReadingService.Reader]
        switch selection {
        case .vision: expected = [.vision]
        case .onDevice: expected = [.onDevice, .vision]
        case .vlm:
            expected =
                defaultProvider == .onDevice
                ? [.onDevice, .vision] : [.remote, .onDevice, .vision]
        case .qwen, .deepseek, .custom: expected = [.remote, .onDevice, .vision]
        }
        #expect(calls == expected)
    }

    @Test func successfulRemoteReadingDoesNotStartLocalReaders() async throws {
        var calls: [TextReadingService.Reader] = []
        try await TextReadingService.vlm.read(remoteAvailable: true) { calls.append($0) }
        #expect(calls == [.remote])
    }

    @Test func unavailableRemoteFallsBackToTheLocalModel() async throws {
        var calls: [TextReadingService.Reader] = []
        try await TextReadingService.vlm.read(remoteAvailable: true) { reader in
            calls.append(reader)
            if reader == .remote { throw URLError(.cannotConnectToHost) }
        }
        #expect(calls == [.remote, .onDevice])
    }

    @Test func missingRemoteSetupStartsOffline() async throws {
        var calls: [TextReadingService.Reader] = []
        try await TextReadingService.vlm.read(remoteAvailable: false) { calls.append($0) }
        #expect(calls == [.onDevice])
    }

    @Test func failedModelsFallBackToVision() async throws {
        var calls: [TextReadingService.Reader] = []
        try await TextReadingService.vlm.read(remoteAvailable: true) { reader in
            calls.append(reader)
            if reader != .vision { throw URLError(.unknown) }
        }
        #expect(calls == [.remote, .onDevice, .vision])
    }

    @Test func everyFailedStepExceptTheLastIsReported() async {
        var reported = 0
        await #expect(throws: URLError.self) {
            try await TextReadingService.vlm.read(
                remoteAvailable: true,
                onFailure: { _ in reported += 1 }
            ) { _ in throw URLError(.timedOut) }
        }
        #expect(reported == 2)
    }

    @Test func visionNeverStartsAModel() async throws {
        var calls: [TextReadingService.Reader] = []
        try await TextReadingService.vision.read(remoteAvailable: true) { calls.append($0) }
        #expect(calls == [.vision])
    }

    @Test func failedVisionDoesNotStartAnotherReader() async {
        var calls: [TextReadingService.Reader] = []
        do {
            try await TextReadingService.vision.read(remoteAvailable: true) { reader in
                calls.append(reader)
                throw URLError(.unknown)
            }
            Issue.record("Expected the final reader's error")
        } catch {
            #expect((error as? URLError)?.code == .unknown)
        }
        #expect(calls == [.vision])
    }

    @Test func cancellationNeverStartsFallback() async {
        let errors: [any Error] = [CancellationError(), URLError(.cancelled)]
        for error in errors {
            var calls: [TextReadingService.Reader] = []
            do {
                try await TextReadingService.vlm.read(remoteAvailable: true) { reader in
                    calls.append(reader)
                    throw error
                }
                Issue.record("Expected cancellation")
            } catch {
                #expect(error is CancellationError)
            }
            #expect(calls == [.remote])
        }
    }

    @Test func cancelledTaskDoesNotStartAReader() async {
        var calls: [TextReadingService.Reader] = []
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await TextReadingService.vlm.read(remoteAvailable: true) { calls.append($0) }
                Issue.record("Expected cancellation")
            } catch {
                #expect(error is CancellationError)
            }
        }
        await task.value
        #expect(calls.isEmpty)
    }

    @Test func cancellationDuringARequestPreventsFallbackAfterANetworkError() async {
        var calls: [TextReadingService.Reader] = []
        let task = Task { @MainActor in
            do {
                try await TextReadingService.vlm.read(remoteAvailable: true) { reader in
                    calls.append(reader)
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw URLError(.networkConnectionLost)
                }
                Issue.record("Expected cancellation")
            } catch {
                #expect(error is CancellationError)
            }
        }
        await task.value
        #expect(calls == [.remote])
    }
}
