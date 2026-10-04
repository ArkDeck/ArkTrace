import ArkTraceCore
import ArkTraceStore
import Foundation

@main struct RepositoryOriginalOracle {
    static func main() async throws {
        let args = CommandLine.arguments
        let output = try await Task.detached {
            let decoder = JSONDecoder()
            let context = try decoder.decode(BatchProofContext.self, from: Data(args[2].utf8))
            let requests = try decoder.decode([RepositoryProofRequest].self, from: Data(args[3].utf8))
            let repository = try SQLiteTraceRepository(databaseURL: URL(filePath: args[1]), parser: context.metadata.parser,
                source: TraceSourceDescriptor(traceSHA256: context.metadata.traceSHA256, sourceByteCount: context.metadata.sourceByteCount,
                    sourceFormat: context.metadata.sourceFormat), expectedPreparation: context.preparation)
            var values: [RepositoryProofValue] = []
            for request in requests { values.append(try await repositoryProofValue(repository, request: request, sortMachineQuality: true)) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(values)
        }.value
        try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
    }
}
