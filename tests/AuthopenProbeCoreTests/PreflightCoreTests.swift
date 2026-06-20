/// PreflightCoreTests -- hardware-free fixture tests for the probe preflight.
///
/// These tests exercise the pure decision logic in AuthopenProbeCore against
/// saved `diskutil info -plist` shapes. They never spawn diskutil and never
/// touch a real device, so the probe's accept/refuse safety decisions can be
/// proven with no USB stick attached. Each case below maps to a refusal path
/// the executable enforces inline before it ever opens a /dev/rdiskN target.
import Foundation
import Testing
@testable import AuthopenProbeCore

// MARK: - Fixture plists

// Fixtures are built by functions rather than module-level `let`s: under
// Swift 6 strict concurrency a global `[String: Any]` is not Sendable and is
// rejected as shared mutable state. Building a fresh dictionary per call sides
// steps that and lets individual tests mutate a local copy freely.

/// A valid external + removable USB stick. Note the real-world nuance: this
/// stick reports Removable=false but RemovableMedia=true and Ejectable=true,
/// which MUST still accept (a sticky point the inline guard already handled).
private func validUSBPlist() -> [String: Any] {
	return [
		"External": true,
		"Internal": false,
		"Removable": false,
		"RemovableMedia": true,
		"Ejectable": true,
		"MediaName": "SanDisk Ultra USB 3.0 Media",
		"TotalSize": 32_010_928_128,
		"DiskUUID": "11111111-2222-3333-4444-555555555555",
		"BusProtocol": "USB",
	]
}

/// An internal SSD: Internal=true, External absent/false.
private func internalSSDPlist() -> [String: Any] {
	return [
		"External": false,
		"Internal": true,
		"Removable": false,
		"RemovableMedia": false,
		"Ejectable": false,
		"MediaName": "APPLE SSD AP1024",
		"TotalSize": 1_000_555_581_440,
		"DiskUUID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
		"BusProtocol": "Apple Fabric",
	]
}

/// An external but NON-removable disk (e.g. a bus-powered external SSD that is
/// fixed media): External=true but all three removable signals false.
private func externalFixedPlist() -> [String: Any] {
	return [
		"External": true,
		"Internal": false,
		"Removable": false,
		"RemovableMedia": false,
		"Ejectable": false,
		"MediaName": "External Fixed SSD",
		"TotalSize": 2_000_398_934_016,
		"DiskUUID": "99999999-8888-7777-6666-555555555555",
		"BusProtocol": "USB",
	]
}

/// A whole-disk plist that is otherwise valid but is missing TotalSize, so
/// identity capture cannot complete.
private func missingTotalSizePlist() -> [String: Any] {
	return [
		"External": true,
		"Internal": false,
		"Removable": true,
		"RemovableMedia": true,
		"Ejectable": true,
		"MediaName": "Mystery Media",
		"DiskUUID": "00000000-0000-0000-0000-000000000000",
		"BusProtocol": "USB",
	]
}

/// Real-shape `diskutil info -plist` XML for a valid external USB. Parsed via
/// PropertyListSerialization to prove the evaluator works on actual plist data
/// (not just hand-built dictionaries). Only the keys the evaluator reads are
/// included; real diskutil output carries many more, which are ignored.
private func validUSBPlistXML() -> String {
	return """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>BusProtocol</key>
	<string>USB</string>
	<key>DeviceIdentifier</key>
	<string>disk4</string>
	<key>DiskUUID</key>
	<string>ABCDEF01-2345-6789-ABCD-EF0123456789</string>
	<key>Ejectable</key>
	<true/>
	<key>External</key>
	<true/>
	<key>Internal</key>
	<false/>
	<key>MediaName</key>
	<string>Kingston DataTraveler 3.0 Media</string>
	<key>Removable</key>
	<false/>
	<key>RemovableMedia</key>
	<true/>
	<key>TotalSize</key>
	<integer>16008609792</integer>
	<key>WholeDisk</key>
	<true/>
</dict>
</plist>
"""
}

