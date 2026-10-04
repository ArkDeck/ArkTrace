import ArkTraceCore
import ArkTraceStore
import Foundation

@main struct DensityOriginalOracle {
    static func main() async throws {
        let args = CommandLine.arguments
        let output = try await Task.detached {
            let decoder = JSONDecoder()
            let metadata = try decoder.decode(TraceMetadata.self, from: Data(args[2].utf8))
            let requests = try decoder.decode([DensityProofRequest].self, from: Data(args[3].utf8))
            let repository = try SQLiteTraceRepository(databaseURL: URL(filePath: args[1]), parser: metadata.parser,
                source: TraceSourceDescriptor(traceSHA256: metadata.traceSHA256, sourceByteCount: metadata.sourceByteCount))
            var values: [DensityProofValue] = []
            for request in requests {
                let query = try TraceDensityQuery(range: request.range, source: request.source, bucketCount: request.bucketCount,
                    deadline: ContinuousClock.now.advanced(by: .seconds(30)))
                let result = try await repository.density(query)
                values.append(try await densityProofValue(result, id: request.id, sortMachineQuality: true))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(values)
        }.value
        try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
    }
}
