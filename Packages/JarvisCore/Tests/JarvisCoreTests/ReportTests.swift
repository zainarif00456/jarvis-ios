import XCTest
@testable import JarvisCore

final class ReportTests: XCTestCase {
    let json = #"""
    {"info":{"id":"r1","title":"Awais thread","kind":"debrief","agent":"friday","created_at":"x","blocks":3,"pictures":0,"parent_id":null,"problems":[]},
     "report":{"title":"Awais thread","blocks":[
       {"id":"thread","type":"messages","heading":"Who said what","tone":"alert","messages":[{"who":"Awais","role":"client","when":"10:02","where":"#sales","text":"We need it today","kind":"quote"},{"who":"Zain","text":"On it","kind":"paraphrase","reply_to":0}],
        "beats":[{"say":"Awais asked for it today.","show":{"part":"messages","item":0}},{"say":"You replied.","show":{"part":"messages","item":1}}],
        "links":[{"to":"impact","label":"blocks"}]},
       {"id":"impact","type":"graph","heading":"Impact","diagram":{"source":"flowchart LR\n A[Awais] -->|asks| B(Release)\n B --> C{Deploy}","nodes":[{"id":"A","label":"Awais","note":"client"}]},
        "beats":[{"say":"It blocks the release.","show":{"focus":["B"],"flow":["A","B"]}}]},
       {"id":"stats","type":"stats","heading":"Numbers","stats":[{"label":"Late","value":"3","note":"days"}],"chart":{"type":"bar","title":"t","unit":"d","labels":["a","b"],"series":[{"name":"s","values":[1,null]}]},
        "person":{"name":"Awais Khan","role":"CTO","org":"Acme","facts":[{"label":"Since","value":"2021"}],"media":0},"media":[{"file":"media/a.webp","caption":"c","role":"photo"}]},
       {"no_id_is_dropped":true}
     ]}}
    """#

    func testParsesAScenePerBlock() throws {
        let r = try XCTUnwrap(Report.parse(JSONValue.parse(json)!))
        XCTAssertEqual(r.info.kind, "debrief"); XCTAssertEqual(r.blocks.count, 3, "a block without an id is dropped, not the report")
        let t = r.blocks[0]
        XCTAssertEqual(t.tone, "alert"); XCTAssertEqual(t.messages.count, 2); XCTAssertTrue(t.messages[0].isQuote); XCTAssertEqual(t.messages[1].replyTo, 0)
        XCTAssertEqual(t.beats.map { $0.item }, [0, 1]); XCTAssertEqual(t.links.first?.to, "impact"); XCTAssertEqual(t.links.first?.label, "blocks")
        XCTAssertEqual(t.count(of: "messages"), 2)
    }

    func testDiagramEdgesComeFromTheMermaidSource() throws {
        let r = try XCTUnwrap(Report.parse(JSONValue.parse(json)!))
        let d = r.blocks[1]
        XCTAssertEqual(d.edges.map { "\($0.from)>\($0.to)" }, ["A>B", "B>C"])
        XCTAssertEqual(d.edges.first?.label, "asks")
        XCTAssertEqual(d.nodes.map { $0.id }, ["A", "B", "C"])
        XCTAssertEqual(d.nodes.first { $0.id == "B" }?.label, "Release")
        XCTAssertEqual(d.nodes.first { $0.id == "A" }?.note, "client")
        XCTAssertEqual(d.beats.first?.focus, ["B"]); XCTAssertEqual(d.beats.first?.flow, ["A", "B"])
    }

    func testDataBlocks() throws {
        let b = try XCTUnwrap(Report.parse(JSONValue.parse(json)!)).blocks[2]
        XCTAssertEqual(b.stats.first?.value, "3"); XCTAssertEqual(b.chart?.series.first?.values.count, 2); XCTAssertNil(b.chart?.series.first?.values[1] ?? nil)
        XCTAssertEqual(b.subjects.first?.name, "Awais Khan"); XCTAssertEqual(b.subjects.first?.mediaPath, "media/a.webp")
        XCTAssertEqual(b.subjects.first?.facts.first?.value, "2021")
    }

    func testGarbageNeverCrashes() {
        XCTAssertNil(Report.parse(.object([:])))
        XCTAssertNil(Report.parse(JSONValue.parse(#"{"info":{"id":"x"},"report":"nope"}"#)!)?.blocks.first)
    }
}
