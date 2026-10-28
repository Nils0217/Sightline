// labels: testing, needs-review
// Checks the Swift SAM parser/decoder against Meta's Python meta-sam-parser on real outputs.
import CryptoKit
import Foundation
import Testing
@testable import SightlineCore

struct SAMFixture: Decodable {
    struct Record: Decodable {
        var id: String
        var left: Int, top: Int, right: Int, bottom: Int
        var confidence: Float?
        var mask_width: Int, mask_height: Int
        var ones: Int
        var sha256: String
    }
    var name: String
    var text: String
    var records: [Record]
}

@Suite struct SAMOutputTests {
    static let fixtures: [SAMFixture] = {
        let url = Bundle.module.url(forResource: "sam_fixtures", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode([SAMFixture].self, from: Data(contentsOf: url))
    }()

    @Test(arguments: fixtures.map(\.name))
    func matchesPythonParser(name: String) throws {
        let fixture = try #require(Self.fixtures.first { $0.name == name })
        let records = SAMParser.parse(fixture.text)
        #expect(records.count == fixture.records.count)
        for (got, want) in zip(records, fixture.records) {
            #expect(got.id == want.id)
            #expect([got.left, got.top, got.right, got.bottom] as [Int] == [want.left, want.top, want.right, want.bottom])
            #expect(got.confidence == want.confidence)
            #expect([got.maskWidth, got.maskHeight] as [Int] == [want.mask_width, want.mask_height])
            let raster = try got.decodeMask()
            #expect(raster.count == want.mask_width * want.mask_height)
            #expect(raster.reduce(0) { $0 + Int($1) } == want.ones)
            let hash = SHA256.hash(data: Data(raster)).map { String(format: "%02x", $0) }.joined()
            #expect(hash == want.sha256)
        }
    }

    @Test func skipsMalformedRecords() {
        #expect(SAMParser.parse("<0f>0<|box;x1=5;y1=0;x2=2;y2=1;w=10;h=10|><|mask;x=0;y=0;data=1,1,~!!!!!|>").isEmpty)
        #expect(SAMParser.parse("no records here").isEmpty)
        #expect(SAMParser.parse("<1f>0<|box;x1=0;y1=0;x2=1;y2=1;w=10;h=10|><|mask;x=0;y=0;data=2,2,~!!!!!|>").isEmpty)
    }

    @Test func rejectsCorruptPayload() throws {
        var record = try #require(SAMParser.parse(Self.fixtures[1].text).first)
        record.payload = String(record.payload.dropLast(3))
        #expect(throws: SAMError.self) { try record.decodeMask() }
    }
}
