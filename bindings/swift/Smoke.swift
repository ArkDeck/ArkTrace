import CArkTrace
import Foundation

@main struct Smoke {
    static func main() throws {
        GeneratedLayouts.validate()
        var identity = ArkTraceAbiIdentity()
        precondition(arktrace_abi_identity(&identity, UInt64(MemoryLayout<ArkTraceAbiIdentity>.size)) == ARKTRACE_STATUS_OK)
        precondition(identity.abi_version == ARKTRACE_ABI_VERSION)
        precondition(arktrace_abi_identity(nil, UInt64(MemoryLayout<ArkTraceAbiIdentity>.size)) == ARKTRACE_STATUS_INVALID_BUFFER)
        precondition(arktrace_abi_identity(&identity, 0) == ARKTRACE_STATUS_INVALID_BUFFER)
        precondition(arktrace_engine_drain(UInt64.max) == ARKTRACE_STATUS_INVALID_HANDLE)
        precondition(arktrace_result_release(UInt64.max) == ARKTRACE_STATUS_INVALID_HANDLE)
        let digest = withUnsafeBytes(of: identity.contract_digest) { $0.map { String(format: "%02x", $0) }.joined() }
        precondition(digest == ARKTRACE_CONTRACT_DIGEST)
        let result: [String: Any] = ["consumer": "Swift C import", "abiVersion": identity.abi_version, "capabilities": identity.capabilities, "nativeEngineAcceptance": false]
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    }
}
