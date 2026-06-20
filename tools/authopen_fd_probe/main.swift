/// main.swift -- SCM_RIGHTS fd-passing harness for the authopen raw-disk spike.
///
/// PURPOSE
/// -------
/// Proves that fd-passing via SCM_RIGHTS works on this machine before the
/// operator touches real hardware.
///
/// TWO MODES
/// ---------
///   selftest   Run the automated SCM_RIGHTS proof (default when no args given).
///              Uses a socketpair + temp file -- NO authopen, NO device, NO auth
///              prompt. Safe to run in CI or from any shell.
///
///   authopen   Scaffold the interactive authopen path. Spawns
///              /usr/libexec/authopen -stdoutpipe and receives the fd via
///              SCM_RIGHTS over its stdout pipe. Requires a path argument and
///              triggers an interactive auth prompt. OPERATOR USE ONLY -- see
///              README.md before running.
///              For /dev/rdiskN targets, enforces a safety preflight that
///              refuses the target unless EVERY gate passes, in order:
///                - path is a well-formed /dev/rdiskN node
///                - disk is external (External=true)
///                - disk is removable (Removable, RemovableMedia, or Ejectable)
///                - disk is NOT internal (Internal=false)
///                - boot disk BSD name is resolvable AND the target is not it
///                - disk identity is capturable (TotalSize key present)
///              It then records media identity, re-checks the hardware flags
///              (external/removable/not-internal/not-boot) and identity before
///              open, and requires the operator to type the exact BSD name to
///              confirm.
///              A non-/dev regular-file target bypasses preflight and is the
///              safe fd-passing isolation test (read/write through the fd).
///
/// EXIT CODES
/// ----------
///   0  -- all checks passed (selftest), or fd received (authopen scaffold)
///   1  -- a test assertion failed or a POSIX call returned an error
///   2  -- bad arguments
///   3  -- preflight safety check refused the target (raw device mode only)

import Darwin
import Foundation
import AuthopenProbeCore

// MARK: - CMSG layout constants (manual substitutes for unavailable C macros)
//
// Swift cannot import function-like C macros (CMSG_LEN, CMSG_SPACE,
// CMSG_FIRSTHDR, CMSG_DATA, CMSG_NXTHDR, WIFEXITED, WEXITSTATUS).
// These are hand-computed from the Darwin sys/socket.h and sys/wait.h
// definitions.

/// cmsghdr size after __DARWIN_ALIGN32 padding (always 16 bytes on Darwin).
private let cmsgHdrSize: Int = {
    // __DARWIN_ALIGN32(sizeof(struct cmsghdr)) = align32(12) = 16 on arm64.
    // Use MemoryLayout stride (includes alignment padding) rather than size
    // so the data pointer is always correctly aligned for the fd payload.
    return MemoryLayout<cmsghdr>.stride
}()

/// CMSG_LEN(l): header size + data size (unpadded; length field value).
private func cmsgLen(dataSize: Int) -> Int {
    return cmsgHdrSize + dataSize
}

/// CMSG_SPACE(l): header size + data size, both aligned (allocation size).
private func cmsgSpace(dataSize: Int) -> Int {
    // __DARWIN_ALIGN32 rounds to next multiple of 4.
    let align = { (n: Int) -> Int in (n + 3) & ~3 }
    return align(cmsgHdrSize) + align(dataSize)
}

/// CMSG_DATA(cmsg): pointer to data bytes immediately after the cmsghdr.
private func cmsgData(_ cmsg: UnsafeMutablePointer<cmsghdr>) -> UnsafeMutableRawPointer {
    // Data sits immediately after the header (Darwin uses stride-aligned offset).
    let base = UnsafeMutableRawPointer(cmsg)
    return base.advanced(by: cmsgHdrSize)
}

/// CMSG_FIRSTHDR(mhdr): first cmsghdr, or nil if control is empty.
private func cmsgFirstHdr(_ msg: inout msghdr) -> UnsafeMutablePointer<cmsghdr>? {
    guard msg.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size) else {
        return nil
    }
    return msg.msg_control?.assumingMemoryBound(to: cmsghdr.self)
}

/// WIFEXITED(status): true if the child exited normally (not signaled).
private func wifExited(_ status: Int32) -> Bool {
    // _WSTATUS(x) == 0; _WSTATUS is (x & 0x7F).
    return (status & 0x7F) == 0
}

/// WEXITSTATUS(status): extract the 8-bit exit code from a normal exit.
private func wExitStatus(_ status: Int32) -> Int32 {
    // (x >> 8) & 0xFF.
    return (status >> 8) & 0xFF
}

// MARK: - Entry point

let args = CommandLine.arguments

// Internal sub-command used by the selftest child process: handled first.
if args.count == 4 && args[1] == "send_fd" {
    runSendFD(sockFDArg: args[2], targetFDArg: args[3])
    // runSendFD always calls exit(); execution does not continue.
}

let mode = args.count > 1 ? args[1] : "selftest"

switch mode {
case "selftest":
    runSelfTest()

case "authopen":
    guard args.count > 2 else {
        fputs("usage: authopen_fd_probe authopen <path>\n", stderr)
        fputs("See tools/authopen_fd_probe/README.md for operator instructions.\n", stderr)
        exit(2)
    }
    let targetPath = args[2]
    runAuthopenScaffold(targetPath: targetPath)

default:
    fputs("unknown mode '\(mode)' -- use: selftest | authopen <path>\n", stderr)
    exit(2)
}

// MARK: - Mode 1: Automated SCM_RIGHTS self-test

