import Combine
import Foundation
import SpatialCore

/// One announcement per directional episode. Brief missing frames retain the latch;
/// only confirmed alignment or a change of side re-arms it.
struct TurnAnnouncementPolicy {
    private var angles = PathHapticPolicy()
    private var announcedSide = 0
    mutating func reset() { self = .init() }
    mutating func update(
        heading: PathHeading?,
        now: Double,
        threshold: Float,
        alignment: Float
    ) -> Int? {
        _ = angles.update(
            heading: heading,
            now: now,
            enabled: true,
            threshold: threshold,
            alignmentDegrees: alignment
        )
        if angles.mode == "aligned_latched" {
            announcedSide = 0
            return nil
        }
        let side = angles.mode == "left_double" ? -1 : (angles.mode == "right_long" ? 1 : 0)
        guard side != 0, side != announcedSide else { return nil }
        announcedSide = side
        return side
    }
}
