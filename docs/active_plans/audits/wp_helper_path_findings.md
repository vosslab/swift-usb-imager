# WP-helper-path findings

Investigation-only finding gating milestone M1 of the plan
`immutable-spinning-sifakis`. No production code, tests, `Package.swift`, or
plists were modified. Every claim below cites `file:line` evidence collected by
reading the sources and running the verification commands in the appendix.

Bottom line: the plan's review evidence holds. The privileged flash path is not
wired to run. The plan's M1 build shape is correct as written, with one
important refinement -- the repo already ships a full SMAppService packaging
runbook in [../../SIGNING.md](../../SIGNING.md), which resolves the plan's
helper-packaging open question and pins the exact daemon location, plist name,
and Mach service name. WP-daemon-main and WP-smappservice should follow that
existing doc rather than re-deriving the layout.

## Verification commands run

- `grep -rn "NSXPCListener\|SMAppService\|_ = peerRequirement" Sources`
- `swift build` (clean: `Build complete! (1.14s)`)
- Targeted `grep`/`ls` and Read-tool inspection of the files cited below.

The only `NSXPCListener` hit in `Sources` is absent (zero matches for the
listener). `SMAppService` appears only inside doc comments, never as code. The
`_ = peerRequirement` discard appears once. See the appendix for the raw
output.

## Point-by-point confirmation

### PrivilegedHelper is an empty enum with no daemon entry

CONFIRMED. `Sources/PrivilegedHelper/PrivilegedHelper.swift:19` is
`public enum PrivilegedHelper {}`. Its doc comment
(`Sources/PrivilegedHelper/PrivilegedHelper.swift:16`) states running as root
"requires code signing and SMAppService installation, which is out of scope for
this milestone".

### No main.swift, no NSXPCListener in PrivilegedHelper

CONFIRMED. The directory listing of `Sources/PrivilegedHelper/` holds only:
`BlockMath.swift`, `CancellationToken.swift`, `HelperAuthorization.swift`,
`HelperErrors.swift`, `HelperSafety.swift`, `HelperService.swift`,
`PrivilegedHelper.swift`, `Unmount.swift`, `VerifyJob.swift`, `WriteJob.swift`.
There is no `main.swift`. The repo-wide grep for `NSXPCListener` returns zero
matches in any source file. `HelperService.production(requirement:)` exists
(`Sources/PrivilegedHelper/HelperService.swift:145`) and is ready to be vended,
but nothing constructs a listener that would set it as an `exportedObject`.

### Package.swift target list

CONFIRMED. `PrivilegedHelper` is a plain `.target` (library), declared as a
product at `Package.swift:18` (`.library(name: "PrivilegedHelper", ...)`) and as
a target at `Package.swift:52-56`. No executable helper/daemon target exists.

Actual products (`Package.swift:12-24`):

- Libraries: `DiskModel`, `HelperProtocol`, `Verifier`, `KeychainStore`,
  `FlashEngine`, `PrivilegedHelper`, `USBImagerCore`, `AppUI`.
- Executables: `USBImagerApp` (target `USBImagerApp`), `usbimager` (target
  `USBImagerCLI`), `USBImagerShots` (target `USBImagerShots`).

Targets (`Package.swift:28-151`): the eight libraries above, three executable
targets (`USBImagerApp`, `USBImagerCLI`, `USBImagerShots`), and nine test
targets. The only executables are the two front ends plus the screenshot
harness; there is no daemon executable target.

### App-side peerRequirement discard

CONFIRMED. `Sources/FlashEngine/HelperConnection.swift:120` reads
`_ = peerRequirement  // retained; used when peer-check wiring lands.`. The
`XPCHelperConnection.init` stores `peerRequirement`
(`Sources/FlashEngine/HelperConnection.swift:102`) but never installs an
`auditTokenBlock` / `setCodeSigningRequirement` enforcement on the
`NSXPCConnection`; the connection resumes
(`Sources/FlashEngine/HelperConnection.swift:122`) with no peer pinning. The
app therefore does not verify the helper's identity today.

