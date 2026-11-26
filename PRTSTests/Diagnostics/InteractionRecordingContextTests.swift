import Foundation
import Testing

@testable import PRTS

struct InteractionRecordingContextTests {
    private typealias Recording = DevInteractionRecording

    @Test func scopesForwardResultsAndErrorsExactlyOnce() {
        var calls = 0
        let value = Recording.withContext(id: UUID(), generation: 1) {
            Recording.withContext(fallbackGeneration: 2) {
                calls += 1
                return 42
            }
        }
        #expect(value == 42)
        #expect(calls == 1)
        #expect(throws: CancellationError.self) {
            try Recording.withContext(fallbackGeneration: 1) {
                try Recording.withContext(generation: 2) {
                    calls += 1
                    throw CancellationError()
                }
            }
        }
        #expect(calls == 2)
    }

    #if PRTS_DEV
    @Test func nestedScopesPreserveParentUntilReplaced() async {
        let parent = UUID()
        let child = UUID()
        let task = Recording.withContext(id: parent, generation: 1) {
            #expect(throws: CancellationError.self) {
                try Recording.withContext(generation: 2) {
                    #expect(Recording.interactionID == parent.uuidString)
                    #expect(Recording.recordingGeneration == 2)
                    try Recording.withContext(id: child, generation: 3) {
                        #expect(Recording.interactionID == child.uuidString)
                        #expect(Recording.recordingGeneration == 3)
                        throw CancellationError()
                    }
                }
            }
            #expect(Recording.interactionID == parent.uuidString)
            #expect(Recording.recordingGeneration == 1)
            return Recording.withContext(id: child, generation: 0) {
                Recording.withContext(fallbackGeneration: 4) {
                    Task { (Recording.interactionID, Recording.recordingGeneration) }
                }
            }
        }
        #expect(Recording.interactionID == nil)
        #expect(Recording.recordingGeneration == nil)
        let (id, generation) = await task.value
        #expect(id == child.uuidString)
        #expect(generation == 0)
        let fallback = Recording.withContext(fallbackGeneration: 4) {
            Recording.recordingGeneration
        }
        #expect(fallback == 4)
    }
    #endif
}
