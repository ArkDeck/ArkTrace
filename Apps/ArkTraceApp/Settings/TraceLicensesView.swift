import AppKit
import ArkTraceCore
import ArkTraceRendering
import SwiftUI

struct TraceLicensesView: View {
    /// Loaded lazily off the main actor when the tab first appears. Reading
    /// the bundled license text used to happen in property initializers,
    /// which ran as soon as the Settings `TabView` materialized its tabs.
    @State private var productLicense: String?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Source Licenses")
                .font(.title2.weight(.semibold))
            Text("ArkTrace includes a pinned TraceStreamer build and its reviewed source closure.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("ArkTrace — MIT License").font(.headline)
                    Text(productLicense ?? "Loading license…")
                    Divider()
                    Text("Third-Party Notices").font(.headline)
                    Text(notice ?? "Loading notices…")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .font(.body.monospaced())
            }
            .accessibilityLabel(Text(.arkTraceAndThirdPartyLicenseNotices))
            HStack {
                Button("Show License Files in Finder") {
                    guard let url = Bundle.main.resourceURL?
                        .appending(path: "Licenses", directoryHint: .isDirectory)
                    else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .arktraceAccessibleTarget()
                Spacer()
                Text("14 reviewed components")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task {
            guard productLicense == nil else { return }
            async let license = Self.loadTextResource(
                named: "LICENSE", extension: nil, maximumBytes: 32 * 1_024
            )
            async let notices = Self.loadTextResource(
                named: "THIRD_PARTY_NOTICES", extension: "md", maximumBytes: 128 * 1_024
            )
            productLicense = await license
            notice = await notices
        }
    }

    private nonisolated static func loadTextResource(
        named name: String,
        extension fileExtension: String?,
        maximumBytes: Int
    ) async -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension),
            let data = try? ArkTraceBoundedRegularFile.read(
                at: url, maximumByteCount: maximumBytes
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            return "License resources are unavailable in this build."
        }
        return text
    }
}
