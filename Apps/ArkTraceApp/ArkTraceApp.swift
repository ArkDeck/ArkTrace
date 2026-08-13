import ArkTraceAppSupport
import ArkTraceCore
import ArkTraceRendering
import SwiftUI

@main
struct ArkTraceNativeApp: App {
    @State private var parserStatus = "Checking bundled TraceStreamer…"

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text(ArkTraceProduct.name)
                    .font(.title2.weight(.semibold))
                Text("Native trace viewer")
                    .foregroundStyle(.secondary)
                Divider()
                Text(parserStatus)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            .frame(minWidth: 640, minHeight: 360, alignment: .topLeading)
            .padding(24)
            .task { await verifyBundledParser() }
        }
        .defaultSize(width: 960, height: 640)
    }

    @MainActor
    private func verifyBundledParser() async {
        do {
            let parser = try ArkTraceBundledParserResolver().resolve()
            let identity = try await parser.identity()
            parserStatus = "TraceStreamer \(identity.reportedVersion) · \(identity.binarySHA256.prefix(12))"
        } catch let error as ArkTraceError {
            parserStatus = "\(error.code.rawValue): \(error.message)"
        } catch {
            parserStatus = "INTERNAL_ERROR: bundled parser verification failed"
        }
    }
}
