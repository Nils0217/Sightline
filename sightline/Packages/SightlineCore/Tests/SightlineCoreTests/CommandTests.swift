// labels: testing, needs-review
import Testing
@testable import SightlineCore

@Suite struct CommandTests {
    @Test(arguments: [
        ("Find the cup", "cup"),
        ("find my red mug", "red mug"),
        ("Hey Sightline, where is my phone?", "phone"),
        ("Where's the TV remote", "tv remote"),
        ("Can you help me find my keys please", "keys"),
        ("I'm looking for the water bottle", "water bottle"),
        ("where is the cup on the table", "cup"),
        ("Sightline find glasses", "glasses"),
    ])
    func findsNoun(_ input: String, _ noun: String) {
        #expect(CommandParser.parse(input) == .find(noun))
    }

    @Test func stop() {
        #expect(CommandParser.parse("Stop") == .stop)
        #expect(CommandParser.parse("cancel.") == .stop)
    }

    @Test(arguments: ["", "hello", "what is this", "find", "find the", "find the big old heavy brown wooden box"])
    func unparsed(_ input: String) {
        #expect(CommandParser.parse(input) == nil)
    }
}
