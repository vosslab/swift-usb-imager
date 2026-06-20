# RawDiskOpener backend design

Design notes for milestone S4 of the raw-disk-write-model spike (plan task A2).
This is a design recommendation only. No production code is wired by this
document; the implementation lands in the follow-up plan after the S5 decision
record. See the plan's S4 milestone for the source requirements and
[wp_helper_path_findings.md](../audits/wp_helper_path_findings.md) for the
unwired-flash-path finding this spike builds on.

## Why this abstraction exists

The dangerous operation in swift-usb-imager is opening one raw device
`/dev/rdiskN` for writing. The spike's design philosophy is that privilege
attaches to that one opened file descriptor, not to the whole app. Today the
privileged side opens the device itself: `WriteJob.run` calls
`open(rawDevicePath, O_RDWR | O_SYNC | O_EXCL)` directly
([Sources/PrivilegedHelper/WriteJob.swift](../../../Sources/PrivilegedHelper/WriteJob.swift),
line 93). The new model inverts this: a separate opener obtains the fd (via
`authopen` or the helper) and hands it to the writer, so the write logic targets
a passed fd it does not own the open of.

A `RawDiskOpener` protocol names that seam. It lets the candidate default
(`authopen`) and the fallback (`SMAppService` helper) be swapped without
touching the byte-streaming loop, and lets tests run the whole flash path
against a regular file with no privilege at all.

## The opener protocol

`RawDiskOpener` has one job: turn a validated raw device path plus a requested
open mode into an owned, write-capable descriptor, or fail with a typed error.
It does not stream bytes, unmount volumes, or revalidate disk identity; those
stay with the caller and the existing safety layer.

Recommended shape (Swift sketch, not final code):

```
public protocol RawDiskOpener: Sendable {
    /// Open `rawDevicePath` with `openFlags` and return an owned descriptor.
    /// The caller has already revalidated the target identity and unmounted
    /// its volumes; the opener only performs the privileged open.
    func openDevice(
        rawDevicePath: String,
        openFlags: RawDiskOpenFlags
    ) async throws -> OpenedRawDisk
}
```

`RawDiskOpenFlags` is a small value carrying the requested open(2) mode
(`O_RDWR`, `O_SYNC`, and optionally `O_EXCL`), so the backend selection and the
exclusivity-vs-openability tradeoff (S1/S3) live in data the caller controls,
not hardcoded in each opener. `authopen` consumes these as its numeric `-o`
argument; the helper opener passes them straight to `open(2)`.

## The value-owning wrapper

The opener returns a small value-owning wrapper, `OpenedRawDisk`, rather than a
bare `FileHandle` or a raw `Int32`. Lifetime, cancellation, and partial-write
status all attach to the opened device, so a named owner for them is clearer
than a loose integer. If S1 through S3 show a bare descriptor suffices (for
example if cancellation turns out to be a pure caller concern and close is
trivially idempotent on macOS 26), record that simplification and drop the
wrapper; until the spike proves that, the wrapper is the safer default.

The wrapper owns:

- the opened file descriptor (the privileged capability),
- the original `rawDevicePath` it was opened against,
- the exact `RawDiskOpenFlags` used (so diagnostics and the write loop agree on
  the mode, and a later `O_EXCL`-vs-no-`O_EXCL` retest is recorded in the
  value),
- diagnostic metadata: which backend opened it (`authopen` or helper), the
  authorization right name shown to the user when applicable
  (e.g. `sys.openfile.readwrite./dev/rdiskN`), and the launch context.

### Ownership semantics

These are the contract points the plan requires the wrapper to define.

- Who closes the fd: the wrapper owns the fd and is the sole closer. The
  byte-streaming writer borrows the fd for the duration of the write and never
  closes it. Closing happens through one wrapper method (`close()`), called by
  the orchestration layer that created the wrapper, in a `defer` analogous to
  `WriteJob`'s current `defer { close(deviceFD) }`.
- Cancellation: closing the fd is the cancellation mechanism. Per the S1
  acceptance criteria, closing the fd mid-write stops progress, reports the run
  as incomplete, and holds before verification. Cancellation therefore routes
  through the wrapper's `close()`; the writer's existing cooperative
  `cancelToken` checkpoint at each chunk boundary
  ([WriteJob.swift](../../../Sources/PrivilegedHelper/WriteJob.swift), line 146)
  remains the in-loop stop, and the wrapper close is what releases the
  capability.
