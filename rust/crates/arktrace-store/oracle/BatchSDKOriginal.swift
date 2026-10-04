import ArkTraceCore
import ArkTraceStore
import Foundation

@main struct BatchOriginalOracle {
    static func main() async throws {
        let args = CommandLine.arguments
        let output = try await Task.detached {
            let decoder = JSONDecoder()
            let context = try decoder.decode(BatchProofContext.self, from: Data(args[2].utf8))
            let requests = try decoder.decode([BatchProofRequest].self, from: Data(args[3].utf8))
            let repository = try SQLiteTraceRepository(databaseURL: URL(filePath: args[1]), parser: context.metadata.parser,
                source: TraceSourceDescriptor(traceSHA256: context.metadata.traceSHA256, sourceByteCount: context.metadata.sourceByteCount),
                expectedPreparation: context.preparation)
            var values: [BatchProofValue] = []
            for request in requests {
                let result = try await repository.eventBatch(request.coreQuery())
                values.append(try await batchProofValue(result, id: request.id, sortMachineQuality: true))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(values)
        }.value
        try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
    }
}
