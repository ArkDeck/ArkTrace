import ArkTraceCore
import Foundation
import XCTest

@testable import ArkTraceRuntime

final class MigrationCacheContractTests: XCTestCase {
    private struct Corpus: Decodable {
        let version: Int
        let vectors: [Vector]
    }
    private struct Vector: Decodable {
        struct Input: Decodable {
            let traceSHA256: String
            let parserBinarySHA256: String
            let upstreamRevision: String
            let schemaAdapterVersion: String
            let indexSchemaVersion: Int
        }
        let id: String
        let input: Input
        let valid: Bool
        let parserKey: String?
        let entryIdentifier: String?
        let lockRelativePath: String?
        let leaseRelativePath: String?
    }

    func testSharedRustMigrationCacheIdentityAndLeaseVectorsAgainstSwiftOracle() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf:
            root.appending(path: "contracts/cache-lease-vectors.json")))
        XCTAssertEqual(corpus.version, 1)
        XCTAssertFalse(corpus.vectors.isEmpty)
        for vector in corpus.vectors {
            let input = vector.input
            let key = try? TraceCacheKey(traceSHA256: input.traceSHA256,
                parserBinarySHA256: input.parserBinarySHA256, upstreamRevision: input.upstreamRevision,
                schemaAdapterVersion: input.schemaAdapterVersion, indexSchemaVersion: input.indexSchemaVersion)
            XCTAssertEqual(key != nil, vector.valid, vector.id)
            if let key {
                XCTAssertEqual(key.parserKey, vector.parserKey, vector.id)
                XCTAssertEqual(key.entryLockIdentifier, vector.entryIdentifier, vector.id)
                XCTAssertEqual(".locks/\(key.entryLockIdentifier).lock", vector.lockRelativePath, vector.id)
                XCTAssertEqual(".leases/\(key.entryLockIdentifier).lease", vector.leaseRelativePath, vector.id)
            }
        }
    }
}
