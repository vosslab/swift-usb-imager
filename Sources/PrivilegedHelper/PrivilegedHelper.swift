/// PrivilegedHelper is the XPC helper process that performs raw disk writes on
/// behalf of the main app. The privileged logic is split across focused files:
///
///   - `HelperService`       -- `HelperXPCProtocol` conformance; decodes the
///                              control payloads and runs the full pipeline.
///   - `HelperAuthorization` -- pre-write authorization gate (real SecCode peer
///                              check; the XPC listener supplies the audit token).
///   - `HelperSafety`        -- independent pre-write `DiskSafety` re-check.
///   - `Unmount`             -- whole-disk unmount + eject (`diskutil` wrapper).
///   - `WriteJob`            -- raw block-aligned write + streaming SHA-512.
///   - `VerifyJob`           -- read-back of the image length + streaming SHA-512.
///   - `BlockMath`           -- pure block-alignment arithmetic.
///   - `CancellationToken`   -- cooperative cancel flag checked per chunk.
///   - `HelperError`         -- typed failures surfaced as `FlashResult.failed`.
///
/// Running the service as root requires code signing and SMAppService
/// installation, which is out of scope for this milestone; the logic here is
/// structured so that wiring is a thin later step (see `HelperAuthorization`).
public enum PrivilegedHelper {}
