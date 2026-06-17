/// UnmountTests.swift - unit tests for Unmount.unmountWholeDisk using an injected
/// process runner instead of a real diskutil invocation.
///
/// Coverage:
///   - A disk with "/" in mountPoints throws refusedRootMount.
///   - A successful diskutil run (exit 0) completes without throwing.
///   - A failing diskutil run (non-zero exit) throws unmountFailed.
///   - Eject returns true on exit 0, false on non-zero exit.
///   - The injected runner receives the correct diskutil arguments.

import Testing
@testable import PrivilegedHelper
import DiskModel

// MARK: - Fixture helpers

/// Make a minimal DiskDescriptor for Unmount tests.
private func makeUnmountTarget(
    bsdName: String = "disk4",
    mountPoints: [String] = []
) -> DiskDescriptor {
    DiskDescriptor(
        bsdName: bsdName,
        devicePath: "/dev/\(bsdName)",
        rawDevicePath: "/dev/r\(bsdName)",
        sizeBytes: 32_000_000_000,
        isRemovable: true,
        isEjectable: true,
        isInternal: false,
        busProtocol: .usb,
        isWritable: true,
        isSynthesized: false,
        carriesMacOSSystem: false,
        carriesTimeMachine: false,
        mountPoints: mountPoints
    )
}

// MARK: - Root mount refusal

@Suite("Unmount: refuses disks mounted at /")
struct UnmountRootMountTests {

    @Test("Disk mounted at / throws refusedRootMount")
    func refusesDiskAtRoot() {
        let disk = makeUnmountTarget(mountPoints: ["/"])
        // The runner should never be called; the root-mount guard fires first.
        let runner: (String, [String]) -> Unmount.ProcessRunResult = { _, _ in
            Unmount.ProcessRunResult(exitCode: 0, combinedOutput: "")
        }
        do {
            try Unmount.unmountWholeDisk(disk, runner: runner)
            Issue.record("Expected refusedRootMount to be thrown")
        } catch HelperError.refusedRootMount(let bsdName) {
            #expect(bsdName == "disk4")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Disk with both / and another mount point throws refusedRootMount")
    func refusesDiskWithRootAndOther() {
        let disk = makeUnmountTarget(mountPoints: ["/Volumes/Data", "/"])
        let runner: (String, [String]) -> Unmount.ProcessRunResult = { _, _ in
            Unmount.ProcessRunResult(exitCode: 0, combinedOutput: "")
        }
        #expect(throws: (any Error).self) {
            try Unmount.unmountWholeDisk(disk, runner: runner)
        }
    }

    @Test("Disk with only /Volumes/X is not refused (not root)")
    func allowsNonRootMount() throws {
        let disk = makeUnmountTarget(mountPoints: ["/Volumes/MyDrive"])
        let runner: (String, [String]) -> Unmount.ProcessRunResult = { _, _ in
            Unmount.ProcessRunResult(exitCode: 0, combinedOutput: "Unmount successful")
        }
        // Should not throw.
        try Unmount.unmountWholeDisk(disk, runner: runner)
    }

    @Test("Disk with no mount points is not refused")
    func allowsNoMountPoints() throws {
        let disk = makeUnmountTarget(mountPoints: [])
        let runner: (String, [String]) -> Unmount.ProcessRunResult = { _, _ in
            Unmount.ProcessRunResult(exitCode: 0, combinedOutput: "")
        }
        try Unmount.unmountWholeDisk(disk, runner: runner)
    }
}

// MARK: - Process runner result handling

@Suite("Unmount: process runner exit code handling")
struct UnmountRunnerResultTests {

    @Test("Exit 0 from runner means success; no throw")
    func exitZeroSucceeds() throws {
        let disk = makeUnmountTarget()
        let runner: (String, [String]) -> Unmount.ProcessRunResult = { _, _ in
            Unmount.ProcessRunResult(exitCode: 0, combinedOutput: "Unmounted successfully")
        }
        try Unmount.unmountWholeDisk(disk, runner: runner)
    }

    @Test("Non-zero exit throws unmountFailed")
    func nonZeroExitThrowsUnmountFailed() {
        let disk = makeUnmountTarget()
        let runner: (String, [String]) -> Unmount.ProcessRunResult = { _, _ in
            Unmount.ProcessRunResult(exitCode: 1, combinedOutput: "volume is busy")
        }
        do {
            try Unmount.unmountWholeDisk(disk, runner: runner)
            Issue.record("Expected unmountFailed to be thrown")
        } catch HelperError.unmountFailed(let detail) {
            // The detail must contain the output and the exit code.
            #expect(detail.contains("volume is busy"))
            #expect(detail.contains("1"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Runner receives the correct diskutil path")
    func runnerReceivesCorrectPath() throws {
        let disk = makeUnmountTarget()
        var receivedPath = ""
        let runner: (String, [String]) -> Unmount.ProcessRunResult = { path, _ in
            receivedPath = path
            return Unmount.ProcessRunResult(exitCode: 0, combinedOutput: "")
        }
        try Unmount.unmountWholeDisk(disk, runner: runner)
        #expect(receivedPath == Unmount.diskutilPath)
    }

    @Test("Runner receives unmountDisk force and device path as arguments")
    func runnerReceivesCorrectArguments() throws {
        let disk = makeUnmountTarget(bsdName: "disk4")
        var receivedArgs: [String] = []
        let runner: (String, [String]) -> Unmount.ProcessRunResult = { _, args in
            receivedArgs = args
            return Unmount.ProcessRunResult(exitCode: 0, combinedOutput: "")
        }
        try Unmount.unmountWholeDisk(disk, runner: runner)
        #expect(receivedArgs.contains("unmountDisk"))
        #expect(receivedArgs.contains("force"))
        #expect(receivedArgs.contains("/dev/disk4"))
    }
}

// MARK: - Eject tests

@Suite("Unmount.eject")
struct EjectTests {

    @Test("Eject returns true on exit 0")
    func ejectSucceeds() {
        let disk = makeUnmountTarget(bsdName: "disk4")
        let runner: (String, [String]) -> Unmount.ProcessRunResult = { _, _ in
            Unmount.ProcessRunResult(exitCode: 0, combinedOutput: "")
        }
        let ok = Unmount.eject(disk, runner: runner)
        #expect(ok == true)
    }

    @Test("Eject returns false on non-zero exit")
    func ejectFails() {
        let disk = makeUnmountTarget(bsdName: "disk4")
        let runner: (String, [String]) -> Unmount.ProcessRunResult = { _, _ in
            Unmount.ProcessRunResult(exitCode: 1, combinedOutput: "eject failed")
        }
        let ok = Unmount.eject(disk, runner: runner)
        #expect(ok == false)
    }

    @Test("Eject runner receives 'eject' as first argument")
    func ejectPassesCorrectArgs() {
        let disk = makeUnmountTarget(bsdName: "disk5")
        var receivedArgs: [String] = []
        let runner: (String, [String]) -> Unmount.ProcessRunResult = { _, args in
            receivedArgs = args
            return Unmount.ProcessRunResult(exitCode: 0, combinedOutput: "")
        }
        Unmount.eject(disk, runner: runner)
        #expect(receivedArgs.first == "eject")
        #expect(receivedArgs.contains("/dev/disk5"))
    }
}
