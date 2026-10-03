// Appended to a cache copy of TraceAgentBatchTests.swift by run_swift_oracle.py.
// Calls the actual engine and its existing synthetic typed repository seam.
extension TraceAgentBatchTests {
    private struct ParallelVector: Decodable {
        let name: String
        let request: ParallelRequest
        let durationNs: Int64
        let cpuAvailable: Bool
        let stateAvailable: Bool
        let namedAvailable: Bool
        let cpuRows: [CpuSlice]
        let stateRows: [ThreadStateInterval]
        let namedRows: [ParallelNamed]
    }
    private struct ParallelNamed: Decodable { let key: EventKey; let range: TraceTimeRange }
    private struct ParallelRequest: Decodable {
        let range: TraceTimeRange
        let maximumCPUSlices: Int
        let maximumProcessSlices: Int
        let maximumThreadSlices: Int
        let maximumStateIntervals: Int
        let maximumSchedulingEvents: Int
        let maximumHotEvents: Int
        let topProcessLimit: Int
        let topThreadLimit: Int
        let schedulingSampleLimit: Int
        let hotIntervalLimit: Int
        let hotBucketCount: Int
        let minimumLongSliceDurationNs: Int64
        let maximumOutputRows: Int
    }
    func testParallelAnalysisOracle() async throws {
        let inputPath = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_ANALYSIS_ORACLE_INPUT"])
        let outputPath = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_ANALYSIS_ORACLE_OUTPUT"])
        let vectors = try JSONDecoder().decode([ParallelVector].self, from: Data(contentsOf: URL(fileURLWithPath: inputPath)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var results: [[String: Any]] = []
        for vector in vectors {
            let r = vector.request
            let named = vector.namedRows.map {
                TraceSlice(key: $0.key, range: $0.range, threadKey: nil, processKey: nil,
                    pid: nil, tid: nil, processName: nil, threadName: nil, name: "oracle",
                    category: nil, depth: 0, parentEventKey: nil, isAsync: false, isOpenEnded: false)
            }
            let repository = Repository(durationNs: vector.durationNs,
                capabilities: TraceCapabilities(cpuScheduling: vector.cpuAvailable, threadStates: vector.stateAvailable,
                    namedSlices: vector.namedAvailable, cpuCounters: false, processCounters: false),
                cpuSlices: vector.cpuRows, states: vector.stateRows, slices: named)
            let request = try TraceDeterministicAnalysisRequest(range: r.range,
                maximumCPUSlices: r.maximumCPUSlices, maximumProcessSlices: r.maximumProcessSlices,
                maximumThreadSlices: r.maximumThreadSlices, maximumStateIntervals: r.maximumStateIntervals,
                maximumNamedSlices: r.maximumHotEvents, maximumSchedulingEvents: r.maximumSchedulingEvents,
                maximumHotEvents: r.maximumHotEvents, topProcessLimit: r.topProcessLimit, topThreadLimit: r.topThreadLimit,
                // Reserve no global output row for the out-of-scope long slice
                // section: project that section to [] before applying the
                // actual Swift retainingRows method below.
                longSliceLimit: 1, schedulingSampleLimit: r.schedulingSampleLimit,
                hotIntervalLimit: r.hotIntervalLimit, hotBucketCount: r.hotBucketCount,
                minimumLongSliceDurationNs: r.minimumLongSliceDurationNs)
            let full = try await TraceDeterministicAnalysisEngine(repository: repository).analyze(request)
            let projected = TraceDeterministicAnalysis(kind: full.kind, parameters: full.parameters, range: full.range,
                cpuUtilization: full.cpuUtilization, topProcesses: full.topProcesses, topThreads: full.topThreads,
                longSlices: [], threadStateDistribution: full.threadStateDistribution, schedulingLatency: full.schedulingLatency,
                hotIntervals: full.hotIntervals, sections: TraceDeterministicAnalysisSections(cpuUtilization: full.sections.cpuUtilization,
                    topProcesses: full.sections.topProcesses, topThreads: full.sections.topThreads,
                    longSlices: .init(returnedCount: 0, matchedCount: 0, truncated: false),
                    threadStateDistribution: full.sections.threadStateDistribution, schedulingLatency: full.sections.schedulingLatency,
                    hotIntervals: full.sections.hotIntervals), dataQuality: full.dataQuality)
            let value = try projected.retainingRows(maximumRows: r.maximumOutputRows)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
            results.append(["name": vector.name, "result": object])
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        XCTAssertEqual(results.count, vectors.count)
    }
}
