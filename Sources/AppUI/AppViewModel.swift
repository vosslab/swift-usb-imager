/// AppViewModel.swift - @Observable @MainActor presentation adapter wiring the
/// four USB-imager panels: source -> target -> flash -> verify.
///
/// The GUI-independent workflow (source stat, target filtering, checksum
/// parse/match/cache, flash orchestration) lives once in `USBImagerCore`. This
/// view model is a thin presentation layer: it calls the core services and maps
/// their results onto `FlashState`/`FlashProgressSnapshot` for the SwiftUI views,
/// owns the disk-event-to-UI binding, and enforces the user-gesture guards. No
/// workflow logic is duplicated here.
///
/// Dependencies are injected through the initializers so the view layer and unit
/// tests can supply fakes. The convenience initializers wire the real `Default*`
/// core services; the full DI initializer accepts the service protocols directly
/// so tests can override any single service with a fake.

import DiskModel
import FlashEngine
import Foundation
import HelperProtocol
import KeychainStore
import Observation
import USBImagerCore
import Verifier

// MARK: - AppViewModel

/// Four-panel presentation adapter for the USB imager.
///
/// `@Observable` makes every stored property a potential publish point; the
/// SwiftUI views access properties directly and update automatically.
///
/// `@MainActor` ensures all state mutations happen on the main thread.
/// Core services that hop to other actors are awaited; results are applied back
/// on the main actor.
@MainActor
@Observable
public final class AppViewModel {

    // MARK: - Public observable state

    /// Current phase of the flash session.
    public private(set) var flashState: FlashState = .idle

    /// The disk image the user selected (set by `selectSource(_:)`).
    public private(set) var sourceURL: URL?

    /// Byte length of the selected image file (stat'd at selection time via core).
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

    /// The most recent typed workflow error surfaced by a source or checksum
    /// operation, or `nil` when the last such operation succeeded.
    ///
    /// This is the observable error surface the audit asked for: a source-stat
    /// failure (`selectSource`) or a Keychain trusted-cache access failure (the
    /// post-flash `matchOutcome` probe) sets a typed `CoreError` here instead of
    /// being swallowed. It is set on failure and cleared on a successful source
    /// selection, a successful flash result, and `reset`, so a stale error never
    /// outlives a later success. The error is the shared core taxonomy
    /// (`CoreError`); later UI work (the inline error panel) renders it via the
    /// core `userMessage(for:)` mapping rather than inventing its own copy.
    public private(set) var currentError: CoreError?

    // MARK: - Private dependencies (USBImagerCore services)

    /// Stats the source image file (byte length). Wraps `FileManager` in core.
    private let imageSourceService: ImageSourceService

    /// Filters disks to safe targets and formats display names. Wraps `DiskModel`
    /// in core. Optional because the live snapshot needs an enumerator; the pure
    /// filtering/display helpers still work when this is the default service.
    private let diskTargetService: DiskTargetService

    /// Parse/validate checksums, match outcomes, and read/write the Keychain
    /// trusted cache. Wraps `Verifier`/`KeychainStore` in core.
    private let checksumService: ChecksumService

    /// Drives a flash session and emits numeric progress. Wraps `FlashEngine`
    /// in core. An actor; `flash`/`cancel` are awaited off the main actor.
    private let flashService: FlashOrchestrationService

    /// Live disk enumerator. Optional because `DiskEnumerator.init?()` can fail
    /// in sandboxed environments. Retained only for the disk-event-to-UI binding;
    /// the snapshot/filter pipeline runs through `diskTargetService`.
    private let diskEnumerator: DiskEnumerator?

    /// Task driving the disk-event subscription loop.
    /// @ObservationIgnored + nonisolated(unsafe) lets deinit cancel the task
    /// without a MainActor hop. Writes to this property happen only from
    /// MainActor-isolated methods, so the unsafe annotation is sound.
    @ObservationIgnored
    nonisolated(unsafe) private var diskEventTask: Task<Void, Never>?

    /// Phase start timestamp, reset on each progress phase transition.
    private var phaseStartDate: Date = Date()

    /// The phase seen in the most recent progress event (to detect transitions).
    private var lastSeenPhase: FlashProgressData.Phase?

    // MARK: - Convenience production initializer

    /// Create the view model wired to real production core services.
    ///
    /// A fresh `FlashEngine` is created for each flash session by the factory
    /// inside the core flash service; this keeps `FlashEngine` non-reusable as
    /// designed.
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

    // MARK: - Dependency-injection initializer (engine factory + keychain)

