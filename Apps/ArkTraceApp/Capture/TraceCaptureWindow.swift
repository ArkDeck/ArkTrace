import AppKit
import ArkTraceAppSupport
import ArkTraceCapture
import ArkTraceRendering
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Capture

/// A separate utility window because capture and inspection are parallel
/// activities: the current trace stays readable while the next one records.
/// All device/process authority remains behind `ArkTraceCapture`; this view
/// owns only native controls, save/open panels and the handoff to the existing
/// document controller.
struct TraceCaptureWindow: View {
    @Bindable var capture: TraceCaptureController
    var documentController: TraceDocumentController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Form {
                connectionSection
                configurationSection
                if let issue = capture.issue {
                    issueSection(issue)
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
        .frame(minWidth: 500, minHeight: 520)
        // Closing the only control surface during a running capture would
        // strand its cancel action. Discovery is short and remains closable;
        // only the actual device operation disables the close affordance.
        .windowDismissBehavior(capture.phase.isCapturing ? .disabled : .enabled)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .task {
            guard capture.devices.isEmpty, !capture.phase.isBusy else { return }
            capture.refreshDevices()
        }
        .onChange(of: capture.phase) { _, phase in
            announce(phase)
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("HDC") {
                HStack(spacing: 10) {
                    if let url = capture.hdcExecutableURL {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(verbatim: hdcDisplayName(url))
                            Text(url.deletingLastPathComponent().path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(url.path)
                        }
                    } else {
                        Label("Not configured", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    Button("Choose…", action: chooseHDC)
                        .disabled(capture.phase.isCapturing)
                        .arktraceAccessibleTarget()
                }
            }

            LabeledContent("Device") {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Picker("Device", selection: $capture.selectedDeviceID) {
                            Text("Select a device").tag(String?.none)
                            ForEach(capture.devices) { device in
                                HStack(alignment: .center, spacing: 8) {
                                    Image(
                                        systemName: device.transport == .network
                                            ? "network" : "cable.connector"
                                    )
                                    .frame(width: 16)
                                    .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(verbatim: deviceDisplayName(device))
                                        Text(verbatim: deviceDetail(device))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(deviceAccessibilityLabel(device))
                                .tag(Optional(device.id))
                            }
                        }
                        .labelsHidden()
                        .disabled(capture.devices.isEmpty || capture.phase.isCapturing)

                        if let device = selectedDevice {
                            Text(verbatim: deviceDetail(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(deviceAccessibilityLabel(device))
                        }
                    }
                    .frame(minWidth: 370, alignment: .leading)

                    if capture.phase == .discovering {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Refreshing connected devices")
                    }
                    Button {
                        capture.refreshDevices()
                    } label: {
                        Label("Refresh devices", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .help("Refresh connected devices")
                    .accessibilityLabel("Refresh connected devices")
                    .disabled(
                        capture.hdcExecutableURL == nil || capture.phase.isBusy
                    )
                    .arktraceAccessibleTarget()
                }
            }

            if capture.phase == .ready, capture.devices.isEmpty {
                Label(
                    "No devices found. Connect a device and enable USB or network debugging, then refresh.",
                    systemImage: "externaldrive.badge.questionmark"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var configurationSection: some View {
        Section("Capture setup") {
            Picker("Profile", selection: $capture.profile) {
                ForEach(TraceCaptureProfile.allCases) { profile in
                    Text(profileTitle(profile)).tag(profile)
                }
            }
            .disabled(capture.phase.isCapturing)

            Text(profileDescription(capture.profile))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            durationControl

            Picker("Trace buffer", selection: $capture.bufferSizeMB) {
                ForEach(TraceCaptureRequest.allowedBufferSizesMB, id: \.self) { size in
                    Text("\(size) MB").tag(size)
                }
            }
            .disabled(capture.phase.isCapturing)

            Label(
                "A larger buffer reduces dropped events but uses more memory on the device.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var durationControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Duration") {
                HStack(spacing: 8) {
                    TextField(
                        "Duration value",
                        value: $capture.durationInputValue,
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 72)
                    .accessibilityLabel("Duration")

                    Picker(
                        "Duration unit",
                        selection: Binding(
                            get: { capture.durationUnit },
                            set: { capture.setDurationUnit($0) }
                        )
                    ) {
                        ForEach(TraceCaptureDurationUnit.allCases) { unit in
                            Text(durationUnitTitle(unit)).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Duration unit")
                }
            }

            LabeledContent("Quick duration") {
                HStack(spacing: 8) {
                    ForEach(capture.durationUnit.quickValues, id: \.self) { value in
                        quickDurationToggle(value)
                    }
                }
            }

            if !capture.isDurationValid {
                Label(durationValidationMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Duration: \(durationValidationMessage)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(capture.phase.isCapturing)
    }

    private func quickDurationToggle(_ value: Int) -> some View {
        Toggle(
            isOn: Binding(
                get: { capture.durationInputValue == value },
                set: { selected in
                    if selected { capture.selectQuickDuration(value) }
                }
            )
        ) {
            Text(quickDurationTitle(value))
                .monospacedDigit()
        }
        .toggleStyle(.button)
        .help(quickDurationAccessibilityLabel(value))
        .accessibilityLabel(quickDurationAccessibilityLabel(value))
        .arktraceAccessibleTarget()
    }

    private func issueSection(_ issue: TraceCaptureIssue) -> some View {
        Section {
            Label("Capture needs attention", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.red)
            Text(issue.message)
            Text(issue.recoverySuggestion)
                .foregroundStyle(.secondary)
            if let diagnostic = issue.diagnostic, !diagnostic.isEmpty {
                DisclosureGroup("Diagnostics") {
                    Text(diagnostic)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .arktraceAccessibleTarget()
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            TraceCaptureStatusView(capture: capture)
                .frame(maxWidth: .infinity, alignment: .leading)

            switch capture.phase {
            case .preparing, .recording, .transferring, .cancelling:
                Button("Cancel capture", role: .cancel) {
                    capture.cancelCapture()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(capture.phase == .cancelling)
                .arktraceAccessibleTarget()
            case .completed:
                Button("Show in Finder", action: showCompletedTrace)
                    .arktraceAccessibleTarget()
                Button("Capture again") {
                    capture.prepareForAnotherCapture()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .arktraceAccessibleTarget()
            default:
                Button("Start capture", action: chooseDestinationAndStart)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!capture.canStart)
                    .arktraceAccessibleTarget()
            }
        }
    }

    private func chooseHDC() {
        let panel = NSOpenPanel()
        panel.title = "Choose HDC"
        panel.prompt = "Choose"
        panel.message = "Choose the hdc executable in the OpenHarmony SDK toolchains folder."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let current = capture.hdcExecutableURL {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        capture.setHDCExecutable(url)
    }

    private func chooseDestinationAndStart() {
        let panel = NSSavePanel()
        panel.title = "Save Captured Trace"
        panel.prompt = "Start Capture"
        panel.message = "Choose where ArkTrace should save the trace after recording."
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // NSSavePanel appends the selected content type's preferred extension.
        // Supplying it here as well produces names such as `.htrace.htrace`.
        panel.nameFieldStringValue = defaultCaptureBaseName()
        if let type = UTType(filenameExtension: "htrace") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        capture.startCapture(to: url) { capturedURL in
            documentController.open(capturedURL)
        }
    }

    private func showCompletedTrace() {
        guard let url = capture.completedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func defaultCaptureBaseName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "ArkTrace_\(formatter.string(from: Date()))"
    }

    private func deviceDisplayName(_ device: TraceCaptureDevice) -> String {
        device.name ?? device.id
    }

    private var selectedDevice: TraceCaptureDevice? {
        guard let selectedDeviceID = capture.selectedDeviceID else { return nil }
        return capture.devices.first(where: { $0.id == selectedDeviceID })
    }

    private func deviceDetail(_ device: TraceCaptureDevice) -> String {
        var components: [String] = []
        if let systemVersion = device.systemVersion {
            components.append(systemVersion)
        }
        components.append(abbreviatedDeviceID(device.id))
        let transport = device.transport == .network ? "Network" : "USB"
        components.append(transport)
        return components.joined(separator: " · ")
    }

    private func abbreviatedDeviceID(_ id: String) -> String {
        guard id.count > 12 else { return id }
        return "\(id.prefix(4))…\(id.suffix(5))"
    }

    private func deviceAccessibilityLabel(_ device: TraceCaptureDevice) -> String {
        var components = [deviceDisplayName(device)]
        if let systemVersion = device.systemVersion {
            components.append(systemVersion)
        }
        components.append("Device \(device.id)")
        components.append(device.transport == .network ? "Network" : "USB")
        return components.joined(separator: ", ")
    }

    private func hdcDisplayName(_ url: URL) -> String {
        guard let version = capture.hdcVersion else { return url.lastPathComponent }
        return "\(url.lastPathComponent) v\(version)"
    }

    private func profileTitle(_ profile: TraceCaptureProfile) -> LocalizedStringResource {
        switch profile {
        case .appResponsiveness: "App responsiveness"
        case .cpuScheduling: "CPU scheduling"
        case .systemOverview: "System overview"
        }
    }

    private func profileDescription(
        _ profile: TraceCaptureProfile
    ) -> LocalizedStringResource {
        switch profile {
        case .appResponsiveness:
            "Scheduling, ArkUI/ACE, Binder, graphics and window events. Best for jank and slow interactions."
        case .cpuScheduling:
            "Scheduling, wakeups, CPU frequency and idle events. Best for contention and CPU investigations."
        case .systemOverview:
            "The app and CPU profiles together, plus distributed, memory and system categories. Produces the largest trace."
        }
    }

    private func durationUnitTitle(
        _ unit: TraceCaptureDurationUnit
    ) -> LocalizedStringResource {
        switch unit {
        case .seconds: "Seconds"
        case .minutes: "Minutes"
        }
    }

    private var durationValidationMessage: String {
        switch capture.durationUnit {
        case .seconds: "Enter 5 to 300 seconds."
        case .minutes: "Enter 1 to 5 minutes."
        }
    }

    private func quickDurationTitle(_ value: Int) -> LocalizedStringResource {
        switch (capture.durationUnit, value) {
        case (.seconds, 5): "5s"
        case (.seconds, 10): "10s"
        case (.seconds, 15): "15s"
        case (.seconds, 30): "30s"
        case (.minutes, 1): "1 min"
        case (.minutes, 2): "2 min"
        case (.minutes, 3): "3 min"
        default: "Custom"
        }
    }

    private func quickDurationAccessibilityLabel(
        _ value: Int
    ) -> String {
        switch (capture.durationUnit, value) {
        case (.seconds, 5): "Set duration to 5 seconds"
        case (.seconds, 10): "Set duration to 10 seconds"
        case (.seconds, 15): "Set duration to 15 seconds"
        case (.seconds, 30): "Set duration to 30 seconds"
        case (.minutes, 1): "Set duration to 1 minute"
        case (.minutes, 2): "Set duration to 2 minutes"
        case (.minutes, 3): "Set duration to 3 minutes"
        default: "Set a custom duration"
        }
    }

    private func announce(_ phase: TraceCapturePhase) {
        let message: String?
        switch phase {
        case .recording: message = "Trace capture started"
        case .transferring: message = "Trace captured, copying to this Mac"
        case .completed: message = "Trace capture complete and opened"
        case .cancelled: message = "Trace capture cancelled"
        case .failed: message = capture.issue?.message ?? "Trace capture failed"
        default: message = nil
        }
        guard let message, let application = NSApp else { return }
        unsafe NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSNumber(value: phase == .failed ? 90 : 50),
            ]
        )
    }
}