### Token-less authorize() in the helper

CONFIRMED. `HelperService.runFlashPipeline` calls `try authorization.authorize()`
with no audit token at `Sources/PrivilegedHelper/HelperService.swift:228`, and
`runVerifyOnly` does the same at
`Sources/PrivilegedHelper/HelperService.swift:463`. `authorize()` delegates to
`authorize(auditToken: nil)`
(`Sources/PrivilegedHelper/HelperAuthorization.swift:169-171`). Under the
production `pinning` gate this fail-closes: a `nil` token returns
`.invalid(status: errSecCSNoSuchCode)`
(`Sources/PrivilegedHelper/HelperAuthorization.swift:128-129`), so every request
would be denied. The default service uses `allowAll`
(`Sources/PrivilegedHelper/HelperService.swift:128`), which is why the
in-process pipeline tests pass; the production gate cannot work until the live
peer audit token is threaded into `authorize(auditToken:)`.

### SMAppService references in Sources

CONFIRMED (as documentation only). Grep shows `SMAppService` only inside doc
comments: `Sources/USBImagerApp/USBImagerApp.swift:39,57`,
`Sources/USBImagerCore/XPCFlashEngineFactory.swift:14,33`,
`Sources/FlashEngine/HelperConnection.swift:80,96`,
`Sources/PrivilegedHelper/PrivilegedHelper.swift:16`, and
`Sources/HelperProtocol/HelperProtocol.swift:2`. No call to
`SMAppService.daemon(...)`, `.register()`, or `.unregister()` exists in any
source file.

### App-side XPC connection setup and Info.plist

CONFIRMED. `USBImagerApp` builds the connection directly in its `@State`
initializer (`Sources/USBImagerApp/USBImagerApp.swift:182-197`): it constructs
a `CodeSigningRequirement` from `helperRequirementString`
(`Sources/USBImagerApp/USBImagerApp.swift:59-63`), then a
`XPCHelperConnection(machServiceName:peerRequirement:)`
(`Sources/USBImagerApp/USBImagerApp.swift:192-195`), and hands it to
`AppViewModel`. There is no `SMAppService.register()` call, so the app never
installs the daemon before opening the connection.

`Sources/USBImagerApp/Info.plist` is the bundle plist consumed by
`build_debug.sh` (excluded from SwiftPM build resources,
`Package.swift:73-76`). It declares `CFBundleIdentifier` `com.nsh.usbimager`
(`Sources/USBImagerApp/Info.plist:7-8`) and the `usbimager` URL scheme
(`Sources/USBImagerApp/Info.plist:21-31`). It does NOT yet declare
`SMPrivilegedExecutables` or any helper/launchd keys; those are specified in
`docs/SIGNING.md` (section below) but not yet present in this committed plist.

### Current runtime failure mode when a flash is attempted

CONFIRMED, with the precise mechanism. The failure surfaces as a runtime
`FlashEngineError.connectionFailed` mapped to a flash-failed outcome, NOT the
exit-code-3 `helperUnavailable` path. The trace:

1. Front ends use the real factory: the CLI defaults to `XPCFlashEngineFactory()`
   (`Sources/USBImagerCLI/Usbimager.swift:93`); the GUI builds an
   `XPCHelperConnection` directly and wraps it in `FlashEngine`
   (`Sources/AppUI/AppViewModel.swift:126`,
   `Sources/USBImagerApp/USBImagerApp.swift:192-196`).
