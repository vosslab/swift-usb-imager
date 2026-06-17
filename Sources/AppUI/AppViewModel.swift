/// AppViewModel.swift - @Observable @MainActor state machine wiring the four
/// USB-imager panels: source -> target -> flash -> verify.
///
/// All business logic lives here so SwiftUI views stay purely declarative.
/// Dependencies (FlashEngine factory, KeychainStore, DiskEnumerator) are
/// injected through the initializer so the view layer and unit tests can
/// supply fakes without touching production types.

import DiskModel
import FlashEngine
import Foundation
import HelperProtocol
import KeychainStore
import Observation
import Verifier

// MARK: - AppViewModel

/// Four-panel state machine for the USB imager.
///
/// `@Observable` makes every stored property a potential publish point; the
/// SwiftUI views access properties directly and update automatically.
///
/// `@MainActor` ensures all state mutations happen on the main thread.
/// Actor-isolated methods that need to await off-main work hop off and back.
@MainActor
@Observable
public final class AppViewModel {

    // MARK: - Public observable state

    /// Current phase of the flash session.
    public private(set) var flashState: FlashState = .idle

    /// The disk image the user selected (set by `selectSource(_:)`).
    public private(set) var sourceURL: URL?

    /// Byte length of the selected image file (stat'd at selection time).
    /// Used as the denominator for safety-size filtering and progress math.
    public private(set) var sourceImageBytes: Int = 0

    /// Disks that pass DiskSafety filtering against the current source.
    /// Refreshed automatically when the source changes or a DiskEvent fires.
    public private(set) var availableTargets: [DiskDescriptor] = []

    /// All currently attached whole disks (before safety filtering).
    public private(set) var allDisks: [DiskDescriptor] = []

    /// The disk the user chose as the write target.
    public private(set) var selectedTarget: DiskDescriptor?

    /// Official expected checksum supplied by the user (pasted hex or file).
    public private(set) var officialChecksumSource: OfficialChecksumSource?

    /// Parsed expected digest derived from `officialChecksumSource`.
    /// `nil` when no checksum is set or when the input was invalid.
    public private(set) var expectedDigest: SHA512Digest?

    /// Validation error from the most recent `setOfficialChecksum` call.
    public private(set) var checksumInputError: String?

    // MARK: - Private dependencies

    /// Factory that creates a fresh `FlashEngine` for each flash session.
    /// Injected so tests can supply a fake engine.
    private let makeEngine: @Sendable () -> FlashEngine

    /// Keychain-backed trusted-checksum cache.
    private let keychainStore: KeychainStore

    /// Live disk enumerator. Optional because `DiskEnumerator.init?()` can
    /// fail in sandboxed environments.
    private let diskEnumerator: DiskEnumerator?

    /// The engine driving the current flash job. Retained for cancellation.
    private var activeEngine: FlashEngine?

    /// Task driving the disk-event subscription loop.
    /// @ObservationIgnored + nonisolated(unsafe) lets deinit cancel the task
    /// without a MainActor hop. Writes to this property happen only from
    /// MainActor-isolated methods, so the unsafe annotation is sound.
    @ObservationIgnored
    nonisolated(unsafe) private var diskEventTask: Task<Void, Never>?

    /// Phase start timestamp, reset on each `FlashProgress.phase` transition.
    private var phaseStartDate: Date = Date()

    /// The phase seen in the most recent progress event (to detect phase transitions).
    private var lastSeenPhase: FlashPhase?

    // MARK: - Convenience production initializer

