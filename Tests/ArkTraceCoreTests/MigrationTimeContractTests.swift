import ArkTraceCore
import Foundation
import XCTest

final class MigrationTimeContractTests: XCTestCase {
    private struct Corpus: Decodable {
        let version: Int
        let vectors: [Vector]
    }

    private struct Vector: Decodable {
        let id: String
        let event: [Int64]
        let query: [Int64]
        let eventValid: Bool
        let queryValid: Bool
        let intersects: Bool?
        let overlapNs: Int64?
    }

    func testSharedRustMigrationTimeVectorsAgainstSwiftOracle() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let corpus = try JSONDecoder().decode(
            Corpus.self,
            from: Data(contentsOf: root.appending(path: "contracts/time-range-vectors.json"))
        )
        XCTAssertEqual(corpus.version, 1)
        XCTAssertFalse(corpus.vectors.isEmpty)
        for vector in corpus.vectors {
            let event = try? TraceTimeRange(startNs: vector.event[0], endNs: vector.event[1])
            let query = try? TraceTimeRange.query(startNs: vector.query[0], endNs: vector.query[1])
            XCTAssertEqual(event != nil, vector.eventValid, vector.id)
            XCTAssertEqual(query != nil, vector.queryValid, vector.id)
            if let event, let query {
                XCTAssertEqual(event.intersects(query: query), vector.intersects, vector.id)
                XCTAssertEqual(event.clippedOverlapNs(with: query), vector.overlapNs, vector.id)
                let encoded = try JSONEncoder().encode(event)
                XCTAssertEqual(try JSONDecoder().decode(TraceTimeRange.self, from: encoded), event)
            }
        }
    }
}
