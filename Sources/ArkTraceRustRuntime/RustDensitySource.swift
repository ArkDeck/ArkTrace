import ArkTraceCore
import Foundation

public enum RustDensitySource: Codable, Sendable {
    case cpu(Int64)
    case threadState(ThreadKey)
    case namedSlice(ThreadKey?)
    case cpuCounter(filterID: Int64, cpu: Int64?)
    case processCounter(filterID: Int64, processKey: ProcessKey?)
    case frame(processKey: ProcessKey?)
}
