/// USBImagerShots.swift - deterministic, non-intrusive screenshot render harness.
///
/// Renders the SwiftUI panel state to PNG files OFFSCREEN and exits. It never
/// puts a visible window on screen and never steals window focus, so it is safe
/// to run on a machine in active use. This replaces the previous approach of
/// repeatedly launching the live foreground GUI, which was rejected as
/// disruptive (see docs/active_plans/decisions/wp0_gui_source_handoff_probe.md).
///
/// What it produces:
///   - screenshots/main_window.png  - the idle main window (step 1).
///   - screenshots/step2_target.png - a preselected source advancing to step 2
///                                     (Target selection), built through the same
///                                     core seam the GUI uses (`selectSource`).
///
/// How it stays non-intrusive:
///   - `NSApplication.shared.setActivationPolicy(.prohibited)` so the process is
///     not a UI app: no window is ordered front, and focus is never taken.
///   - Rendering uses `ImageRenderer` over `RootView`, which rasterizes the view
///     tree to a `CGImage` without presenting a window.
///
/// State is real, not mocked-out UI:
///   - The view model is built with injected fake core services (a fixed-byte
///     `ImageSourceService` and a `DiskTargetService` returning a fixture USB
///     disk), so no real disk, helper, or file is needed.
///   - `selectSource` drives the same core path the GUI uses. Before rendering
///     step2_target.png the harness ASSERTS the view-model state actually
///     advanced (`flashState.currentStep == 2`, `availableTargets` and
///     `sourceImageBytes` populated). If the state did not advance it exits
///     non-zero so a blank/idle PNG is never written as the step-2 image.
///
/// `usbimager open --source <iso> --auto-exit N` is retained only as an opt-in
/// smoke test a human runs deliberately; it is NOT part of this screenshot flow.

import AppKit
import AppUI
import DiskModel
import Foundation
import SwiftUI
import USBImagerCore

// MARK: - Fixed-byte image source fake

/// An `ImageSourceService` that reports a fixed byte length for any URL.
///
/// The harness never touches the filesystem: a fixed source size is enough to
/// drive `selectSource` and the downstream safety filter. The size is chosen
/// well below the fixture disk size so the fixture USB disk passes filtering.
private struct FixedByteLengthImageSourceService: ImageSourceService {

    /// The byte length returned for every `byteLength(of:)` call.
    let length: Int

    func byteLength(of url: URL) throws -> Int {
        length
    }
}

// MARK: - Fixture disk target fake

/// File-scope wrapper naming the `DiskModel` `validTargets` free function so the
/// `DiskTargetService.validTargets` method below can forward to it without the
/// bare call self-resolving to the protocol method (infinite recursion).
private func diskModelValidTargets(
    from disks: [DiskDescriptor],
    imageSizeBytes: Int,
    sourceBackingBSDName: String?
) -> [DiskDescriptor] {
    validTargets(from: disks, imageSizeBytes: imageSizeBytes, sourceBackingBSDName: sourceBackingBSDName)
}

/// A `DiskTargetService` that returns a fixed disk list and forwards filtering to
/// the real `DiskModel` safety rules, so the rendered step-2 image reflects the
/// actual safe-target path rather than a stub list.
private struct FixtureDiskTargetService: DiskTargetService {

    /// The disks reported by `snapshotDisks()` (a single fixture USB disk).
    let disks: [DiskDescriptor]

    func snapshotDisks() async -> [DiskDescriptor] {
        disks
    }

    func validTargets(
        from disks: [DiskDescriptor],
        imageSizeBytes: Int,
        sourceBackingBSDName: String?
    ) -> [DiskDescriptor] {
        // Use the real DiskModel safety filter via the file-scope wrapper.
        diskModelValidTargets(
            from: disks,
            imageSizeBytes: imageSizeBytes,
            sourceBackingBSDName: sourceBackingBSDName
        )
    }

    func displayName(for disk: DiskDescriptor) -> String {
        let gb = Double(disk.sizeBytes) / 1_000_000_000.0
        let sizeString = String(format: "%.1f GB", gb)
        return "\(disk.bsdName)  (\(disk.busProtocol.rawValue), \(sizeString))"
    }
}

