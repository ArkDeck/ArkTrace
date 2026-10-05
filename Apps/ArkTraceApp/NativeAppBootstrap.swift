import AppKit
import ArkTraceAppSupport
import ArkTraceCore
import Observation
import SwiftUI

@MainActor
@Observable
final class NativeAppBootstrap {
    enum Phase: Equatable { case preparing, ready, stopping, failed, stopped }
    private(set) var phase = Phase.preparing
    private(set) var controller: TraceDocumentController?
    private(set) var failure: TraceAppErrorPresentation?
    private(set) var shutdownRequested = false
    @ObservationIgnored private var runtime: TraceRustProductRuntime?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, any Error>?
    @ObservationIgnored private var pendingURL: URL?

    func start() {
        guard phase == .preparing, startupTask == nil, runtime == nil, !shutdownRequested else { return }
        startupTask = Task { [self] in
            defer { startupTask = nil }
            do {
                let product = try await TraceRustProductRuntime.createBundled()
                runtime = product
                // A racing stop owns the newly created runtime and joins this
                // task before drain. It cannot be orphaned or published late.
                guard !shutdownRequested, !Task.isCancelled else { return }
                let controller = product.makeDocumentController()
                self.controller = controller
                phase = .ready
                if let pendingURL { self.pendingURL = nil; controller.open(pendingURL) }
            } catch {
                guard !shutdownRequested else { return }
                failure = Self.presentation(error, stage: .preparing)
                phase = .failed
            }
        }
    }

    func retryStartup() {
        guard phase == .failed, !shutdownRequested, runtime == nil, startupTask == nil else { return }
        failure = nil
        phase = .preparing
        start()
    }

    func open(_ url: URL) {
        guard !shutdownRequested else { return }
        if let controller, phase == .ready { controller.open(url) }
        else { pendingURL = url.standardizedFileURL; start() }
    }

    /// An App-wide barrier, separate from closing an individual document or
    /// window. Concurrent Quit requests share one task; cleanup survives the
    /// requesting task's cancellation and failures leave the owner visible.
    func stop() async throws {
        if let stopTask { return try await stopTask.value }
        if phase == .stopped { return }
        shutdownRequested = true
        phase = .stopping
        pendingURL = nil
        startupTask?.cancel()
        let starting = startupTask
        let task = Task { [self] in
            defer { stopTask = nil }
            await starting?.value
            var failureError: (any Error)?
            do { try await controller?.closeForProductShutdown() } catch { failureError = error }
            // Saving failure still requires native drain and lease release.
            do { try await runtime?.shutdown() } catch { failureError = error }
            if let error = failureError {
                failure = Self.presentation(error, stage: .openingDatabase)
                phase = .failed
                throw error
            }
            controller = nil
            runtime = nil
            failure = nil
            phase = .stopped
        }
        stopTask = task
        try await task.value
    }

    private static func presentation(_ error: any Error, stage: ArkTraceError.Stage) -> TraceAppErrorPresentation {
        TraceAppErrorPresentation(error: error as? ArkTraceError ?? ArkTraceError(
            code: .internalError, stage: stage, message: "ArkTrace could not complete the operation", retryable: true))
    }
}

@MainActor
final class ArkTraceApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var bootstrap: NativeAppBootstrap?
    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let bootstrap else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { [self] in
            defer { terminationTask = nil }
            do { try await bootstrap.stop(); sender.reply(toApplicationShouldTerminate: true) }
            catch { sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
}

struct NativeAppStartupView: View {
    let bootstrap: NativeAppBootstrap

    var body: some View {
        if let failure = bootstrap.failure {
            ContentUnavailableView {
                Label(LocalizedStringKey(bootstrap.shutdownRequested ? "app.shutdown.failure" : "app.startup.failure"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.reason)
            } actions: {
                if bootstrap.shutdownRequested {
                    Button("app.shutdown.retry") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Retry", action: bootstrap.retryStartup).keyboardShortcut(.defaultAction)
                }
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text(LocalizedStringKey(bootstrap.shutdownRequested ? "app.shutdown.progress" : "app.startup.progress"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