    /// DI initializer used by the production `convenience init` and the existing
    /// AppUI tests. It builds the four core services from the injected primitives
    /// (an engine factory, a `KeychainStore`, and an optional `DiskEnumerator`),
    /// then forwards to the service initializer. Keeping this signature unchanged
    /// preserves the existing AppViewModelTests dependency-injection seam.
    ///
    /// - Parameters:
    ///   - makeEngine: closure that produces a fresh `FlashEngine` per job.
    ///   - keychainStore: trusted-checksum cache.
    ///   - diskEnumerator: live disk enumerator; pass `nil` to skip live events.
    public convenience init(
        makeEngine: @escaping @Sendable () -> FlashEngine,
        keychainStore: KeychainStore = KeychainStore(),
        diskEnumerator: DiskEnumerator? = DiskEnumerator()
    ) {
        // Wrap the engine factory in a core FlashEngineFactory so the core flash
        // service owns the orchestration while tests keep their engine seam.
        let engineFactory = ClosureFlashEngineFactory(factory: makeEngine)
        let flashService = DefaultFlashOrchestrationService(engineFactory: engineFactory)
        // The disk service needs an enumerator for the live snapshot; build it
        // from the injected enumerator when present, else use a no-snapshot
        // service so the pure filtering/display helpers stay available.
        let diskService: DiskTargetService
        if let enumerator = diskEnumerator {
            diskService = DefaultDiskTargetService(enumerator: enumerator)
        } else {
            diskService = EmptyDiskTargetService()
        }
        self.init(
            imageSourceService: DefaultImageSourceService(),
            diskTargetService: diskService,
            checksumService: DefaultChecksumService(keychainStore: keychainStore),
            flashService: flashService,
            diskEnumerator: diskEnumerator
        )
    }

    // MARK: - Full service-injection initializer

    /// Full DI initializer that accepts the core service protocols directly.
    ///
    /// Tests use this to override any single service with a fake while leaving the
    /// others as the real `Default*` implementations. The `diskEnumerator` is kept
    /// separate because the live event loop is a presentation concern owned here,
    /// not a core service.
    ///
    /// - Parameters:
    ///   - imageSourceService: stats the source image file.
    ///   - diskTargetService: snapshots disks, filters safe targets, names disks.
    ///   - checksumService: parse/validate/match checksums + Keychain cache.
    ///   - flashService: drives a flash session, emits numeric progress.
    ///   - diskEnumerator: live disk enumerator for the disk-event-to-UI binding.
    public init(
        imageSourceService: ImageSourceService = DefaultImageSourceService(),
        diskTargetService: DiskTargetService,
        checksumService: ChecksumService = DefaultChecksumService(),
        flashService: FlashOrchestrationService,
        diskEnumerator: DiskEnumerator? = DiskEnumerator()
    ) {
        self.imageSourceService = imageSourceService
        self.diskTargetService = diskTargetService
        self.checksumService = checksumService
        self.flashService = flashService
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
    /// Stats the file through the core image-source service to get the byte
    /// length (used for target filtering and as the advisory denominator). Resets
    /// target selection, then refreshes the target list.
    ///
    /// A missing or unreadable file surfaces a typed `CoreError` on `currentError`
    /// and leaves the view model on step 1 (source unselected). Only a successful
    /// stat advances to step 2; on success any prior error is cleared so a stale
    /// error never outlives a later successful selection.
    ///
    /// - Parameter url: the file URL chosen by the user.
    public func selectSource(_ url: URL) async {
        // Stat the file directly; a missing/unreadable source stays on step 1.
        let byteLength: Int
        do {
            byteLength = try imageSourceService.byteLength(of: url)
        } catch {
            // Source is missing or unreadable: surface the typed error so the UI
            // can render it, then stay on step 1. The core image-source service
            // throws CoreError.badInput; map any other error to the same case so
            // the observable surface is always a typed CoreError.
            currentError = (error as? CoreError)
                ?? .badInput(message: "Could not read the source image at \(url.path): \(error).")
            return
        }
        // Success: a fresh, valid selection clears any prior surfaced error.
        currentError = nil
        sourceURL = url
        sourceImageBytes = byteLength
        selectedTarget = nil
        flashState = .sourceSelected(url: url)
        // Refresh targets now that we have the correct source size.
        await refreshTargets()
    }

    // MARK: - Public API: target management

    /// Re-query the disk service and re-apply DiskSafety filtering.
    ///
    /// Called automatically when the source changes or a DiskEvent fires.
    /// The SwiftUI views can also call this to force a refresh.
    public func refreshTargets() async {
        let disks = await diskTargetService.snapshotDisks()
        updateTargetList(from: disks)
    }

    /// Human-readable display name for a disk, forwarded from the core service.
    ///
    /// The primary text shown in target rows. Delegates to
    /// `diskTargetService.displayName(for:)` so the GUI and CLI share one
    /// canonical label rather than each re-deriving the format.
    ///
    /// - Parameter disk: the disk to describe.
    /// - Returns: a single-line human-readable name.
    public func displayName(for disk: DiskDescriptor) -> String {
        diskTargetService.displayName(for: disk)
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
            displayName: diskTargetService.displayName(for: disk)
        )
        flashState = .targetSelected(sourceURL: url, target: info)
    }