/// Prove SCM_RIGHTS fd-passing without authopen or any device access.
///
/// Proof steps:
///   1. Create a temp file and write a known payload.
///   2. Open the temp file and obtain an fd.
///   3. Create a socketpair (UNIX domain stream sockets).
///   4. CHILD (posix_spawn'd): send the fd over the socket via SCM_RIGHTS,
///             close its copies, exit 0.
///   5. PARENT: wait for the child to exit (sender gone).
///   6. PARENT: receive the fd via recvmsg(2) SCM_RIGHTS on the socket.
///   7. PARENT: verify read/write capability on the RECEIVED fd after sender exit.
///   8. PARENT: verify correct close behavior.
///
/// The child is a re-invocation of this same binary with a private sub-command
/// "send_fd <sock_fd> <target_fd>" so we avoid fork() (unavailable in Swift).
func runSelfTest() {
    print("[selftest] SCM_RIGHTS fd-passing harness -- automated, no authopen")
    print("[selftest] platform: \(unameString())")
    print()

    // --- Step 1: Create a temp file with a known payload ---
    let tempPath = "/tmp/authopen_fd_probe_\(ProcessInfo.processInfo.processIdentifier).bin"
    let magicPayload: [UInt8] = Array("SCM_RIGHTS_PROBE_OK".utf8)

    let createResult = tempPath.withCString { cPath -> Int32 in
        let fd = open(cPath, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return -1 }
        defer { close(fd) }
        let buf = magicPayload
        let n = buf.withUnsafeBytes { raw in
            // SAFETY: magicPayload is a non-empty fixed array, so the Swift
            // stdlib guarantees baseAddress is non-nil inside withUnsafeBytes.
            write(fd, raw.baseAddress!, raw.count)
        }
        return n == magicPayload.count ? 0 : -1
    }
    check(createResult == 0, "temp file creation and initial write")
    print("[selftest] step 1: temp file created at \(tempPath) with \(magicPayload.count) bytes")
    defer {
        unlink(tempPath)
        print("[selftest] temp file removed")
    }

    // --- Step 2: Open the temp file to get an fd to pass ---
    let tempFD = tempPath.withCString { open($0, O_RDWR) }
    guard tempFD >= 0 else { check(false, "open temp file for passing (errno \(errno))"); exit(1) }
    print("[selftest] step 2: temp file fd \(tempFD) opened for passing")

    // --- Step 3: Create a socketpair for SCM_RIGHTS transport ---
    // AF_UNIX, SOCK_STREAM -- the standard SCM_RIGHTS shape.
    var socks: [Int32] = [0, 0]
    let sockResult = socketpair(AF_UNIX, SOCK_STREAM, 0, &socks)
    check(sockResult == 0, "socketpair")
    let parentSock = socks[0]  // parent receives
    let childSock  = socks[1]  // child sends
    print("[selftest] step 3: socketpair created (parent=\(parentSock), child=\(childSock))")

    // --- Step 4: Spawn a child to send the fd via SCM_RIGHTS ---
    // The child is a re-invocation of this binary with "send_fd <sock> <fd>".
    // posix_spawn is used because fork() is unavailable in Swift.
    let selfPath = CommandLine.arguments[0]
    let childPid = spawnSendFDChild(
        binaryPath: selfPath,
        sockFD: childSock,
        targetFD: tempFD
    )
    check(childPid > 0, "spawn send_fd child (pid \(childPid))")

    // The parent no longer needs these fds; close them before waiting.
    close(childSock)
    close(tempFD)
    print("[selftest] step 4: child pid \(childPid) spawned; parent copies of fds closed")

    // --- Step 5: Wait for child to exit (proves sender-gone capability lifetime) ---
    var childStatus: Int32 = 0
    waitpid(childPid, &childStatus, 0)
    let childExited = wifExited(childStatus) && wExitStatus(childStatus) == 0
    check(childExited, "child exited cleanly (wExitStatus=\(wExitStatus(childStatus)))")
    print("[selftest] step 5: child process (sender) has exited -- fd is now sender-gone")

    // --- Step 6: Receive the fd via SCM_RIGHTS ---
    let receivedFD = scmReceiveFD(sock: parentSock)
    check(receivedFD >= 0, "SCM_RIGHTS fd receive (returned \(receivedFD))")
    print("[selftest] step 6: received fd \(receivedFD) via SCM_RIGHTS")
    close(parentSock)

    // --- Step 7a: Verify READ capability on the received fd (after sender exit) ---
    let seekResult = lseek(receivedFD, 0, SEEK_SET)
    check(seekResult == 0, "lseek to start on received fd (errno \(errno))")

    var readBuf = [UInt8](repeating: 0, count: magicPayload.count + 8)
    let nRead = readBuf.withUnsafeMutableBytes { raw in
        // SAFETY: readBuf is a non-empty fixed array, so baseAddress is non-nil
        // inside withUnsafeMutableBytes per the Swift stdlib contract.
        read(receivedFD, raw.baseAddress!, magicPayload.count)
    }
    check(nRead == magicPayload.count,
          "read \(magicPayload.count) bytes via received fd (got \(nRead))")
    let readSlice = Array(readBuf[0..<magicPayload.count])
    check(readSlice == magicPayload, "payload matches magic bytes")
    let payloadStr = String(bytes: readSlice, encoding: .utf8) ?? "<non-utf8>"
    print("[selftest] step 7a: READ via received fd after sender exit -- payload: \"\(payloadStr)\"")

    // --- Step 7b: Verify WRITE capability on the received fd ---
    let writePayload: [UInt8] = Array("WRITE_VERIFIED".utf8)
    let nWritten = writePayload.withUnsafeBytes { raw in
        // SAFETY: writePayload is a non-empty fixed array, so baseAddress is
        // non-nil inside withUnsafeBytes per the Swift stdlib contract.
        write(receivedFD, raw.baseAddress!, raw.count)
    }
    check(nWritten == writePayload.count,
          "write via received fd (wrote \(nWritten) of \(writePayload.count))")
    print("[selftest] step 7b: WRITE via received fd -- \(nWritten) bytes written")

    // Confirm the write landed by seeking back and reading both payloads.
    let seekBack = lseek(receivedFD, 0, SEEK_SET)
    check(seekBack == 0, "lseek back to start for verification (errno \(errno))")
    let totalLen = magicPayload.count + writePayload.count
    var verifyBuf = [UInt8](repeating: 0, count: totalLen + 8)
    let nVerify = verifyBuf.withUnsafeMutableBytes { raw in
        // SAFETY: verifyBuf is a non-empty fixed array, so baseAddress is non-nil
        // inside withUnsafeMutableBytes per the Swift stdlib contract.
        read(receivedFD, raw.baseAddress!, totalLen)
    }
    check(nVerify == totalLen, "re-read combined payload (\(nVerify) of \(totalLen))")
    let combined = Array(verifyBuf[0..<totalLen])
    check(combined == magicPayload + writePayload, "combined payload matches expected bytes")
    print("[selftest] step 7c: read-back confirms both payloads intact")

    // --- Step 8: Verify correct close behavior ---
    let closeResult = close(receivedFD)
    check(closeResult == 0, "close received fd (errno \(errno))")
    // A second close must return EBADF.
    let closeAgain = close(receivedFD)
    check(closeAgain == -1 && errno == EBADF,
          "second close returns EBADF (got \(closeAgain), errno \(errno))")
    print("[selftest] step 8: close behavior correct (EBADF on double-close)")

    // --- Summary ---
    print()
    print("[selftest] ALL CHECKS PASSED")
    print("[selftest] SCM_RIGHTS fd-passing proven:")
    print("[selftest]   fd passed from child to parent over UNIX socketpair")
    print("[selftest]   read/write capability confirmed on received fd")
    print("[selftest]   fd remains usable AFTER sender (child) has exited")
    print("[selftest]   close() returns 0; double-close returns EBADF")
    exit(0)
}

