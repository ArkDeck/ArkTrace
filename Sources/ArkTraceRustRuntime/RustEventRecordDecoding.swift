import ArkTraceCore
import Foundation

extension RustPackedCPU: RustEventColdRecord {
    static var isQuality: Bool { false }
    var additionalRetainedBytes: Int { 0 }
    private enum CodingKeys: String, CodingKey { case key, range, cpu, threadKey, processKey, tid, pid, threadName, processName, endState, priority, isOpenEnded }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["key", "range", "cpu", "threadKey", "processKey", "tid", "pid", "threadName", "processName", "endState", "priority", "isOpenEnded"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(RustWireEventKey.self, forKey: .key).value
        range = try values.decode(RustWireRange.self, forKey: .range).value
        cpu = try values.decode(Int64.self, forKey: .cpu)
        threadKey = try values.decodeIfPresent(RustWireThreadKey.self, forKey: .threadKey)?.value
        processKey = try values.decodeIfPresent(RustWireProcessKey.self, forKey: .processKey)?.value
        tid = try values.decodeIfPresent(Int64.self, forKey: .tid)
        pid = try values.decodeIfPresent(Int64.self, forKey: .pid)
        threadName = try context.text(values.decodeIfPresent(String.self, forKey: .threadName), maximum: 4096, allowEmpty: true)
        processName = try context.text(values.decodeIfPresent(String.self, forKey: .processName), maximum: 4096, allowEmpty: true)
        endState = try context.text(values.decodeIfPresent(String.self, forKey: .endState), maximum: 256, allowEmpty: true)
        priority = try values.decodeIfPresent(Int64.self, forKey: .priority)
        isOpenEnded = try values.decode(Bool.self, forKey: .isOpenEnded)
        guard key.table == .schedSlice else { throw RustAdmission.invalidBuffer }
    }
}

extension RustPackedState: RustEventColdRecord {
    static var isQuality: Bool { false }
    var additionalRetainedBytes: Int { 0 }
    private enum CodingKeys: String, CodingKey { case key, range, threadKey, processKey, state, normalizedState, cpu, tid, pid, processName, threadName, isOpenEnded }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["key", "range", "threadKey", "processKey", "state", "normalizedState", "cpu", "tid", "pid", "processName", "threadName", "isOpenEnded"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(RustWireEventKey.self, forKey: .key).value
        range = try values.decode(RustWireRange.self, forKey: .range).value
        threadKey = try values.decode(RustWireThreadKey.self, forKey: .threadKey).value
        processKey = try values.decodeIfPresent(RustWireProcessKey.self, forKey: .processKey)?.value
        state = try context.text(values.decode(String.self, forKey: .state), maximum: 256, allowEmpty: true)!
        normalizedState = try values.decodeIfPresent(TraceThreadState.self, forKey: .normalizedState)
        cpu = try values.decodeIfPresent(Int64.self, forKey: .cpu)
        tid = try values.decodeIfPresent(Int64.self, forKey: .tid)
        pid = try values.decodeIfPresent(Int64.self, forKey: .pid)
        processName = try context.text(values.decodeIfPresent(String.self, forKey: .processName), maximum: 4096, allowEmpty: true)
        threadName = try context.text(values.decodeIfPresent(String.self, forKey: .threadName), maximum: 4096, allowEmpty: true)
        isOpenEnded = try values.decode(Bool.self, forKey: .isOpenEnded)
        guard key.table == .threadState else { throw RustAdmission.invalidBuffer }
    }
}

extension RustPackedSlice: RustEventColdRecord {
    static var isQuality: Bool { false }
    var additionalRetainedBytes: Int { 0 }
    private enum CodingKeys: String, CodingKey { case key, range, threadKey, processKey, pid, tid, processName, threadName, name, category, depth, parentEventKey, isAsync, isOpenEnded, argSetID }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["key", "range", "threadKey", "processKey", "pid", "tid", "processName", "threadName", "name", "category", "depth", "parentEventKey", "isAsync", "isOpenEnded", "argSetID"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(RustWireEventKey.self, forKey: .key).value
        range = try values.decode(RustWireRange.self, forKey: .range).value
        threadKey = try values.decodeIfPresent(RustWireThreadKey.self, forKey: .threadKey)?.value
        processKey = try values.decodeIfPresent(RustWireProcessKey.self, forKey: .processKey)?.value
        pid = try values.decodeIfPresent(Int64.self, forKey: .pid)
        tid = try values.decodeIfPresent(Int64.self, forKey: .tid)
        processName = try context.text(values.decodeIfPresent(String.self, forKey: .processName), maximum: 4096, allowEmpty: true)
        threadName = try context.text(values.decodeIfPresent(String.self, forKey: .threadName), maximum: 4096, allowEmpty: true)
        name = try context.text(values.decode(String.self, forKey: .name), maximum: 4096, allowEmpty: true)!
        category = try context.text(values.decodeIfPresent(String.self, forKey: .category), maximum: 1024, allowEmpty: true)
        depth = try values.decodeIfPresent(Int64.self, forKey: .depth)
        parentEventKey = try values.decodeIfPresent(RustWireEventKey.self, forKey: .parentEventKey)?.value
        isAsync = try values.decode(Bool.self, forKey: .isAsync)
        isOpenEnded = try values.decode(Bool.self, forKey: .isOpenEnded)
        argSetID = try values.decodeIfPresent(Int64.self, forKey: .argSetID)
        guard key.table == .callstack else { throw RustAdmission.invalidBuffer }
        guard parentEventKey.map({ $0.table == .callstack }) ?? true else { throw RustAdmission.invalidBuffer }
    }
}

