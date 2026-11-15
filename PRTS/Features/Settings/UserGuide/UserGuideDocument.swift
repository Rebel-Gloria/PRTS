import Foundation

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