// MARK: - Non-running flash orchestration fake

/// A `FlashOrchestrationService` the screenshot harness never drives to a flash;
/// it exists only to satisfy the `AppViewModel` initializer.
private actor NoopFlashOrchestrationService: FlashOrchestrationService {

    func flash(
        source: URL,
        target: DiskDescriptor,
        advisorySHA512: String?,
        verifyReadBack: Bool,
        progress: @escaping @Sendable (FlashProgressData) -> Void
    ) async -> FlashRunResult {
        .failure(error: .cancelled)
    }

    func cancel() async {}
}

// MARK: - Fixture builders

/// Build the fixture USB disk used as a safe write target.
///
/// A removable, ejectable, external USB disk that carries no system or Time
/// Machine volume, so it passes `DiskModel.validTargets` for the small fixture
/// source. Sized at 32 GB to read as a typical flash drive in the rendered row.
private func makeFixtureUSBDisk() -> DiskDescriptor {
    DiskDescriptor(
        bsdName: "disk4",
        devicePath: "/dev/disk4",
        rawDevicePath: "/dev/rdisk4",
        sizeBytes: 32_000_000_000,
        isRemovable: true,
        isEjectable: true,
        isInternal: false,
        busProtocol: .usb,
        isWritable: true,
        isSynthesized: false,
        carriesMacOSSystem: false,
        carriesTimeMachine: false,
        mountPoints: []
    )
}

/// Build an `AppViewModel` wired to the fixture fake services.
///
/// `diskEnumerator: nil` skips the live DiskArbitration event loop; the fixture
/// `DiskTargetService` supplies the disk list deterministically instead.
@MainActor
private func makeFixtureViewModel() -> AppViewModel {
    AppViewModel(
        imageSourceService: FixedByteLengthImageSourceService(length: 4 * 1024 * 1024 * 1024),
        diskTargetService: FixtureDiskTargetService(disks: [makeFixtureUSBDisk()]),
        checksumService: DefaultChecksumService(),
        flashService: NoopFlashOrchestrationService(),
        diskEnumerator: nil
    )
}

// MARK: - Offscreen rendering

/// Render `view` to a PNG at `path` using `ImageRenderer` (offscreen, no window).
///
/// `ImageRenderer` rasterizes the SwiftUI view tree to a `CGImage` without
/// presenting it. The view is given an explicit frame so the rendered canvas has
/// a deterministic size regardless of any window the app would otherwise lay it
/// out in. Returns the number of bytes written so the caller can confirm a
/// non-empty file.
///
/// - Throws: a `ScreenshotError` when the view cannot be rasterized or the PNG
///   cannot be encoded/written.
@MainActor
private func renderPNG(_ view: some View, to path: String, width: CGFloat, height: CGFloat) throws {
    // Pin the canvas size so the offscreen raster is deterministic, and switch the
    // panels into documentation-render mode. `.glassEffect`/`GlassEffectContainer`
    // (Liquid Glass) does NOT rasterize through ImageRenderer without a live
    // window's backing, so without this flag the PNGs show tinted cards with blank
    // text/icons. With it on, panels draw as solid opaque cards (same step tint and
    // highlighting) so headers, SF Symbol icons, and labels rasterize offscreen.
    // These are documentation renders, NOT exact Liquid Glass captures; the
    // interactive app keeps its unchanged Liquid Glass appearance (flag default
    // false).
    let sized = view
        .frame(width: width, height: height)
        .environment(\.documentationRender, true)
    let renderer = ImageRenderer(content: sized)
    // Render at 2x for a crisp screenshot on Retina-class display assets.
    renderer.scale = 2.0

    guard let cgImage = renderer.cgImage else {
        throw ScreenshotError.renderFailed(path: path)
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw ScreenshotError.encodeFailed(path: path)
    }
    let url = URL(fileURLWithPath: path)
    do {
        try pngData.write(to: url)
    } catch {
        throw ScreenshotError.writeFailed(path: path, underlying: error)
    }
}

