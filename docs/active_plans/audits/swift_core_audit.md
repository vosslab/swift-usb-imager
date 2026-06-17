# Swift core audit

**Status:** findings complete -- awaiting sign-off and remediation
**Artifact:** `docs/active_plans/audits/swift_core_audit.md`
**Date:** 2026-06-16

## Executive summary

The codebase is structurally sound. The write path, block-alignment math,
digest comparison, cancellation, and the advisory-vs-truth contract are all
correct. The main gaps are one permanent stub that leaves the authorization
gate open (critical), two concurrency hazards (high), one unsafe cast that
would truncate large images on a 32-bit host (medium), and a cluster of
low-severity defensive-code omissions. None of the high/medium issues are
exploitable today because the helper is not yet signed or installed; they
must be fixed before the SMAppService signing milestone ships.

## Severity counts

| Severity | Count |
| --- | --- |
| Critical | 1 |
| High | 3 |
| Medium | 4 |
| Low | 4 |
| **Total** | **12** |

---

## C-1 Authorization gate is a permanent allow-all stub

**Severity:** Critical
**File:** `Sources/PrivilegedHelper/HelperAuthorization.swift` (lines 52, 75-87)

The production helper ships with `HelperAuthorization.allowAll` as the
default gate (line 52). The `pinning(requirement:)` factory (lines 75-87)
evaluates no security policy: it captures the requirement string, does
`_ = pinned`, and returns `nil` (allow). No `SecCodeCheckValidity` call is
present anywhere in the file.

```
public static let allowAll = HelperAuthorization(decide: { nil })  // line 52
_ = pinned          // line 83 -- requirement string is discarded
return nil          // line 84 -- unconditional allow
```

Any Mach client that can reach the XPC service endpoint can drive raw disk
writes as root. The file-level comment acknowledges this is a stub, but the
stub must not ship to users.

**Suggested fix:** Before the SMAppService milestone closes, wire
`NSXPCConnection.auditToken` into a `SecCodeCopyGuestWithAttributes` /
`SecCodeCheckValidity` call inside `pinning(requirement:)`. Pass the
`CodeSigningRequirement.requirementString` as the `SecRequirement`. Deny the
connection on any non-nil `OSStatus`. Update `HelperService.init` to inject
`HelperAuthorization.pinning(requirement: ...)` instead of `.allowAll`.

---

## H-1 Source-overlap rule is permanently inert

**Severity:** High
**Files:**
- `Sources/AppUI/AppViewModel.swift` (line 525)
- `Sources/PrivilegedHelper/HelperService.swift` (line 82)

Both sides hard-code `sourceBackingBSDName = nil`. `FlashRequest` carries no
field for it. The `DiskSafety.sourceOverlap` rule is therefore never
triggered, even when the source image is read from a disk that is also listed
as a flash target.

```
// AppViewModel.swift line 525
let sourceBackingBSDName: String? = nil   // always nil -- MVP comment

// HelperService.swift line 82 (default parameter)
sourceBackingBSDName: String? = nil
```

**Suggested fix:** Add a `sourceBackingBSDName: String?` field to
`FlashRequest`. In `FlashEngine`, use `DADiskCopyDescription` on the source
URL's volume to populate it. In `HelperService`, read the field from the
decoded request and pass it to `HelperSafety.validatedTarget`. Both the app
and helper should compute the value independently from their own DA sessions
so neither side can spoof the other.

---

## H-2 Semaphore-over-Task in blockingSnapshot can deadlock

**Severity:** High
**File:** `Sources/PrivilegedHelper/HelperSafety.swift` (lines 102-114)

`blockingSnapshot` parks a cooperative-pool thread on a `DispatchSemaphore`
while waiting for a `Task` that itself needs a cooperative-pool thread to
call `await enumerator.snapshot()`. Under two concurrent flash calls the pool
can exhaust, making each task wait for a thread the other holds.

```swift
// lines 102-114
let semaphore = DispatchSemaphore(value: 0)
Task {
    let snapshot = await enumerator.snapshot()
    semaphore.signal()
}
semaphore.wait()   // parks the caller's cooperative thread
```

**Suggested fix:** Make `liveResolve` and `validatedTarget` async and
`await enumerator.snapshot()` directly. If a synchronous boundary is
unavoidable, offload the wait to a dedicated `Thread` (not a cooperative
task) so the pool stays available.

---

## H-3 `@unchecked Sendable` on `HelperService` with mutable guarded state

