# Raw disk write model decision

Parent plan: `immutable-spinning-sifakis` (a session-local plan kept outside the
repo tree, so it has no GitHub-browsable link here). This record closes its
milestone S5; the software lane spans tasks A1-A4 and the hardware lane spans
tasks B1-B3 (milestones S1-S5 cover the full spike).

Decision record for the raw-disk-write-model spike (milestone S5 of the plan
`immutable-spinning-sifakis`). It recommends the least-persistent privileged
backend for opening one `/dev/rdiskN` for writing, with SMAppService as the
documented fallback.

This record separates LOCKED software-lane evidence from PENDING hardware-lane
placeholders. The software lane (A1-A4) is complete and its findings are final.
The hardware lane (B1-B3) requires the user to run
[authopen_hardware_runbook.md](authopen_hardware_runbook.md) on real Apple
Silicon macOS 26; until those results land, the hardware sections are marked
placeholders and the overall verdict is pending.

```
+-----------------------------------------------------------+
| VERDICT: PENDING HARDWARE LANE                            |
| Software lane (A1-A4) locked. Hardware lane (B1-B3)       |
| not yet run. Recommend authopen IF the installed-app      |
| context passes B1-B3; otherwise escalate to SMAppService. |
+-----------------------------------------------------------+
```

## Model ranking

Least to most persistent. Lower persistence is the better risk surface for a
one-shot destructive raw write, per the plan's design philosophy ("privilege
attaches to the opened fd, not the whole app").

| Model | Persistence | Privilege scope | Fit for raw write |
| --- | --- | --- | --- |
| authopen -stdoutpipe | Lowest | One opened path, one fd | Best first candidate |
| sudo child process | Temporary | Whole child as root | Works, broad and clunky |
| SMAppService LaunchDaemon | Persistent registration | Root helper + XPC API | Sanctioned fallback |
| Full Disk Access for the app | Persistent privacy grant | Broad filesystem/privacy | Too broad if only raw write is needed |

Recommended default: `authopen`, conditional on the installed-app context
passing the hardware lane. Recommended fallback: SMAppService LaunchDaemon,
behind the same `RawDiskOpener` seam.

## Source-tiered evidence (LOCKED, software lane)

Evidence is separated by source class. A "2026 writeup" is not Apple guidance.
Full detail in
[../audits/authopen_source_research.md](../audits/authopen_source_research.md).
Tiers, strongest first: Tier 1 Apple official docs, Tier 2 Apple DTS forum
posts, Tier 3 man pages, Tier 4 third-party experiments.

### authopen: lighter in mechanism, less sanctioned for distribution

- Tier 3 (man page): `authopen -stdoutpipe` performs the Authorization Services
  check and passes the already-open fd back over `SCM_RIGHTS`. `-o flags`
  numerically sets the exact `open(2)` mode. `-w` adds truncate semantics (wrong
  for a raw device), confirming the explicit `-o` choice. Rights are
  path-qualified: `sys.openfile.readwrite./dev/rdiskN`. authopen "appeared in Mac
  OS X 10.1 to assist with the manipulation of disk devices", so raw-disk work is
  its original purpose. No launchd registration exists in the mechanism.