    // MARK: - Public API: checksum input

    /// Supply an official expected checksum for the source image.
    ///
    /// Accepts either a pasted 128-hex-char string or a SHA512SUMS file body.
    /// Sets `expectedDigest` on success or `checksumInputError` on failure.
    /// All parsing/validation is delegated to the core checksum service.
    ///
    /// - Parameter source: how the checksum was provided.
    public func setOfficialChecksum(_ source: OfficialChecksumSource) {
        checksumInputError = nil
        officialChecksumSource = source
        switch source {
        case .pastedHex(let hex):
            // Validate and store the pasted hex string via core.
            do {
                expectedDigest = try checksumService.validatePastedHex(hex)
            } catch {
                expectedDigest = nil
                checksumInputError = "Invalid checksum: must be exactly 128 hex characters."
            }
        case .sha512SumsFile(let body):
            // Parse the file body and match against the current source filename via core.
            let filename = sourceURL?.lastPathComponent ?? ""
            do {
                expectedDigest = try checksumService.expectedDigest(fromSums: body, matching: filename)
            } catch {
                expectedDigest = nil
                checksumInputError = "Could not find a matching checksum entry for \"\(filename)\"."
            }
        }
    }

    /// Supply an official expected checksum by reading a SHA512SUMS file at `url`.
    ///
    /// Reads the file body here (in the view model) so a read failure surfaces as
    /// a user-facing `checksumInputError` instead of being silently turned into an
    /// empty body by the view layer. On a successful read this delegates to
    /// `setOfficialChecksum(.sha512SumsFile(body:))`, reusing the core parse and
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
        // Read succeeded; reuse the core parse/match path.
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
    /// Only callable from `.confirming`. Delegates the entire write/verify run to
    /// the core flash orchestration service, mapping each numeric
    /// `FlashProgressData` sample into a `FlashProgressSnapshot` for the UI and the
    /// terminal `FlashRunResult` into the appropriate `FlashState`.
    public func startFlash() async {
        guard case .confirming(let sourceURL, _) = flashState else { return }
        guard let disk = selectedTarget else { return }

        // Pass the advisory SHA-512 to the helper for early UI sanity checks.
        // The helper re-hashes what it writes; this is not a safety gate.
        let advisoryHex = expectedDigest?.hexString

        // Advance to flashing state with an empty initial snapshot.
        phaseStartDate = Date()
        lastSeenPhase = nil
        flashState = .flashing(snapshot: Self.snapshot(
            from: FlashProgressData(
                phase: .writing,
                bytesDone: 0,
                totalBytes: UInt64(max(0, sourceImageBytes))
            ),
            phaseStart: phaseStartDate
        ))

        // The core service invokes `progress` on an arbitrary task; marshal each
        // sample back onto the main actor before touching observable state.
        let result = await flashService.flash(
            source: sourceURL,
            target: disk,
            advisorySHA512: advisoryHex,
            verifyReadBack: false,
            progress: { [weak self] data in
                Task { @MainActor in
                    self?.handleProgress(data)
                }
            }
        )

        await handleFlashResult(result)
    }

    /// Cancel the active flash job.
    ///
    /// Best-effort; the authoritative outcome still arrives as a
    /// `.failure(.cancelled)` from the originating `flash` call in `startFlash`.
    public func cancel() async {
        await flashService.cancel()
    }

    /// Reset the view model to `.idle` so the user can start a new session.
    public func reset() {
        sourceURL = nil
        sourceImageBytes = 0
        selectedTarget = nil
        officialChecksumSource = nil
        expectedDigest = nil
        checksumInputError = nil
        currentError = nil
        flashState = .idle
        // Re-apply target filtering against empty source.
        Task { await refreshTargets() }
    }

