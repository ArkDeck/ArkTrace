import ArkTraceCore
import Foundation

private struct BatchWireArray<Page: Decodable & Sendable>: Decodable {
    let pages: [Page]
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        guard let family = decoder.codingPath.last?.stringValue else { throw RustAdmission.invalidBuffer }
        let expected = try context.pageCount(for: family)
        var container = try decoder.unkeyedContainer()
        guard container.count == expected else { throw RustAdmission.invalidBuffer }
        let reservation = try context.reserveArray(Page.self, count: expected)
        var pages: [Page] = []; pages.reserveCapacity(expected)
        guard pages.capacity * MemoryLayout<Page>.stride <= reservation else { throw RustAdmission.outputLimit }
        while !container.isAtEnd {
            try Task.checkCancellation()
            guard pages.count < expected else { throw RustAdmission.invalidBuffer }
            pages.append(try container.decode(Page.self))
        }
        guard pages.count == expected else { throw RustAdmission.invalidBuffer }
        self.pages = pages
    }
}

private struct BatchWireResult: Decodable {
    let cpuSlices: [EventWirePage<RustPackedCPU>]
    let threadStates: [EventWirePage<RustPackedState>]
    let slices: [EventWirePage<RustPackedSlice>]
    let counters: [EventWirePage<RustPackedCounter>]
    let counterSeries: [EventWirePage<RustPackedDescriptor>]
    let densities: [DensityWireResult]
    let threads: [DirectoryWirePage<RustPackedThread>]
    private enum CodingKeys: String, CodingKey { case cpuSlices, threadStates, slices, counters, counterSeries, densities, threads }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["cpuSlices", "threadStates", "slices", "counters", "counterSeries", "densities", "threads"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cpuSlices = try values.decode(BatchWireArray<EventWirePage<RustPackedCPU>>.self, forKey: .cpuSlices).pages
        threadStates = try values.decode(BatchWireArray<EventWirePage<RustPackedState>>.self, forKey: .threadStates).pages
        slices = try values.decode(BatchWireArray<EventWirePage<RustPackedSlice>>.self, forKey: .slices).pages
        counters = try values.decode(BatchWireArray<EventWirePage<RustPackedCounter>>.self, forKey: .counters).pages
        counterSeries = try values.decode(BatchWireArray<EventWirePage<RustPackedDescriptor>>.self, forKey: .counterSeries).pages
        densities = try values.decode(BatchWireArray<DensityWireResult>.self, forKey: .densities).pages
        threads = try values.decode(BatchWireArray<DirectoryWirePage<RustPackedThread>>.self, forKey: .threads).pages
    }
}

enum RustBatchDecoder {
    private static func limits(_ query: RustBatchQuery) throws -> [String: [Int]] {
        let limits = ["cpuSlices": query.cpuSlices.map(\.limit), "threadStates": query.threadStates.map(\.limit),
            "slices": query.slices.map(\.limit), "counters": query.counters.map(\.limit),
            "counterSeries": query.counterSeries.map(\.limit), "densities": query.densities.map(\.bucketCount), "threads": query.threads.map(\.limit)]
        let count = limits.values.reduce(0) { $0 + $1.count }
        guard (1...32).contains(count), limits.values.allSatisfy({ $0.allSatisfy({ (1...100_000).contains($0) }) }),
              query.densities.allSatisfy({ (1...40_000).contains($0.bucketCount) }) else { throw RustAdmission.invalidBuffer }
        return limits
    }
    private static func eventBytes<T: RustEventColdRecord>(_ pages: [EventWirePage<T>]) throws -> Int {
        var bytes = 0
        for page in pages {
            bytes += page.items.capacity * MemoryLayout<T>.stride + page.quality.capacity * MemoryLayout<RustPackedQuality>.stride
            for item in page.items { try Task.checkCancellation(); bytes += item.additionalRetainedBytes }
        }
        return bytes
    }
    private static func pageArrayBound<T>(_ type: T.Type, count: Int) -> Int { count * MemoryLayout<T>.stride * 2 + 128 }

    private static func eventPages<Packed: RustEventColdRecord, Record: Sendable>(_ pages: [EventWirePage<Packed>], text: RustTextStorage,
        identity: RustSessionIdentity, record: @escaping @Sendable (RustEventLease<Packed>, Int) -> Record) throws -> [RustEventPage<Record>] {
        var output: [RustEventPage<Record>] = []; output.reserveCapacity(pages.count)
        guard output.capacity * MemoryLayout<RustEventPage<Record>>.stride <= pageArrayBound(RustEventPage<Record>.self, count: pages.count) else {
            throw RustAdmission.outputLimit
        }
        for page in pages {
            try Task.checkCancellation()
            output.append(RustEventPage(RustEventLease(records: page.items, quality: page.quality, text: text,
                truncated: page.truncated, capabilityAvailable: page.capabilityAvailable, identity: identity), record: record))
        }
        return output
    }