2. `XPCFlashEngineFactory.makeEngine()` only fails synchronously if the
   requirement STRING is malformed (`Sources/USBImagerCore/XPCFlashEngineFactory.swift:90-105`).
   The shipped string is valid, so `makeEngine()` SUCCEEDS and returns a live
   engine; the `CoreError.helperUnavailable` (CLI exit 3) path is NOT taken for a
   merely missing helper. The exit-3 path belongs to
   `HelperUnavailableEngineFactory` (`Sources/USBImagerCore/HelperUnavailableEngineFactory.swift:19-30`),
   which the front ends do not select by default.
3. `XPCHelperConnection.init` resumes the connection but defers the Mach lookup
   (`Sources/FlashEngine/HelperConnection.swift:104-123`).
4. On `engine.flash(...)` the connection calls
   `remoteObjectProxyWithErrorHandler`
   (`Sources/FlashEngine/HelperConnection.swift:143-147`); when the Mach service
   `com.nsh.usbimager.helper` is not registered (no daemon installed), the XPC
   error handler fires `resultCallback(.failure(.connectionFailed(...)))`
   (`Sources/FlashEngine/HelperConnection.swift:144`).
5. `FlashEngine.flash` rethrows that `FlashEngineError`
   (`Sources/FlashEngine/FlashEngine.swift:151-152`).
6. `DefaultFlashOrchestrationService` catches it as a `FlashEngineError`
   (`Sources/USBImagerCore/FlashOrchestrationService.swift:118-119`) and
   `resultForEngineError` maps every non-`.cancelled` engine error to
   `.failure(.flashFailed(message:))`
   (`Sources/USBImagerCore/FlashOrchestrationService.swift:191-199`).

Net: with no installed helper, a flash attempt fails at first proxy use as
`connectionFailed` -> `flashFailed` (CLI exit code 4, "flash failed"), reaching
this only after the engine is built. This matches the plan's "Current state
summary" line: "`makeEngine()` connects lazily so a missing helper surfaces as a
runtime `FlashEngineError` -> `.flashFailed`". The plan's phrasing is accurate;
the exit code for the no-helper case is 4 (flash failed), not 3.

### SMAppService helper location and launchd plist expectations

CONFIRMED against current Apple docs AND, more usefully, against an existing
in-repo runbook. The repo already ships [../../SIGNING.md](../../SIGNING.md),
which documents the canonical SMAppService bundled-daemon layout. This resolves
the plan's "helper packaging" open question without external research:

- Helper executable location:
  `Contents/Library/LaunchDaemons/com.nsh.usbimager.helper` inside the app
  bundle (`docs/SIGNING.md:206-239`). This is the standard SMAppService bundled
  LaunchDaemon location.
- launchd plist: `Contents/Library/LaunchDaemons/com.nsh.usbimager.helper.plist`,
  with `Label` = `com.nsh.usbimager.helper`, a `MachServices` entry for the same
  name, and `BundleProgram` =
  `Contents/Library/LaunchDaemons/com.nsh.usbimager.helper` relative to the
  bundle root (`docs/SIGNING.md:189-213`).
- `SMAppService.daemon(plistName: "com.nsh.usbimager.helper.plist")` then
  `register()` from the app (`docs/SIGNING.md:383-400`).
- App Info.plist must add `SMPrivilegedExecutables` keyed by the helper bundle ID
  with the helper's designated requirement (`docs/SIGNING.md:94-102`); the
  committed `Sources/USBImagerApp/Info.plist` does not yet carry this.

This matches Apple's `SMAppService` class reference and "Signing a daemon with a
restricted entitlement" guidance, which `docs/SIGNING.md:468-471` already cites.

## Per-flash on-demand background task (nothing runs when the app is closed)

Hard constraint from the user, stronger than "on-demand": the privileged helper
is a PER-FLASH BACKGROUND TASK, not a daemon. It is launched only for the
duration of a single flash and exits as soon as that flash (or its XPC
connection) ends. Nothing privileged may remain running once the app is closed.
This refines only the launch/lifecycle and teardown shape; the security contract
(`HelperService.production`, `HelperAuthorization.pinning`,
`CodeSignatureValidator`) is unchanged.

