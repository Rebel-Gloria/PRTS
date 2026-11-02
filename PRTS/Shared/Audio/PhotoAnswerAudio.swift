@MainActor
protocol PhotoAnswerAudio: AnyObject {
    var onFinished: (() -> Void)? { get set }
    func cue(_ cue: PhotoAudioOutput.Cue) throws
    func speak(_ text: String) throws
    func stop()
}

extension PhotoAudioOutput: PhotoAnswerAudio {}
