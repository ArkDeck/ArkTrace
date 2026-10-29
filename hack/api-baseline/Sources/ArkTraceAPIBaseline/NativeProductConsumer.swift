#if canImport(ArkTraceRustRuntime)
import ArkTraceAppSupport
import ArkTraceCore
import ArkTraceRustRuntime

// Compile-only external consumer: the product owns its configuration and
// publisher while startup, document creation and shutdown remain shared.
@MainActor
private func pinNativeProductSurface(configuration: TraceProductConfiguration) async throws {
    let runtime = try await TraceRustProductRuntime.createBundled(
        configuration: configuration,
        publisherCodeIdentifierPrefix: "com.example.Consumer")
    let controller = runtime.makeDocumentController()
    try await controller.closeForProductShutdown()
    try await runtime.shutdown()
}
#endif