**Severity:** High
**File:** `Sources/PrivilegedHelper/HelperService.swift` (line 52)

`HelperService` is declared `@unchecked Sendable`. It holds mutable state
(`cancelTokens`, etc.) guarded by `NSLock`. The pattern is correct today, but
`@unchecked Sendable` silences the compiler: any future field added without a
lock will introduce a data race with no diagnostic.

```swift
// line 52
public final class HelperService: NSObject, HelperXPCProtocol, @unchecked Sendable {
```

**Suggested fix:** Either document every mutable field and its guard in a
dedicated comment block, or extract `cancelTokens` into a dedicated `actor
TokenRegistry` and remove the `@unchecked` conformance so the compiler
enforces isolation going forward.

---

## M-1 Force-unwrapped `AsyncStream.Continuation`

**Severity:** Medium
**File:** `Sources/FlashEngine/FlashEngine.swift` (line 62)

The initializer captures the continuation via an implicitly-unwrapped
optional. If `AsyncStream`'s closure contract ever changes (or is called
zero times), the force-unwrap silently leaves `progressContinuation` nil and
crashes on first use.

```swift
// line 62
var continuation: AsyncStream<FlashProgress>.Continuation!
self.progressStream = AsyncStream<FlashProgress> { cont in
    continuation = cont
}
self.progressContinuation = continuation
```

**Suggested fix:** Use `AsyncStream.makeStream()` which returns the stream
and continuation together with no implicitly-unwrapped optional.

```swift
let (stream, continuation) = AsyncStream<FlashProgress>.makeStream()
self.progressStream = stream
self.progressContinuation = continuation
```

---

## M-2 `handleProgress` `@MainActor` hop is non-obvious

**Severity:** Medium
**File:** `Sources/AppUI/AppViewModel.swift` (lines 278-282)

The `Task` that consumes the progress stream inherits `@MainActor` from the
enclosing `@MainActor` context under Swift 6, so `handleProgress` runs on the
main actor. The inheritance is implicit and easy to break if the call site is
moved into a non-isolated context.

```swift
// lines 278-282
let progressTask = Task { [weak self, weak engine] in
    guard let engine else { return }
    for await progress in await engine.progressStream {
        self?.handleProgress(progress)   // @MainActor inferred, not declared
    }
}
```

**Suggested fix:** Annotate the Task body explicitly:
`Task { @MainActor [weak self, weak engine] in ... }` so the isolation is
stated rather than inferred.

---

## M-3 `Int(imageLength)` truncates images larger than `Int.max` on 32-bit hosts

**Severity:** Medium
**File:** `Sources/PrivilegedHelper/HelperService.swift` (line 163)

`groundTruthImageLength` returns `UInt64`. It is immediately narrowed to
`Int` for `imageSizeBytes`. On a 32-bit process (or a future port) any image
larger than 2 GB truncates silently, causing the safety check to under-count
available space.

```swift
// line 163
imageSizeBytes: Int(imageLength),   // UInt64 -> Int; silent truncation on 32-bit
```

**Suggested fix:** Use `Int64` or `UInt64` throughout the size path, or add
an explicit guard:

```swift
guard imageLength <= UInt64(Int.max) else {
    throw HelperError.imageTooLarge
}
```

---

## M-4 Time Machine detection misses some mount paths

**Severity:** Medium
**File:** `Sources/DiskModel/DiskEnumerator.swift` (lines 293-295)

Time Machine volumes are matched by three patterns: volume name prefix
`"Backups of"`, mount path prefix `/Volumes/.timemachine`, and mount path
prefix `/Volumes/com.apple.TimeMachine`. Apple has used additional paths
across OS versions (e.g. `/Volumes/MobileBackups`, local snapshots mounted
under `/System/Volumes/Data/.Snapshots`). A volume that does not match any
of the three patterns is not protected.

```swift
// lines 293-295
let isTimeMachine = volumeName.hasPrefix("Backups of")
    || (mountPoint?.hasPrefix("/Volumes/.timemachine") ?? false)
    || (mountPoint?.hasPrefix("/Volumes/com.apple.TimeMachine") ?? false)
```

**Suggested fix:** Add `/Volumes/MobileBackups` to the prefix list, and also
check `kDADiskDescriptionVolumeBrowsableKey == false` (non-browsable volumes
include most system-internal mounts and should be treated as protected).

---

## L-1 `baseAddress!` force-unwrap in read/write loops

