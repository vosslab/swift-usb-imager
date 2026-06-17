/// CancellationToken.swift -- a cooperative cancel flag for in-flight jobs.
///
/// The write and verify loops check this token at every chunk boundary. When a
/// `cancel(jobIDData:)` XPC message arrives, `HelperService` flips the token for
/// the matching job; the next checkpoint observes it and stops without claiming
/// success. Cancellation is cooperative (checked at boundaries), never a forced
/// kill mid-syscall, so the device is always left in a known, unmounted state.
///
/// The token is a small reference type guarded by a lock so the XPC delivery
/// thread and the worker thread can touch it safely. It is `@unchecked Sendable`
/// because the lock provides the synchronization the compiler cannot prove.

import Foundation

// MARK: - CancellationToken

/// Thread-safe one-way cancel flag. Starts un-cancelled; `cancel()` is sticky.
public final class CancellationToken: @unchecked Sendable {

    /// Serializes access to `cancelled` across the XPC and worker threads.
    private let lock = NSLock()

    /// Backing flag; only ever transitions false -> true.
    private var cancelled = false

    public init() {}

    /// Request cancellation. Idempotent; safe to call from any thread.
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// `true` once `cancel()` has been called. Checked at each loop checkpoint.
    public var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}