/// Decode an XML plist string into the [String: Any] shape the evaluator takes,
/// mirroring how the executable parses real `diskutil info -plist` output.
///
/// Throws rather than force-unwrapping so a malformed fixture surfaces as a test
/// failure (caught by `try` at the call site) instead of crashing the process.
private func decodePlist(_ xml: String) throws -> [String: Any] {
	let data = Data(xml.utf8)
	let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
	guard let dict = obj as? [String: Any] else {
		throw CocoaError(.propertyListReadCorrupt)
	}
	return dict
}

// MARK: - Path parsing / validation

@Suite("Raw device path parsing")
struct PathParsingTests {

	@Test("Well-formed /dev/rdiskN paths parse to their numeric suffix")
	func validPaths() {
		#expect(parseRawDevicePath("/dev/rdisk0") == "0")
		#expect(parseRawDevicePath("/dev/rdisk4") == "4")
		#expect(parseRawDevicePath("/dev/rdisk10") == "10")
	}

	@Test("Malformed raw paths are rejected by the parser")
	func malformedPaths() {
		// Non-numeric suffix.
		#expect(parseRawDevicePath("/dev/rdiskGARBAGE") == nil)
		// Bare prefix with no digits.
		#expect(parseRawDevicePath("/dev/rdisk") == nil)
		// Buffered node, not the raw node.
		#expect(parseRawDevicePath("/dev/disk4") == nil)
		// A regular file path.
		#expect(parseRawDevicePath("/tmp/scratch.img") == nil)
		// Trailing junk after the digits.
		#expect(parseRawDevicePath("/dev/rdisk4s1") == nil)
	}

	@Test("Whole-disk path and BSD name derive from the raw node")
	func wholeDiskDerivation() {
		#expect(wholeDiskPath(fromRaw: "/dev/rdisk4") == "/dev/disk4")
		#expect(wholeDiskBSD(fromRaw: "/dev/rdisk4") == "disk4")
		#expect(wholeDiskBSD(fromRaw: "/dev/rdisk10") == "disk10")
		// A malformed raw path yields no BSD name.
		#expect(wholeDiskBSD(fromRaw: "/dev/disk4") == nil)
	}
}

// MARK: - Preflight evaluator: accept

@Suite("Preflight evaluator ACCEPT")
struct PreflightAcceptTests {

	@Test("Valid external + removable USB accepts and returns identity")
	func acceptValidUSB() {
		// validUSBPlist() already encodes the key real-world nuance: this stick
		// reports Removable=false but RemovableMedia=true and Ejectable=true, yet
		// MUST accept. So this test also covers the Removable=false nuance path.
		let decision = evaluateRawDevicePreflight(
			rawPath: "/dev/rdisk4",
			plist: validUSBPlist(),
			bootWholeBSD: "disk0"
		)
		guard case .accept(let identity) = decision else {
			Issue.record("expected accept, got \(decision)")
			return
		}
		#expect(identity.wholeDiskBSD == "disk4")
		#expect(identity.mediaName == "SanDisk Ultra USB 3.0 Media")
		#expect(identity.totalSizeBytes == 32_010_928_128)
		#expect(identity.diskUUID == "11111111-2222-3333-4444-555555555555")
	}

	@Test("Evaluator accepts real-shape XML plist parsed from diskutil output")
	func acceptParsedXMLPlist() throws {
		let parsed = try decodePlist(validUSBPlistXML())
		let decision = evaluateRawDevicePreflight(
			rawPath: "/dev/rdisk4",
			plist: parsed,
			bootWholeBSD: "disk0"
		)
		guard case .accept(let identity) = decision else {
			Issue.record("expected accept from parsed XML, got \(decision)")
			return
		}
		#expect(identity.mediaName == "Kingston DataTraveler 3.0 Media")
		#expect(identity.totalSizeBytes == 16_008_609_792)
		#expect(identity.diskUUID == "ABCDEF01-2345-6789-ABCD-EF0123456789")
	}
}

// MARK: - Preflight evaluator: refuse