/// Errors the render harness can fail with. Each maps to a clear stderr line and
/// a non-zero exit so a blank or missing PNG never passes silently.
private enum ScreenshotError: Error, CustomStringConvertible {
    case renderFailed(path: String)
    case encodeFailed(path: String)
    case writeFailed(path: String, underlying: Error)
    case stateDidNotAdvance(step: Int, targetCount: Int, sourceBytes: Int)

    var description: String {
        switch self {
        case .renderFailed(let path):
            return "ImageRenderer produced no CGImage for \(path) (cannot render offscreen on this system)."
        case .encodeFailed(let path):
            return "Could not PNG-encode the rendered image for \(path)."
        case .writeFailed(let path, let underlying):
            return "Could not write PNG to \(path): \(underlying)."
        case .stateDidNotAdvance(let step, let targetCount, let sourceBytes):
            return "Step-2 guard failed: view model did not advance to step 2 "
                + "(currentStep=\(step), availableTargets=\(targetCount), sourceImageBytes=\(sourceBytes)). "
                + "Refusing to write a blank step2_target.png."
        }
    }
}

// MARK: - Harness entry point

@main
struct USBImagerShots {

    /// Render both screenshots offscreen and exit. Exits non-zero (with a clear
    /// stderr line) on any render/encode/write failure or if the step-2 state
    /// guard does not hold.
    @MainActor
    static func main() async {
        // Make this a non-UI process: prohibit window activation so nothing is
        // ordered front and focus is never taken. This is the key to staying
        // non-intrusive on a machine in active use.
        NSApplication.shared.setActivationPolicy(.prohibited)

        // Resolve the output directory relative to the repo root (the harness is
        // run from the repo root by capture_screenshot.sh / `swift run`).
        let screenshotsDir = "screenshots"
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            atPath: screenshotsDir,
            withIntermediateDirectories: true
        )

        // The rendered canvas size: four panels side by side plus padding. This
        // matches the GUI's intended four-panel layout at a comfortable size.
        let canvasWidth: CGFloat = 1280
        let canvasHeight: CGFloat = 720

        do {
            // --- Idle main window (step 1) ---
            let idleVM = makeFixtureViewModel()
            // Sanity: a freshly built view model is on step 1 (idle).
            print("[USBImagerShots] idle state: currentStep=\(idleVM.flashState.currentStep)")
            try renderPNG(
                RootView(vm: idleVM),
                to: "\(screenshotsDir)/main_window.png",
                width: canvasWidth,
                height: canvasHeight
            )

            // --- Preselected source advancing to step 2 (Target) ---
            let step2VM = makeFixtureViewModel()
            // Drive the SAME core seam the GUI uses; the URL is never read because
            // the fixed-byte source service ignores it.
            await step2VM.selectSource(URL(fileURLWithPath: "/fixture/debian.iso"))

            // Step-2 guard: assert the state actually advanced before rendering so
            // a blank/idle image is never written as the step-2 screenshot.
            let step = step2VM.flashState.currentStep
            let targetCount = step2VM.availableTargets.count
            let sourceBytes = step2VM.sourceImageBytes
            print("[USBImagerShots] step2 state: currentStep=\(step), "
                + "availableTargets=\(targetCount), sourceImageBytes=\(sourceBytes)")
            guard step == 2, targetCount > 0, sourceBytes > 0 else {
                throw ScreenshotError.stateDidNotAdvance(
                    step: step,
                    targetCount: targetCount,
                    sourceBytes: sourceBytes
                )
            }

            try renderPNG(
                RootView(vm: step2VM),
                to: "\(screenshotsDir)/step2_target.png",
                width: canvasWidth,
                height: canvasHeight
            )
        } catch {
            FileHandle.standardError.write(Data("[USBImagerShots] error: \(error)\n".utf8))
            exit(1)
        }

        print("[USBImagerShots] wrote screenshots/main_window.png and screenshots/step2_target.png")
        exit(0)
    }
}
