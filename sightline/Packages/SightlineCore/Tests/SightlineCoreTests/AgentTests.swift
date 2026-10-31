// labels: testing, needs-review
import Foundation
import Testing
@testable import SightlineCore

@Suite struct AgentTests {
    @Test func parsesActions() {
        #expect(AgentAction.parse(name: "find_object", arguments: #"{"noun":" Water Bottle "}"#) == .findObject("water bottle"))
        #expect(AgentAction.parse(name: "find_object", arguments: #"{"noun":"key with an orange tag"}"#) == .findObject("key with an orange tag"))
        #expect(AgentAction.parse(name: "scan_for", arguments: #"{"noun":"green key"}"#) == .scanFor("green key"))
        #expect(AgentAction.parse(name: "map_room", arguments: "{}") == .mapRoom)
        #expect(AgentAction.parse(name: "select_target", arguments: #"{"candidate_id":"1"}"#) == .selectTarget("1", say: nil))
        #expect(AgentAction.parse(name: "select_target", arguments: #"{"candidate_id":"0","say":"Left cup."}"#) == .selectTarget("0", say: "Left cup."))
        #expect(AgentAction.parse(name: "say", arguments: #"{"text":"Two cups. Checking."}"#) == .say("Two cups. Checking."))
        #expect(AgentAction.parse(name: "get_state", arguments: "{}") == .getState)
        #expect(AgentAction.parse(name: "stop", arguments: "") == .stop)
    }

    @Test func rejectsBadActions() {
        #expect(AgentAction.parse(name: "delete_files", arguments: "{}") == nil)
        #expect(AgentAction.parse(name: "find_object", arguments: "{}") == nil)
        #expect(AgentAction.parse(name: "find_object", arguments: "not json") == nil)
        #expect(AgentAction.parse(name: "say", arguments: #"{"text":"   "}"#) == nil)
        let long = String(repeating: "a", count: 201)
        #expect(AgentAction.parse(name: "ask_user", arguments: "{\"question\":\"\(long)\"}") == nil)
    }

    @Test func stateJSON() {
        let c = AgentCandidate(id: "1", confidence: 0.8734, offset: BodyOffset(right: -0.123, up: -0.3, forward: 0.456),
                               widthFraction: 0.1234, heightFraction: 0.2)
        let s = AgentState(phase: "choosing", userSaid: "find the cup", targetName: "cup", candidates: [c],
                           samCallsLeft: 4, tracking: "normal")
        #expect(s.json() == #"{"candidates":[{"confidence":0.87,"forward_cm":46,"height_fraction":0.2,"id":"1","name":"","right_cm":-12,"up_cm":-30,"width_fraction":0.12}],"not_found":[],"phase":"choosing","room_items":[],"sam_calls_left":4,"target_name":"cup","tracking":"normal","user_said":"find the cup"}"#)
    }

    @Test func ambiguity() {
        #expect(AgentTools.isAmbiguous([0.9, 0.85]))
        #expect(!AgentTools.isAmbiguous([0.95, 0.6]))
        #expect(!AgentTools.isAmbiguous([0.9, 0.3]))
        #expect(!AgentTools.isAmbiguous([0.9]))
        #expect(AgentTools.isAmbiguous([0.52, 0.69, 0.5]) == false)  // IMG_5770: 0.69 vs 0.52
    }

    @Test func toolDefinitionsAreValidJSON() throws {
        let data = try JSONSerialization.data(withJSONObject: AgentTools.definitions)
        #expect(data.count > 100)
        #expect(AgentTools.definitions.map { $0["name"] as? String } == ["get_state", "find_object", "select_target", "say", "ask_user", "scan_for", "map_room", "stop"])
    }
}
