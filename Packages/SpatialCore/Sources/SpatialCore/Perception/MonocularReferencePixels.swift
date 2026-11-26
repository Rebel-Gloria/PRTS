import Foundation

/// The integer lookup identifies the observation; the subpixel ray and native ID are for reprojection.
public struct MonocularReferencePixels: Sendable {
    public private(set) var samples: [ScaleSample] = []
    public private(set) var pixelIndices: [Int] = []

    public init() {}

    public mutating func append(
        pixelIndex: Int,
        relativeMap: [Float],
        meters: Float,
        u: Float,
        v: Float,
        source: String,
        featureID: UInt64? = nil
    ) {
        samples.append(
            .init(
                relative: relativeMap[pixelIndex],
                meters: meters,
                u: u,
                v: v,
                source: source,
                featureID: featureID
            )
        )
        pixelIndices.append(pixelIndex)
    }

    /// A model pixel contributes at most one vote. A pair of landmarks at that resolution
    /// cannot distinguish an occlusion edge from a near outlier, so neither chooses the scale.
    public func independentSamples() -> [ScaleSample] {
        var selected: [Int: Int] = [:]
        var keep = [Bool](repeating: false, count: samples.count)
        for (i, s) in samples.enumerated() {
            guard s.relative.isFinite, (0.3...8).contains(s.meters),
                (0..<1).contains(s.u), (0..<1).contains(s.v)
            else { continue }
            let pixel = pixelIndices[i]
            if let old = selected[pixel] {
                guard old >= 0, s.featureID != nil else { continue }
                keep[old] = false
                if samples[old].featureID != nil {
                    selected[pixel] = -1  // Ambiguous landmarks; a floor ray cannot resolve them.
                    continue
                }
            }
            selected[pixel] = i
            keep[i] = true
        }
        return samples.indices.compactMap { keep[$0] ? samples[$0] : nil }
    }
}
