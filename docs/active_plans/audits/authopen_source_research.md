# authopen source research

Source-tiered research backing the raw-disk-write model spike (plan task A3, S2/S5).
This audit gathers evidence for adopting `authopen` fd-passing as the least-persistent
privileged backend, with SMAppService as the documented fallback. It feeds the decision
record at `docs/active_plans/decisions/raw_disk_write_model.md` (S5).

Evidence is separated by source class so the reader can weigh it. A "2026 writeup" is not
Apple guidance. The tiers, strongest first:

- Tier 1: Apple official documentation (developer.apple.com/documentation, archived guides).
- Tier 2: Apple DTS forum posts (developer.apple.com/forums, Quinn "The Eskimo!" and peers).
- Tier 3: man pages (the Xcode-distributed `authopen.1`, authoritative for tool behavior).
- Tier 4: third-party experiments and writeups (GitHub issues, community blogs).

Plan reference: `immutable-spinning-sifakis.md`, task A3. Cross-references the repo signing
runbook at [../../SIGNING.md](../../SIGNING.md).

## Caveat on tier mixing

The plan adopts authopen as the candidate default, but the evidence base is uneven. The
strongest authopen evidence is Tier 3 (man page) plus a single Tier 2 DTS sentence; there is
no Tier 1 Apple documentation that endorses authopen for app distribution. SMAppService, by
contrast, has full Tier 1 documentation. The hardware spike (B1-B3) must supply the missing
direct-observation evidence before authopen is relied on for the shipping context. Do not
present the Tier 3/Tier 4 authopen findings below as Apple endorsement of the model.

## 1. authopen fd-passing

### 1.1 Tier 3 (man page): authopen.1 behavior

