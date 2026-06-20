# Swift safety audit

Read-only sweep of all production Swift sources under `Sources/` (USBImagerCore,
AppUI, PrivilegedHelper, FlashEngine, DiskModel, Verifier, KeychainStore, the
USBImagerApp entry target, and the USBImagerCLI command targets). The codebase is
already disciplined: there are zero `try!`, zero `as!`, zero implicitly-unwrapped
optional declarations, and no `assert`, `precondition`, or `preconditionFailure`
in production code. The one `fatalError` guards a compile-time-constant code
signing requirement at app launch and is a sound programmer-error trap. The real
hazards cluster in two places that map to planned work: a UI source-selection
failure is swallowed into a `print` with no observable error surface
(WP-core-typed-errors), and several `try?` discards collapse a genuine error into
a silent "absent" result (most notably the Keychain trusted-cache lookup, which
can downgrade a checksum verdict). The remaining force-unwraps are guarded by
prior validation or by construction; the highest-value fixes are the UI error
surface and the Keychain lookup, then the two UTType force-unwraps in the file
importer.

## Findings

Severity ordering: blocker, high, medium, low. No blockers were found.

| Severity | File | Line | Snippet | Smallest sound fix |
| --- | --- | --- | --- | --- |
| high | Sources/AppUI/AppViewModel.swift | 232 | `print("[AppViewModel] selectSource: source missing/unreadable: ...")` then `return` | Set an observable typed error on the view model (e.g. a published `lastError: CoreError?` or a `.error` flash state) so the UI can render the failure; keep logging via `os.Logger`. The swallow-and-stay-on-step-1 path is invisible to the operator. |
| high | Sources/USBImagerCore/ChecksumService.swift | 132 | `let cached = try? keychainStore.lookup(sha512: deviceDigest, imageByteLength: imageByteLength)` | Distinguish a true miss (`nil`) from a Keychain access error. Catch the error explicitly; on a real failure return a dedicated outcome (or propagate) rather than silently resolving to `.noOfficialChecksum`, which can downgrade the verification verdict. |
| medium | Sources/AppUI/SourcePanel.swift | 57 | `.init(filenameExtension: "iso")!` | `UTType(filenameExtension:)` returns an optional. Use the static `UTType.diskImage` (or `[.diskImage, .data]`), or `compactMap` the constructed types, so an environment that fails to resolve the extension cannot crash the importer. |
| medium | Sources/AppUI/SourcePanel.swift | 58 | `.init(filenameExtension: "img")!` | Same fix as line 57: build the allowed-content-types array without a force-unwrap on an optional `UTType` initializer. |
| low | Sources/USBImagerApp/USBImagerApp.swift | 190 | `fatalError("Invalid code-signing requirement string: \(error)")` | Acceptable as-is: the requirement string is a compile-time constant and a malformed value is a build-time programmer error. If a softer failure mode is wanted, surface an inert "helper unavailable" view model instead of aborting. No change required for safety. |
| low | Sources/USBImagerCLI/Subcommands/FlashCommand.swift | 228 | `return result!` | Guarded by the semaphore happens-before: `result` is assigned before `signal()`. Optional hardening: `guard let value = result else { fatalError("runBlocking: result unset after signal") }`. CLI-only; not user-facing GUI state. |
| low | Sources/USBImagerCLI/Subcommands/ListCommand.swift | 94 | `return result!` | Same `runBlocking` pattern and same optional hardening as FlashCommand.swift:228. CLI-only. |
| low | Sources/USBImagerCLI/Subcommands/OpenCommand.swift | 110 | `return URL(string: urlString)!` | URL string is percent-encoded by construction, so the unwrap is practically safe. Hardening: build via `URLComponents` and `guard let url = components.url` to remove the force-unwrap. CLI-only. |
| low | Sources/Verifier/Digest.swift | 46 | `result.append(UInt8(byteString, radix: 16)!)` | Safe: all characters are validated against the hex `CharacterSet` and length-checked before the loop. The comment documents this. No change required; if desired, fold parsing into the validated guard to drop the `!`. |
| low | Sources/PrivilegedHelper/WriteJob.swift | 238 | `let base = raw.baseAddress!.advanced(by: total)` | Buffer is allocated at non-zero `chunkBytes` and the closure runs only while `total < count`, so `baseAddress` is non-nil. Idiomatic. Optional: `guard let base = raw.baseAddress else { ... }` for defense if a zero-length buffer is ever introduced. |
| low | Sources/PrivilegedHelper/WriteJob.swift | 273 | `let base = raw.baseAddress!.advanced(by: total)` | Same reasoning and optional fix as WriteJob.swift:238. |
| low | Sources/PrivilegedHelper/VerifyJob.swift | 150 | `let base = raw.baseAddress!.advanced(by: total)` | Same reasoning and optional fix as WriteJob.swift:238. |
| low | Sources/AppUI/AppViewModel.swift | 508 | `try? checksumService.saveTrustedCache(entry)` | Best-effort cache write; the comment notes duplicate-item is expected and other errors are non-fatal. Acceptable, but a logged `os.Logger` line on unexpected failures would aid diagnosis. |
| low | Sources/FlashEngine/FlashEngine.swift | 167 | `try? connection.cancel(jobID: jobID)` | Best-effort cancel; the job still terminates via its own result callback if the XPC send fails. Acceptable. A debug log on the discarded error would help diagnosis. |
| low | Sources/PrivilegedHelper/HelperService.swift | 520 | `guard let jobID = try? HelperProtocolCoding.decode(JobID.self, ...)` | Fire-and-forget cancel decode; the authoritative outcome still flows through the job reply. Acceptable as documented. |
| low | Sources/FlashEngine/HelperConnection.swift | 151 | `guard let progressValue = try? HelperProtocolCoding.decode(FlashProgress.self, ...)` | Non-terminal progress update; dropping a malformed one is safe and documented. Acceptable. |
| low | Sources/PrivilegedHelper/HelperService.swift | 605 | `guard let data = try? HelperProtocolCoding.encode(value) else { return }` | Non-terminal control message (`emit`); the terminal result uses `emit(terminal:)` with a guaranteed fallback. Acceptable as documented. |
| low | Sources/PrivilegedHelper/HelperService.swift | 616, 630 | `if let data = try? HelperProtocolCoding.encode(result)` / fallback encode | Terminal emit with an always-encodable primitive fallback so the caller's continuation never hangs. Sound design. Acceptable. |
| low | Sources/USBImagerCore/Services.swift | 311 | `try? handle.close()` (in `defer`) | Idiomatic best-effort cleanup of a read handle in a defer. Acceptable; no change. |
| low | Sources/DiskModel/DiskEnumerator.swift | 362, 412 | `guard let ... = try? url.resourceValues(...)` / `contentsOfDirectory(...)` | Enumeration probes where an unreadable volume legitimately means "skip this entry." Acceptable; the absent result is the correct semantics here. |