extension RustPackedFrame: RustEventColdRecord {
    static var isQuality: Bool { false }
    var additionalRetainedBytes: Int { 0 }
    private enum CodingKeys: String, CodingKey { case key, range, kind, vsync, processKey, threadKey, pid, processName, flag, isOpenEnded }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["key", "range", "kind", "vsync", "isOpenEnded"], optional: ["processKey", "threadKey", "pid", "processName", "flag"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(RustWireEventKey.self, forKey: .key).value
        range = try values.decode(RustWireRange.self, forKey: .range).value
        kind = try values.decode(RustFrameKind.self, forKey: .kind)
        vsync = try values.decode(Int64.self, forKey: .vsync)
        processKey = try values.decodeIfPresent(RustWireProcessKey.self, forKey: .processKey)?.value
        threadKey = try values.decodeIfPresent(RustWireThreadKey.self, forKey: .threadKey)?.value
        pid = try values.decodeIfPresent(Int64.self, forKey: .pid)
        processName = try context.text(values.decodeIfPresent(String.self, forKey: .processName), maximum: 4096, allowEmpty: true)
        flag = try values.decodeIfPresent(Int64.self, forKey: .flag)
        isOpenEnded = try values.decode(Bool.self, forKey: .isOpenEnded)
        guard key.table == .frameSlice else { throw RustAdmission.invalidBuffer }
    }
}

extension RustPackedArgument: RustEventColdRecord {
    static var isQuality: Bool { false }
    var additionalRetainedBytes: Int { 0 }
    private enum CodingKeys: String, CodingKey { case key, value, typeName }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["key", "value"], optional: ["typeName"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try context.text(values.decode(String.self, forKey: .key), maximum: context.maximumTextBytes, allowEmpty: true)!
        value = try context.text(values.decode(String.self, forKey: .value), maximum: context.maximumTextBytes, allowEmpty: true)!
        typeName = try context.text(values.decodeIfPresent(String.self, forKey: .typeName), maximum: context.maximumTextBytes, allowEmpty: true)
        guard !key.isEmpty else { throw RustAdmission.invalidBuffer }
    }
}

extension RustPackedDescriptor: RustEventColdRecord {
    static var isQuality: Bool { false }
    var additionalRetainedBytes: Int { 0 }
    private enum CodingKeys: String, CodingKey { case filterID, name, scope, cpu, processKey, pid, processName, unit }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["filterID", "name", "scope"], optional: ["cpu", "processKey", "pid", "processName", "unit"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        filterID = try values.decode(Int64.self, forKey: .filterID)
        name = try context.text(values.decode(String.self, forKey: .name), maximum: 256, allowEmpty: true)!
        scope = try values.decode(RustCounterScope.self, forKey: .scope)
        cpu = try values.decodeIfPresent(Int64.self, forKey: .cpu)
        processKey = try values.decodeIfPresent(RustWireProcessKey.self, forKey: .processKey)?.value
        pid = try values.decodeIfPresent(Int64.self, forKey: .pid)
        processName = try context.text(values.decodeIfPresent(String.self, forKey: .processName), maximum: 4096, allowEmpty: true)
        unit = try context.text(values.decodeIfPresent(String.self, forKey: .unit), maximum: 256, allowEmpty: true)
    }
}

extension RustPackedCounter: RustEventColdRecord {
    static var isQuality: Bool { false }
    var additionalRetainedBytes: Int { samples.capacity * MemoryLayout<RustPackedCounterSample>.stride }
    private enum CodingKeys: String, CodingKey { case filterID, name, scope, cpu, processKey, pid, processName, unit, samples }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["filterID", "name", "scope", "cpu", "processKey", "pid", "processName", "unit", "samples"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        filterID = try values.decode(Int64.self, forKey: .filterID)
        name = try context.text(values.decode(String.self, forKey: .name), maximum: 256, allowEmpty: true)!
        scope = try values.decode(RustCounterScope.self, forKey: .scope)
        cpu = try values.decodeIfPresent(Int64.self, forKey: .cpu)
        processKey = try values.decodeIfPresent(RustWireProcessKey.self, forKey: .processKey)?.value
        pid = try values.decodeIfPresent(Int64.self, forKey: .pid)
        processName = try context.text(values.decodeIfPresent(String.self, forKey: .processName), maximum: 4096, allowEmpty: true)
        unit = try context.text(values.decodeIfPresent(String.self, forKey: .unit), maximum: 256, allowEmpty: true)
        samples = try values.decode(RustColdArray<RustPackedCounterSample>.self, forKey: .samples).values
        guard !samples.isEmpty, samples.allSatisfy({ scope == .process || $0.key.table == .measure }) else { throw RustAdmission.invalidBuffer }
    }
}
