enum AnswerCue { case submit, record }

/// Handles user-requested answers, status prompts and tones for descriptions, live captions and
/// text reading; SpeechManager handles obstacle announcements.
@MainActor
protocol AnswerAudio: AnyObject {
    var onFinished: (() -> Void)? { get set }
    func cue(_ cue: AnswerCue) async throws
    func speak(_ text: String) throws
    func stop()
}

extension AnswerAudioOutput: AnswerAudio {}