// MARK: - Sub-command: send_fd (child helper for selftest)

/// Called when the binary is re-spawned with arguments: send_fd <sock> <fd>.
///
/// Sends <fd> over the UNIX socket <sock> via SCM_RIGHTS, then exits 0.
/// The parent opened both fds and passed them as file-descriptor inherits
/// via posix_spawn. This avoids fork() (unavailable in Swift >= 6.0).
func runSendFD(sockFDArg: String, targetFDArg: String) {
    guard let sockFD = Int32(sockFDArg), let targetFD = Int32(targetFDArg) else {
        fputs("[send_fd] bad arguments: \(sockFDArg) \(targetFDArg)\n", stderr)
        exit(1)
    }
    scmSendFD(sock: sockFD, fd: targetFD)
    close(targetFD)
    close(sockFD)
    exit(0)
}

// MARK: - Raw device preflight
//
// DiskIdentity, parseRawDevicePath, wholeDiskPath, wholeDiskBSD, the pure
// preflight evaluator (evaluateRawDevicePreflight), identity capture
// (diskIdentity(fromPlist:...)), and identity comparison
// (identityMismatchFields) all live in the AuthopenProbeCore library so the
// accept/refuse decisions can be unit-tested against saved plist fixtures with
// no hardware. The functions below are the thin diskutil-calling wrappers that
// fetch a plist and then delegate the decision to that pure core.

/// Run `diskutil info -plist <diskPath>` and parse the plist output.
///
/// Returns the parsed top-level dictionary, or nil if the command fails or
/// the output cannot be parsed. Uses Foundation's PropertyListSerialization.
func diskutilInfoPlist(diskPath: String) -> [String: Any]? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    task.arguments = ["info", "-plist", diskPath]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()  // suppress stderr noise
    do {
        try task.run()
    } catch {
        fputs("[preflight] diskutil launch failed: \(error)\n", stderr)
        return nil
    }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        fputs("[preflight] diskutil info failed for \(diskPath) (exit \(task.terminationStatus))\n", stderr)
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    do {
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
        return obj as? [String: Any]
    } catch {
        fputs("[preflight] plist parse failed: \(error)\n", stderr)
        return nil
    }
}

/// Query diskutil to determine the whole-disk BSD name of the boot/system disk.
///
/// Runs `diskutil info -plist /` and reads the "ParentWholeDisk" key (or
/// "WholeDisk" if present) from the result. Returns nil if the query fails.
func bootDiskWholeBSD() -> String? {
    guard let plist = diskutilInfoPlist(diskPath: "/") else { return nil }
    // "ParentWholeDisk" is set for a partition; "/" is always a partition, so
    // this key gives us the parent disk (e.g. "disk0" for the internal SSD).
    if let parent = plist["ParentWholeDisk"] as? String, !parent.isEmpty {
        return parent
    }
    // Fallback: "WholeDisk" may be present in some diskutil versions.
    if let whole = plist["WholeDisk"] as? String, !whole.isEmpty {
        return whole
    }
    return nil
}

