import CoreGraphics
import Foundation

/// Turns the document outline found in each preview frame into one spoken hint and an
/// auto-capture decision. Corners are normalized, origin top-left, in the upright portrait image.
nonisolated struct DocumentFraming {
    enum Hint: String, Equatable, CaseIterable {
        case searching, moveLeft, moveRight, moveUp, moveDown, closer, farther, hold
        var localizationKey: String { "ocr.hint.\(rawValue)" }
    }
    enum Decision: Equatable { case wait, hint(Hint), capture }

    /// A corner this close to the frame edge means the page continues outside the picture.
    static let edgeMargin: CGFloat = 0.03
    /// Smaller pages are too few pixels for small print.
    static let minimumArea: CGFloat = 0.15
    /// Capture only after the outline has stayed put this long, so a passing table edge or
    /// screen glimpsed while moving is never shot.
    static let steadyDuration: TimeInterval = 0.8
    static let steadyTolerance: CGFloat = 0.03
    /// The same hint is repeated at most this often; a changed hint is spoken at once.
    static let repeatInterval: TimeInterval = 2.5

    private var steadyCorners: [CGPoint]?
    private var steadySince: TimeInterval = 0
    private var lastHint: Hint?
    private var lastHintAt: TimeInterval = 0

    mutating func update(corners: [CGPoint]?, at time: TimeInterval) -> Decision {
        let hint = Self.hint(for: corners)
        if hint == .hold, let corners {
            if let steadyCorners, zip(steadyCorners, corners).allSatisfy({ hypot($0.x - $1.x, $0.y - $1.y) <= Self.steadyTolerance }) {
                if time - steadySince >= Self.steadyDuration { return .capture }
            } else {
                steadyCorners = corners; steadySince = time
            }
        } else {
            steadyCorners = nil
        }
        guard hint != lastHint || time - lastHintAt >= Self.repeatInterval else { return .wait }
        lastHint = hint; lastHintAt = time
        return .hint(hint)
    }

    static func hint(for corners: [CGPoint]?) -> Hint {
        guard let corners, corners.count == 4 else { return .searching }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let left = xs.min()! < edgeMargin, right = xs.max()! > 1 - edgeMargin
        let top = ys.min()! < edgeMargin, bottom = ys.max()! > 1 - edgeMargin
        if (left && right) || (top && bottom) { return .farther }
        // Moving the phone toward the cut-off side brings that part of the page into view.
        if left { return .moveLeft }
        if right { return .moveRight }
        if top { return .moveUp }
        if bottom { return .moveDown }
        return area(corners) < minimumArea ? .closer : .hold
    }

    /// Shoelace area of the outline, as a fraction of the frame.
    static func area(_ corners: [CGPoint]) -> CGFloat {
        let pairs = zip(corners, corners.dropFirst() + corners.prefix(1))
        return abs(pairs.reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }) / 2
    }
}
