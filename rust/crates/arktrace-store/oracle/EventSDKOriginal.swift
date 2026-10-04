import ArkTraceCore
import ArkTraceStore
import Foundation

// Runs the original repository implementation on the same Ready database.
// No query behavior is reimplemented in this harness.
@main struct EventOriginalOracle {
    static func main() async throws {
        let args = CommandLine.arguments
        let output = try await Task.detached {
            let decoder = JSONDecoder()
            let metadata = try decoder.decode(TraceMetadata.self, from: Data(args[2].utf8))
            let requests = try decoder.decode([EventProofRequest].self, from: Data(args[3].utf8))
            let repository = try SQLiteTraceRepository(databaseURL: URL(filePath: args[1]), parser: metadata.parser,
                source: TraceSourceDescriptor(traceSHA256: metadata.traceSHA256, sourceByteCount: metadata.sourceByteCount))
            var values: [EventProofValue] = []
            for request in requests {
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                switch request.kind {
            case .cpuSlices:
                let page = try await repository.cpuSlices(CpuSliceQuery(range: request.range, limit: request.limit, deadline: deadline))
                values.append(try await eventProofValue(page, id: request.id, sortMachineQuality: true))
            case .threadStates:
                let page = try await repository.threadStates(ThreadStateQuery(range: request.range, limit: request.limit, deadline: deadline))
                values.append(try await eventProofValue(page, id: request.id, sortMachineQuality: true))
            case .slices:
                let page = try await repository.slices(TraceSliceQuery(range: request.range, includesArgumentSet: request.includesArgumentSet, limit: request.limit, deadline: deadline))
                values.append(try await eventProofValue(page, id: request.id, handles: page.items.map(\.argSetID), sortMachineQuality: true))
            case .frames:
                let page = try await repository.frames(TraceFrameQuery(range: request.range, limit: request.limit, deadline: deadline))
                values.append(try await eventProofValue(page, id: request.id, sortMachineQuality: true))
            case .counterSeries:
                let page = try await repository.counterSeries(CounterSeriesQuery(range: request.range, limit: request.limit, deadline: deadline))
                values.append(try await eventProofValue(page, id: request.id, sortMachineQuality: true))
            case .counters:
                let page = try await repository.counters(CounterQuery(range: request.range, limit: request.limit, deadline: deadline))
                values.append(try await eventProofValue(page, id: request.id, sortMachineQuality: true))
            case .arguments:
                let page = try await repository.arguments(TraceArgumentQuery(argSetID: request.argSetID!, limit: request.limit, deadline: deadline))
                values.append(try await eventProofValue(page, id: request.id, sortMachineQuality: true))
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(values)
        }.value
        try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
    }
}