/// Run the code-level preflight safety checks for a /dev/rdiskN target.
///
/// Enforces the preflight invariant documented in the runbook:
///   - target is external
///   - target is removable
///   - target is NOT internal
///   - target is NOT the boot/system disk
///
/// Also records the disk identity and returns it so the caller can re-check
/// immediately before opening. Exits with code 3 on any refusal.
func rawDevicePreflight(rawPath: String) -> DiskIdentity {
    // Step 1: Validate the path format before printing the "detected" header.
    // The pure parser (in AuthopenProbeCore) is the single source of truth for
    // the /dev/rdiskN shape; we surface the same REFUSED message on failure.
    guard parseRawDevicePath(rawPath) != nil else {
        fputs("[preflight] REFUSED: '\(rawPath)' is not a valid /dev/rdiskN path\n", stderr)
        fputs("[preflight] Accepted form: /dev/rdisk0, /dev/rdisk1, /dev/rdisk4, etc.\n", stderr)
        exit(3)
    }

    print("[preflight] raw device target detected: \(rawPath)")

    // Step 2: Derive the whole-disk /dev/diskN path and the BSD name. The path
    // format already passed parseRawDevicePath above, so wholeDiskBSD(fromRaw:)
    // is guaranteed non-nil here; fall back to the derived path defensively.
    let diskPath = wholeDiskPath(fromRaw: rawPath)
    let wholeBSD = wholeDiskBSD(fromRaw: rawPath) ?? String(diskPath.dropFirst("/dev/".count))
    print("[preflight] paired whole-disk path: \(diskPath) (BSD name: \(wholeBSD))")

    // Step 3: Query diskutil info for the whole disk (wrapper-owned I/O).
    guard let plist = diskutilInfoPlist(diskPath: diskPath) else {
        fputs("[preflight] REFUSED: could not query diskutil info for \(diskPath)\n", stderr)
        exit(3)
    }

    // Step 4: Resolve the boot-disk BSD name (wrapper-owned I/O). nil here maps
    // to the pure evaluator's `.bootDiskUnknown` refusal below.
    let bootWholeBSD = bootDiskWholeBSD()

    // Step 5: Delegate the accept/refuse decision to the pure evaluator. It
    // checks external -> removable -> internal -> boot-disk -> identity in
    // order and returns the FIRST gate that failed. We print the same per-gate
    // progress and refusal lines the inline logic printed, so the real
    // `authopen <device>` output is unchanged.
    let decision = evaluateRawDevicePreflight(
        rawPath: rawPath,
        plist: plist,
        bootWholeBSD: bootWholeBSD
    )

    switch decision {
    case .refuse(let reason):
        printPreflightRefusal(reason, diskPath: diskPath, plist: plist, bootWholeBSD: bootWholeBSD)
        exit(3)

    case .accept(let identity):
        // Echo the gate-passed progress lines exactly as before. The removable
        // gate passed, so at least one of these three flags is true; reading
        // them through the shared helper keeps the line consistent with the
        // pure evaluator's decision.
        print("[preflight] External: YES")
        let flags = removabilityFlags(plist: plist)
        print("[preflight] Removable: YES (Removable=\(flags.removable) RemovableMedia=\(flags.removableMedia) Ejectable=\(flags.ejectable))")
        print("[preflight] Internal: NO (good)")
        // Invariant: gate 5 (boot-disk) refuses with .bootDiskUnknown when
        // bootWholeBSD is nil, so reaching .accept guarantees it is non-nil.
        // Bind it explicitly rather than papering over the guarantee with ?? "".
        let bootBSD = bootWholeBSD!
        print("[preflight] Boot/system disk: /dev/\(bootBSD)")
        print("[preflight] Target is NOT the boot disk: OK")

        print("[preflight] disk identity recorded:")
        print("[preflight]   BSD name  : \(identity.wholeDiskBSD)")
        print("[preflight]   Media name: \(identity.mediaName)")
        let mb = identity.totalSizeBytes / (1024 * 1024)
        print("[preflight]   Size      : \(identity.totalSizeBytes) bytes (\(mb) MB)")
        print("[preflight]   UUID/anchor: \(identity.diskUUID)")

        return identity
    }
}

/// Print the operator-facing refusal lines for a pure-evaluator refusal.
///
/// Each branch reproduces, byte-for-byte, the lines the inline guards printed
/// before they called exit(3). Gates that passed before the refused one print
/// their "YES"/"NO (good)" progress line first, matching the original order.
func printPreflightRefusal(
    _ reason: PreflightRefusal,
    diskPath: String,
    plist: [String: Any],
    bootWholeBSD: String?
) {
    switch reason {
    case .malformedPath(let rawPath):
        // Step-1 path failure is handled before this function in the real flow;
        // surfaced here for completeness so the message stays identical.
        fputs("[preflight] REFUSED: '\(rawPath)' is not a valid /dev/rdiskN path\n", stderr)
        fputs("[preflight] Accepted form: /dev/rdisk0, /dev/rdisk1, /dev/rdisk4, etc.\n", stderr)

    case .notExternal(let busProtocol):
        fputs("[preflight] REFUSED: disk is NOT external (External=false)\n", stderr)
        fputs("[preflight] Only external disks are safe targets for this probe.\n", stderr)
        fputs("[preflight] BusProtocol: \(busProtocol)\n", stderr)

    case .notRemovable(let removable, let removableMedia, let ejectable):
        // External passed before this gate; echo its progress line first.
        print("[preflight] External: YES")
        fputs("[preflight] REFUSED: disk is NOT removable\n", stderr)
        fputs("[preflight]   Removable=\(removable) RemovableMedia=\(removableMedia) Ejectable=\(ejectable)\n", stderr)

    case .isInternal:
        // External + Removable passed; echo both progress lines first.
        print("[preflight] External: YES")
        let flags = removabilityFlags(plist: plist)
        print("[preflight] Removable: YES (Removable=\(flags.removable) RemovableMedia=\(flags.removableMedia) Ejectable=\(flags.ejectable))")
        fputs("[preflight] REFUSED: disk is Internal (Internal=true)\n", stderr)
        fputs("[preflight] Internal drives are never valid targets.\n", stderr)

    case .bootDiskUnknown:
        // External + Removable + Internal passed; echo those progress lines.
        printGatesThroughInternal(plist: plist)
        fputs("[preflight] REFUSED: could not determine boot disk (diskutil info / failed)\n", stderr)
        fputs("[preflight] Cannot verify the target is not the boot disk. Aborting.\n", stderr)

    case .isBootDisk(_, let bootBSD):
        // External + Removable + Internal passed and the boot disk resolved;
        // the target's whole-disk BSD name equals the boot disk's, so refuse.
        printGatesThroughInternal(plist: plist)
        print("[preflight] Boot/system disk: /dev/\(bootBSD)")
        fputs("[preflight] REFUSED: target '\(diskPath)' IS the boot/system disk (/dev/\(bootBSD))\n", stderr)
        fputs("[preflight] Writing to the boot disk would corrupt macOS. Aborting.\n", stderr)

    case .missingIdentityField(let field):
        // All safety gates passed; only the identity capture failed because a
        // required key (e.g. TotalSize) was absent. Print the "diskutil info
        // missing <field>" line and the REFUSED summary, plus the boot-disk
        // progress lines that preceded them.
        printGatesThroughInternal(plist: plist)
        if let bootBSD = bootWholeBSD {
            print("[preflight] Boot/system disk: /dev/\(bootBSD)")
            print("[preflight] Target is NOT the boot disk: OK")
        }
        fputs("[preflight] diskutil info missing \(field) for \(diskPath)\n", stderr)
        fputs("[preflight] REFUSED: could not capture disk identity for \(diskPath)\n", stderr)
    }
}