Source: `authopen(1)`, Xcode-distributed man page
([keith.github.io mirror](https://keith.github.io/xcode-man-pages/authopen.1.html); also
[phracker MacOSX-SDKs copy](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.13.sdk/usr/share/man/man1/authopen.1)).
The local copy on the test Mac is authoritative; see the capture checklist in section 5.

- `-stdoutpipe`: STDOUT_FILENO has been `dup2()`'d onto a pipe to the parent process, and an
  open file descriptor to the target (with the appropriate access mode) is sent back across
  it using the `SCM_RIGHTS` extension to `sendmsg(2)`, rather than the file being written to
  or read from stdin/stdout. This is the fd-passing path the plan depends on (H1).
- `-o flags`: numerically specifies the flags passed to `open(2)`. This lets the caller set
  the exact open mode (the plan's first tested set is `O_RDWR | O_EXCL | O_SYNC`).
- `-w`: opens the target read/write AND truncates it. Truncate is the wrong semantic for a
  raw block device, which confirms the plan's choice of explicit `-o` flags over `-w`.
- `-x`: requires that the file being created does not already exist.
- Authorization rights are fully qualified with the target path appended. The three families
  are `sys.openfile.readonly.*`, `sys.openfile.readwrite.*`, and
  `sys.openfile.readwritecreate.*`. For a raw device write the right is therefore
  `sys.openfile.readwrite./dev/rdiskN` (path-specific, per the plan).
- HISTORY: "authopen appeared in Mac OS X 10.1 to assist with the manipulation of disk
  devices." Raw-disk work is its original purpose, supporting the plan's framing.
- BUGS: the man page notes authopen "should support prefix path authentication" (so a right
  like `sys.openfile.readwrite./dev/` could cover all `/dev` entries) and "should use
  getopt(3)." Prefix authentication is listed as a wished-for, not guaranteed, behavior; do
  not assume a prefix right works without testing the exact right string on hardware.

### 1.2 Tier 2 (Apple DTS): the single authopen endorsement and its narrow scope

Source: "BSD Privilege Escalation on macOS", Apple Developer Forums thread
[708765](https://developer.apple.com/forums/thread/708765), Quinn "The Eskimo!" (Apple DTS).

This is the load-bearing Tier 2 evidence, and it is thinner than the plan's framing implies.

- The thread's revision history records: "2025-03-24 Added info about `authopen` and
  `osascript`." This is the DTS update the plan refers to.
- The only authopen mention is in an interactive-use context: "If you're working
  interactively on the command line, use `sudo`, `authopen`, and `osascript` as you see
  fit." DTS frames authopen as an interactive command-line convenience, NOT as a sanctioned
  building block for a distributed GUI app. This is a meaningful caveat for S5: the plan's
  authopen-as-default rests on the man page plus this interactive-only endorsement, not on
  any Apple statement that authopen is appropriate for shipping apps.
- The thread does NOT mention `/usr/libexec/authopen` for `/dev/rdisk` specifically, does NOT
  state that launchd-run root helpers are denied raw block-device opens that the same binary
  performs under sudo, and does NOT discuss EPERM vs EACCES (that lives in the file-system
  permissions thread, section 4). The plan's "launchd root helper denied raw open" claim is
  not corroborated by this thread and should be treated as UNVERIFIED until B1 observes it.
- DTS ranking in the same thread, paraphrased: never use setuid-root; for interactive CLI use
  sudo/authopen/osascript; for ad hoc one-shot use `AuthorizationExecuteWithPrivileges`
  (personal use only); for one-shot in distributed products `SMJobSubmit` (deprecated but
  stable via Sparkle); for install-only use a `.pkg`; for ongoing privileges use SMAppService
  (macOS 13+) or SMJobBless (older). Note authopen does not appear in the distributed-product
  branch of this ranking.

### 1.3 Tier 4 (third-party): rpi-imager raw-disk authopen behavior

Source: Raspberry Pi Imager GitHub issues
[#469](https://github.com/raspberrypi/rpi-imager/issues/469) and
[#270](https://github.com/raspberrypi/rpi-imager/issues/270). Third-party experiments; not
Apple guidance.

- rpi-imager uses authopen to obtain raw `/dev/rdiskN` access on macOS, confirming the model
  is used in shipping third-party software. The exact flag string is not disclosed in these
  issues.
- Issue #270 shows the failure mode that matters most for exclusivity (S3/H6):
  `authopen: couldn't open /dev/rdisk2: Resource busy` and `authopen returned failure code 1`.
  The reported fix was to unmount the volume/APFS container first (via Disk Utility). This is
  Tier 4 corroboration that the target must be UNMOUNTED before an exclusive raw open
  succeeds, and that "Resource busy" (EBUSY) is the practical blocker, distinct from a
  permission error. It directly informs the plan's `O_EXCL`-vs-unmount tradeoff: unmount
  first, then the exclusive open can proceed.
- Issue #469: an authopen failure on `/dev/rdisk2` persisted even with Full Disk Access
  granted to the app, suggesting the busy/exclusivity problem is separate from the TCC grant.
  Treat as anecdotal (older macOS 11.x); confirm on macOS 26 in B1/B3.

### 1.4 Reconciliation: "no path lighter than an SMAppService daemon" vs authopen

A prior investigation concluded that "there is no sanctioned macOS 26 API that grants root for
raw whole-disk writes WITHOUT registering a launchd service (SMAppService daemon); SMJobBless
and AuthorizationExecuteWithPrivileges are deprecated; a login item runs as the user." That
conclusion did NOT consider authopen. This subsection reconciles the two head-on, because it
is the entire authopen-vs-SMAppService crux for the decision record.

The factual gap in the prior conclusion: `/usr/libexec/authopen` returns a privileged
(write-capable) file descriptor for `/dev/rdiskN` via Authorization Services WITHOUT
registering any launchd service. There is no daemon, no background item, no `sfltool dumpbtm`
entry, no SMAppService registration. The privilege is a transient capability bound to one
opened fd; the authopen child exits after handing the fd over `SCM_RIGHTS`. So the prior
"no lighter path exists" claim is FALSE as a statement about technical mechanism: authopen is
strictly lighter than an SMAppService daemon (no persistent registration). That is the
technical fact (Tier 3 man page, section 1.1).

The catch is that "lighter mechanism" and "sanctioned for distribution" are different
questions, and they split by source tier:

- Is authopen technically capable of the raw privileged open without a launchd service?
  YES. Tier 3 (man page, 1.1): `-stdoutpipe` + `SCM_RIGHTS` + a path-specific
  `sys.openfile.readwrite./dev/rdiskN` right, and authopen's stated original purpose is disk
  device manipulation. No registration step exists in the mechanism. Tier 4 (rpi-imager, 1.3)
  shows shipping third-party software using exactly this for raw `/dev/rdiskN`.
- Does Apple SANCTION authopen for a broadly distributed app? UNCONFIRMED, and the available
  Apple evidence leans toward "no, use SMAppService." Tier 2 (DTS thread 708765, 1.2) names
  authopen only under "if you're working interactively on the command line" and routes
  distributed products to SMAppService (ongoing) or a `.pkg`/`SMJobSubmit` (one-shot).
  authopen does NOT appear in the distributed-product branch of Apple's own ranking. Tier 1:
  there is NO Apple documentation endorsing authopen for app distribution at all, whereas
  SMAppService has full Tier 1 documentation (section 3).

So the prior conclusion is best read as scoped to Apple-SANCTIONED, documented APIs for
distribution: within that frame, SMAppService daemon is indeed the lightest sanctioned path,
because authopen -- though lighter in mechanism -- carries an Apple steer toward treating CLI
tools as interactive/limited-use rather than distribution building blocks. The prior
investigation's error was conflating "no sanctioned API" with "no API"; authopen is an API
that works, just one Apple has not blessed for this use in writing.

Net for the decision record: authopen is technically lighter (no launchd registration) but
LESS SANCTIONED for distribution (man-page behavior plus an interactive-only DTS mention, no
Tier 1 endorsement); SMAppService is heavier (persistent, user-visible background item) but
MORE SANCTIONED (full Tier 1 docs, named in Apple's distributed-product ranking). The spike
must decide which axis dominates for this project's distribution target. Provisional read,
consistent with section 1.2 and the unresolved question below: prefer authopen for its lighter
risk surface IF the installed-app context proves it works (B1-B2), and keep SMAppService as the
sanctioned fallback for the distribution path where the lack of an Apple blessing matters.

## 2. AuthorizationExecuteWithPrivileges deprecation status

Tier 2 (Apple DTS), corroborated by community writeups (Tier 4).

- `AuthorizationExecuteWithPrivileges` has been deprecated since macOS 10.7 (Lion). Apple DTS
  describes it as suitable only for ad hoc, one-shot, personal-use escalation, explicitly not
  for widely distributed products (thread
  [708765](https://developer.apple.com/forums/thread/708765); see also
  [theevilbit: macOS Authorization](https://theevilbit.github.io/posts/macos_authorization/)).
- It is therefore NOT the foundation of the authopen model, matching the plan's Context bullet.
  authopen performs its own Authorization Services check internally; it does not rely on
  `AuthorizationExecuteWithPrivileges`.
- For distributed products needing privilege, DTS steers to SMAppService (ongoing) or a `.pkg`
  installer (install-only), with `SMJobSubmit` named as a deprecated-but-stable one-shot
  option used by Sparkle.

## 3. SMAppService daemon fallback shape

Tier 1 (Apple documentation, JS-rendered and not directly extractable here) plus Tier 4
characterization ([theevilbit: SMAppService](https://theevilbit.github.io/posts/smappservice/)),
cross-referenced against the repo runbook [../../SIGNING.md](../../SIGNING.md).

- Factory: `SMAppService.daemon(plistName:)` (Swift) /
  `+daemonServiceWithPlistName:` (Objective-C). Minimum macOS 13 (Ventura). SMAppService
  replaces the older `SMJobBless` / `SMLoginItemSetEnabled` APIs.
- Lifecycle: `register()` (Swift: `try service.register()`), `unregister()`. Registration
  requires user approval AND authentication, because installing a daemon needs root. Once
  approved, "unregistering and registering it again doesn't require further authentication."
- Status: the `status` property exposes `SMAppService.Status` with values `notRegistered`,
  `enabled`, `requiresApproval` (user must act in System Settings), and `notFound`.
- Background-item visibility: registering a daemon creates a background item shown in System
  Settings (Login Items / Background Items), inspectable via `sfltool dumpbtm`. This is the
  persistence the plan weighs against authopen: a registered, user-visible background item
  versus a transient child process.
- Bundle layout: the launchd plist and helper executable live INSIDE the app bundle; they are
  not moved to `/Library/Launch*`. This matches the runbook's required layout
  (`Contents/Library/LaunchDaemons/<label>` plus the `.plist`), the `BundleProgram` relative
  path, and the `SMPrivilegedExecutables` / `SMAuthorizedClients` DR pinning described in
  [../../SIGNING.md](../../SIGNING.md) sections 3-4 and 12.
- Fallback fit: SMAppService is the heavier, persistent control plane. It is retained as the
  swappable `SMAppServiceHelperRawDiskOpener` backend, wrapping the existing helper machinery
  (`HelperAuthorization.pinning`, `CodeSignatureValidator`, `HelperService.production`), not
  the default. It has the strongest Tier 1 documentation of any option here.

## 4. TCC / Full Disk Access for raw block-device writes

Tier 2 (Apple DTS), the strongest evidence in this audit after the man page.

### 4.1 Whether raw writes need FDA, and the read-vs-write split

Source: Apple Developer Forums thread
[777577](https://developer.apple.com/forums/thread/777577) (DTS).

- DTS: "when other macOS applications try to read from a raw block device it triggers an
  Access Removable Media prompt and when other applications try to write to a raw block
  device it triggers a Full Disk Access prompt." So a raw WRITE to `/dev/rdiskN` is gated by
  Full Disk Access; a raw READ is gated by the (lighter) Removable Media privacy control.
- DTS deployment steer in the same thread: for personal use,
  `AuthorizationExecuteWithPrivileges` to run `dd`; for distribution, SMAppService to install
  a privileged daemon. authopen is not named as the distribution answer here either.

### 4.2 EPERM vs EACCES (errno 13 vs errno 1)

Source: Quinn's canonical pinned thread "On File System Permissions",
[678819](https://developer.apple.com/forums/thread/678819) (DTS). This is the authoritative
errno reference.

- Quinn: "If an operation was blocked by BSD permissions or ACLs, it fails with `EACCES`
  (Permission denied, 13). If it was blocked by something else, it'll fail with `EPERM`
  (Operation not permitted, 1)." So:
  - `EACCES` (13) = BSD-level permission gap. The unprivileged app hitting raw `/dev/rdiskN`
    without the open capability sees this; authopen handing back an authorized fd is the cure.
  - `EPERM` (1) = sandbox / MAC / TCC-layer denial. If the spike sees EPERM, the blocker is
    the privacy stack (FDA), not BSD permissions, and authorizing the open will not help by
    itself. The spike (B1/B2) must record WHICH errno appears, per S1/S2 exit criteria.

### 4.3 Which component FDA attaches to (responsible code) and the bundled-executable nuance

Source: thread [678819](https://developer.apple.com/forums/thread/678819) (DTS).

- TCC grants attach to "responsible code." Quinn: for an app containing a helper tool that
  trips a MAC prompt, the system wants the APP's name and usage description in the alert, the
  user's decision recorded for the whole app, and that decision shown in System Settings under
  the app's name. So the parent app bundle, not the child tool, is the FDA grant holder when
  attribution works correctly.
- For launchd daemons/agents whose attribution is wrong: "add the `AssociatedBundleIdentifiers`
  property to your `launchd` property list" to tie the daemon back to the app.
- Bundled-executable nuance: "TCC expects its bundled clients -- apps, app extensions, and so
  on -- to use a native main executable ... If your product uses a script as its main
  executable, you're likely to encounter TCC problems." Embed a Mach-O writer in the app
  bundle; do not use a script as the bundle's main executable.
- Implication for this project: an installed, signed app bundle is the right FDA-grant holder.
  A child authopen invocation should attribute back to the app, but the plan's distinction
  (which of: app bundle, Terminal, authopen child, probe executable, signed installed app
  actually needs the grant) is NOT fully answered by these threads and must be measured in B2.

### 4.4 macOS 26.1/26.2 CLI FDA regression -- CONFIRMED as a real bug, scope-limited

Status: previously UNVERIFIED in the plan; now CONFIRMED against PRIMARY Apple sources for
standalone CLI tools, but the bundled-app impact remains UNVERIFIED and must be observed.

Sources (Tier 2, Apple DTS):
- "sshd-keygen-wrapper permissions problem", thread
  [806187](https://developer.apple.com/forums/thread/806187) (Quinn, the canonical thread).
- "Emerging Issue with macOS Tahoe 26.1 -- Full Disk Access (FDA) Behaviour", thread
  [809549](https://developer.apple.com/forums/thread/809549) (DTS redirects to 806187).
- Corroborating Tier 4: backrest issue
  [#986](https://github.com/garethgeorge/backrest/issues/986),
  Trellix [KB 000015086](https://thrive.trellix.com/s/article/000015086).

Findings:
- The bug: command-line tools / wrapper executables are not displayed in (or do not take
  effect under) Privacy & Security Full Disk Access in macOS 26.1 and 26.2. Quinn: "This is
  eminently bugworthy" and requested a Feedback; filed as FB20662270 (Nov '25).
- Persistence: "still present in the macOS 26.2 Release Candidate ... very likely to remain
  unfixed in the final release of macOS 26.2" (Dec '25).
- Fix: "Seems that this is resolved in 26.3 beta 1" and Quinn: "That gels with my
  expectations" (Jan '26). A parallel Accessibility-permission regression in 26.1/26.2 was
  also fixed in 26.3 beta.
- Scope: the threads center on STANDALONE CLI binaries / wrapper executables, NOT executables
  bundled inside an app bundle. This is favorable for this project, because the shipping
  context is a signed app bundle (FDA "responsible code" = the app, per 4.3), and the spike's
  decisive context is the installed app, not a bare CLI tool. It is also a hazard for the CLI
  and Xcode launch contexts (S1 contexts 1 and 2), which may show false FDA failures on an
  affected point release.
- UNVERIFIED residue: no Apple source explicitly states the bundled-app path is unaffected; it
  is inferred from the threads' CLI-only framing. The spike must confirm by direct observation
  (B2). Record the exact OS build the spike runs on, since behavior is build-specific.

How to confirm in the spike:
- Capture `sw_vers` (section 5) and note whether the build is 26.1, 26.2, or 26.3+.
- In context 2 (CLI from Terminal) and context 3 (installed app), grant FDA, then attempt the
  raw write and record the errno (EACCES vs EPERM, per 4.2) and whether the binary appears in
  the FDA list at all.
- If a CLI context fails to honor FDA on a 26.1/26.2 build, attribute it to FB20662270 rather
  than to authopen, and re-test on a 26.3+ build before concluding authopen is blocked.
- The installed-app-from-/Applications result (context 3) is decisive and should not be
  discarded on the basis of a CLI-only regression.

## 5. Operator capture checklist (must run locally on the test Mac)

The man page and OS/Xcode versions are build-specific. The operator running the hardware lane
(B1-B3) must capture the following on the actual test Mac and paste them into the decision
record, because remote mirrors may not match the installed build:

- `man authopen` -- the LOCAL, Xcode-distributed man page is authoritative for low-level
  behavior. Capture the full text (for example `man authopen | col -b > authopen_man.txt`).
- `sw_vers` -- records `ProductName`, `ProductVersion`, and the `BuildVersion` build number.
  The build number determines whether the 26.1/26.2 FDA regression (section 4.4) is in play.
- `xcodebuild -version` -- records the Xcode version (and bundled SDK) used, since the man
  page and signing toolchain ship with Xcode.
- Optional but recommended for the FDA/exclusivity work:
  - `authopen` exact invocation and the authorization right string actually presented
    (confirm it is `sys.openfile.readwrite./dev/rdiskN`).
  - `lsof <device>` and `ps -ax | grep -i authopen` after the fd closes, to prove no
    privileged residue remains (plan S1 residue check).
  - `diskutil info <device>` before and after unmount, to document the exclusivity/EBUSY
    behavior seen in rpi-imager #270.

## Highest-value findings

- The authopen distribution endorsement is thin: Apple DTS names authopen only for
  interactive command-line use (Tier 2, thread 708765, 2025-03-24), never for distributed GUI
  apps. The man page (Tier 3) plus this one sentence are the entire pro-authopen Apple
  evidence base. SMAppService alone has Tier 1 documentation.
- A raw WRITE to `/dev/rdiskN` triggers Full Disk Access; a raw READ triggers the lighter
  Removable Media prompt (Tier 2, thread 777577). FDA is therefore the gating privacy control
  the spike must clear for writing.
- EACCES (13) means a BSD permission gap (authopen's authorized fd is the cure); EPERM (1)
  means a sandbox/MAC/TCC denial (FDA, not BSD, and authorizing the open will not help). The
  spike must record which errno appears (Tier 2, thread 678819).
- The macOS 26.1/26.2 CLI FDA regression is a CONFIRMED Apple bug (FB20662270), fixed in 26.3
  beta, scoped to standalone CLI tools/wrappers, not app bundles (Tier 2, threads 806187 and
  809549). This favors the installed-app shipping context and warns that the CLI/Xcode spike
  contexts may show false FDA failures on an affected build.
- Exclusivity blocks on a still-mounted target: authopen returns "Resource busy" (EBUSY) until
  the volume is unmounted (Tier 4, rpi-imager #270). Unmount-first, then exclusive open is the
  working order, corroborating the plan's unmount-before-`O_EXCL` sequence.

## Biggest unresolved question for the hardware lane

Does an installed, signed app bundle launched from /Applications attribute the authopen child
process's Full Disk Access grant to the APP (so a single app-level FDA grant authorizes the
raw write), or does TCC instead demand FDA on the authopen child / probe executable
separately? Section 4.3 says responsible-code attribution SHOULD land on the app, but no Apple
source confirms it for an authopen child specifically, and the 26.1/26.2 regression muddies
CLI-context observations. B2 must measure which component must hold FDA, on a known build
number, in the installed-app context -- this is the single result that decides whether
authopen is shippable or whether the SMAppService fallback is forced.
