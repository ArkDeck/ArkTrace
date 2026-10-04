import ArkTraceCore
import ArkTraceStore
import Foundation

@main struct DeadlineOriginalOracle {
    static func main() async throws {
        let args = CommandLine.arguments
        let output = try await Task.detached {
            let decoder = JSONDecoder()
            let context = try decoder.decode(BatchProofContext.self, from: Data(args[2].utf8))
            let requests = try decoder.decode([DeadlineProofRequest].self, from: Data(args[3].utf8))
            let repository = try SQLiteTraceRepository(databaseURL: URL(filePath: args[1]), parser: context.metadata.parser,
                source: TraceSourceDescriptor(traceSHA256: context.metadata.traceSHA256, sourceByteCount: context.metadata.sourceByteCount),
                expectedPreparation: context.preparation)
            var values: [DeadlineProofValue] = []
            for request in requests {
                do {
                    let result = try await repository.eventBatch(request.coreQuery())
                    values.append(try await DeadlineProofValue(id: request.plan.id, value: batchProofValue(result, id: request.plan.id, sortMachineQuality: true)))
                } catch let error as ArkTraceError {
                    values.append(DeadlineProofValue(id: request.plan.id, error: error))
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(values)
        }.value
        try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
    }
}