/// Extract the three removability flags from a diskutil plist as a triple.
///
/// Uses the SAME `as? Bool ?? false` reads as the pure evaluator's removable
/// gate (PreflightCore.evaluateRawDevicePreflight), so any progress line built
/// from this triple reports exactly what the gate decided on. Centralizing the
/// extraction keeps the operator-facing "Removable: ..." line from drifting
/// from the value the gate actually used.
func removabilityFlags(plist: [String: Any]) -> (removable: Bool, removableMedia: Bool, ejectable: Bool) {
    let removable = plist["Removable"] as? Bool ?? false
    let removableMedia = plist["RemovableMedia"] as? Bool ?? false
    let ejectable = plist["Ejectable"] as? Bool ?? false
    return (removable, removableMedia, ejectable)
}

/// Echo the External/Removable/Internal progress lines for refusals that occur
/// at or after the boot-disk gate (all three safety gates passed).
func printGatesThroughInternal(plist: [String: Any]) {
    print("[preflight] External: YES")
    let flags = removabilityFlags(plist: plist)
    print("[preflight] Removable: YES (Removable=\(flags.removable) RemovableMedia=\(flags.removableMedia) Ejectable=\(flags.ejectable))")
    print("[preflight] Internal: NO (good)")
}

/// Re-query diskutil and verify the identity snapshot still matches.
///
/// BSD numbers change on disk reinsert, so any mismatch means the target
/// is not the same physical medium. Exits with code 3 on mismatch.
///
/// This re-check fetches the whole-disk plist ONCE and uses it for both the
/// hardware-flag re-check (external / removable / not-internal / not-boot, via
/// the pure evaluator) and the identity-field comparison. Re-running the full
/// evaluator -- not just the UUID compare -- closes the window where a disk
/// keeps its UUID/size/name but flips a hardware flag (e.g. an enclosure that
/// re-presents the same medium as internal); the UUID mismatch alone would not
/// catch that.
func revalidateDiskIdentity(_ recorded: DiskIdentity) {
    print("[preflight] re-validating disk identity before open...")

    // Fetch the whole-disk plist once; reuse it for both the hardware re-check
    // and the identity comparison below.
    let diskPath = "/dev/\(recorded.wholeDiskBSD)"
    guard let plist = diskutilInfoPlist(diskPath: diskPath) else {
        fputs("[preflight] ABORTED: could not re-query disk identity for \(recorded.wholeDiskBSD)\n", stderr)
        fputs("[preflight] The disk may have been removed or renumbered. Aborting.\n", stderr)
        exit(3)
    }

    // Re-run the full hardware preflight on the fresh plist. The recorded BSD
    // is a whole-disk name (e.g. "disk4"); the evaluator expects the raw node,
    // so reconstruct "/dev/rdisk4". A flag flip since the first preflight (now
    // internal, no longer removable, now the boot disk, etc.) refuses here.
    let rawPath = "/dev/r\(recorded.wholeDiskBSD)"
    let recheck = evaluateRawDevicePreflight(
        rawPath: rawPath,
        plist: plist,
        bootWholeBSD: bootDiskWholeBSD()
    )
    if case .refuse(let reason) = recheck {
        fputs("[preflight] ABORTED: hardware re-check failed before open (\(reason))\n", stderr)
        fputs("[preflight] A disk attribute changed since the first preflight. Aborting.\n", stderr)
        exit(3)
    }

    // Identity field comparison uses the same fetched plist.
    guard case .success(let current) = diskIdentity(fromPlist: plist, wholeDiskBSD: recorded.wholeDiskBSD) else {
        fputs("[preflight] ABORTED: could not re-capture disk identity for \(recorded.wholeDiskBSD)\n", stderr)
        fputs("[preflight] The disk may have been removed or renumbered. Aborting.\n", stderr)
        exit(3)
    }

    // Compare each identity field via the pure comparator; any mismatch aborts.
    // identityMismatchFields returns the changed field names ("UUID/anchor",
    // "size", "media name") in the same order the inline checks ran, so the
    // per-field MISMATCH lines stay identical.
    let mismatchedFields = identityMismatchFields(recorded: recorded, current: current)
    for field in mismatchedFields {
        switch field {
        case "UUID/anchor":
            fputs("[preflight] MISMATCH: UUID/anchor changed\n", stderr)
            fputs("[preflight]   recorded : \(recorded.diskUUID)\n", stderr)
            fputs("[preflight]   current  : \(current.diskUUID)\n", stderr)
        case "size":
            fputs("[preflight] MISMATCH: size changed\n", stderr)
            fputs("[preflight]   recorded : \(recorded.totalSizeBytes)\n", stderr)
            fputs("[preflight]   current  : \(current.totalSizeBytes)\n", stderr)
        case "media name":
            fputs("[preflight] MISMATCH: media name changed\n", stderr)
            fputs("[preflight]   recorded : \(recorded.mediaName)\n", stderr)
            fputs("[preflight]   current  : \(current.mediaName)\n", stderr)
        default:
            fputs("[preflight] MISMATCH: \(field) changed\n", stderr)
        }
    }

    if !mismatchedFields.isEmpty {
        fputs("[preflight] ABORTED: disk identity changed since preflight.\n", stderr)
        fputs("[preflight] Disk may have been reinserted (BSD numbers change on reinsert).\n", stderr)
        fputs("[preflight] Re-run from the beginning to start a fresh preflight.\n", stderr)
        exit(3)
    }

    print("[preflight] identity re-check PASSED: \(current.summary)")
}