    // MARK: - Private: progress handling

    /// Apply one numeric progress sample: update `flashState` with a fresh
    /// presentation snapshot.
    private func handleProgress(_ data: FlashProgressData) {
        // Progress samples are marshaled onto the main actor as fire-and-forget
        // tasks, so a late sample can arrive after the run already resolved. Drop
        // any sample once the session reached a terminal state so a stray
        // `.flashing`/`.verifying` never overwrites `.succeeded`/`.failed`/`.cancelled`.
        guard !flashState.isTerminal else { return }
        // Detect phase transitions and reset the speed clock.
        if data.phase != lastSeenPhase {
            phaseStartDate = Date()
            lastSeenPhase = data.phase
        }
        let snapshot = Self.snapshot(from: data, phaseStart: phaseStartDate)
        switch data.phase {
        case .writing:
            flashState = .flashing(snapshot: snapshot)
        case .verifying:
            flashState = .verifying(snapshot: snapshot)
        }
    }

    // MARK: - Private: result handling

    /// Translate a core `FlashRunResult` into the appropriate terminal state.
    private func handleFlashResult(_ result: FlashRunResult) async {
        switch result {
        case .failure(let error):
            applyFailure(error)
        case .success(let deviceSHA512):
            await applySuccess(deviceSHA512: deviceSHA512)
        }
    }

    /// Map a typed `CoreError` failure onto the terminal presentation state.
    private func applyFailure(_ error: CoreError) {
        switch error {
        case .cancelled:
            flashState = .cancelled
        case .verificationMismatch(let expected, let actual):
            flashState = .failed(
                message: "Verification mismatch: expected \(expected), got \(actual)."
            )
        case .helperUnavailable(let message):
            flashState = .failed(message: message)
        case .flashFailed(let message):
            flashState = .failed(message: message)
        case .badInput(let message):
            flashState = .failed(message: message)
        case .appNotFound(let message):
            flashState = .failed(message: message)
        }
    }

    /// Resolve checksum/cache match for a successful write, offer to cache a
    /// confirmed match, and advance to `.succeeded`.
    private func applySuccess(deviceSHA512: String) async {
        // The write completed, so any earlier surfaced error is stale; clear it.
        // A Keychain probe failure below re-sets a typed error without un-marking
        // the successful write.
        currentError = nil

        guard let deviceDigest = SHA512Digest(hexString: deviceSHA512) else {
            // No usable device digest: report success with nothing to compare.
            flashState = .succeeded(deviceSHA512: deviceSHA512, matchOutcome: .noOfficialChecksum)
            return
        }

        // Core resolves the outcome against the official digest then the cache.
        // A genuine Keychain access error throws here rather than silently
        // collapsing into a cache miss; surface it on the observable error while
        // still resolving the success state (the write itself succeeded). A true
        // cache miss does not throw and resolves to `.noOfficialChecksum`.
        let coreOutcome: USBImagerCore.ChecksumMatchOutcome
        do {
            coreOutcome = try checksumService.matchOutcome(
                deviceDigest: deviceDigest,
                officialDigest: expectedDigest,
                imageByteLength: sourceImageBytes
            )
        } catch {
            // The cache probe failed for a real reason (not a miss). Surface the
            // typed error and present the verdict as "no official checksum" so the
            // success state resolves without claiming an unverified trusted hit.
            currentError = (error as? CoreError)
                ?? .badInput(message: "Trusted-cache lookup failed: \(error).")
            flashState = .succeeded(deviceSHA512: deviceSHA512, matchOutcome: .noOfficialChecksum)
            return
        }
        let presentationOutcome = Self.presentationOutcome(for: coreOutcome)

        // If the user supplied a checksum and it matched, cache it. The "offer to
        // save" decision is the front end's; core only performs the storage.
        if coreOutcome == .officialMatch {
            saveTrustedChecksum(deviceDigest: deviceDigest)
        }

        flashState = .succeeded(
            deviceSHA512: deviceSHA512,
            matchOutcome: presentationOutcome
        )
    }

    /// Persist a confirmed checksum to the Keychain trusted cache via core.
    ///
    /// A save failure is non-fatal: a cache write failure is not a reason to mark
    /// the flash as failed, so any error is swallowed.
    private func saveTrustedChecksum(deviceDigest: SHA512Digest) {
        guard sourceImageBytes > 0 else { return }
        let filename = sourceURL?.lastPathComponent ?? "unknown"
        let entry = TrustedChecksum(
            sha512: deviceDigest,
            imageByteLength: sourceImageBytes,
            originalFilename: filename,
            sourceLabel: nil
        )
        // Core swallows duplicate-item; other errors are non-fatal here.
        try? checksumService.saveTrustedCache(entry)
    }