Frame all guidance below as "on-demand background task launched per flash," not
"daemon." The word "daemon" appears in this finding only where it names the
unavoidable launchd/SMAppService API surface (`SMAppService.daemon(plistName:)`,
`Contents/Library/LaunchDaemons`), because those are the literal Apple symbols.

### Two distinct things: the process vs. the launchd registration

The "nothing runs when app closed" guarantee has two parts, and they fail
differently, so M1 must handle both:

1. The privileged PROCESS. This is already ephemeral in the shape the repo
   documents. The launchd plist in `docs/SIGNING.md:189-210` declares only
   `Label`, `MachServices`, and `BundleProgram`, with NO `KeepAlive` and NO
   `RunAtLoad`. A `MachServices` entry with neither key is precisely launchd's
   on-demand activation: launchd advertises the Mach service, spawns the helper
   process only when the first XPC message arrives, and reaps it when it goes
   idle. So the process is not resident between flashes and is not resident while
   the app sits idle. WP-smappservice must KEEP the plist minimal and NOT add
   `KeepAlive`/`RunAtLoad`; WP-daemon-main must NOT add a self-keep-alive.

2. The launchd REGISTRATION. This is the part that, left alone, violates the
   user's hard requirement. `SMAppService.daemon(...).register()`
   (`docs/SIGNING.md:383-400`) installs a PERSISTENT launchd registration that
   survives app quit and reboot until something unregisters it. The registration
   is not a running process -- with the on-demand plist above, `ps` shows nothing
   privileged when no flash is active -- but the SERVICE remains installed and
   would relaunch the helper on the next XPC connection even after the app has
   quit. To honor "nothing privileged remains after the app quits" in the
   strongest sense (no resident process AND no latent installed service), the app
   must tear the registration down on termination.

### Plainly: the only sanctioned root raw-disk route still registers a launchd service

There is no macOS 26 API that grants root for a raw whole-disk write WITHOUT
registering a launchd-managed helper. SMAppService is Apple's current sanctioned
route and is what the repo targets; the deprecated `SMJobBless` /
`AuthorizationExecuteWithPrivileges` one-shot routes are not a supported
alternative. A `SMAppService.loginItem` agent is ruled out on a different axis:
login items run as the USER, not root, so they cannot perform raw disk writes at
all. So the helper must be a root SMAppService `daemon`-class service. The way to
make it behave as an ephemeral per-flash background task rather than a persistent
daemon is the combination of three settings, all of which M1 owns:

- On-demand start: `MachServices` with no `RunAtLoad` (launchd starts the helper
  only on first XPC message). Already in the documented plist.
- Exit-when-idle: no `KeepAlive` (launchd reaps the helper when the connection
  closes and it goes idle). Already in the documented plist.
- App-quit teardown: the app calls `SMAppService.daemon(plistName:
  "com.nsh.usbimager.helper.plist").unregister()` when it terminates, so the
  registration does not outlive the app. `docs/SIGNING.md:410-413` already
  documents the `unregister()` call (currently only as a dev cleanup step); M1
  should also invoke it from the app's termination path.

### How to guarantee nothing remains after the app quits

Recommended belt-and-suspenders shape (both, not either):

- Helper exits on connection invalidation. In WP-daemon-main, the listener
  delegate's accepted `NSXPCConnection` sets an `invalidationHandler` (and
  `interruptionHandler`) that, once no job is in flight, terminates the helper
  process (e.g. `exit(0)` after the last connection drops). This makes the
  process exit promptly when the app closes the connection, rather than waiting
  for launchd's idle reaping. It must NOT terminate mid-flash: gate the exit on
  no active job (the existing `TokenRegistry` already tracks live jobs, so the
  daemon main can check for an empty registry before exiting).
