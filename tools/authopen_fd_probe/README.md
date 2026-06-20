# authopen_fd_probe

Standalone SCM_RIGHTS fd-passing harness for the WP-authopen-fd-spike (task A1).

This probe has two modes:

- `selftest` -- automated proof of SCM_RIGHTS fd-passing, no authopen, no
  device, no auth prompt. Run this first, always.
- `authopen` -- scaffolded interactive authopen run. Requires operator setup,
  a real auth prompt, and for raw-device use: a sacrificial USB.

## How to build

Build and link this target as a product:

```
swift build
```

The binary lands at `.build/debug/authopen_fd_probe` (symlink to
`.build/arm64-apple-macosx/debug/authopen_fd_probe`).

To build only this target (compiles but does not link the binary):

```
swift build --target authopen_fd_probe
```

Use `swift build` (whole project) or `swift run authopen_fd_probe <args>` to
ensure the binary is fully linked.

## Mode 1: automated SCM_RIGHTS self-test (safe, run first)

This mode proves the SCM_RIGHTS fd-passing mechanism works on this machine
WITHOUT touching authopen or any device. It uses a `socketpair` + temp file.

```
.build/debug/authopen_fd_probe selftest
```

Expected output (all checks passing -- pid and fd numbers vary):

```
[selftest] SCM_RIGHTS fd-passing harness -- automated, no authopen
[selftest] platform: Darwin 25.5.0 arm64

[check] OK: temp file creation and initial write
[selftest] step 1: temp file created at /tmp/authopen_fd_probe_<pid>.bin with 19 bytes
[selftest] step 2: temp file fd 3 opened for passing
[check] OK: socketpair
[selftest] step 3: socketpair created (parent=4, child=5)
[check] OK: spawn send_fd child (pid <pid>)
[selftest] step 4: child pid <pid> spawned; parent copies of fds closed
[check] OK: child exited cleanly (wExitStatus=0)
[selftest] step 5: child process (sender) has exited -- fd is now sender-gone
[check] OK: SCM_RIGHTS fd receive (returned 3)
[selftest] step 6: received fd 3 via SCM_RIGHTS
[check] OK: lseek to start on received fd (errno 1)
[check] OK: read 19 bytes via received fd (got 19)
[check] OK: payload matches magic bytes
[selftest] step 7a: READ via received fd after sender exit -- payload: "SCM_RIGHTS_PROBE_OK"
[check] OK: write via received fd (wrote 14 of 14)
[selftest] step 7b: WRITE via received fd -- 14 bytes written
[check] OK: lseek back to start for verification (errno 1)
[check] OK: re-read combined payload (33 of 33)
[check] OK: combined payload matches expected bytes
[selftest] step 7c: read-back confirms both payloads intact
[check] OK: close received fd (errno 1)
[check] OK: second close returns EBADF (got -1, errno 9)
[selftest] step 8: close behavior correct (EBADF on double-close)

[selftest] ALL CHECKS PASSED
[selftest] SCM_RIGHTS fd-passing proven:
[selftest]   fd passed from child to parent over UNIX socketpair
[selftest]   read/write capability confirmed on received fd
[selftest]   fd remains usable AFTER sender (child) has exited
[selftest]   close() returns 0; double-close returns EBADF
```

Note: "errno 1" in success `[check] OK:` lines is a cosmetic artifact of how
Swift captures the `errno` global after a successful call that reset it; the
check condition itself passed. Only `[check] FAIL:` lines are actionable.

Exit code 0 = all checks passed.
Exit code 1 = a check failed; stderr shows which one.
Exit code 3 = raw device preflight refused the target (not applicable to selftest).

## Mode 2: interactive authopen run (OPERATOR-ONLY)

This mode spawns `/usr/libexec/authopen -stdoutpipe` and receives the fd via
SCM_RIGHTS over authopen's stdout pipe. It triggers a real Authorization
Services dialog.

**Requirements before running:**

- Complete mode 1 (`selftest`) successfully on this machine.
- Identify a safe target path (regular file first, then sacrificial USB).
- For raw-device targets: complete the preflight invariant checklist below.

### Step 1: regular file target (no hardware needed)

```
# Create a writable temp file as the target.
touch /tmp/probe_target.bin

.build/debug/authopen_fd_probe authopen /tmp/probe_target.bin
```

Record:
- Whether an auth prompt appeared.
- The authorization right name shown (example: `sys.openfile.readwrite./tmp/probe_target.bin`).
- authopen exit status (0 = authorized, non-zero = denied).
- `lsof /tmp/probe_target.bin` output after the run to confirm no residual open.