/// Print a safety summary and require the operator to type the exact BSD name.
///
/// The confirmation string is the whole-disk BSD name (e.g. "disk4"), NOT the
/// raw-device node. This prevents accidental confirmation with a stale or
/// mistyped value, while keeping the required string short and unambiguous.
///
/// Any input other than the exact BSD name aborts with exit code 3.
func requireOperatorConfirmation(identity: DiskIdentity, rawPath: String) {
    let mb = identity.totalSizeBytes / (1024 * 1024)
    print()
    print("[confirm] ==================== SAFETY SUMMARY ====================")
    print("[confirm] Target raw device : \(rawPath)")
    print("[confirm] Whole disk        : /dev/\(identity.wholeDiskBSD)")
    print("[confirm] Media name        : \(identity.mediaName)")
    print("[confirm] Size              : \(identity.totalSizeBytes) bytes (\(mb) MB)")
    print("[confirm] UUID/anchor       : \(identity.diskUUID)")
    print("[confirm]")
    print("[confirm] All preflight checks PASSED:")
    print("[confirm]   External: YES | Removable: YES | Internal: NO | Not boot disk: YES")
    print("[confirm]   Identity re-validated immediately before this prompt.")
    print("[confirm]")
    print("[confirm] To proceed, type the whole-disk BSD name and press Enter.")
    print("[confirm] Expected: \(identity.wholeDiskBSD)")
    print("[confirm] Any other input ABORTS. Ctrl-C also aborts.")
    print("[confirm] ===========================================================")
    print()
    print("Enter BSD name to confirm > ", terminator: "")

    // Flush stdout so the prompt appears before readLine blocks.
    fflush(stdout)
    let input = readLine(strippingNewline: true) ?? ""
    let trimmed = input.trimmingCharacters(in: .whitespaces)

    guard trimmed == identity.wholeDiskBSD else {
        fputs("\n[confirm] ABORTED: input '\(trimmed)' does not match expected '\(identity.wholeDiskBSD)'\n", stderr)
        exit(3)
    }
    print("[confirm] Confirmed: '\(trimmed)' -- proceeding to authopen")
    print()
}

// MARK: - Mode 2: Scaffolded interactive authopen path (OPERATOR-ONLY)