@Suite("Preflight evaluator REFUSE")
struct PreflightRefuseTests {

	@Test("Internal disk is refused")
	func refuseInternal() {
		let decision = evaluateRawDevicePreflight(
			rawPath: "/dev/rdisk0",
			plist: internalSSDPlist(),
			bootWholeBSD: "disk1"
		)
		// External=false on the internal disk, so the FIRST failing gate is the
		// external check. (Internal=true would also fail; external is checked
		// first.) Either way the disk is refused, never accepted.
		guard case .refuse(let reason) = decision else {
			Issue.record("expected refuse for internal disk, got \(decision)")
			return
		}
		#expect(reason == .notExternal(busProtocol: "Apple Fabric"))
	}

	@Test("Internal disk that claims External=true is still refused on Internal gate")
	func refuseInternalDespiteExternalTrue() {
		// Force the external + removable gates to pass so the Internal gate is
		// the one that fires, proving the Internal=true refusal path.
		var plist = internalSSDPlist()
		plist["External"] = true
		plist["RemovableMedia"] = true
		let decision = evaluateRawDevicePreflight(
			rawPath: "/dev/rdisk5",
			plist: plist,
			bootWholeBSD: "disk0"
		)
		#expect(decision == .refuse(.isInternal))
	}

	@Test("External but non-removable disk is refused")
	func refuseNonRemovable() {
		let decision = evaluateRawDevicePreflight(
			rawPath: "/dev/rdisk6",
			plist: externalFixedPlist(),
			bootWholeBSD: "disk0"
		)
		#expect(decision == .refuse(.notRemovable(
			removable: false,
			removableMedia: false,
			ejectable: false
		)))
	}

	@Test("Target equal to the boot disk is refused")
	func refuseBootDisk() {
		// Valid external removable USB, but its BSD name IS the boot disk.
		let decision = evaluateRawDevicePreflight(
			rawPath: "/dev/rdisk0",
			plist: validUSBPlist(),
			bootWholeBSD: "disk0"
		)
		#expect(decision == .refuse(.isBootDisk(targetBSD: "disk0", bootBSD: "disk0")))
	}

	@Test("Unknown boot disk is refused (fails closed)")
	func refuseBootUnknown() {
		let decision = evaluateRawDevicePreflight(
			rawPath: "/dev/rdisk4",
			plist: validUSBPlist(),
			bootWholeBSD: nil
		)
		#expect(decision == .refuse(.bootDiskUnknown))
	}

	@Test("Malformed raw path is refused by the evaluator")
	func refuseMalformedPath() {
		// /dev/rdiskGARBAGE -- non-numeric suffix.
		let garbage = evaluateRawDevicePreflight(
			rawPath: "/dev/rdiskGARBAGE",
			plist: validUSBPlist(),
			bootWholeBSD: "disk0"
		)
		#expect(garbage == .refuse(.malformedPath(rawPath: "/dev/rdiskGARBAGE")))
		// Bare /dev/rdisk -- no digits.
		let bare = evaluateRawDevicePreflight(
			rawPath: "/dev/rdisk",
			plist: validUSBPlist(),
			bootWholeBSD: "disk0"
		)
		#expect(bare == .refuse(.malformedPath(rawPath: "/dev/rdisk")))
	}

	@Test("Buffered /dev/diskN node is refused by the evaluator")
	func refuseBufferedNode() {
		// /dev/disk4 is the buffered node, not the raw node; the path parser
		// rejects it, so the evaluator refuses with malformedPath.
		let decision = evaluateRawDevicePreflight(
			rawPath: "/dev/disk4",
			plist: validUSBPlist(),
			bootWholeBSD: "disk0"
		)
		#expect(decision == .refuse(.malformedPath(rawPath: "/dev/disk4")))
	}

	@Test("Missing TotalSize fails identity capture and is refused")
	func refuseMissingIdentityField() {
		let decision = evaluateRawDevicePreflight(
			rawPath: "/dev/rdisk4",
			plist: missingTotalSizePlist(),
			bootWholeBSD: "disk0"
		)
		#expect(decision == .refuse(.missingIdentityField(field: "TotalSize")))
	}
}