- Tier 2 (Apple DTS thread 708765): the only authopen endorsement is
  interactive-CLI-scoped ("If you're working interactively on the command line,
  use sudo, authopen, and osascript as you see fit"). authopen does NOT appear in
  Apple's distributed-product ranking, which routes to SMAppService (ongoing) or
  a `.pkg`/`SMJobSubmit` (one-shot).
- Tier 4 (rpi-imager): shipping third-party software uses authopen for raw
  `/dev/rdiskN`, and shows EBUSY until the volume is unmounted.
- Tier 1: there is NO Apple documentation endorsing authopen for app
  distribution. SMAppService has full Tier 1 documentation.

Net: authopen is strictly lighter in mechanism (no launchd registration, no
background item, privilege bound to one fd that vanishes on close) but LESS
SANCTIONED for distribution. SMAppService is heavier (persistent, user-visible
background item) but MORE SANCTIONED. Which axis dominates depends on the
distribution target and on whether authopen passes the installed-app hardware
test.

### FDA gates the write; errno meanings

- A raw WRITE to `/dev/rdiskN` triggers Full Disk Access; a raw READ triggers the
  lighter Removable Media prompt (Tier 2, thread 777577). FDA is the gating
  privacy control for writing.
- EACCES (13) = a BSD-level permission gap; the authorized authopen fd is the
  cure. EPERM (1) = a sandbox/MAC/TCC denial; authorizing the open does not fix
  it by itself (Tier 2, thread 678819). The hardware lane must record which
  errno appears.
- TCC grants attach to "responsible code", which SHOULD be the app bundle for a
  bundled tool, but no Apple source confirms this for an authopen child
  specifically (Tier 2, thread 678819). This is the decisive unknown B2 measures.

### The confirmed 26.x regression

- The 26.1/26.2 CLI Full Disk Access regression is a CONFIRMED Apple bug
  (FB20662270), fixed in 26.3 beta1, scoped to standalone CLI tools and wrapper
  executables, NOT app bundles (Tier 2, threads 806187 and 809549).
- Consequence: the Xcode and Terminal launch contexts may show FALSE FDA
  failures on an affected build. The installed-app-from-/Applications context
  (ideally on 26.3+) is decisive and must not be discarded on the basis of a
  CLI-only regression.

### A1 proof: SCM_RIGHTS fd-passing works (LOCKED)

The A1 harness at
[../../../tools/authopen_fd_probe/README.md](../../../tools/authopen_fd_probe/README.md)
proves, via its `selftest` mode, that the SCM_RIGHTS mechanism works on this
machine independent of authopen and any device:

- An fd passed from a child over a UNIX socketpair is received in the parent.
- Read and write through the received fd both succeed.
- The fd stays usable AFTER the sender (child) has exited, proving the
  capability-lifetime model.
- `close()` returns 0; a double-close returns EBADF.

This isolates fd-passing correctness from disk-permission behavior. The riskiest
technical part of the model (SCM_RIGHTS fd receipt) is therefore proven before
any hardware run.

### A2 design summary: the RawDiskOpener seam (LOCKED)

Full design in [rawdiskopener_design.md](rawdiskopener_design.md). The model
inverts today's `WriteJob.run` direct `open(rawDevicePath, ...)`: a separate
opener obtains the fd and hands it to a fd-only writer.

- `RawDiskOpener` protocol: `openDevice(rawDevicePath:openFlags:) async throws ->
  OpenedRawDisk`. It only performs the privileged open; identity revalidation,
  unmount, and byte streaming stay with the caller.
- `OpenedRawDisk` value-owning wrapper owns the fd, the device path, the exact
  `RawDiskOpenFlags`, and diagnostics (backend, right name, launch context). It
  defines ownership: the wrapper is the sole closer, close is idempotent,
  cancellation routes through `close()`, and partial-write status is carried by
  the existing `FlashResult`/`FlashOutcome.cancelled` path, not a new type.
- Three implementations: `AuthopenRawDiskOpener` (candidate default),
  `SMAppServiceHelperRawDiskOpener` (fallback, wrapping the existing helper/XPC
  machinery), `MockRawDiskOpener` (tests, over a regular file).
- Write-to-fd refactor: the streaming core (`streamWrite`, `writeExactly`,
  `queryBlockSize`, `F_NOCACHE`) is already fd-only; only the single device
  `open(...)` is replaced by a passed-in `OpenedRawDisk`, wired across the
  boundary via the stubbed `SourceAccess.fileDescriptor` case.

### Binding modularity constraint (REQUIRED under both options)

This holds regardless of which backend wins, and the implementation plan must
honor it. The aim is NOT to pick the perfect privilege model today; it is to make
privilege handling SWAPPABLE without rewriting the app.

- Separation of concerns: the byte-streaming writer must NOT know whether the
  write target came from authopen, a helper, a mock, or a future API. It receives
  a write TARGET and streams bytes. "Authorize/open" stays separate from "stream
  bytes."
- ONE authorization seam and ONE injection point (parallel to today's
  `FlashEngineFactory` seam where the GUI and CLI already select engines).
- The backend is swappable between `authopen`, SMAppService, and the mock
  WITHOUT touching the byte-streaming write loop or the UI.
- Production selects the authopen authorization by default and the SMAppService
  authorization when the decision matrix says to escalate; tests select the mock.
  No front end hardcodes a backend.

This constraint is what lets the verdict change after hardware results without
reworking the write path: only the injected authorization backend changes.

#### Name the boundary for authorization, not just opening

A2 named the seam `RawDiskOpener` (open-shaped). Folding in the user's emphasis,
the candidate production boundary names AUTHORIZATION, not just opening, because
the fallback path does not return an fd at all. Candidate shape (Swift sketch,
not final; sits alongside A2's `RawDiskOpener` naming and notes the rename
emphasis):

```
protocol RawDiskWriteAuthorization {
    func openAuthorizedRawDisk(
        request: RawDiskOpenRequest
    ) async throws -> AuthorizedRawDiskTarget
}
```

- `AuthorizedRawDiskTarget` owns its full lifecycle: close behavior, cancellation
  behavior, diagnostics, AND whether it is a local fd or a remote helper-backed
  write target. This is A2's `OpenedRawDisk` ownership contract, widened so the
  target type, not just the fd, is part of what the value owns.
- Backend selection stays injectable, same as A2's three implementations renamed
  to the authorization emphasis: `AuthopenRawDiskAuthorization` (default if it
  passes the spike), `SMAppServiceRawDiskAuthorization` (fallback),
  `MockRawDiskAuthorization` (tests).
- Avoid fake symmetry: authopen returns a local fd, but SMAppService writes
  remotely inside the helper (the fd never crosses back). The common boundary may
  therefore need to be "authorized write target," NOT "opened fd." That is the
  cleaner unification than forcing the helper path into a fake-fd shim.

#### S5 acceptance items

The record must satisfy these to be ready for human review:

- The record shows the exact write-loop interface and walks the five behaviors
  (progress, cancellation, close, partial-write state, verification) per target
  kind (local-fd vs helper-backed). See
  [Write-loop interface against the target](#write-loop-interface-against-the-target).
- The write loop never special-cases the backend; the target type carries the
  difference. The two-column table makes the writer's calls identical in both
  columns.

## Hardware lane evidence (PLACEHOLDER, pending B1-B3)

The following sections are PLACEHOLDERS. They are filled from the operator
results produced by [authopen_hardware_runbook.md](authopen_hardware_runbook.md).
No hardware results are fabricated here.

### Test environment (PLACEHOLDER)

To be filled from the runbook capture block:

- macOS `ProductVersion` and `BuildVersion` (`sw_vers`): PENDING.
- Xcode version (`xcodebuild -version`): PENDING.
- Local `man authopen` confirmation or deviation from the A3 summary: PENDING.
- Sacrificial USB: BSD name, size, volume label, media identity: PENDING.

### B1: authopen raw-device write per context (PLACEHOLDER)

PENDING HARDWARE. To be filled with PASS/FAIL per launch context (Xcode,
Terminal, installed app), each with: the auth prompt text, the right name
(expect `sys.openfile.readwrite./dev/rdiskN`), the residue check (`ps`/`lsof`
clean after close), the errno on any failure, and the cancellation outcome.

### B2: Full Disk Access attribution (PLACEHOLDER, DECISIVE)

PENDING HARDWARE. The decisive result. To be filled with, per context: the OS
build, the errno before and after granting FDA (EACCES 13 vs EPERM 1), which
component holds FDA when the write succeeds, and whether that component even
appears in the FDA list. The decisive line: in the installed-app context, does
ONE app-level FDA grant authorize the authopen child's raw write, or does TCC
demand FDA on the child / probe separately.

### B3: unmount and exclusivity matrix (PLACEHOLDER)

PENDING HARDWARE. To be filled with: whether `diskutil unmountDisk` succeeds
unprivileged (resolves H6), the exclusivity matrix (open result + errno per disk
state: mounted, unmounted, busy, removed mid-open, path changed), the
`O_EXCL`-vs-`O_RDWR|O_SYNC` tradeoff, and confirmation that `F_NOCACHE`/sync on
the passed fd lands bytes on the media.

## Boundary shape decision (OPEN, tied to hardware)

This is an EXPLICIT S5 decision: what is the final production boundary, and is it
fd-shaped or authorization-shaped. It restates A2's Option A vs Option B in
authorization terms (see
[rawdiskopener_design.md](rawdiskopener_design.md) "Open questions for S5"). The
modular seam is REQUIRED under either choice; this decision is only about the
boundary's SHAPE, not whether it is swappable.

The structural asymmetry that forces the choice: authopen returns a local
app-held fd, while SMAppService keeps the open AND the write inside the helper
(the fd never crosses back).

- Fd-opener-only (the lean authopen-wins shape, A2's Option A): if authopen works
  cleanly, a local fd is enough. One fd-shaped seam (`RawDiskOpener` returning an
  `OpenedRawDisk`) serves the default; the fallback, if ever used, returns a
  wrapper whose `close()` invalidates the XPC job. Leanest when authopen is the
  default.
- Broader authorized-write-backend (Option-A-done-right, the
  `RawDiskWriteAuthorization` shape above): the boundary is "authorized write
  target," not "opened fd." `AuthorizedRawDiskTarget` represents a local fd OR a
  remote helper-backed write target honestly, so the helper path is not forced
  into a fake-fd shim. Cleaner when the fallback path needs helper-owned remote
  writing. This is the broader, more honest unification.
- Option B (two narrower protocols behind a common selector) remains the
  most-honest-but-most-branching alternative: a fd-returning opener for authopen
  and a session/write-backend for the helper, unified only at the injection
  point.

Decision: PENDING, tied to the hardware-lane result, same as the A2 framing.

- authopen passes the installed-app hardware test (B1-B3) -> a clean fd-based
  default; the fd-opener-only shape is provisionally recommended (local fd is
  enough), with the fallback treated as a SEPARATE writer backend rather than a
  fake-fd shim.
- authopen fails -> SMAppService becomes the default as a helper-owned remote
  writer; the broader authorized-write-backend (`RawDiskWriteAuthorization` /
  `AuthorizedRawDiskTarget`) or Option B is the honest shape, since an fd-shaped
  boundary no longer fits the winning backend.

Do not force symmetry early. The boundary shape follows the backend that passes
hardware; the swappable seam ships first under either outcome.

## Write-loop interface against the target

To keep the abstraction concrete rather than vague, this is the exact interface
the byte-streaming write loop uses against an `AuthorizedRawDiskTarget`, plus how
each behavior works for BOTH a local-fd target (authopen) AND a helper-backed
remote target (SMAppService). The write loop calls only this interface; it never
special-cases the backend. The target type carries the difference.

Candidate interface (Swift sketch, not final; the writer holds the target and
nothing else backend-specific):

```
protocol AuthorizedRawDiskTarget {
    // Stream one block-aligned chunk; returns bytes accepted.
    func write(_ chunk: ByteBuffer) async throws -> Int
    // Cooperative progress: cumulative bytes the target has accepted.
    var bytesWritten: Int { get }
    // Read back for verification (SHA-512 compare), from the same target.
    func read(into buffer: inout ByteBuffer, count: Int) async throws -> Int
    // Release the capability; idempotent.
    func close() async
}
```

The five behaviors per target kind:

| Behavior | Local-fd target (authopen) | Helper-backed remote target (SMAppService) |
| --- | --- | --- |
| 1. Progress | Writer holds the fd, streams in-process, reports cumulative bytes locally | open+write run in the daemon; progress crosses the XPC boundary back to the app |
| 2. Cancellation | Cancel = close the fd; the in-loop `cancelToken` checkpoint stops the stream | Cancel crosses XPC; close = invalidate the XPC job so the daemon stops |
| 3. Close | `close()` closes the app-held fd; idempotent via an already-closed guard | `close()` invalidates the XPC job; idempotent; the daemon reaps on invalidation |
| 4. Partial-write state | Cumulative `bytesWritten` plus the existing `FlashOutcome.cancelled`; no new status type | Same outcome contract, reported across XPC from the daemon's cumulative count |
| 5. Verification | Read-back via the same fd path, SHA-512 compared app-side | Read-back and SHA-512 compare run helper-side or stream bytes back over XPC |

The point the table makes: the write loop's calls are identical in both columns.
Only `AuthorizedRawDiskTarget`'s concrete type changes, so progress, cancel,
close, partial-write reporting, and verification each have a local-fd path and a
helper-backed path WITHOUT the writer branching on which backend is in use. This
is the separation-of-concerns constraint made concrete.

## Fallback decision matrix

Maps each failure mode to its next step. Driven by the hardware-lane results.

| Failure mode | Next step |
| --- | --- |
| authopen fd-passing fails outright in the installed-app context | Escalate to the SMAppService fallback backend |
| Raw write requires FDA in the shipping context but attribution lands on the app | Add FDA onboarding for the app; keep authopen |
| Raw write requires FDA on the authopen child / probe separately (not the app) | FDA likely unsatisfiable for an installed app this way; escalate to SMAppService |
| Unmount needs a privileged path anyway | Privilege is no longer fd-only; reweigh SMAppService (move unmount+open into the helper) |
| Distribution requires the Mac App Store | Raw disk writing + privilege escalation likely not viable for App Store; flag as a separate distribution decision, not an authopen-vs-SMAppService technical one |
| Signed-app-only behavior blocks the Xcode/CLI contexts | Acceptable if the installed-app context passes; record as a known dev-vs-ship difference |
| A 26.1/26.2 build shows CLI FDA failure | Attribute to FB20662270, not authopen; re-test on 26.3+ before concluding |

## Residual risks

- The authopen distribution endorsement is thin (Tier 3 man page plus one
  interactive-only Tier 2 sentence, no Tier 1). The installed-app hardware test
  is what would justify shipping it.
- FDA attribution to the app for an authopen child is inferred, not Apple-stated;
  B2 must confirm it directly.
- The 26.1/26.2 regression can produce false negatives in the Xcode/Terminal
  contexts; the build number must be recorded and the installed-app context
  treated as decisive.
- `O_EXCL` behavior on `/dev/rdiskN` may differ from a regular file; B3 measures
  it, with a documented `O_RDWR|O_SYNC` fallback.

## Hardware results still needed from the user

To lift the verdict from PENDING, the user runs
[authopen_hardware_runbook.md](authopen_hardware_runbook.md) and returns:

1. Capture block: `man authopen`, `sw_vers` (with `BuildVersion`),
   `xcodebuild -version`, and the sacrificial USB identity.
2. `selftest` pass confirmation and exit code.
3. B1: PASS/FAIL per launch context, with prompt text, right name, residue
   check, errno on failure, and cancellation outcome.
4. B2 (decisive): per context, errno before/after FDA, which component holds
   FDA, whether it appears in the FDA list, and the installed-app attribution
   answer (app-level grant vs child-specific FDA).
5. B3: unprivileged-unmount result, the exclusivity matrix, and the
   `F_NOCACHE`/sync confirmation on the passed fd.

The installed-app context on a 26.3+ build is the decisive measurement; without
it the verdict stays PENDING HARDWARE LANE.

## Handoff

Once the hardware placeholders are filled, this record is delivered "ready for
human review". The plan is complete when the record exists and is internally
evidence-backed; it does not require the user to approve it first. No production
flash code is written until the user reviews this record and commissions the
follow-up implementation plan for the chosen backend.
