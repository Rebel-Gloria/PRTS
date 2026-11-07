import Foundation
import Testing

@testable import PRTS

private struct FallbackFailure: Error {}

@MainActor
struct PhotoDescriptionFallbackTests {
    private func request(_ provider: PhotoChatProvider, thinking: Bool = false)
        -> PhotoDescriptionRequest
    {
        PhotoDescriptionRequest(
            configuration: PhotoDescriptionConfiguration(
                provider: provider,
                service: provider == .onDevice ? nil : .qwen,
                system: "cloud",
                localSystem: "local",
                thinking: thinking,
                uploadAllowed: true,
                highResolution: false
            ),
            key: "synthetic-test-key"
        )
    }

    @Test func aWorkingCloudModelNeverStartsTheLocalModel() async throws {
        let answer = try await PhotoDescriptionBackend.answer(
            request: request(.qwen),
            errors: .ignored,
            remote: { "cloud answer" },
            local: { _ in
                Issue.record("The local model must not start")
                return ""
            }
        )
        #expect(answer == "cloud answer")
    }

    @Test func aFailedCloudModelFallsBackWithTheLocalPrompt() async throws {
        var systems: [String] = []
        let answer = try await PhotoDescriptionBackend.answer(
            request: request(.qwen),
            errors: .ignored,
            remote: { throw FallbackFailure() },
            local: {
                systems.append($0)
                return "local answer"
            }
        )
        #expect(answer == "local answer")
        #expect(systems == ["local"])
    }

    @Test func theLocalErrorIsReportedWhenBothFail() async {
        await #expect(throws: PhotoChatError.self) {
            _ = try await PhotoDescriptionBackend.answer(
                request: request(.qwen),
                errors: .ignored,
                remote: { throw FallbackFailure() },
                local: { _ in throw PhotoChatError.emptyAnswer }
            )
        }
    }

    @Test func cancellationNeverStartsTheLocalModel() async {
        for failure in [CancellationError() as Error, URLError(.cancelled) as Error] {
            await #expect(throws: (any Error).self) {
                _ = try await PhotoDescriptionBackend.answer(
                    request: request(.qwen),
                    errors: .ignored,
                    remote: { throw failure },
                    local: { _ in
                        Issue.record("A cancelled request must not fall back")
                        return ""
                    }
                )
            }
        }
    }

    @Test func onDeviceSkipsTheCloudModel() async throws {
        let answer = try await PhotoDescriptionBackend.answer(
            request: request(.onDevice),
            errors: .ignored,
            remote: {
                Issue.record("On device must not call the cloud")
                return ""
            },
            local: { $0 }
        )
        #expect(answer == "local")
    }

    @Test func theDeadlineStopsASlowRequest() async {
        let start = ContinuousClock.now
        do {
            _ = try await RequestDeadline.run(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
                return "late"
            }
            Issue.record("The request must time out")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func aFastRequestBeatsTheDeadline() async throws {
        let answer = try await RequestDeadline.run(.seconds(30)) { "soon" }
        #expect(answer == "soon")
    }
}