// MARK: - Identity capture

@Suite("Disk identity capture")
struct IdentityCaptureTests {

	@Test("Identity capture extracts all fields from a valid plist")
	func captureValid() {
		let result = diskIdentity(fromPlist: validUSBPlist(), wholeDiskBSD: "disk4")
		guard case .success(let identity) = result else {
			Issue.record("expected success, got \(result)")
			return
		}
		#expect(identity.wholeDiskBSD == "disk4")
		#expect(identity.mediaName == "SanDisk Ultra USB 3.0 Media")
		#expect(identity.totalSizeBytes == 32_010_928_128)
		#expect(identity.diskUUID == "11111111-2222-3333-4444-555555555555")
	}

	@Test("Missing DiskUUID falls back to a name+size anchor")
	func captureUUIDFallback() {
		var plist = validUSBPlist()
		plist.removeValue(forKey: "DiskUUID")
		let result = diskIdentity(fromPlist: plist, wholeDiskBSD: "disk4")
		guard case .success(let identity) = result else {
			Issue.record("expected success, got \(result)")
			return
		}
		#expect(identity.diskUUID == "name=SanDisk Ultra USB 3.0 Media,size=32010928128")
	}

	@Test("Missing TotalSize reports the missing field")
	func captureMissingTotalSize() {
		let result = diskIdentity(fromPlist: missingTotalSizePlist(), wholeDiskBSD: "disk4")
		#expect(result == .failure(.missingIdentityField(field: "TotalSize")))
	}
}

// MARK: - Identity comparison

@Suite("Disk identity comparison")
struct IdentityComparisonTests {

	private let recorded = DiskIdentity(
		wholeDiskBSD: "disk4",
		mediaName: "SanDisk Ultra",
		totalSizeBytes: 32_010_928_128,
		diskUUID: "11111111-2222-3333-4444-555555555555"
	)

	@Test("Identical identities report no mismatched fields")
	func noMismatch() {
		#expect(identityMismatchFields(recorded: recorded, current: recorded).isEmpty)
	}

	@Test("A differing UUID is reported as a mismatch")
	func uuidMismatch() {
		let current = DiskIdentity(
			wholeDiskBSD: recorded.wholeDiskBSD,
			mediaName: recorded.mediaName,
			totalSizeBytes: recorded.totalSizeBytes,
			diskUUID: "FFFFFFFF-0000-0000-0000-000000000000"
		)
		#expect(identityMismatchFields(recorded: recorded, current: current) == ["UUID/anchor"])
	}

	@Test("A differing size is reported as a mismatch")
	func sizeMismatch() {
		let current = DiskIdentity(
			wholeDiskBSD: recorded.wholeDiskBSD,
			mediaName: recorded.mediaName,
			totalSizeBytes: 64_000_000_000,
			diskUUID: recorded.diskUUID
		)
		#expect(identityMismatchFields(recorded: recorded, current: current) == ["size"])
	}

	@Test("A differing media name is reported as a mismatch")
	func mediaNameMismatch() {
		let current = DiskIdentity(
			wholeDiskBSD: recorded.wholeDiskBSD,
			mediaName: "Different Stick",
			totalSizeBytes: recorded.totalSizeBytes,
			diskUUID: recorded.diskUUID
		)
		#expect(identityMismatchFields(recorded: recorded, current: current) == ["media name"])
	}

	@Test("Multiple changed fields are all reported in order")
	func multipleMismatch() {
		let current = DiskIdentity(
			wholeDiskBSD: recorded.wholeDiskBSD,
			mediaName: "Different Stick",
			totalSizeBytes: 64_000_000_000,
			diskUUID: "FFFFFFFF-0000-0000-0000-000000000000"
		)
		#expect(identityMismatchFields(recorded: recorded, current: current)
			== ["UUID/anchor", "size", "media name"])
	}
}
