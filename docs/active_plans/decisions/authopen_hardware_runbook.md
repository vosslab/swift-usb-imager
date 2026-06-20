# authopen hardware runbook

Step-by-step procedure the operator runs on real Apple Silicon macOS 26 with a
sacrificial USB. It covers the hardware lane of the raw-disk-write-model spike:
tasks B1 (authopen raw-device write across three launch contexts), B2 (Full Disk
Access attribution), and B3 (unmount + exclusivity matrix). The results fill the
hardware placeholders in
[raw_disk_write_model.md](raw_disk_write_model.md).

This runbook is procedure only. It does not change `Sources/`, tests, the
changelog, or [../../SIGNING.md](../../SIGNING.md). The probe it drives is the
A1 harness at [../../../tools/authopen_fd_probe/README.md](../../../tools/authopen_fd_probe/README.md).

## Who runs this and why

The software lane is done: A1 proved SCM_RIGHTS fd-passing works
([../../../tools/authopen_fd_probe/README.md](../../../tools/authopen_fd_probe/README.md)),
A2 fixed the backend design
([rawdiskopener_design.md](rawdiskopener_design.md)), and A3 gathered the
source-tiered evidence
([../audits/authopen_source_research.md](../audits/authopen_source_research.md)).
What remains is direct observation on hardware. Only the USER can run this: it
needs a physical Apple Silicon Mac on macOS 26, a sacrificial USB stick whose
contents can be destroyed, a real Authorization Services prompt, and (for the
decisive context) a Developer ID signing identity.

The single result that decides the verdict is B2 in the installed-app context:
does TCC attribute the authopen child's Full Disk Access grant to the APP, or
demand FDA on the child separately. Everything else supports or scopes that
answer.

## Safety first: hard preflight invariant

The probe enforces this in code, but the operator must understand it. A raw
write proceeds ONLY when the target is:

- external,
- removable,
- not an internal disk (Internal=false),
- free of the system/boot volume,
- media-identity revalidated immediately before the open.

Record BOTH the `/dev/diskN` parent path and the `/dev/rdiskN` raw path for
every run. BSD numbers change on reinsert, so re-resolve identity right before
each authopen invocation. Any mismatch stops the run with a clear report. Do not
defeat this check. A wrong target overwrites a real disk.

## Capture locally first

The man page, OS build, and Xcode version are build-specific. Mirrors online may
not match the installed build, so capture these on the actual test Mac before
anything else and paste them into the decision record.

Run and record:

```
man authopen | col -b > /tmp/authopen_man.txt
sw_vers
xcodebuild -version
```

Paste back:

- The full `/tmp/authopen_man.txt` text (or confirm it matches the A3 summary in
  [../audits/authopen_source_research.md](../audits/authopen_source_research.md)
  section 1.1, and note any difference).
- The `sw_vers` output verbatim: `ProductName`, `ProductVersion`, and the
  `BuildVersion` build number.
- The `xcodebuild -version` output verbatim.

The `BuildVersion` decides whether the confirmed 26.1/26.2 CLI FDA regression is
in play. The regression is fixed in 26.3 beta1 and is scoped to standalone CLI
tools, not app bundles. If the build is 26.1 or 26.2, the Xcode and Terminal
contexts may show FALSE FDA failures; the installed-app context, ideally on
26.3+, is decisive. See
[../audits/authopen_source_research.md](../audits/authopen_source_research.md)
section 4.4.

## Build the probe

```
swift build
```

The binary lands at `.build/debug/authopen_fd_probe`. Confirm the safe self-test
passes before any device work:

```
swift run authopen_fd_probe selftest
```

Paste back: the final two lines (`[selftest] ALL CHECKS PASSED` and the summary)
and the exit code. Exit code 0 means SCM_RIGHTS fd-passing works on this machine.
Do not proceed to authopen mode until this passes.

## Launch contexts (run every section in all three)

macOS privacy controls differ by how a process is launched, so B1, B2, and B3
each run in three contexts and record each separately:

1. Xcode-launched (development). Run the probe scheme from Xcode.
2. Terminal CLI. Run the built binary from a shell, no Xcode.
3. Installed signed app from `/Applications` (the decisive one). Requires a
   Developer ID identity; see [../../SIGNING.md](../../SIGNING.md) for the
   sign/notarize steps. The installed-app context governs the shipping decision.

If a Developer ID identity is not yet available, run contexts 1 and 2, record
that context 3 is BLOCKED on signing, and mark the installed-app results PENDING.
The verdict stays PENDING HARDWARE LANE until context 3 is measured.

## B1: authopen raw-device write across three contexts

Goal: prove (or disprove) that the unprivileged probe runs
`/usr/libexec/authopen -stdoutpipe -o <flags> <path>`, receives a write-capable
fd over SCM_RIGHTS, writes, and leaves no privileged residue. Resolves the
destructive half of S1.