## Maps to which work package

- WP-core-typed-errors (observable error surface): the two high findings drive
  this. AppViewModel.swift:232 must replace the `print`-and-`return` swallow with
  an observable typed error so a missing or unreadable source surfaces to the UI.
  ChecksumService.swift:132 must stop collapsing a Keychain access failure into a
  cache miss, since that can silently downgrade a verification outcome. The
  low-severity `try?` discards (AppViewModel.swift:508, FlashEngine.swift:167) are
  candidates for the same surface plus logging once the typed-error path exists.
- WP-forceunwrap-audit (replace unsafe force-unwraps): the two medium SourcePanel
  UTType unwraps (lines 57-58) are the only force-unwraps in GUI code that touch a
  genuinely optional API and should be replaced with `UTType.diskImage` or a
  `compactMap`. The remaining force-unwraps (Digest.swift:46, the three helper
  `baseAddress!` sites, the CLI `result!`/`URL!` sites) are guarded by validation,
  buffer sizing, or construction and are low priority; convert them to guarded
  forms opportunistically when those files are next edited.
- WP-logger (replace print() with os.Logger): the AppViewModel.swift:232 and the
  USBImagerApp handoff/auto-exit `print` calls are out of scope for this safety
  audit's findings table but reinforce the same gap; the error-bearing `print` at
  AppViewModel.swift:232 should become a typed error plus an `os.Logger` line.

## Finding counts per severity

- blocker: 0
- high: 2
- medium: 2
- low: 15
- total: 19
