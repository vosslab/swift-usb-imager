/// XPCFlashEngineFactory.swift - the real privileged-helper-backed flash-engine
/// factory.
///
/// Builds a `FlashEngine` over an `XPCHelperConnection` to the privileged helper
/// daemon, so the flash path is functional once the helper is installed and
/// approved. It lives in `USBImagerCore` (not in the CLI) for the same reason
/// `HelperUnavailableEngineFactory` does: the `FlashEngine`, `XPCHelperConnection`,
/// and `CodeSigningRequirement` types belong to modules the thin front ends reach
/// only through core. Keeping this factory here lets the CLI select the real flash
/// path without importing `FlashEngine` directly -- it depends on `USBImagerCore`
/// and `ArgumentParser` only.
///
/// The helper identity constants are the same ones the GUI app pins (the Mach
/// service name the helper registers via `SMAppService` and the designated
/// code-signing requirement the XPC peer must satisfy). Both front ends pin the
/// identical peer so a single signed helper serves the GUI and the CLI.
///
/// Helper-absent behavior: `makeEngine()` throws `CoreError.helperUnavailable`
/// when the connection cannot be established (a structurally invalid requirement
/// string is the only synchronous failure here, since `XPCHelperConnection`
/// activates the Mach lookup lazily). A genuinely missing helper at flash time
/// surfaces later as a `FlashEngineError` the orchestration service maps to its
/// flash-failed result; the no-wiring placeholder path (exit code 3 before any
/// device work) is owned by `HelperUnavailableEngineFactory`, which the front
/// ends select when they choose not to attempt a real connection.

import FlashEngine
import Foundation
import HelperProtocol

// MARK: - Helper identity constants

/// Mach service name registered by the privileged helper via `SMAppService`.
///
/// Shared by both front ends so the GUI and CLI connect to the same daemon. The
/// signing phase replaces this with the final daemon bundle ID; it is kept in
/// core so neither front end hard-codes its own copy.
public let usbimagerHelperMachServiceName = "com.nsh.usbimager.helper"

/// Designated-requirement string pinning the XPC peer's code-signing identity.
///
/// Both front ends pin the identical peer requirement. The signing phase replaces
/// this with the real Apple-signed requirement.
public let usbimagerHelperRequirementString =
    #"identifier "com.nsh.usbimager.helper" and anchor apple generic"#

// MARK: - XPCFlashEngineFactory

/// A `FlashEngineFactory` that builds an `XPCHelperConnection`-backed engine.
///
/// Construct one with the default helper identity (the constants above) or with
/// explicit values; the orchestration service obtains a fresh engine from it per
/// flash session.
public struct XPCFlashEngineFactory: FlashEngineFactory {

    /// The Mach service name the helper daemon registers.
    private let machServiceName: String

    /// The designated-requirement string the XPC peer must satisfy.
    private let requirementString: String

    /// Create a factory pinning the given helper identity.
    ///
    /// - Parameters:
    ///   - machServiceName: the helper's Mach service name. Defaults to the shared
    ///     `usbimagerHelperMachServiceName`.
    ///   - requirementString: the peer code-signing requirement string. Defaults
    ///     to the shared `usbimagerHelperRequirementString`.
    public init(
        machServiceName: String = usbimagerHelperMachServiceName,
        requirementString: String = usbimagerHelperRequirementString
    ) {
        self.machServiceName = machServiceName
        self.requirementString = requirementString
    }

    /// Build a fresh `FlashEngine` over a new `XPCHelperConnection`.
    ///
    /// Constructs the `CodeSigningRequirement` from the pinned string first; a
    /// structurally invalid string is the synchronous "connection cannot be
    /// established" path and is reported as `CoreError.helperUnavailable` (CLI exit
    /// code 3) rather than crashing. `XPCHelperConnection` then activates the Mach
    /// lookup lazily on first use, so a missing/unapproved helper surfaces later as
    /// a `FlashEngineError` during the flash, which the orchestration service maps
    /// to its typed result.
    ///
    /// - Returns: a new engine wired to the privileged helper.
    /// - Throws: `CoreError.helperUnavailable` when the peer requirement string is
    ///   structurally invalid (the connection cannot be established).
    public func makeEngine() throws -> FlashEngine {
        let requirement: CodeSigningRequirement
        do {
            requirement = try CodeSigningRequirement(requirementString: requirementString)
        } catch {
            throw CoreError.helperUnavailable(
                message: "Invalid helper code-signing requirement: \(error)."
            )
        }
        let connection = XPCHelperConnection(
            machServiceName: machServiceName,
            peerRequirement: requirement
        )
        let engine = FlashEngine(connection: connection)
        return engine
    }
}
