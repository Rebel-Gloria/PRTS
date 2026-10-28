# SpatialCore

Pure Swift, platform-light geometry package used by the PRTS app and the standalone validation project.

## Responsibilities

- depth observation validation and projection
- robust local ground estimation
- three-state local grid and conservative clearance
- surface/obstacle model summaries
- fixed-target path prediction and haptic policy inputs
- Codable contracts used by diagnostics and replay tests

## Non-responsibilities

SpatialCore does not import SwiftUI, ARKit, Metal, AVFoundation, Core ML or UIKit. It does not own a camera session, draw pixels, speak, vibrate or write files.

Keep synthetic tests deterministic and label replay data honestly; a passing package test is not a LiDAR acceptance result.