**Severity:** Low
**Files:**
- `Sources/PrivilegedHelper/WriteJob.swift` (lines 238, 273)
- `Sources/PrivilegedHelper/VerifyJob.swift` (line 150)

`raw.baseAddress!` is force-unwrapped inside `withUnsafeMutableBytes` /
`withUnsafeBytes`. Safe in practice because the caller always passes a
buffer of at least 512 bytes, but the force-unwrap will crash on an
empty slice with no diagnostic.

**Suggested fix:** Replace with a `precondition` or `guard`:

```swift
guard let base = raw.baseAddress else {
    preconditionFailure("buffer must be non-empty")
}
```

---

## L-2 `passUnretained` C callback with no `deinit` unschedule

**Severity:** Low
**File:** `Sources/DiskModel/DiskEnumerator.swift` (lines 154, 386-399)

`armCallbacks` passes an unretained `self` pointer to the DA session (line
154). The C callbacks at lines 386-399 recover `self` with
`takeUnretainedValue`. If the `DiskEnumerator` is deallocated while the DA
session is still scheduled, the next callback dereferences a dangling pointer.

**Suggested fix:** Add a `deinit` that calls `DASessionUnscheduleFromRunLoop`
(or equivalent) before the object is freed. Alternatively switch to
`passRetained` + `release` in the callback so the DA session holds a
reference, though this requires a matching `release` on each callback path.

---

## L-3 Magic number 48 for `F_NOCACHE`

**Severity:** Low
**File:** `Sources/PrivilegedHelper/WriteJob.swift` (line 57)

`fNoCache` is set to the literal `48`. The value is stable on macOS and
equals `F_NOCACHE` in the Darwin headers, but it is not cross-checked at
compile time.

```swift
// line 57
static let fNoCache: Int32 = 48
```

**Suggested fix:** Import `Darwin` (already transitively available) and use
the SDK constant `Darwin.F_NOCACHE`, or add a compile-time assertion
`assert(fNoCache == Darwin.F_NOCACHE)` in the test suite to catch any
divergence.

---

## L-4 `emit` swallows encode errors; terminal result can be lost

**Severity:** Low
**File:** `Sources/PrivilegedHelper/HelperService.swift` (lines 433-438)

The `emit` helper uses `try?` and returns silently on encode failure (line
434). For progress events this is acceptable. For the terminal `FlashResult`,
a silent drop leaves the app side waiting on its continuation indefinitely.

```swift
// lines 433-438
private func emit<Value: Encodable>(_ value: Value, to sink: (Data) -> Void) {
    guard let data = try? HelperProtocolCoding.encode(value) else {
        return   // silent drop -- hangs caller if this was the terminal result
    }
    sink(data)
}
```

**Suggested fix:** For the terminal result call site, prefer a non-`try?`
encode with explicit error handling. On encode failure, synthesize a
fallback-encoded `FlashResult.failure` (using only primitive types that
cannot fail to encode) and deliver it to the sink so the caller always
receives a terminal event.

---

## Validated as correct

The following areas were reviewed and found to be correct; no changes are
needed.

- **Block alignment.** `BlockMath` correctly rounds image size up to the
  nearest block boundary and pads the write buffer accordingly.
- **Streaming-hash-excludes-padding invariant.** SHA-512 is computed over
  exactly the image bytes; padding bytes appended to reach block alignment
  are written to the device but not hashed. Verification re-reads only
  image-length bytes, so the digest comparison is consistent.
- **Cancellation correctness.** `CancellationToken` is checked at each major
  phase boundary (after safety re-check, after unmount, after write); a
  cancelled token causes an early return with a `cancelled` result, not a
  partial write silently labelled success.
- **Advisory-vs-truth contract.** `request.advisorySizeBytes` is labelled
  advisory and is used only for UI hints. `groundTruthImageLength` derives
  the authoritative size from the opened file descriptor, and that value
  drives both the safety check and the write loop. The two values are never
  conflated.
- **`O_RDWR | O_SYNC | O_EXCL` + `F_NOCACHE` rationale.** `O_EXCL` prevents
  two helpers from opening the same device concurrently; `O_SYNC` ensures
  each `write(2)` call blocks until the data reaches the device; `F_NOCACHE`
  bypasses the unified buffer cache so large writes do not evict application
  pages.
- **`DiskSafety` rule completeness.** The set of safety rules (size, system
  volume, Time Machine, internal disk, source overlap) covers all known
  dangerous target categories. The only confirmed gap is the source-overlap
  rule being permanently inert (see H-1 above).