/// Scaffold for running /usr/libexec/authopen -stdoutpipe and receiving the fd
/// via SCM_RIGHTS over its stdout pipe.
///
/// THIS FUNCTION SPAWNS AN INTERACTIVE AUTH PROMPT. See README.md for the full
/// operator checklist before pointing this at any /dev/rdiskN.
///
/// For /dev/rdiskN targets, enforces the full preflight invariant in code:
///   1. Validates path format (/dev/rdiskN only).
///   2. Resolves /dev/diskN and queries disk attributes via diskutil.
///   3. Refuses if the disk is not external, not removable, is internal, or is boot.
///   4. Records media identity (BSD name, media name, size, UUID).
///   5. Re-checks the hardware flags (external/removable/not-internal/not-boot)
///      and identity immediately before spawning authopen.
///   6. Prints a safety summary and requires explicit operator confirmation.
/// Regular file targets (not /dev/rdisk*) bypass preflight -- they are the
/// safe fd-passing isolation test.
///
/// Open flags: O_RDWR | O_EXCL | O_SYNC (first tested set per the spike plan).
func runAuthopenScaffold(targetPath: String) {
    // Determine if this is a raw device target or a regular-file target.
    let isRawDevice = targetPath.hasPrefix("/dev/rdisk")
    // A regular-file target is anything not under /dev/. The post-receive
    // isolation write runs only for these; raw devices stay open/fstat/close.
    let isRegularFile = !targetPath.hasPrefix("/dev/")

    if isRawDevice {
        // --- Raw device path: run the full preflight invariant. ---

        // Step A: Run static checks (external/removable/not-boot) and record identity.
        let identity = rawDevicePreflight(rawPath: targetPath)

        // Step B: Re-check identity immediately before the open.
        revalidateDiskIdentity(identity)

        // Step C: Print safety summary and require explicit confirmation.
        requireOperatorConfirmation(identity: identity, rawPath: targetPath)

        // All preflight passed; fall through to the authopen spawn below.
    } else if targetPath.hasPrefix("/dev/") {
        // --- Other /dev node: reject. Only /dev/rdiskN is an accepted
        // device shape. A buffered node (/dev/diskN), a partition slice, or
        // any other /dev path must not reach authopen unguarded. ---
        fputs("[preflight] REFUSED: '\(targetPath)' is a /dev path but not /dev/rdiskN\n", stderr)
        fputs("[preflight] Accepted device form: /dev/rdisk0, /dev/rdisk1, /dev/rdisk4, etc.\n", stderr)
        fputs("[preflight] Use the raw node (/dev/rdiskN), not the buffered node or a slice.\n", stderr)
        exit(3)
    } else {
        // --- Regular file path: no preflight, proceed directly. ---
        // Anything not under /dev/ is treated as a regular file. This is the
        // deliberate unguarded fd-passing isolation test (selftest and
        // `authopen <regular-file>`); it must NOT be gated by disk preflight.
        print("[authopen] target is a regular file path -- skipping raw device preflight")
    }

    print("[authopen] interactive authopen scaffold")
    print("[authopen] target path: \(targetPath)")
    print("[authopen] open flags: O_RDWR | O_EXCL | O_SYNC")
    print("[authopen] WARNING: this spawns /usr/libexec/authopen and may prompt")
    print()

    // Build the open flags decimal string for the -o argument.
    // O_RDWR=2, O_EXCL=0x0800, O_SYNC=0x80 on Darwin.
    //
    // Spike-noted deviation: O_EXCL has NO exclusivity effect here. On a
    // regular file (no O_CREAT) O_EXCL is a no-op -- its "fail if the file
    // exists" semantics only apply alongside O_CREAT. Real exclusive-access
    // behavior (refusing to open a busy device) is meaningful only on a raw
    // device node, where the kernel enforces it. We keep O_EXCL in the tested
    // set to mirror the eventual raw-device open, but the regular-file branch
    // gains nothing from it.
    let openFlags: Int32 = O_RDWR | O_EXCL | O_SYNC
    let openFlagsStr = "\(openFlags)"
    print("[authopen] -o flags value: \(openFlagsStr) (O_RDWR|\(O_EXCL)=O_EXCL|O_SYNC)")

    // Create a socketpair; we connect authopen's stdout to one end so we can
    // call recvmsg on the other end for the SCM_RIGHTS payload.
    var socks: [Int32] = [0, 0]
    let sockResult = socketpair(AF_UNIX, SOCK_STREAM, 0, &socks)
    guard sockResult == 0 else {
        fputs("[authopen] socketpair failed (errno \(errno))\n", stderr)
        exit(1)
    }
    let parentSock = socks[0]   // we receive on this end
    let authopenSock = socks[1] // we pass this as authopen's stdout

    // Spawn authopen with its stdout redirected to authopenSock.
    // posix_spawn file actions: dup2(authopenSock, STDOUT_FILENO).
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    posix_spawn_file_actions_adddup2(&fileActions, authopenSock, STDOUT_FILENO)
    // Close authopenSock in the child after the dup2 (not needed there).
    posix_spawn_file_actions_addclose(&fileActions, authopenSock)

    let authopenPath = "/usr/libexec/authopen"
    var childPid: pid_t = 0
    // Build argv as C strings.
    var cArgs: [UnsafeMutablePointer<CChar>?] = [
        strdup("authopen"),
        strdup("-stdoutpipe"),
        strdup("-o"),
        strdup(openFlagsStr),
        strdup(targetPath),
        nil
    ]
    defer { cArgs.compactMap { $0 }.forEach { free($0) } }

    let spawnErr = authopenPath.withCString { pathCStr in
        posix_spawn(&childPid, pathCStr, &fileActions, nil, &cArgs, nil)
    }
    posix_spawn_file_actions_destroy(&fileActions)

    guard spawnErr == 0 else {
        fputs("[authopen] posix_spawn authopen failed (errno \(spawnErr))\n", stderr)
        close(parentSock)
        close(authopenSock)
        exit(1)
    }

    // Close the child-side socket; parent uses parentSock only.
    close(authopenSock)
    print("[authopen] spawned authopen pid \(childPid) -- waiting for auth dialog...")

    // Receive the fd. authopen writes it on its stdout (our parentSock end).
    let receivedFD = scmReceiveFD(sock: parentSock)
    close(parentSock)

    // Wait for authopen to finish.
    var status: Int32 = 0
    waitpid(childPid, &status, 0)
    let exitCode = wifExited(status) ? wExitStatus(status) : -1
    print("[authopen] authopen exited with status \(exitCode)")

    if receivedFD < 0 {
        fputs("[authopen] fd receive failed -- authorization may have been denied\n", stderr)
        fputs("[authopen] or the target path requires Full Disk Access\n", stderr)
        fputs("[authopen] check: does /usr/libexec/authopen exist on this system?\n", stderr)
        exit(1)
    }

    print("[authopen] received fd \(receivedFD) via SCM_RIGHTS from authopen")
    print("[authopen] authopen has exited; privileged side is GONE")
    print("[authopen] fd \(receivedFD) remains open in this process")

    // Basic capability check: stat the received fd.
    var info = stat()
    let statResult = fstat(receivedFD, &info)
    if statResult == 0 {
        let mode = String(info.st_mode, radix: 8, uppercase: false)
        print("[authopen] fstat on received fd: st_size=\(info.st_size) st_mode=\(mode)")
    } else {
        print("[authopen] fstat returned \(statResult) (errno \(errno)) -- may be a raw device node")
    }

    // Isolation write -- REGULAR FILES ONLY. For a regular-file target this
    // proves read/write capability survives through the passed fd after the
    // privileged authopen process has exited, mirroring the selftest's
    // write/read-back step. Raw devices are deliberately skipped: they stay
    // open/fstat/close with NO write payload, so pointing the probe at a disk
    // never writes a byte to it.
    if isRegularFile {
        let isoPayload: [UInt8] = Array("AUTHOPEN_FD_ISOLATION_OK".utf8)
        // Write at offset 0; O_RDWR was requested so the fd should be writable.
        _ = lseek(receivedFD, 0, SEEK_SET)
        let nWritten = isoPayload.withUnsafeBytes { raw in
            // SAFETY: isoPayload is a non-empty fixed array, so baseAddress is
            // non-nil inside withUnsafeBytes per the Swift stdlib contract.
            write(receivedFD, raw.baseAddress!, raw.count)
        }
        if nWritten == isoPayload.count {
            // Seek back and read it to confirm the bytes landed.
            _ = lseek(receivedFD, 0, SEEK_SET)
            var readBack = [UInt8](repeating: 0, count: isoPayload.count)
            let nRead = readBack.withUnsafeMutableBytes { raw in
                // SAFETY: readBack is a non-empty fixed array, so baseAddress is
                // non-nil inside withUnsafeMutableBytes per the stdlib contract.
                read(receivedFD, raw.baseAddress!, isoPayload.count)
            }
            let matched = nRead == isoPayload.count && readBack == isoPayload
            print("[authopen] isolation write through received fd: SUCCESS "
                  + "(\(nWritten) bytes written, read-back \(matched ? "matched" : "MISMATCH"))")
        } else {
            print("[authopen] isolation write through received fd: FAILED "
                  + "(wrote \(nWritten) of \(isoPayload.count), errno \(errno))")
        }
    } else {
        print("[authopen] raw device target -- skipping isolation write (open/fstat/close only)")
    }

    // Close cleanly.
    let closeResult = close(receivedFD)
    print("[authopen] close(fd) returned \(closeResult) (0 = success)")
    print()
    print("[authopen] SCAFFOLD COMPLETE -- operator should record:")
    print("[authopen]   - whether an auth prompt appeared")
    print("[authopen]   - the authorization right shown (e.g. sys.openfile.readwrite.<path>)")
    print("[authopen]   - authopen exit status: \(exitCode)")
    print("[authopen]   - whether /dev/rdiskN target required FDA or removable-media permission")
    print("[authopen]   - `lsof <path>` output to confirm no residual open after close")
    exit(0)
}

// MARK: - SCM_RIGHTS POSIX helpers

