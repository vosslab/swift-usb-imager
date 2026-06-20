/// RunBlocking.swift - one correct sync-over-async bridge for the CLI.
///
/// ArgumentParser's `run()` is synchronous, but the core disk lookup, snapshot,
/// and flash orchestration are `async` (they hop to the `DiskEnumerator` /
/// `FlashEngine` actors). The CLI subcommands need to block the calling thread
/// until one async call completes and return its value.
///
/// History (the bug this file fixes): each subcommand had its own copy of a
/// helper that stored the result in a captured local `var result: T? = nil`
/// marked `nonisolated(unsafe)`, wrote it from a `Task.detached`, and read it
/// back after `semaphore.wait()`. Capturing a stack-local `var` by an
/// `@escaping @Sendable` closure and mutating it from another thread is
/// undefined behavior: the optimizer is free to assume the local is not aliased
/// across the concurrency boundary, and for a generic associated-value enum
/// (`FlashRunResult`) it emitted a `@out` copy (`memmove`) from a null box,
/// segfaulting the test process (`EXC_BAD_ACCESS` at 0x0 inside
/// `_platform_memmove`, on the detached-task thread).
///
/// The fix is to give the result a stable heap address that both threads share
/// by reference. `ResultBox` is a class, so the closure captures the box
/// (a reference) rather than a stack slot; the `DispatchSemaphore` still
/// provides the happens-before barrier between the write and the read.

import Dispatch

// MARK: - ResultBox

/// A heap-allocated, single-assignment slot for the async result.
///
/// A reference type so the detached task and the waiting thread share one
/// stable storage location instead of a captured stack local. `@unchecked
/// Sendable` is sound here because the `DispatchSemaphore` orders the single
/// write (before `signal`) before the single read (after `wait`); there is no
/// concurrent access to `value`.
private final class ResultBox<T>: @unchecked Sendable {
	var value: T?
}

// MARK: - runBlocking

/// Block the calling thread until `body` completes and return its result.
///
/// Spins up a detached task to run `body`, stores the result in a shared
/// heap box, signals a semaphore, and returns the boxed value once the wait
/// completes. Shared by every CLI subcommand that bridges one async core call
/// into a synchronous `run()`.
///
/// - Parameter body: the async work to block on.
/// - Returns: the value produced by `body`.
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
	let semaphore = DispatchSemaphore(value: 0)
	// Heap box gives the result a stable address shared by reference across the
	// concurrency boundary, avoiding the captured-stack-local UB.
	let box = ResultBox<T>()
	Task.detached {
		box.value = await body()
		semaphore.signal()
	}
	semaphore.wait()
	// The semaphore guarantees the write above happens-before this read, so the
	// box is populated. Force-unwrap is safe: `body` always assigns before signal.
	return box.value!
}