- Idempotent close: `close()` is idempotent. A second call is a no-op and does
  not double-close the descriptor (guard on an internal "already closed" flag so
  a cancel-then-defer or defer-then-cancel ordering is safe). This is required
  because cancellation and normal teardown can both reach close.
- Partial-write status: the wrapper does not compute success; it reports how the
  open ended and lets the caller's existing `FlashResult` carry the outcome. The
  writer already returns cumulative `bytesDone` and distinguishes a clean finish
  from a `CancellationError`; on cancel the run is reported incomplete via the
  existing `FlashOutcome.cancelled` path
  ([Sources/HelperProtocol/FlashTypes.swift](../../../Sources/HelperProtocol/FlashTypes.swift)),
  not by the wrapper inventing a new status type.

## Three implementations

### AuthopenRawDiskOpener (candidate default)

Spawns `/usr/libexec/authopen -stdoutpipe -o <numeric flags> <rawDevicePath>`,
performs the SCM_RIGHTS fd receipt (the mechanism proven by the A1 harness at
`tools/authopen_fd_probe/`), and wraps the received descriptor in an
`OpenedRawDisk` tagged with backend `authopen` and the authorization right name.
Responsibilities:

- build the numeric `-o` open(2) flag argument from `RawDiskOpenFlags`,
- run the child, receive the fd over the Unix-domain socket, and confirm the
  child exited (the privileged side is gone once the fd is handed over, per the
  S1 residue check),
- surface authorization-prompt cancellation and open failures (EACCES vs EPERM)
  as a typed opener error so S2's FDA findings map cleanly.

This implementation is the one whose viability S1 through S3 prove; it becomes
the default only if the installed-app context passes.

### SMAppServiceHelperRawDiskOpener (fallback)

Wraps the existing helper/XPC machinery so the privileged daemon performs the
open and the write happens helper-side, behind the same `RawDiskOpener` seam.
This reuses the tested security primitives without change:
`XPCHelperConnection`
([Sources/FlashEngine/HelperConnection.swift](../../../Sources/FlashEngine/HelperConnection.swift)),
the pinned identity constants and `CodeSigningRequirement` in
`XPCFlashEngineFactory`
([Sources/USBImagerCore/XPCFlashEngineFactory.swift](../../../Sources/USBImagerCore/XPCFlashEngineFactory.swift)),
and the SMAppService daemon described in `docs/SIGNING.md`.

Note a structural asymmetry to resolve in the implementation plan: in the
fallback model the open and the byte streaming both happen inside the privileged
helper (the helper opens the device and runs `WriteJob`), so the fd never
crosses back to the app. The `OpenedRawDisk` this opener returns is therefore a
handle to a helper-side open, not an app-held descriptor; the write-to-fd path
below applies directly only to the `authopen` model. The cleanest reconciliation
is that the fallback opener returns a wrapper whose "fd" is the helper-side
session and whose `close()` invalidates the XPC job. This keeps one protocol
while honoring that the helper path's privilege boundary is the XPC connection,
not a passed fd.

### MockRawDiskOpener (tests)

Opens a regular file (a temp path) with the requested flags and returns an
`OpenedRawDisk` over that descriptor, so the entire write loop can be exercised
with no privilege, no device, and no install. This mirrors the existing test
seam where `HelperConnection` and `FlashEngineFactory` are faked
([Sources/USBImagerCore/Services.swift](../../../Sources/USBImagerCore/Services.swift),
`FlashEngineFactory`). The mock also lets a test simulate cancellation by
closing the fd mid-write and assert the wrapper's idempotent-close and
incomplete-report behavior.

## Write-to-fd refactor outline

The block-aligned streaming logic in `WriteJob` already works against a plain
`Int32` device fd: `streamWrite`, `writeExactly`, `queryBlockSize`, and the
`F_NOCACHE` `fcntl` all take a descriptor, not a path
([Sources/PrivilegedHelper/WriteJob.swift](../../../Sources/PrivilegedHelper/WriteJob.swift),
lines 99 through 122 and 128 onward). The only path-owning step is the single
`open(rawDevicePath, O_RDWR | O_SYNC | O_EXCL)` at line 93.

