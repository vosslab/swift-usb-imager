/// USBImagerApp.swift - SwiftUI @main entry point for the macOS USB imager.
///
/// This is the GUI-only product. It parses no operational command-line flags.
/// For terminal/automation use, run the `usbimager` CLI instead (list, verify,
/// flash, open); the CLI is the supported headless entry point.
///
/// Constructs a single `AppViewModel` wired to the production XPC helper and
/// presents `RootView` inside a single resizable window. Launched with no
/// input it shows a normal window on step 1.
///
/// Source handoff (no argv parsing):
///   The app receives a preselected source through a custom URL scheme handled
///   by SwiftUI `.onOpenURL` (the URL-scheme handoff). The CLI's
///   `usbimager open --source PATH [--auto-exit N]` issues:
///
///       usbimager://open?source=<percent-encoded file URL>&autoExitAfter=N
///
///   The handler decodes the percent-encoded file URL with `URLComponents`,
///   accepts only a readable `file:`-backed source (a non-file or missing/
///   unreadable source keeps the app on step 1 and logs), and calls
///   `AppViewModel.selectSource`. An optional positive `autoExitAfter` rides in
///   the same payload and schedules a clean self-termination via the normal app
///   lifecycle (`NSApplication.terminate`) - a handoff-delivered automation
///   instruction, not raw argv parsing and not an external kill.
///
///   The auto-exit timer starts only when BOTH the source is preselected and
///   the window is visible (`RootView.onAppear`), whichever happens last: the
///   URL can arrive after the window is already on screen, so a single
///   idempotent `startAutoExitIfReady()` is called from both paths and schedules
///   at most once. Absent `autoExitAfter` schedules no timer and the window
///   stays open until the user quits.
///
///   Bundle registration: the `usbimager` scheme reaches the app only through a
///   packaged `USBImagerApp.app` bundle whose Info.plist declares
///   `CFBundleURLTypes`. See `Info.plist` in this directory and the bundle
///   assembly step in `build_debug.sh`.
///
/// TODO (signing phase):
///   - Replace `helperMachServiceName` with the final SMAppService daemon name
///     once the helper's Info.plist and launchd plist are committed.
///   - Replace `helperRequirementString` with the real Apple-signed designated
///     requirement for the privileged helper (e.g.
///     `anchor apple generic and identifier "com.nsh.usbimager.helper"`).
///   - The `CodeSigningRequirement` init throws when the string is structurally
///     invalid; `fatalError` here is intentional - a bad requirement string is a
///     programmer error that must be caught before shipping.

import AppKit
import AppUI
import FlashEngine
import Foundation
import HelperProtocol
import SwiftUI

// MARK: - Constants

/// Mach service name registered by the privileged helper via SMAppService.
/// Replace with the real daemon bundle ID during the signing phase.
private let helperMachServiceName = "com.nsh.usbimager.helper"

/// Designated-requirement string used to pin the XPC peer's code-signing identity.
/// Replace with the real Apple-signed requirement during the signing phase.
private let helperRequirementString = #"identifier "com.nsh.usbimager.helper" and anchor apple generic"#

// MARK: - Handoff request decoding

/// Result of decoding a `usbimager://open?...` handoff URL.
///
/// `sourcePath` is non-nil only when the URL carries a readable `file:`-backed
/// source; otherwise the app stays on step 1. `autoExitAfterSeconds` is non-nil
/// only when the payload carries a positive numeric `autoExitAfter`.
private struct HandoffRequest {
    let sourcePath: String?
    let autoExitAfterSeconds: Double?
}

