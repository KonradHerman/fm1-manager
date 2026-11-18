// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Runs main-actor code from a callback that may come on any thread: at once when already on the main thread
/// (in order with the caller), else queued on the main queue.
///
/// Why this exists: in Swift 6 a closure written inside a @MainActor context is itself main-actor isolated, and when
/// an API (CoreMIDI, CoreMotion, KVO, a dispatch queue) calls it on another thread the runtime traps. A callback
/// handed to such an API is written as a @Sendable (nonisolated) closure that calls onMain { ... } for its UI work.
/// MainActor.assumeIsolated alone would trap the same way off the main thread.
public func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
	if Thread.isMainThread {
		MainActor.assumeIsolated(body)
	} else {
		DispatchQueue.main.async { MainActor.assumeIsolated(body) }
	}
}
