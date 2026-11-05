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
    var errorDescription: String? {
        switch self {
        case .missingKey: "请先在设置中保存 API Key"
        case .invalidService: "请在设置里填写服务地址和模型"
        case .emptyInput: "未获取到图片或提问内容"
        case .malformedStream: "图片描述服务返回了无效数据"
        case .incompleteStream, .answerTooLong: "图片描述连接提前结束，请重试"
        case .emptyAnswer: "图片描述服务没有返回正文"
        case .responseTooLarge: "图片描述响应过长"
        case .http(let status): "图片描述请求失败（HTTP \(status)）"
        }
    }
}
