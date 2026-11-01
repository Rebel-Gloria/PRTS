import Foundation

nonisolated enum PhotoChatError: Error, LocalizedError {
    case missingKey, invalidService, emptyInput, malformedStream, incompleteStream, emptyAnswer,
        responseTooLarge
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .missingKey: "请先在设置中保存 API Key"
        case .invalidService: "请在设置里填写服务地址和模型"
        case .emptyInput: "未获取到图片或提问内容"
        case .malformedStream: "图片描述服务返回了无效数据"
        case .incompleteStream: "图片描述连接提前结束，请重试"
        case .emptyAnswer: "图片描述服务没有返回正文"
        case .responseTooLarge: "图片描述响应过长"
        case .http(let status): "图片描述请求失败（HTTP \(status)）"
        }
    }
}