    /// Create the view model wired to real production dependencies.
    ///
    /// A fresh `FlashEngine` is created for each flash session by the factory
    /// closure; this keeps `FlashEngine` non-reusable as designed.
    ///
    /// - Parameters:
    ///   - helperConnection: XPC connection to the privileged helper.
    ///   - keychainStore: trusted-checksum cache (defaults to real Keychain).
    ///   - diskEnumerator: live disk enumerator (defaults to real DiskArbitration session).
    public convenience init(
        helperConnection: some HelperConnection,
        keychainStore: KeychainStore = KeychainStore(),
        diskEnumerator: DiskEnumerator? = DiskEnumerator()
    ) {
        // The factory captures the connection; each call produces a fresh engine.
        let factory: @Sendable () -> FlashEngine = {
            FlashEngine(connection: helperConnection)
        }
        self.init(
            makeEngine: factory,
            keychainStore: keychainStore,
            diskEnumerator: diskEnumerator
        )
    }

    // MARK: - Full dependency-injection initializer

    /// Full DI initializer used by tests and the production `convenience init`.
    ///
    /// - Parameters:
    ///   - makeEngine: closure that produces a fresh `FlashEngine` per job.
    ///   - keychainStore: trusted-checksum cache.
    ///   - diskEnumerator: live disk enumerator; pass `nil` to skip live events.
    public init(
        makeEngine: @escaping @Sendable () -> FlashEngine,
        keychainStore: KeychainStore = KeychainStore(),
        diskEnumerator: DiskEnumerator? = DiskEnumerator()
    ) {
        self.makeEngine = makeEngine
        self.keychainStore = keychainStore
        self.diskEnumerator = diskEnumerator

        // Kick off the initial snapshot + live event loop.
        // We schedule this as a Task so we don't call async code from init.
        Task { [weak self] in
            await self?.startDiskEventLoop()
        }
    }

    deinit {
        diskEventTask?.cancel()
    }

    // MARK: - Public API: source selection

    /// Set the source image URL.
    ///
    /// Stats the file to get the byte length (used for target filtering and
    /// as the advisory denominator). Resets target selection and available
    /// targets, then refreshes the target list.
    ///
    /// - Parameter url: the file URL chosen by the user.
    public func selectSource(_ url: URL) async {
        let byteLength = Self.statFileBytes(at: url)
        sourceURL = url
        sourceImageBytes = byteLength
        selectedTarget = nil
        flashState = .sourceSelected(url: url)
        // Refresh targets now that we have the correct source size.
        await refreshTargets()
    }

    // MARK: - Public API: target management

    /// Re-query the enumerator and re-apply DiskSafety filtering.
    ///
    /// Called automatically when the source changes or a DiskEvent fires.
    /// The SwiftUI views can also call this to force a refresh.
    public func refreshTargets() async {
        guard let enumerator = diskEnumerator else { return }
        let disks = await enumerator.snapshot()
        updateTargetList(from: disks)
    }

    /// Choose the write target.
    ///
    /// - Parameter disk: must be present in `availableTargets`; the call is
    ///   silently ignored when the disk is not in the safe list.
    public func selectTarget(_ disk: DiskDescriptor) {
        guard availableTargets.contains(disk) else { return }
        selectedTarget = disk
        guard let url = sourceURL else { return }
        let info = TargetInfo(
            disk: disk,
            displayName: Self.displayName(for: disk)
        )
        flashState = .targetSelected(sourceURL: url, target: info)
    }

    // MARK: - Public API: checksum input

    /// Supply an official expected checksum for the source image.
    ///
    /// Accepts either a pasted 128-hex-char string or a SHA512SUMS file body.
    /// Sets `expectedDigest` on success or `checksumInputError` on failure.
    ///
    /// - Parameter source: how the checksum was provided.
    public func setOfficialChecksum(_ source: OfficialChecksumSource) {
        checksumInputError = nil
        officialChecksumSource = source
        switch source {
        case .pastedHex(let hex):
            // Validate and store the pasted hex string.
            do {
                let digest = try validatePastedHex(hex)
                expectedDigest = digest
            } catch {
                expectedDigest = nil
                checksumInputError = "Invalid checksum: must be exactly 128 hex characters."
            }
        case .sha512SumsFile(let body):
            // Parse the file; match against the current source filename.
            do {
                let checksumFile = try ChecksumFile(sha512SumsBody: body)
                let filename = sourceURL?.lastPathComponent ?? ""
                let digest = try checksumFile.expectedDigest(for: filename)
                expectedDigest = digest
            } catch ChecksumFileError.filenameNotFound(let name) {
                expectedDigest = nil
                checksumInputError = "No entry for \"\(name)\" in the checksum file."
            } catch {
                expectedDigest = nil
                checksumInputError = "Could not parse checksum file: \(error.localizedDescription)"
            }
        }
    }