    // MARK: - Private: disk event loop

    /// Start the long-running task that consumes `DiskEnumerator.events()`.
    ///
    /// Called once from `init` via a detached `Task`. The task runs until
    /// the view model is deallocated (cancelled by `deinit`). The disk-event-to-UI
    /// binding is a presentation concern owned here, not in core.
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

    /// Re-apply DiskSafety filtering to `disks` via core and update `availableTargets`.
    private func updateTargetList(from disks: [DiskDescriptor]) {
        allDisks = disks
        // The source backing BSD name is nil when the source is a regular file.
        // For MVP: source images are always files, so sourceBackingBSDName is nil.
        let sourceBackingBSDName: String? = nil
        availableTargets = diskTargetService.validTargets(
            from: disks,
            imageSizeBytes: sourceImageBytes,
            sourceBackingBSDName: sourceBackingBSDName
        )
    }

    // MARK: - Private: presentation mapping

    /// Map a core `ChecksumMatchOutcome` onto the GUI's presentation outcome.
    ///
    /// The two enums are intentionally distinct: core's value is workflow-neutral,
    /// the GUI's drives the Verify panel. This single mapping keeps the view layer
    /// from touching the core type.
    private static func presentationOutcome(
        for outcome: USBImagerCore.ChecksumMatchOutcome
    ) -> ChecksumMatchOutcome {
        switch outcome {
        case .officialMatch:
            return .officialMatch
        case .officialMismatch:
            return .officialMismatch
        case .trustedCacheHit:
            return .trustedCacheHit
        case .noOfficialChecksum:
            return .noOfficialChecksum
        }
    }

    /// Build a presentation `FlashProgressSnapshot` from a numeric core progress
    /// sample plus the current phase-start timestamp.
    ///
    /// All display-string formatting (phase label, speed, transfer) lives in
    /// `FlashProgressSnapshot`; this adapter only supplies the numbers and timing.
    private static func snapshot(
        from data: FlashProgressData,
        phaseStart: Date
    ) -> FlashProgressSnapshot {
        FlashProgressSnapshot.make(from: data, phaseStart: phaseStart)
    }
}

// MARK: - ClosureFlashEngineFactory

/// Adapts a `@Sendable () -> FlashEngine` closure to the core `FlashEngineFactory`
/// protocol so the existing engine-factory injection seam (used by the production
/// `convenience init` and AppViewModelTests) drives the core flash service.
///
/// The closure never fails, so `makeEngine()` does not throw the helper-unavailable
/// path here; production wires that path through the real `XPCHelperConnection`
/// inside `USBImagerApp`.
private struct ClosureFlashEngineFactory: FlashEngineFactory {

    /// Produces a fresh engine per session.
    let factory: @Sendable () -> FlashEngine

    func makeEngine() throws -> FlashEngine {
        factory()
    }
}

// MARK: - EmptyDiskTargetService

/// A `DiskTargetService` for the no-enumerator path (tests that pass
/// `diskEnumerator: nil`, matching the prior behavior where `refreshTargets`
/// returned early with no live snapshot).
///
/// `snapshotDisks()` returns an empty list, so `availableTargets` stays empty and
/// `selectTarget`/`displayName` are never reached through the public flow. The
/// pure `validTargets` filter still forwards to the same `DiskModel` free function
/// the core service uses, so no safety logic is duplicated. `displayName` forwards
/// to the same canonical formatter for the unreachable case.
private struct EmptyDiskTargetService: DiskTargetService {

    func snapshotDisks() async -> [DiskDescriptor] {
        []
    }

    func validTargets(
        from disks: [DiskDescriptor],
        imageSizeBytes: Int,
        sourceBackingBSDName: String?
    ) -> [DiskDescriptor] {
        // Forward to the DiskModel module-level alias so the bare name does not
        // self-resolve to this protocol method (infinite recursion).
        diskModelValidTargets(
            from: disks,
            imageSizeBytes: imageSizeBytes,
            sourceBackingBSDName: sourceBackingBSDName
        )
    }

    func displayName(for disk: DiskDescriptor) -> String {
        // Forward to the one canonical DiskModel formatter for the unreachable path.
        diskDisplayName(for: disk)
    }
}
