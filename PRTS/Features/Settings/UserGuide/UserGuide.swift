import Foundation

/// The bundled user guide that matches this iPhone's buttons, in the system language. Each guide
/// leads with the buttons the phone has and mentions the on-screen fallback once.
enum UserGuide: String, CaseIterable {
    /// Action button and Camera Control: iPhone 16 and 17 series, iPhone Air.
    case cameraControl = "camera-control"
    /// Action button only: iPhone 15 Pro, iPhone 15 Pro Max, iPhone 16e.
    case actionButton = "action-button"
    /// Neither button: iPhone 15 and earlier.
    case basic

    /// Set once the guide has opened by itself on the first launch.
    static let shownKey = "userGuide.shown"

    static var current: UserGuide {
        kind(hasCameraControl: PhotoHardwareButtons.hasCameraControl, model: modelIdentifier)
    }

    static func kind(hasCameraControl: Bool, model: String) -> UserGuide {
        if hasCameraControl { return .cameraControl }
        return hasActionButton(model) ? .actionButton : .basic
    }

    /// There is no API for the Action button. It arrived with iPhone 15 Pro (iPhone16,1 and
    /// iPhone16,2) and is on every iPhone from iPhone17,1 on, including iPhone 16e.
    static func hasActionButton(_ model: String) -> Bool {
        guard model.hasPrefix("iPhone") else { return false }
        let numbers = model.dropFirst("iPhone".count).split(separator: ",").compactMap { Int($0) }
        guard numbers.count == 2 else { return false }
        return numbers[0] >= 17 || (numbers[0] == 16 && numbers[1] <= 2)
    }

    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }

    func markdown(language: SpeechLanguage) -> String {
        guard
            let url = Bundle.main.url(
                forResource: "\(rawValue).\(language.resourceIdentifier)",
                withExtension: "md"
            ),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }
}

/// A guide split into the few block types the guides use.
struct UserGuideDocument: Equatable {
    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
        case bullet(String)
    }

    let blocks: [Block]

    /// The level-1 title is dropped: the window already shows it.
    init(markdown: String) {
        blocks = markdown.split(separator: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("# ") { return nil }
            if text.hasPrefix("## ") { return .heading(String(text.dropFirst(3))) }
            if text.hasPrefix("- ") { return .bullet(String(text.dropFirst(2))) }
            return .paragraph(text)
        }
    }

    /// What the reader speaks: the same blocks without Markdown marks, one per line.
    var spokenText: String {
        blocks.map { block in
            switch block {
            case .heading(let text), .paragraph(let text), .bullet(let text):
                text.replacingOccurrences(of: "**", with: "")
            }
        }
        .joined(separator: "\n")
    }
}