- App unregisters the helper on termination. The current app has no termination
  teardown: `Sources/USBImagerApp/USBImagerApp.swift:170` only calls
  `NSApplication.shared.terminate(nil)` and there is no
  `applicationWillTerminate` hook anywhere in the app. WP-smappservice should add
  an `NSApplicationDelegate.applicationWillTerminate` (or a SwiftUI termination
  observer) that calls `SMAppService.daemon(plistName:).unregister()` so the
  privileged service is removed when the app quits. (Trade-off the manager should
  weigh: unregister-on-quit means the next launch re-registers and the user is
  re-prompted for approval each session. If that prompt-every-launch cost is
  unacceptable, the fallback is to keep the registration but rely on parts 1-2 so
  no PROCESS runs between sessions; the user's stated requirement is "nothing
  running when app closed," which parts 1-2 already satisfy at the process level.
  Flag this as an explicit decision rather than silently choosing.)

### Verification the user can run

To confirm nothing privileged is resident after quitting the app:

- `ps -Ao user,pid,comm | grep -i usbimager` -- expect no root-owned helper
  process when no flash is running and after the app quits.
- `launchctl print system/com.nsh.usbimager.helper` -- with on-demand settings
  this shows the service as loaded-but-not-running between flashes; after an
  app-quit `unregister()` it should report the service is not found.
- `sfltool dumpbtm` -- lists SMAppService Background Task Manager registrations;
  after `unregister()` on quit, the helper should not appear. (`docs/SIGNING.md`
  already lists `sfltool dumpbtm` and `launchctl list | grep nsh` as the dev
  status checks.)

### WP-daemon-main run-loop note

The daemon `main` creates `NSXPCListener(machServiceName:
"com.nsh.usbimager.helper")`, sets its delegate, `resume()`s it, and parks on the
run loop to service the connection -- with NO artificial keep-alive (no timer, no
`KeepAlive`/`RunAtLoad`, no idle work). The only lifecycle code it adds is the
connection `invalidationHandler` that exits the process once the last connection
drops and no job is active (part 1 above). Letting the process exit on idle IS
the per-flash background-task behavior.

## Expected Mach service name and bundle identity

- Mach service name: `com.nsh.usbimager.helper`. CONFIRMED consistent across the
  two source constants (`Sources/USBImagerCore/XPCFlashEngineFactory.swift:38`,
  `Sources/USBImagerApp/USBImagerApp.swift:59`), the helper bundle ID and
  launchd `Label` in `docs/SIGNING.md:55-57`, and the existing app bundle ID
  prefix `com.nsh.usbimager` (`Sources/USBImagerApp/Info.plist:8`). The plan's
  recommendation to keep `com.nsh.usbimager.helper` is correct: the `com.nsh`
  prefix is already in use in committed Info.plist and docs.
- Helper bundle ID: `com.nsh.usbimager.helper` (`docs/SIGNING.md:55`).
- launchd plist name: `com.nsh.usbimager.helper.plist` (`docs/SIGNING.md:57`).

## Recommended helper packaging shape

Recommend the SMAppService bundled-helper shape the repo already documents, run
as a PER-FLASH ON-DEMAND BACKGROUND TASK, not a persistent daemon (see the
lifecycle section above): a root helper executable embedded at
`Contents/Library/LaunchDaemons/com.nsh.usbimager.helper` (Apple's literal bundle
path) with its minimal, `KeepAlive`/`RunAtLoad`-free launchd plist alongside,
registered by the app via `SMAppService.daemon(plistName:
"com.nsh.usbimager.helper.plist")`. launchd starts the helper only when the XPC
Mach-service connection arrives, the helper exits when the connection drops and no
job is active, and the app unregisters the service on quit so nothing privileged
(process or installed service) remains once the app is closed.