    /// Supply an official expected checksum by reading a SHA512SUMS file at `url`.
    ///
    /// Reads the file body here (in the view model) so a read failure surfaces as
    /// a user-facing `checksumInputError` instead of being silently turned into an
    /// empty body by the view layer. On a successful read this delegates to
    /// `setOfficialChecksum(.sha512SumsFile(body:))`, reusing the existing parse and
    /// filename-match logic. Reading a small text file synchronously on the main
    /// actor is fine here.
    ///
    /// - Parameter url: file URL of the SHA512SUMS file the user picked.
    public func setOfficialChecksumFile(at url: URL) {
        let body: String
        do {
            body = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Read failure: report it and leave the expected digest unset.
            officialChecksumSource = .sha512SumsFile(body: "")
            expectedDigest = nil
            checksumInputError = "Could not read the checksum file."
            return
        }
        // Read succeeded; reuse the existing parse/match path.
        setOfficialChecksum(.sha512SumsFile(body: body))
    }

    /// Clear any previously set official checksum.
    public func clearOfficialChecksum() {
        officialChecksumSource = nil
        expectedDigest = nil
        checksumInputError = nil
    }

    // MARK: - Public API: flash lifecycle

    /// Advance from `.targetSelected` to `.confirming`.
    ///
    /// The view shows a confirmation sheet; the user taps a second time to
    /// actually start (`startFlash()`).
    public func requestConfirmation() {
        guard case .targetSelected(let url, let target) = flashState else { return }
        flashState = .confirming(sourceURL: url, target: target)
    }

    /// Begin the flash operation.
    ///
    /// Only callable from `.confirming`. Drives the `FlashEngine`, consuming
    /// its `progressStream`, updating `flashState` on each event, and
    /// performing checksum + Keychain matching on completion.
    public func startFlash() async {
        guard case .confirming(let sourceURL, _) = flashState else { return }
        guard let disk = selectedTarget else { return }

        let engine = makeEngine()
        activeEngine = engine

        // Pass the advisory SHA-512 to the helper for early UI sanity checks.
        // The helper re-hashes what it writes; this is not a safety gate.
        let advisoryHex = expectedDigest?.hexString

        // Advance to flashing state with an empty initial snapshot.
        phaseStartDate = Date()
        lastSeenPhase = nil
        flashState = .flashing(snapshot: FlashProgressSnapshot.make(
            from: FlashProgress(
                jobID: JobID.generate(),
                bytesDone: 0,
                totalBytes: UInt64(max(0, sourceImageBytes)),
                phase: .writing
            ),
            phaseStart: phaseStartDate
        ))

        // Subscribe to progress on a background task so the actor does not block.
        let progressTask = Task { [weak self, weak engine] in
            guard let engine else { return }
            for await progress in await engine.progressStream {
                self?.handleProgress(progress)
            }
        }

        do {
            let result = try await engine.flash(
                source: sourceURL,
                target: disk,
                advisorySHA512: advisoryHex
            )
            progressTask.cancel()
            await handleFlashResult(result)
        } catch let engineError as FlashEngineError {
            progressTask.cancel()
            handleFlashError(engineError)
        } catch {
            progressTask.cancel()
            flashState = .failed(message: "Unexpected error: \(error.localizedDescription)")
        }

        activeEngine = nil
    }

    /// Cancel the active flash job.
    ///
    /// Best-effort; the authoritative outcome still arrives via the engine's
    /// result. Marks state `.cancelled` only after the engine confirms cancellation.
    public func cancel() async {
        guard let engine = activeEngine else { return }
        await engine.cancel()
        // State transitions to .cancelled via the error path in startFlash().
    }

