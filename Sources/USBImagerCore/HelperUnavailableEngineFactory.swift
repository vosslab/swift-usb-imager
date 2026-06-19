/// HelperUnavailableEngineFactory.swift - a placeholder flash-engine factory.
///
/// A `FlashEngineFactory` that always reports the privileged helper as
/// unavailable. It lets a front end stand up a `DefaultFlashOrchestrationService`
/// before the real privileged-helper wiring exists: the flash path returns a
/// clean `CoreError.helperUnavailable` (CLI exit code 3) instead of crashing.
///
/// This lives in `USBImagerCore` (not in the CLI) because the `FlashEngine` type
/// in the factory signature belongs to the `FlashEngine` module, which the thin
/// front ends reach only through core. Front ends that want the real flash path
/// pass an `XPCFlashEngineFactory` into the orchestration service instead.

import FlashEngine

// MARK: - HelperUnavailableEngineFactory

/// A `FlashEngineFactory` that never builds an engine and always reports the
/// helper unavailable.
public struct HelperUnavailableEngineFactory: FlashEngineFactory {

    /// Create the placeholder factory.
    public init() {}

    /// Always throws `CoreError.helperUnavailable`; never builds an engine.
    ///
    /// - Returns: never returns normally.
    /// - Throws: `CoreError.helperUnavailable`.
    public func makeEngine() throws -> FlashEngine {
        throw CoreError.helperUnavailable(
            message: "The privileged helper is not wired into this front end yet."
        )
    }
}