For the SwiftPM build, this means adding ONE new `.executableTarget` for the
daemon (e.g. a new `Sources/PrivilegedHelperDaemon/main.swift` target, or a
`main.swift` added under a renamed executable target) that depends on the
existing `PrivilegedHelper` library and starts an `NSXPCListener(machServiceName:
"com.nsh.usbimager.helper")` whose `exportedObject` is
`HelperService.production(requirement:)`. Keeping `PrivilegedHelper` as a library
and adding a thin daemon executable on top of it is the cleanest split: the
library stays unit-testable as it is today, and the executable target is just the
listener wiring. `build_debug.sh` (and `build_release.sh`) then copy that built
executable plus the launchd plist into
`Contents/Library/LaunchDaemons/` per `docs/SIGNING.md:217-240`.

Note: `Package.swift` cannot itself place the executable inside the `.app`
bundle's `Contents/Library/LaunchDaemons/`; SwiftPM only builds the binary. The
bundle assembly is a build-script step, mirroring how `Info.plist` is already
handled outside SwiftPM (`Package.swift:73-76`, `build_debug.sh`). WP-smappservice
must extend the build script accordingly; this is consistent with the plan's
WS-smappservice touch points.

## Is the plan's M1 build shape correct?

Yes, with refinements rather than corrections. The ordering
WP-daemon-main -> WP-accept-gate -> WP-token-thread, plus WP-app-pin and
WP-smappservice, is sound and matches the evidence:

- WP-daemon-main (new executable + `NSXPCListener` vending
  `HelperService.production`) is exactly what is missing; the production factory
  already exists (`Sources/PrivilegedHelper/HelperService.swift:145`).
- WP-accept-gate (`shouldAcceptNewConnection` reading `auditToken`,
  `CodeSignatureValidator.evaluate`) is buildable now: the validator is complete
  and unit-testable (`Sources/PrivilegedHelper/HelperAuthorization.swift:123-141`).
- WP-token-thread (thread the live token into `authorize(auditToken:)`) is the
  correct fix for the confirmed token-less calls
  (`Sources/PrivilegedHelper/HelperService.swift:228,463`); the
  `authorize(auditToken:)` entry point already exists
  (`Sources/PrivilegedHelper/HelperAuthorization.swift:177-181`).
- WP-app-pin (enforce `peerRequirement`, remove the `_ = peerRequirement`
  discard) targets the confirmed discard
  (`Sources/FlashEngine/HelperConnection.swift:120`).
- WP-smappservice (Info.plist `SMPrivilegedExecutables`, launchd plist,
  `docs/INSTALL.md`) is correct in intent.

Refinements for the manager to fold into M1:

1. WP-smappservice should reuse the existing `docs/SIGNING.md` runbook as the
   source of truth for the daemon location, plist name, `SMPrivilegedExecutables`
   block, and registration call, instead of treating packaging as an open
   question. The plan's open question (helper packaging route) is effectively
   already answered in-repo. INSTALL/USAGE doc updates can cross-reference
   `docs/SIGNING.md` rather than restate it.
2. WP-daemon-main's stated touch point "new
   `Sources/PrivilegedHelper/main.swift` (daemon target)" needs a small
   adjustment: a single SwiftPM target cannot be BOTH a library product
   (`PrivilegedHelper`, depended on by tests) and an executable with a
   `main.swift`. The daemon `main.swift` belongs in a NEW executable target that
   depends on the `PrivilegedHelper` library, leaving the library importable by
   `PrivilegedHelperTests`. Otherwise the existing
   `PrivilegedHelperTests` target (`Package.swift:126-130`) breaks.
3. The no-helper runtime failure is exit code 4 (flash failed via
   `connectionFailed`), not exit code 3 (`helperUnavailable`). The plan's prose
   already says `.flashFailed`; any M1 "connection-failure" exit-code test should
   assert the flash-failed mapping, not exit 3. The exit-3 `helperUnavailable`
   path is reachable only through `HelperUnavailableEngineFactory`, which the
   front ends do not use by default.
