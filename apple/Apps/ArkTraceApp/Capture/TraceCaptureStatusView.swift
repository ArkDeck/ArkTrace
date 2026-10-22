import ArkTraceCapture
import SwiftUI

/// Observation boundary for the recording clock and progress. A tick only
/// rebuilds this status view, leaving the device and configuration form alone.
struct TraceCaptureStatusView: View {
    var capture: TraceCaptureController

    var body: some View {
        switch capture.phase {
        case .discovering:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for devices…")
            }
        case .preparing:
            captureProgress("Preparing the device…", value: nil)
        case .recording:
            captureProgress(
                "Recording — \(capture.elapsedSeconds) of \(capture.durationSeconds) seconds",
                value: capture.progressFraction
            )
        case .transferring:
            captureProgress("Copying the trace to this Mac…", value: nil)
        case .cancelling:
            captureProgress("Stopping the capture…", value: nil)
        case .completed:
            VStack(alignment: .leading, spacing: 3) {
                Label("Capture complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let url = capture.completedURL {
                    Text("Opened \(url.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .cancelled:
            Label("Capture cancelled", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Label("Fix the issue above, then try again.", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        case .idle, .ready:
            Label(
                "The trace stays on this Mac and opens automatically.",
                systemImage: "lock"
            )
            .foregroundStyle(.secondary)
        }
    }

    private func captureProgress(_ label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).monospacedDigit()
            if let value {
                ProgressView(value: value)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: 270, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