    /// Reset the view model to `.idle` so the user can start a new session.
    public func reset() {
        activeEngine = nil
        sourceURL = nil
        sourceImageBytes = 0
        selectedTarget = nil
        officialChecksumSource = nil
        expectedDigest = nil
        checksumInputError = nil
        flashState = .idle
        // Re-apply target filtering against empty source.
        Task { await refreshTargets() }
    }

    // MARK: - Private: progress handling

    /// Apply one progress event: update `flashState` with a fresh snapshot.
    private func handleProgress(_ progress: FlashProgress) {
        // Detect phase transitions and reset the speed clock.
        if progress.phase != lastSeenPhase {
            phaseStartDate = Date()
            lastSeenPhase = progress.phase
        }
        let snapshot = FlashProgressSnapshot.make(
            from: progress,
            phaseStart: phaseStartDate
        )
        switch progress.phase {
        case .unmounting, .writing:
            flashState = .flashing(snapshot: snapshot)
        case .verifying, .done:
            flashState = .verifying(snapshot: snapshot)
        }
    }

    // MARK: - Private: result handling

    /// Translate a successful `FlashResult` into the appropriate terminal state.
    private func handleFlashResult(_ result: FlashResult) async {
        switch result.outcome {
        case .cancelled:
            flashState = .cancelled
            return
        case .failed:
            let message = result.errorMessage ?? "The flash operation failed."
            flashState = .failed(message: message)
            return
        case .success:
            break
        }

        guard let deviceSHA512 = result.deviceSHA512 else {
            flashState = .succeeded(
                deviceSHA512: "",
                matchOutcome: .noOfficialChecksum
            )
            return
        }

        let matchOutcome = await resolveMatchOutcome(deviceSHA512: deviceSHA512)

        // If the user supplied a checksum and it matches, offer to cache it.
        if matchOutcome == .officialMatch {
            await offerToSaveToKeychain(deviceSHA512: deviceSHA512)
        }

        flashState = .succeeded(
            deviceSHA512: deviceSHA512,
            matchOutcome: matchOutcome
        )
    }

    /// Translate a `FlashEngineError` into the appropriate terminal state.
    private func handleFlashError(_ error: FlashEngineError) {
        switch error {
        case .cancelled:
            flashState = .cancelled
        case .connectionFailed(let detail):
            flashState = .failed(message: "Helper connection failed: \(detail)")
        case .decodeFailed(let detail):
            flashState = .failed(message: "Communication error (decode): \(detail)")
        case .encodeFailed(let detail):
            flashState = .failed(message: "Communication error (encode): \(detail)")
        case .helperReportedFailure(let message):
            let display = message ?? "The privileged helper reported a failure."
            flashState = .failed(message: display)
        case .jobIDMismatch(let expected, let received):
            flashState = .failed(
                message: "Internal protocol error: job ID mismatch (expected \(expected), got \(received))."
            )
        }
    }

    // MARK: - Private: checksum resolution

    /// Compare `deviceSHA512` against the official expected digest and the
    /// Keychain trusted-checksum cache.
    ///
    /// Priority order:
    ///   1. If an official checksum was supplied, compare to that.
    ///   2. Otherwise, look up in the Keychain cache.
    ///   3. If neither is available, return `.noOfficialChecksum`.
    private func resolveMatchOutcome(deviceSHA512: String) async -> ChecksumMatchOutcome {
        // Compare against the official expected digest if one was set.
        if let expected = expectedDigest {
            if let actualDigest = SHA512Digest(hexString: deviceSHA512) {
                if expected == actualDigest {
                    return .officialMatch
                } else {
                    return .officialMismatch
                }
            }
        }

        // No official checksum; check the Keychain trusted-checksum cache.
        if let actualDigest = SHA512Digest(hexString: deviceSHA512) {
            do {
                let hit = try keychainStore.lookup(
                    sha512: actualDigest,
                    imageByteLength: sourceImageBytes
                )
                if hit != nil {
                    return .trustedCacheHit
                }
            } catch {
                // Keychain failure: treat as cache miss, not a fatal error.
            }
        }

        return .noOfficialChecksum
    }