4. Per-flash background task, nothing resident after quit (per the hard user
   constraint): the helper is a per-flash on-demand background task, not a
   persistent daemon. Three settings deliver this, split across M1 work packages:
   (a) on-demand start + exit-when-idle -- the `docs/SIGNING.md` plist is already
   `KeepAlive`/`RunAtLoad`-free, so WP-smappservice keeps it that way and
   WP-daemon-main adds no self-keep-alive; (b) prompt process exit --
   WP-daemon-main's listener sets a connection `invalidationHandler` that exits
   the helper once the last connection drops and no job is active (gate on the
   existing `TokenRegistry`); (c) app-quit teardown -- WP-smappservice adds an
   `applicationWillTerminate` hook calling
   `SMAppService.daemon(plistName:).unregister()` (the app currently has NO
   termination teardown -- `Sources/USBImagerApp/USBImagerApp.swift:170` only
   calls `terminate(nil)`). The unavoidable SMAppService registration is the one
   thing that otherwise outlives the app; (c) removes it. Flag the
   re-prompt-each-launch trade-off of (c) as an explicit manager decision. See
   the "Per-flash on-demand background task" section above for the full rationale
   and the `ps`/`launchctl print`/`sfltool dumpbtm` verification commands.

## Residual risks and open questions for the manager

- The committed `Sources/USBImagerApp/Info.plist` lacks `SMPrivilegedExecutables`
  and the helper designated requirement. WP-smappservice must add these; the real
  DR string can only be finalized after the helper is signed once
  (`docs/SIGNING.md:97-101`), so the automated M1 gate must use the documented
  placeholder/test-seam DR, with the real DR a release-time step. This matches the
  plan's risk register ("No Developer ID cert blocks M1 manual gate").
- `HelperService.production(...)` takes an optional `sourceBackingBSDName`
  (`Sources/PrivilegedHelper/HelperService.swift:145-155`). The daemon main must
  decide what to pass; the helper already falls back to the request-carried
  `sourceBackingBSDName` (`Sources/PrivilegedHelper/HelperService.swift:246`), so
  passing `nil` from the daemon is safe and is the recommended default.
- The bundle-assembly step (copying the daemon binary + plist into
  `Contents/Library/LaunchDaemons/`) lives in the shell build scripts, outside
  SwiftPM and outside `swift build`/`swift test`. The automated M1 gate can verify
  the daemon target builds and vends the interface, but it cannot verify the
  bundled layout without running the build script; that bundling check should be a
  scripted smoke step, not a unit test.

## Appendix: key command output

`grep -rn "NSXPCListener\|SMAppService\|_ = peerRequirement" Sources` (matches,
all SMAppService hits are doc comments; zero NSXPCListener; one peerRequirement
discard):

```
Sources/README.md:22:- `PrivilegedHelper/` - SMAppService LaunchDaemon root helper. Signed separately
Sources/HelperProtocol/HelperProtocol.swift:2: ... privileged SMAppService root LaunchDaemon helper ...
Sources/USBImagerApp/USBImagerApp.swift:39: ... Replace `helperMachServiceName` with the final SMAppService daemon name
Sources/USBImagerApp/USBImagerApp.swift:57: ... Mach service name registered by the privileged helper via SMAppService.
Sources/USBImagerCore/XPCFlashEngineFactory.swift:14: ... service name the helper registers via `SMAppService` ...
Sources/USBImagerCore/XPCFlashEngineFactory.swift:33: ... Mach service name registered by the privileged helper via `SMAppService`.
Sources/FlashEngine/HelperConnection.swift:80: ... Mach service name registered by the helper's `SMAppService` daemon.
Sources/FlashEngine/HelperConnection.swift:96: ... `SMAppService.daemon(plistName:)`, e.g.
Sources/FlashEngine/HelperConnection.swift:120:        _ = peerRequirement  // retained; used when peer-check wiring lands.
```

`swift build`: `Build complete! (1.14s)`.
