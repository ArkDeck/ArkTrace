#if canImport(ArkTraceRustRuntime)
import ArkTraceCore
import ArkTraceRustRuntime
import Foundation
import XCTest
@testable import ArkTraceAppSupport

@MainActor
final class NativeProductProfileTests: XCTestCase {
    private func profile() throws -> TraceProductConfiguration {
        let root = URL(filePath: "/private/tmp/arktrace-profile-validation")
        return try TraceProductConfiguration(bundleURL: root.appending(path: "tools"),
            cacheDirectory: root.appending(path: "traces"), stagingDirectory: root.appending(path: "staging"),
            recentDocumentsKey: "ArkTraceNativeProfileTests", signpostSubsystem: "dev.arktrace.profile.tests",
            bundledParser: TraceBundledParserLocation(executableRelativePath: "parser", manifestRelativePath: "manifest.json"))
    }
    private func runtime(_ product: TraceProductConfiguration, namespace: URL? = nil,
                         parser: URL? = nil, storage: RustStoragePolicy? = nil) -> RustConfiguration {
        RustConfiguration(namespace: namespace ?? product.stagingDirectory,
            helper: product.bundleURL.appending(path: "helper"),
            parser: parser ?? product.bundledParser.executableURL(in: product.bundleURL),
            helperSHA256: String(repeating: "a", count: 64),
            parserIdentity: TraceParserIdentity(name: "parser", reportedVersion: "1", binarySHA256: String(repeating: "b", count: 64),
                upstreamRepository: "https://example.invalid", upstreamRevision: String(repeating: "c", count: 40),
                architecture: "arm64", adapterVersion: "1", buildRecipeVersion: "1"),
            publisher: RustPublisher(teamIdentifier: "TESTTEAM", helperCodeIdentifier: "test.helper", parserCodeIdentifier: "test.parser"),
            storagePolicy: storage ?? .contentAddressed(cacheDirectory: product.cacheDirectory))
    }
    private func reject(_ product: TraceProductConfiguration, _ native: RustConfiguration,
                        open: UInt32 = 60_000, query: UInt32 = 30_000) async {
        do {
            _ = try await TraceRustProductRuntime.create(configuration: product, runtimeConfiguration: native,
                openTimeoutMilliseconds: open, queryTimeoutMilliseconds: query)
            XCTFail("mismatched fixed product profile admitted")
        } catch {
            XCTAssertEqual((error as? ArkTraceError)?.code, .invalidArgument)
            XCTAssertEqual((error as? ArkTraceError)?.stage, .preparing)
        }
    }
    func testRootsPolicyAndBundledParserCannotDriftBetweenDocumentsAndMaintenance() async throws {
        let product = try profile()
        await reject(product, runtime(product, namespace: product.stagingDirectory.appending(path: "other")))
        await reject(product, runtime(product, parser: product.bundleURL.appending(path: "other")))
        await reject(product, runtime(product, storage: .ephemeral))
        await reject(product, runtime(product, storage: .contentAddressed(cacheDirectory: product.cacheDirectory.appending(path: "other"))))
    }
    func testInvalidFixedBudgetsAreRejectedBeforeAnyEngineOrToolIO() async throws {
        let product = try profile(), native = runtime(try profile())
        await reject(product, native, open: 0)
        await reject(product, native, open: 300_001)
        await reject(product, native, query: 0)
        await reject(product, native, query: 300_001)
    }
}
#endif