The refactor splits `run` so the open is injected rather than performed:

- Keep the streaming core (`streamWrite` and helpers) exactly as is; it is
  already fd-only and needs no change.
- Replace the device `open(...)` plus its `defer { close(deviceFD) }` with a
  passed-in `OpenedRawDisk`. `WriteJob.run` (or a thin sibling) accepts the
  wrapper, reads `deviceFD` from it, applies `F_NOCACHE` and block-size query as
  today, runs the streaming loop, and does NOT close the fd (the wrapper's owner
  closes it). The source-side open stays unchanged.
- Wire the descriptor across the boundary via the already-stubbed
  `SourceAccess.fileDescriptor` case in
  [Sources/HelperProtocol/FlashTypes.swift](../../../Sources/HelperProtocol/FlashTypes.swift)
  (lines 67 through 68). That enum case is documented as the marker that an
  out-of-band descriptor accompanies the message, carried by `NSXPCConnection`
  fd-transfer machinery rather than inside the Codable value. In the `authopen`
  model the app holds the device fd and the writer runs app-side, so this is the
  transport that lets a fd-only `WriteJob` consume the opener's descriptor
  without reopening the device.

The exact open flags the writer asks the opener for come from S3's exclusivity
findings: the first tested set is `O_RDWR | O_EXCL | O_SYNC`, with a documented
fallback to `O_RDWR | O_SYNC` if `O_EXCL` blocks a valid raw-device open after
unmount. Those flags ride in `RawDiskOpenFlags` so the writer and opener never
disagree.

## Backend selection point

The opener must be selectable so `authopen` can be the default with the helper
as a drop-in fallback. The selection belongs where the flash session is
assembled, parallel to today's `FlashEngineFactory` seam.

- Today the GUI builds its flash service through a `FlashEngineFactory` closure
  in `AppViewModel`
  ([Sources/AppUI/AppViewModel.swift](../../../Sources/AppUI/AppViewModel.swift),
  the `makeEngine` initializer around line 147), and the CLI selects
  `XPCFlashEngineFactory` versus `HelperUnavailableEngineFactory`
  ([Sources/USBImagerCore/XPCFlashEngineFactory.swift](../../../Sources/USBImagerCore/XPCFlashEngineFactory.swift),
  [Sources/USBImagerCore/HelperUnavailableEngineFactory.swift](../../../Sources/USBImagerCore/HelperUnavailableEngineFactory.swift)).
- Add a `RawDiskOpener`-producing factory alongside that existing factory seam,
  injected the same way: production picks `AuthopenRawDiskOpener` by default and
  `SMAppServiceHelperRawDiskOpener` when the decision matrix (S5) says to
  escalate; tests pick `MockRawDiskOpener`. Keeping the opener choice next to the
  engine-factory choice means both front ends select the backend through one
  injection point and no front end hardcodes a backend.

This mirrors the repo's existing dependency-injection pattern (every service
protocol in [Sources/USBImagerCore/Services.swift](../../../Sources/USBImagerCore/Services.swift)
is injected, with `Default*` production conformers and fakes in tests), so the
opener seam adds no new architectural concept.

## Open questions for S5

- Single protocol vs two: the `authopen` model passes a real fd app-side, while
  the helper fallback keeps the open and the write inside the daemon. The
  asymmetry above is reconciled by treating the fallback wrapper's `close()` as
  an XPC-job invalidation, but S5 should confirm one `RawDiskOpener` protocol is
  the right unification rather than two narrower protocols behind a common
  selector.
- Whether the value-owning wrapper survives or collapses to a bare descriptor
  depends on the S1 through S3 cancellation and close-idempotency findings.
- Async vs sync `openDevice`: `authopen` shows an authorization prompt and waits
  on a child, so `async` is recommended; confirm against the actual A1 harness
  shape.

## Status

DONE. The design names the `RawDiskOpener` protocol, the `OpenedRawDisk`
value-owning wrapper and its ownership semantics, the three implementations, the
write-to-fd refactor reusing `SourceAccess.fileDescriptor`, and the backend
selection point, all grounded in the current sources.
