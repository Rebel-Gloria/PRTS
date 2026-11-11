import Foundation

nonisolated enum PhotoChatError: Error, LocalizedError, CustomNSError {
    case missingKey, invalidService, emptyInput, malformedStream, incompleteStream, emptyAnswer,
        responseTooLarge, answerTooLong
    case http(Int)
    static var errorDomain: String { "PRTS.PhotoChat" }
    var errorCode: Int {
        switch self {
        case .missingKey: 1
        case .invalidService: 2
        case .emptyInput: 3
        case .malformedStream: 4
        case .incompleteStream: 5
        case .emptyAnswer: 6
        case .responseTooLarge: 7
        case .answerTooLong: 8
        case .http(let status): status
        }
    }
    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription!]
    }
    /// Shown under the photo button and read aloud, so it follows the interface language.
    var errorDescription: String? {
        if case .http(let status) = self {
            return AppLocalization.interfaceString(localizationKey, arguments: [status])
        }
        return AppLocalization.interfaceString(localizationKey)
    }
    private var localizationKey: String {
        switch self {
        case .missingKey: "photo.error.missingKey"
        case .invalidService: "photo.error.invalidService"
        case .emptyInput: "photo.error.emptyInput"
        case .malformedStream: "photo.error.malformedStream"
        case .incompleteStream, .answerTooLong: "photo.error.incompleteStream"
        case .emptyAnswer: "photo.error.emptyAnswer"
        case .responseTooLarge: "photo.error.responseTooLarge"
        case .http: "photo.error.http"
        }
    }
}
