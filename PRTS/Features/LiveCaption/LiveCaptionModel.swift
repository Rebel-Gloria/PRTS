import Foundation

/// Experimental choice of the model behind live captions. Only Qwen takes real video; the others
/// get the same frames in the form they accept, so their answers are not yet validated.
nonisolated enum LiveCaptionModel {
    static let selectionKey = "intelligence.provider.liveCaption"
    static let choices: [PhotoChatProvider] = [.qwen, .deepseek, .onDevice]

    static func current(_ defaults: UserDefaults = .standard) -> PhotoChatProvider {
        defaults.string(forKey: selectionKey).flatMap(PhotoChatProvider.init(rawValue:))
            .flatMap { choices.contains($0) ? $0 : nil } ?? .qwen
    }

    /// New frames per request. The bundled model's picture holds four frames and no more.
    static func frameLimit(_ provider: PhotoChatProvider) -> Int {
        provider == .onDevice ? 4 : LiveCaptionPolicy.maximumSamples
    }

    /// A picture of four frames has no room for one from the previous video.
    static func carriesPreviousFrame(_ provider: PhotoChatProvider) -> Bool {
        provider != .onDevice
    }

    /// The bundled model runs one request at a time on its own queue.
    static func requestLimit(_ provider: PhotoChatProvider) -> Int {
        provider == .onDevice ? 1 : LiveCaptionPolicy.maximumRequestsInFlight
    }
}
