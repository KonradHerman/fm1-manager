// SPDX-License-Identifier: GPL-3.0-only
#if canImport(WebKit)
import Foundation

/// How an Apply ended.
public enum RigApplyOutcome: Sendable {
	/// Every step done; `issues` is what the last LIST still shows differently from the rig (empty: verified).
	case finished(device: DockDeviceState, issues: [String], bytesPerSecond: Double?)
	/// Stopped at step `failedStep` (0-based): why, what is on the device now (nil if it could not be read), and the
	/// steps that were done. Resume: read again, plan again.
	case stopped(reason: String, failedStep: Int, device: DockDeviceState?, done: [RigPlan.Step])
}

/// Runs a plan on the device step by step, checks the device after each step against what the plan expected, and
/// stops at the first difference or failure.
@MainActor
public final class RigApplier {
	public struct Progress: Sendable {
		public var step: Int, steps: Int
		public var text: String
		/// within the step (a deploy's data), 0...1
		public var fraction: Double
	}

	private let link: DockLink
	private let library: URL
	private var cancelled = false

	public init(link: DockLink, libraryFolder: URL) { self.link = link; self.library = libraryFolder }

	/// Stops after the step running now (a deploy under way is let finish: half a module is worse).
	public func cancel() { cancelled = true }

	/// Reads the device for a plan: an open receive left by a cut-off deploy is closed (ABORT) first.
	public static func readForPlanning(_ link: DockLink) async throws -> DockDeviceState {
		var s = try await link.readState()
		if s.receiving {
			try await link.abort()
			s = try await link.readState()
		}
		return s
	}

	public func run(_ plan: RigPlan, rig: Rig, library modules: [LibraryModule],
	                progress: @escaping @MainActor (Progress) -> Void) async -> RigApplyOutcome {
		cancelled = false
		var done: [RigPlan.Step] = []
		var sentBytes = 0, sendSeconds = 0.0
		for (i, step) in plan.steps.enumerated() {
			if cancelled { return await stop("Stopped.", i, done) }
			do {
				switch step {
				case let .delete(name, _):
					progress(Progress(step: i, steps: plan.steps.count, text: "Removing \(name)", fraction: 0))
					try await link.delete(name)
				case let .deploy(m, fileName):
					progress(Progress(step: i, steps: plan.steps.count, text: "Adding \(m.name)", fraction: 0))
					let data = try Data(contentsOf: library.appendingPathComponent(fileName))
					guard CRC32.hex(CRC32.of(data)) == m.crc32.lowercased() else {
						return await stop("\(fileName) changed since the plan was made: nothing of it was sent.", i, done)
					}
					let t0 = Date()
					try await link.deploy(data) { x in
						progress(Progress(step: i, steps: plan.steps.count, text: "Adding \(m.name)", fraction: x))
					}
					sentBytes += data.count; sendSeconds += Date().timeIntervalSince(t0)
				case let .select(name):
					progress(Progress(step: i, steps: plan.steps.count, text: "Selecting \(name)", fraction: 0))
					try await link.select(name)
				}
			} catch {
				return await stop("\(error)", i, done)
			}
			done.append(step)
			if case .select = step { continue }
			// the device as the plan said? (where every module is, from a fresh LIST; with a layout not known exactly,
			// at least that the module came or went)
			do {
				let s = try await link.readState()
				let names = Set(s.deployed.map(\.name))
				var asPlanned: Bool
				switch step {
				case let .delete(name, _): asPlanned = !names.contains(name)
				case let .deploy(m, _): asPlanned = s.deployed.contains { m.matches($0) }
				case .select: asPlanned = true
				}
				if asPlanned && plan.layoutExact {
					asPlanned = Set(RigPlanner.layout(of: s, library: modules).layout.blocks) == Set(plan.expected[i].blocks)
				}
				if !asPlanned {
					return .stopped(reason: "The FM-1's modules are not where the plan expected them after this step: stopped to plan again.",
					                failedStep: i + 1, device: s, done: done)
				}
			} catch {
				return await stop("\(error)", i + 1, done)
			}
		}
		do {
			let s = try await link.readState()
			return .finished(device: s, issues: Self.differences(rig: rig, device: s),
			                 bytesPerSecond: sendSeconds > 0.5 ? Double(sentBytes) / sendSeconds : nil)
		} catch {
			return await stop("The last check could not read the FM-1: \(error)", plan.steps.count, done)
		}
	}

	private func stop(_ reason: String, _ step: Int, _ done: [RigPlan.Step]) async -> RigApplyOutcome {
		let s = try? await link.readState()
		return .stopped(reason: reason, failedStep: step, device: s, done: done)
	}

	/// What the device shows differently from the rig: missing or other versions, modules the rig does not have,
	/// another module playing.
	public static func differences(rig: Rig, device: DockDeviceState) -> [String] {
		var out: [String] = []
		let fixed = Set(device.modules.filter { $0.kind.isFixed }.map(\.name))
		for m in rig.modules where !fixed.contains(m.name) {
			if let d = device.deployed.first(where: { $0.name == m.name }) {
				if !m.matches(d) { out.append("\(m.name) is version \(d.version) on the FM-1, \(m.version) in the rig") }
			} else { out.append("\(m.name) is not on the FM-1") }
		}
		let names = Set(rig.modules.map(\.name))
		for d in device.deployed where !names.contains(d.name) { out.append("\(d.name) is on the FM-1 but not in the rig") }
		if let sel = rig.select, device.currentName != sel { out.append("\(device.currentName ?? "nothing") plays, not \(sel)") }
		return out
	}
}
#endif