/// Send `fd` over `sock` using sendmsg(2) with SCM_RIGHTS ancillary data.
///
/// Uses the manual CMSG layout helpers above (the CMSG_* C macros are not
/// importable into Swift). A 1-byte dummy payload is required because sendmsg
/// will not deliver a control message with an empty data iov on Darwin.
func scmSendFD(sock: Int32, fd: Int32) {
    // Allocate the control message buffer for one Int32 fd.
    let dataSize = MemoryLayout<Int32>.size
    let bufSize  = cmsgSpace(dataSize: dataSize)
    var cmsgBuf  = [UInt8](repeating: 0, count: bufSize)

    // Dummy payload byte (required for Darwin sendmsg to deliver ancdata).
    var iobyte: UInt8 = 0
    var iov = iovec()
    iov.iov_base = withUnsafeMutablePointer(to: &iobyte) {
        UnsafeMutableRawPointer($0)
    }
    iov.iov_len = 1

    var msg = msghdr()
    msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
    msg.msg_iovlen = 1

    cmsgBuf.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        msg.msg_control    = base
        msg.msg_controllen = socklen_t(bufSize)

        // Fill in the cmsghdr fields.
        let cmsg = base.assumingMemoryBound(to: cmsghdr.self)
        cmsg.pointee.cmsg_len   = socklen_t(cmsgLen(dataSize: dataSize))
        cmsg.pointee.cmsg_level = SOL_SOCKET
        cmsg.pointee.cmsg_type  = SCM_RIGHTS

        // Copy the fd value into CMSG_DATA (bytes immediately after the header).
        var fdValue = fd
        withUnsafeBytes(of: &fdValue) { fdRaw in
            // SAFETY: fdValue is a single non-zero-size Int32, so withUnsafeBytes
            // yields a non-empty buffer whose baseAddress is non-nil.
            cmsgData(cmsg).copyMemory(from: fdRaw.baseAddress!, byteCount: dataSize)
        }

        let n = sendmsg(sock, &msg, 0)
        if n < 0 {
            fputs("[scmSendFD] sendmsg failed (errno \(errno))\n", stderr)
            exit(1)
        }
    }
}

/// Receive one fd from `sock` via SCM_RIGHTS ancillary data using recvmsg(2).
///
/// Returns the received fd (>= 0) on success, -1 on failure.
/// Uses the manual CMSG layout helpers above (the CMSG_* macros are not
/// importable into Swift).
func scmReceiveFD(sock: Int32) -> Int32 {
    let dataSize = MemoryLayout<Int32>.size
    let bufSize  = cmsgSpace(dataSize: dataSize)
    var cmsgBuf  = [UInt8](repeating: 0, count: bufSize)

    var iobyte: UInt8 = 0
    var iov = iovec()
    iov.iov_base = withUnsafeMutablePointer(to: &iobyte) {
        UnsafeMutableRawPointer($0)
    }
    iov.iov_len = 1

    var msg = msghdr()
    msg.msg_iov    = withUnsafeMutablePointer(to: &iov) { $0 }
    msg.msg_iovlen = 1

    var receivedFD: Int32 = -1

    cmsgBuf.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        msg.msg_control    = base
        msg.msg_controllen = socklen_t(bufSize)

        let n = recvmsg(sock, &msg, 0)
        guard n >= 0 else {
            fputs("[scmReceiveFD] recvmsg failed (errno \(errno))\n", stderr)
            return
        }

        // Walk the cmsghdr chain looking for SCM_RIGHTS.
        guard let firstCmsg = cmsgFirstHdr(&msg) else { return }
        let cmsg = firstCmsg
        // We only send one control message, so checking the first is sufficient.
        if cmsg.pointee.cmsg_level == SOL_SOCKET
            && cmsg.pointee.cmsg_type == SCM_RIGHTS {
            // Read the fd value from the data region.
            var fdValue: Int32 = -1
            withUnsafeMutableBytes(of: &fdValue) { fdBuf in
                fdBuf.baseAddress?.copyMemory(
                    from: cmsgData(cmsg),
                    byteCount: dataSize
                )
            }
            receivedFD = fdValue
        }
    }

    return receivedFD
}

// MARK: - posix_spawn helper for the selftest child

/// Spawn a child process that is a re-invocation of this binary with
/// sub-command "send_fd <sock> <fd>".
///
/// posix_spawn inherits open file descriptors by default; both sockFD and
/// targetFD are passed through. Returns the child pid (> 0) or -1 on error.
func spawnSendFDChild(binaryPath: String, sockFD: Int32, targetFD: Int32) -> pid_t {
    var childPid: pid_t = 0
    var cArgs: [UnsafeMutablePointer<CChar>?] = [
        strdup(binaryPath),
        strdup("send_fd"),
        strdup("\(sockFD)"),
        strdup("\(targetFD)"),
        nil
    ]
    defer { cArgs.compactMap { $0 }.forEach { free($0) } }

    let err = binaryPath.withCString { pathCStr in
        posix_spawn(&childPid, pathCStr, nil, nil, &cArgs, nil)
    }
    if err != 0 {
        fputs("[spawnSendFDChild] posix_spawn failed (errno \(err))\n", stderr)
        return -1
    }
    return childPid
}

// MARK: - Assertion helper

/// Print the check result; exit(1) on failure.
func check(_ condition: Bool, _ label: String) {
    if condition {
        print("[check] OK: \(label)")
    } else {
        fputs("[check] FAIL: \(label)\n", stderr)
        exit(1)
    }
}

// MARK: - Platform info

/// Brief uname string for logging (sysname, release, machine).
func unameString() -> String {
    var info = utsname()
    uname(&info)
    // SAFETY: each utsname field is a non-empty fixed-size C char tuple, so
    // withUnsafeBytes yields a non-empty buffer with a non-nil baseAddress.
    let sysname = withUnsafeBytes(of: &info.sysname) {
        String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
    let machine = withUnsafeBytes(of: &info.machine) {
        String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
    let release = withUnsafeBytes(of: &info.release) {
        String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
    return "\(sysname) \(release) \(machine)"
}
