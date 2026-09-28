// Synthetic API validation only: no engine/player is created and NO hardware is vibrated.
import Foundation
import CoreHaptics
import SpatialCore
@main struct Main {
    static func main() throws {
        var records: [[String:Any]] = []
        for angle in [-30,30,0] {
            let data = try JSONSerialization.data(withJSONObject:["angleDegrees":angle,"crossTrack":0,"startDistance":0.5,"remainingLength":3,"target":[0,0,-1]])
            let heading = try JSONDecoder().decode(PathHeading.self,from:data)
            var policy = PathHapticPolicy(),count = 0
            for t in stride(from:0.0,through:2.0,by:0.05) {
                guard let pulse = policy.update(heading:heading,now:t,enabled:true,threshold:12) else { continue }
                let events = (pulse.segments ?? []).map { s in CHHapticEvent(eventType:.hapticContinuous,parameters:[
                    CHHapticEventParameter(parameterID:.hapticIntensity,value:s.intensity),
                    CHHapticEventParameter(parameterID:.hapticSharpness,value:s.sharpness)
                ],relativeTime:s.relativeTime,duration:s.duration) }
                let pattern = try CHHapticPattern(events:events,parameters:[])
                precondition(abs(pattern.duration-pulse.duration) < 0.00001)
                records.append(["angle":angle,"time":t,"kind":pulse.kind,"pattern":try pattern.exportDictionary()]);count += 1
            }
            precondition(angle == 0 ? count == 1 : count >= 3)
        }
        let payload: [String:Any] = ["source":"synthetic_CoreHaptics_pattern_validation","hardwarePlayed":false,"records":records]
        print(String(data:try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