### B1 step 1: regular-file target (no hardware)

Run this in each of the three contexts before touching the USB. It isolates
fd-passing and auth behavior from disk-permission behavior.

```
touch /tmp/probe_target.bin
.build/debug/authopen_fd_probe authopen /tmp/probe_target.bin
lsof /tmp/probe_target.bin
ps -ax | grep -i authopen
```

Open flags: the first tested set is `O_RDWR | O_EXCL | O_SYNC`. `O_EXCL` on a
regular file requires the file to NOT already exist; if authopen errors on the
existing temp file, rerun against a non-existent path or drop `O_EXCL` and
record the deviation. See
[../../../tools/authopen_fd_probe/README.md](../../../tools/authopen_fd_probe/README.md)
step 1.

Paste back, per context:

- Whether an auth prompt appeared, and its exact wording.
- The authorization right name shown (expect
  `sys.openfile.readwrite./tmp/probe_target.bin`).
- The authopen exit status (0 = authorized, non-zero = denied).
- Whether the fd was received and the probe wrote through it successfully.
- `lsof` output after the run (expect no residual open).
- `ps -ax | grep -i authopen` output after the run (expect the child gone).
- The errno if anything failed (record the number AND the name).

### B1 step 2: sacrificial USB raw device (HARDWARE REQUIRED)

Run the preflight invariant checklist, then the probe, in each context.

Preflight (do not skip any item):

```
diskutil info /dev/diskN | grep -E "Removable|External"
diskutil list | grep -v internal
diskutil info /dev/diskN
diskutil unmountDisk /dev/diskN
```

- `Removable` and `External` must both say Yes.
- The target must appear only in the external section of `diskutil list`.
- Record the BSD name, size, volume label, and media identity from
  `diskutil info`. If the disk is reinserted, the BSD number changes; re-run
  this check before proceeding.
- `diskutil unmountDisk` is expected to print "Unmount of all volumes on diskN
  was successful". This is also the first B3 datapoint (does it succeed
  unprivileged); record the result here and reuse it in B3.

Immediately before the probe, re-resolve identity (step 5 of the checklist in
[../../../tools/authopen_fd_probe/README.md](../../../tools/authopen_fd_probe/README.md))
and confirm UUID/anchor, size, and media name still match.

Then run, per context:

```
.build/debug/authopen_fd_probe authopen /dev/rdiskN
ps -ax | grep -i authopen
lsof /dev/rdiskN
```

Paste back, per context:

- Both the `/dev/diskN` parent path and the `/dev/rdiskN` raw path used.
- Whether the auth prompt appeared, its exact wording, and the right name
  (expect `sys.openfile.readwrite./dev/rdiskN`).
- The authopen exit status and whether the probe wrote bytes through the fd.
- The errno if it failed: EACCES (13) means a BSD permission gap that the
  authorized fd should cure; EPERM (1) means a TCC/FDA denial that authorizing
  the open will not fix. EBUSY means the target was still mounted; unmount and
  retry. See
  [../audits/authopen_source_research.md](../audits/authopen_source_research.md)
  section 4.2.
- `ps -ax | grep -i authopen` after the run (expect no privileged residue).
- `lsof /dev/rdiskN` after close (expect no residual open).
- Cancellation outcome: close the fd mid-write and record that progress stops,
  the run reports incomplete, it holds before verification, and the authopen
  child is already gone (it exits once it has handed over the fd).

### B1 result shape

For each context (Xcode, Terminal, installed app), report PASS or FAIL with: the
prompt text, the right name, the residue check (`ps`/`lsof` both clean), the
errno on any failure, and whether the explicit `-o` flags yielded a usable write
fd. A FAIL in a context must carry its exact errno so it feeds B2.

## B2: Full Disk Access attribution (the decisive measurement)

Goal: in the installed-app context, determine whether TCC attributes the
authopen child's FDA grant to the APP (one app-level grant authorizes the raw
write) or demands FDA on the child / probe executable separately. This is the
single result that decides whether authopen is shippable or whether the
SMAppService fallback is forced. See the A3 "biggest unresolved question" in
[../audits/authopen_source_research.md](../audits/authopen_source_research.md).

Background the operator needs:

- A raw WRITE to `/dev/rdiskN` triggers Full Disk Access; a raw READ triggers the
  lighter Removable Media prompt (A3 section 4.1).
- TCC grants attach to "responsible code", which SHOULD be the app bundle for a
  bundled tool, but no Apple source confirms this for an authopen child
  specifically (A3 section 4.3). B2 measures it.