/// Decode and validate a handoff URL.
///
/// Only the `usbimager` scheme is handled. `source` is carried as a
/// percent-encoded `file:` URL string; `URLComponents` already percent-decodes
/// query values, so the decoded value is the file URL. The source is accepted
/// only when it is a `file:` URL that points at a readable file. `autoExitAfter`
/// must parse as a positive `Double` or it is ignored. Every rejection logs a
/// clear line and leaves the corresponding field nil so the window stays usable.
private func decodeHandoff(_ url: URL) -> HandoffRequest {
    // Scheme guard: only our scheme is handled.
    guard url.scheme == "usbimager" else {
        print("[USBImagerApp] handoff: ignoring non-usbimager scheme: \(url.scheme ?? "nil")")
        return HandoffRequest(sourcePath: nil, autoExitAfterSeconds: nil)
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let items = components.queryItems else {
        print("[USBImagerApp] handoff: no query items in \(url)")
        return HandoffRequest(sourcePath: nil, autoExitAfterSeconds: nil)
    }

    // source: a percent-encoded file URL; accept only a readable file: URL.
    var resolvedPath: String? = nil
    if let sourceValue = items.first(where: { $0.name == "source" })?.value {
        if let fileURL = URL(string: sourceValue), fileURL.isFileURL {
            let path = fileURL.path
            if FileManager.default.isReadableFile(atPath: path) {
                resolvedPath = path
            } else {
                print("[USBImagerApp] handoff: source missing/unreadable: \(path); staying on step 1")
            }
        } else {
            print("[USBImagerApp] handoff: source is not a file URL: \(sourceValue); staying on step 1")
        }
    }

    // autoExitAfter: ignored unless it parses as a positive number.
    var autoExit: Double? = nil
    if let raw = items.first(where: { $0.name == "autoExitAfter" })?.value {
        if let secs = Double(raw), secs > 0 {
            autoExit = secs
        } else {
            print("[USBImagerApp] handoff: ignoring non-positive autoExitAfter: \(raw)")
        }
    }
    return HandoffRequest(sourcePath: resolvedPath, autoExitAfterSeconds: autoExit)
}

// MARK: - Auto-exit coordinator

/// Owns the auto-exit gating for the GUI.
///
/// The auto-exit timer must start only when BOTH the source is preselected and
/// the window is visible, whichever completes last. The handoff URL can arrive
/// before or after `RootView.onAppear`, so both code paths feed this coordinator
/// and call the idempotent `startAutoExitIfReady()`; it schedules at most once.
/// This state lives here (not on `AppViewModel`) so the GUI's presentation
/// surface is unchanged.
@MainActor
private final class AutoExitCoordinator {
    private var sourcePreselected = false
    private var windowVisible = false
    private var pendingAutoExitSeconds: Double?
    private var scheduled = false

    /// Record that the window is on screen (called from `RootView.onAppear`).
    func markWindowVisible() {
        windowVisible = true
        startAutoExitIfReady()
    }

    /// Record that the source has been preselected (`selectSource` completed).
    func markSourcePreselected() {
        sourcePreselected = true
        startAutoExitIfReady()
    }

    /// Record the requested auto-exit interval from the handoff payload.
    /// A nil value (absent or non-positive) schedules no timer.
    func setAutoExit(seconds: Double?) {
        pendingAutoExitSeconds = seconds
        startAutoExitIfReady()
    }

    /// Schedule the clean-quit timer once, only when source + visibility hold.
    /// Idempotent: safe to call from every triggering path.
    func startAutoExitIfReady() {
        guard !scheduled else { return }
        guard let seconds = pendingAutoExitSeconds else { return }
        guard sourcePreselected, windowVisible else { return }
        scheduled = true
        print("[USBImagerApp] auto-exit: scheduling clean quit in \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            print("[USBImagerApp] auto-exit: terminating now (clean quit)")
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - App

@main
struct USBImagerApp: App {

    // MARK: State

    @State private var viewModel: AppViewModel = {
        // CodeSigningRequirement.init throws only when the string is structurally
        // malformed. fatalError is correct here - invalid requirement is a
        // programmer error that must be caught before shipping.
        let requirement: CodeSigningRequirement
        do {
            requirement = try CodeSigningRequirement(requirementString: helperRequirementString)
        } catch {
            fatalError("Invalid code-signing requirement string: \(error)")
        }
        let connection = XPCHelperConnection(
            machServiceName: helperMachServiceName,
            peerRequirement: requirement
        )
        return AppViewModel(helperConnection: connection)
    }()

    /// Auto-exit gating state, fed by both the window-visible trigger and the
    /// handoff handler so the timer starts only when both conditions hold.
    @State private var autoExit = AutoExitCoordinator()

    // MARK: Scene

    var body: some Scene {
        WindowGroup {
            RootView(vm: viewModel)
                // Window-visible trigger: RootView.onAppear proves the window is
                // on screen. Attached here, on the RootView instance, so the
                // AppUI module's RootView stays unchanged.
                .onAppear {
                    print("[USBImagerApp] window: visible (RootView.onAppear)")
                    autoExit.markWindowVisible()
                }
                // Source handoff (URL scheme). Decodes, validates,
                // preselects the source, and records any auto-exit request.
                .onOpenURL { url in
                    print("[USBImagerApp] handoff: received URL \(url)")
                    let request = decodeHandoff(url)
                    // The auto-exit request is recorded first; the timer only
                    // starts once the source is preselected and the window is
                    // visible (see AutoExitCoordinator).
                    autoExit.setAutoExit(seconds: request.autoExitAfterSeconds)
                    guard let path = request.sourcePath else { return }
                    Task {
                        await viewModel.selectSource(URL(fileURLWithPath: path))
                        // Preselect completed; the auto-exit timer can now start.
                        print("[USBImagerApp] handoff: preselected \(path), step 2")
                        autoExit.markSourcePreselected()
                    }
                }
        }
        .windowResizability(.contentMinSize)
    }
}