    /// Attempt to save a confirmed checksum to the Keychain trusted-checksum cache.
    ///
    /// Silently swallows duplicate-item errors (already cached is fine).
    /// Other Keychain errors are also swallowed here because a cache write
    /// failure is not a reason to mark the flash as failed.
    private func offerToSaveToKeychain(deviceSHA512: String) async {
        guard let digest = SHA512Digest(hexString: deviceSHA512) else { return }
        guard sourceImageBytes > 0 else { return }
        let filename = sourceURL?.lastPathComponent ?? "unknown"
        let entry = TrustedChecksum(
            sha512: digest,
            imageByteLength: sourceImageBytes,
            originalFilename: filename,
            sourceLabel: nil
        )
        do {
            try keychainStore.save(entry)
        } catch KeychainError.duplicateItem {
            // Already cached; no action needed.
        } catch {
            // Non-fatal: log in a real app; silently ignore here.
        }
    }

    // MARK: - Private: disk event loop

    /// Start the long-running task that consumes `DiskEnumerator.events()`.
    ///
    /// Called once from `init` via a detached `Task`. The task runs until
    /// the view model is deallocated (cancelled by `deinit`).
    private func startDiskEventLoop() async {
        // Snapshot the initial disk list synchronously on the first call.
        await refreshTargets()

        guard let enumerator = diskEnumerator else { return }

        diskEventTask = Task { [weak self] in
            let stream = await enumerator.events()
            for await event in stream {
                guard let self else { break }
                self.handleDiskEvent(event)
            }
        }
    }

    /// Apply a `DiskEvent` to the raw disk list and re-filter safe targets.
    private func handleDiskEvent(_ event: DiskEvent) {
        switch event {
        case .appeared(let descriptor):
            // Insert only if not already present.
            if !allDisks.contains(descriptor) {
                allDisks.append(descriptor)
                allDisks.sort { $0.bsdName < $1.bsdName }
            } else {
                // Update in place (descriptor may have changed if re-appeared).
                allDisks = allDisks.map { $0.bsdName == descriptor.bsdName ? descriptor : $0 }
            }
        case .disappeared(let bsdName):
            allDisks.removeAll { $0.bsdName == bsdName }
            // Clear the selected target if it just disappeared.
            if selectedTarget?.bsdName == bsdName {
                selectedTarget = nil
                if let url = sourceURL {
                    flashState = .sourceSelected(url: url)
                } else {
                    flashState = .idle
                }
            }
        }
        updateTargetList(from: allDisks)
    }

    /// Re-apply DiskSafety filtering to `disks` and update `availableTargets`.
    private func updateTargetList(from disks: [DiskDescriptor]) {
        allDisks = disks
        // The source backing BSD name is nil when the source is a regular file.
        // If the source URL lives directly on a disk device we would set this.
        // For MVP: source images are always files, so sourceBackingBSDName is nil.
        let sourceBackingBSDName: String? = nil
        let safe = validTargets(
            from: disks,
            imageSizeBytes: sourceImageBytes,
            sourceBackingBSDName: sourceBackingBSDName
        )
        availableTargets = safe
    }

    // MARK: - Private: helpers

    /// Stat the file at `url` and return its byte length, or 0 on failure.
    private static func statFileBytes(at url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        return size
    }

    /// Build a human-readable display name for a disk.
    ///
    /// Format: "<mediaName or busProtocol> <size> (<bsdName>)"
    /// Example: "USB 32.0 GB (disk4)"
    private static func displayName(for disk: DiskDescriptor) -> String {
        let sizeStr = formatBytes(disk.sizeBytes)
        let busLabel = disk.busProtocol.rawValue.uppercased()
        return "\(busLabel) \(sizeStr) (\(disk.bsdName))"
    }
}