- EACCES (13) = BSD gap; EPERM (1) = TCC/FDA denial (A3 section 4.2).
- The confirmed 26.1/26.2 CLI FDA regression (FB20662270, fixed 26.3 beta1) is
  scoped to standalone CLI tools, not app bundles, so the Xcode and Terminal
  contexts may show false FDA failures on an affected build. Do not discard the
  installed-app result on the basis of a CLI-only regression (A3 section 4.4).

Procedure, run in each context but treat context 3 as decisive:

1. Record the build first: `sw_vers` (note 26.1, 26.2, or 26.3+).
2. With FDA NOT granted to anything, attempt the raw write (B1 step 2) and record
   the errno and whether any prompt to grant FDA appears, and to which component
   (the app, Terminal, the probe binary).
3. Grant FDA to the candidate component in System Settings > Privacy & Security >
   Full Disk Access. Record which component you could even add to the list (on an
   affected 26.1/26.2 build a bare CLI binary may not appear at all).
4. Re-attempt the raw write and record the errno again.
5. Record WHICH component, once granted, makes the write succeed: the app bundle,
   Terminal, the authopen child, or the probe executable.

Paste back, per context:

- The exact OS build (`sw_vers` `BuildVersion`).
- The errno before and after granting FDA (EACCES 13 vs EPERM 1, by number and
  name).
- Which component holds FDA when the write succeeds.
- Whether the candidate component even appears in the FDA list (the regression
  signal).
- For the installed-app context specifically: does ONE app-level FDA grant
  authorize the authopen child's raw write (the shippable outcome), or does TCC
  demand FDA on the child / probe separately (which would push toward the
  SMAppService fallback)?

If a CLI/Xcode context fails to honor FDA on a 26.1/26.2 build, attribute it to
FB20662270, not to authopen, and re-test on 26.3+ before concluding authopen is
blocked.

## B3: unmount and exclusivity matrix

Goal: confirm the unprivileged app can unmount the target's volumes and that the
authopen-opened fd takes an exclusive write, and record actual `O_EXCL` behavior
on `/dev/rdiskN` (which may differ from a regular file). Resolves H6 and the S3
write mechanics.

A3 (rpi-imager #270, section 1.3) shows authopen returns EBUSY until the volume
is unmounted, so the working order is unmount-first, then the exclusive open.

### B3 unmount viability

```
diskutil unmountDisk /dev/diskN
```

Paste back:

- Whether `diskutil unmountDisk` succeeded as the normal user with NO sudo and NO
  auth prompt (resolves H6: is unmount unprivileged).
- If it prompted or failed, the exact message and whether it was a permissions
  issue. A privileged unmount narrows the "unprivileged app" claim and feeds the
  S5 decision matrix.

### B3 exclusivity matrix

For each disk state below, run the probe with `O_RDWR | O_EXCL | O_SYNC` and
record the open result and errno. Then, where `O_EXCL` blocks a valid open after
unmount, retest with `O_RDWR | O_SYNC` and record the exclusivity-vs-openability
tradeoff.

| Disk state | What to do | Record |
| --- | --- | --- |
| Mounted volume present | Do not unmount; run the probe | Open result, errno (expect EBUSY) |
| Volumes unmounted | `diskutil unmountDisk`, then run the probe | Open result, errno, whether `O_EXCL` succeeds |
| Disk busy | Hold the device open elsewhere, run the probe | Open result, errno |
| Disk removed mid-open | Pull the USB during the open/write | Open result, errno, write behavior |
| Device path changed | Reinsert (BSD number changes), run preflight | Whether identity revalidation catches the change |

Paste back, per state: the open flags used, the open result (success or fail),
and the exact errno (number and name). Note explicitly whether `O_EXCL` on
`/dev/rdiskN` behaves like a regular file or differently.

### B3 cache control on the passed fd

After a successful open in the unmounted state, confirm the probe can set
`F_NOCACHE` / sync behavior on the passed fd so writes hit the media.

Paste back:

- Whether `F_NOCACHE` (`fcntl`) succeeded on the passed fd.
- Whether the block-size query succeeded on the passed fd.
- Confirmation that bytes written through the passed fd landed on the media
  (read back and compare a bounded payload).

## What to paste back, consolidated

For the decision record, the operator returns:

- The capture block: `man authopen` text (or confirmation it matches A3),
  `sw_vers`, `xcodebuild -version`.
- The `selftest` pass confirmation and exit code.
- B1: PASS/FAIL per context, with prompt text, right name, residue check, errno
  on failure, and cancellation outcome.
- B2: per context, the build number, errno before/after FDA, which component
  holds FDA, whether the component appears in the FDA list, and the decisive
  installed-app attribution answer (app-level grant vs child-specific FDA).
- B3: unprivileged-unmount result, the exclusivity matrix (open result + errno
  per disk state), and the `F_NOCACHE`/sync confirmation on the passed fd.

Each item maps directly to a placeholder in
[raw_disk_write_model.md](raw_disk_write_model.md).
