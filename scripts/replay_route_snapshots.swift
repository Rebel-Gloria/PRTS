// Offline replay of explicitly labelled AnalysisResult snapshots (including reconstructed
// compact-grid diagnostics). Caller must document any lost evidence; no sensor acquisition.
import Foundation
import SpatialCore

struct Input: Decodable {
  var result: AnalysisResult
  var options: PathOptions
  var cameraView: RouteCameraView?
}
struct Output: Encodable {
  var epoch: UInt64
  var frameID: UInt64
  var timestamp: Double
  var update: PathUpdate
}
let decoder = JSONDecoder()
let encoder = JSONEncoder()
encoder.outputFormatting = .sortedKeys
// The previous verified policy is an explicit comparator; recording does not select a planner.
let policy: RoutePlanningPolicy = CommandLine.arguments.contains("--verified") ? .verified : .obstacleVeto
var predictor = PathPredictor(policy:policy)
let input = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
for line in input.split(separator: "\n") {
  let row = try decoder.decode(Input.self, from: Data(line.utf8))
  let update = predictor.update(result: row.result, observation: nil, options: row.options, cameraView: row.cameraView)
  print(
    String(
      decoding: try encoder.encode(
        Output(
          epoch: row.result.epoch,
          frameID: row.result.frameID, timestamp: row.result.timestamp, update: update)),
      as: UTF8.self))
}