    @concurrent static func decode(_ data: Data, identity: RustSessionIdentity, request: UInt64, query: RustBatchQuery,
        storage: RustRetainedStorage = .shared, staging: RustRetainedStorage = rustColdStaging) async throws -> RustBatchResult {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard identity.engine != 0, identity.session != 0, request != 0 else { throw RustAdmission.invalidBuffer }
        let pageLimits = try limits(query), count = pageLimits.values.reduce(0) { $0 + $1.count }
        let context = try RustColdContext(limit: 32, session: identity.session, request: request, inputBytes: data.count,
            staging: staging, pageLimits: pageLimits)
        try RustJSONShape.validate(data, staging: staging, integerNumbersOnly: true, floatingField: .batchDensityUtilization)
        let decoder = JSONDecoder(); decoder.userInfo[rustColdContextKey] = context
        let decoded: RustColdEnvelope<BatchWireResult>
        do { decoded = try decoder.decode(RustColdEnvelope<BatchWireResult>.self, from: data) }
        catch is DecodingError { throw RustAdmission.invalidBuffer }
        for (index, page) in decoded.body.slices.enumerated() where !query.slices[index].includesArgumentSet {
            guard page.items.allSatisfy({ $0.argSetID == nil }) else { throw RustAdmission.invalidBuffer }
        }
        let bytes = context.bytes
        var retained = bytes.capacity + 512 + count * RustEventDecoder.ownerOverhead
        retained += try eventBytes(decoded.body.cpuSlices) + eventBytes(decoded.body.threadStates) + eventBytes(decoded.body.slices)
            + eventBytes(decoded.body.counters) + eventBytes(decoded.body.counterSeries)
        for page in decoded.body.densities {
            retained += page.buckets.capacity * MemoryLayout<RustPackedDensityBucket>.stride + page.quality.capacity * MemoryLayout<RustPackedQuality>.stride
        }
        for page in decoded.body.threads {
            retained += page.items.capacity * MemoryLayout<RustPackedThread>.stride + page.quality.capacity * MemoryLayout<RustPackedQuality>.stride
        }
        let parentArrayCredit = pageArrayBound(RustCPUSlicePage.self, count: decoded.body.cpuSlices.count)
            + pageArrayBound(RustThreadStatePage.self, count: decoded.body.threadStates.count)
            + pageArrayBound(RustSlicePage.self, count: decoded.body.slices.count)
            + pageArrayBound(RustCounterPage.self, count: decoded.body.counters.count)
            + pageArrayBound(RustCounterSeriesPage.self, count: decoded.body.counterSeries.count)
            + pageArrayBound(RustDensityResult.self, count: decoded.body.densities.count)
            + pageArrayBound(RustThreadPage.self, count: decoded.body.threads.count)
        let parentStaging = try staging.reserve(parentArrayCredit)
        defer { withExtendedLifetime(parentStaging) {} }
        try Task.checkCancellation()
        let credit = try storage.reserve(retained + parentArrayCredit)
        let text = RustTextStorage(bytes: bytes, credit: credit)
        let cpu = try eventPages(decoded.body.cpuSlices, text: text, identity: identity) { RustCPUSliceRecord(lease: $0, index: $1) }
        let states = try eventPages(decoded.body.threadStates, text: text, identity: identity) { RustThreadStateRecord(lease: $0, index: $1) }
        let slices = try eventPages(decoded.body.slices, text: text, identity: identity) { RustSliceRecord(lease: $0, index: $1) }
        let counters = try eventPages(decoded.body.counters, text: text, identity: identity) { RustCounterRecord(lease: $0, index: $1) }
        let series = try eventPages(decoded.body.counterSeries, text: text, identity: identity) { RustCounterSeriesRecord(lease: $0, index: $1) }
        var densities: [RustDensityResult] = []; densities.reserveCapacity(decoded.body.densities.count)
        guard densities.capacity * MemoryLayout<RustDensityResult>.stride <= pageArrayBound(RustDensityResult.self, count: decoded.body.densities.count) else { throw RustAdmission.outputLimit }
        for page in decoded.body.densities {
            try Task.checkCancellation()
            densities.append(RustDensityResult(RustEventLease(records: page.buckets, quality: page.quality, text: text,
                truncated: false, capabilityAvailable: page.capabilityAvailable, identity: identity)))
        }
        var threads: [RustThreadPage] = []; threads.reserveCapacity(decoded.body.threads.count)
        guard threads.capacity * MemoryLayout<RustThreadPage>.stride <= pageArrayBound(RustThreadPage.self, count: decoded.body.threads.count) else { throw RustAdmission.outputLimit }
        for page in decoded.body.threads {
            try Task.checkCancellation()
            threads.append(RustThreadPage(RustDirectoryLease(records: page.items, quality: page.quality, text: text, truncated: page.truncated, identity: identity)))
        }
        try Task.checkCancellation()
        return RustBatchResult(cpuSlices: cpu, threadStates: states, slices: slices, counters: counters, counterSeries: series,
            densities: densities, threads: threads, identity: identity, text: text)
    }
}