Open flags used: `O_RDWR | O_EXCL | O_SYNC` (decimal value passed to `-o`).
Note: `O_EXCL` on a regular file requires it to NOT already exist; if authopen
returns an error, try without `O_EXCL` (edit `openFlags` in `main.swift` and
rebuild) and document the deviation.

### Step 2: sacrificial USB raw device (HARDWARE REQUIRED)

The probe enforces the preflight invariant in code. When the target path
matches `/dev/rdiskN`, it runs these checks automatically before spawning
authopen:

1. Validates the path format (`/dev/rdiskN`, digits only; rejects everything
   else with exit code 3).
2. Resolves the paired `/dev/diskN` whole-disk path.
3. Queries `diskutil info -plist /dev/diskN` and refuses unless the disk is
   External (yes), Removable (yes), and Internal (no).
4. Queries `diskutil info -plist /` to find the boot/system disk parent and
   refuses if the target whole disk matches it.
5. Records the disk identity: BSD name, media name, total size in bytes, and
   a UUID anchor (DiskUUID from diskutil, or a name+size fallback).
6. Re-queries the same identity immediately before spawning authopen and
   aborts on any mismatch (BSD numbers change on reinsert; any mismatch
   stops the run).
7. Prints a safety summary (target, size, label, BSD name, identity) and
   requires the operator to type the exact whole-disk BSD name (e.g. `disk4`)
   at the prompt before proceeding. Any other input aborts.

**Operator pre-step: unmount all volumes** (required for `O_EXCL` on the raw device):

```
diskutil unmountDisk /dev/diskN
```

Expected: "Unmount of all volumes on diskN was successful". If this fails,
record the error and whether it is a permissions issue. This is also B3
datapoint 1 (does unprivileged unmount work).

Record the exact OS build number and Xcode version before running:

```
sw_vers && xcodebuild -version
```

**Then run the probe:**

```
.build/debug/authopen_fd_probe authopen /dev/rdiskN
```

The probe prints the safety summary and pauses for confirmation. Type the
BSD name shown (e.g. `disk4`) and press Enter to proceed. Any other input
aborts with exit code 3.

Record everything the `selftest` checklist above asks for, plus:
- Whether `diskutil unmountDisk` succeeded unprivileged (resolves H6/S3).
- Whether FDA (Full Disk Access) was required; if so, which component
  (Terminal, the probe binary, or the app bundle) needed it.
- Whether the auth prompt named a right like
  `sys.openfile.readwrite./dev/rdiskN`.
- `ps -ax | grep -i authopen` after the run to confirm the privileged side
  is gone.
- `lsof /dev/rdiskN` after close to confirm no residual open.

### Launch contexts to test

Run the `authopen` mode in all three contexts and record each separately
(macOS privacy controls differ between them):

1. From Xcode (Run in Xcode with the probe scheme).
2. From Terminal (shell, no Xcode).
3. From /Applications (signed app installed there -- requires Developer ID
   signing; see `docs/SIGNING.md` for the sign/notarize steps).

The installed-app-from-/Applications context is the one that governs the
shipping decision. The other two inform the development experience.

## Open flags note

The first tested set is `O_RDWR | O_EXCL | O_SYNC` (per the spike plan).
If `O_EXCL` blocks a valid raw-device open even after all volumes are
unmounted, retest with `O_RDWR | O_SYNC`, document the exclusivity-vs-openability
safety tradeoff, and feed the finding into S3.

`-w` (the read/write+truncate form) is intentionally NOT used here; it carries
truncate semantics appropriate for regular files, not raw devices. The explicit
`-o <flags>` form lets the caller control the exact open mode.

## Relationship to the spike plan

This probe covers the SOFTWARE lane (task A1):

- `selftest` completes A1: proves the SCM_RIGHTS mechanism works.
- `authopen` mode scaffolds the HARDWARE lane (task B1): the operator runs this
  against a real device in each of the three launch contexts. B1 results feed
  S2 (TCC/FDA) and S3 (unmount + exclusivity). S5 synthesizes everything into
  the decision record at `docs/active_plans/decisions/raw_disk_write_model.md`.

## Files

```
tools/authopen_fd_probe/
  main.swift   -- SCM_RIGHTS self-test + authopen scaffold
  README.md    -- this file
```

The target is declared in `Package.swift` as `authopen_fd_probe` and is
excluded from the fast `swift test` lane (it is an executable, not a test
target). The existing test targets are unaffected.
