// SPDX-License-Identifier: GPL-3.0-only
import CoreMotion
import FM1Kit
import SwiftUI
import UIKit

/// Where Hands sends: the FM-1's output on the app's engine, read under a lock (touches on the main thread, tilt on
/// the motion queue); nothing when no FM-1 is plugged in.
final class FM1Output: @unchecked Sendable {
	private let lock = NSLock()
	private var engine: MIDIEngine?
	private var id: String?
	func set(_ engine: MIDIEngine?, _ id: String?) { lock.withLock { self.engine = engine; self.id = id } }
	var isConnected: Bool { lock.withLock { id != nil } }
	func send(_ m: [UInt8]) {
		let (e, id) = lock.withLock { (engine, self.id) }
		guard let e, let id else { return }
		try? e.send(m, to: id)
	}
}

/// The screen's state: the settings, Hands (the MIDI), tilt.
@MainActor @Observable
final class HandsModel {
	var settings = HandsSettings.load() { didSet { settings.save(); apply() } }
	let output = FM1Output()
	let hands: Hands
	private(set) var tiltValue = 0.0
	private(set) var tiltOn = false
	private(set) var tiltAvailable = false
	var xy = CGPoint(x: 0.5, y: 0.5)
	private let motion = CMMotionManager()
	private let motionQueue = OperationQueue()
	private let tiltState = TiltState()

	/// The tilt mapper and its switch, for the motion queue (the main actor is not waited on there).
	final class TiltState: @unchecked Sendable {
		let lock = NSLock()
		var mapper = TiltMapper()
		var engaged = false
		var target: ControlTarget = .cc(1)
		var zeroNext = true
		var lastAngle = 0.0
	}

	init() {
		let out = output
		hands = Hands(send: { out.send($0) })
		motionQueue.maxConcurrentOperationCount = 1
		motionQueue.qualityOfService = .userInteractive
		tiltAvailable = motion.isDeviceMotionAvailable
		apply()
	}

	private func apply() {
		hands.setChannel(settings.channel)
		hands.latch = settings.latch
		let s = settings
		tiltState.lock.withLock {
			tiltState.mapper.rangeDegrees = s.tiltRangeDegrees
			tiltState.mapper.smoothing = s.tiltSmoothing
			tiltState.target = s.tilt
		}
	}

	/// The FM-1 came or went: gone, the notes are forgotten; back, a panic clears anything left hanging on it.
	/// (Opening the screen sends nothing; only a replug clears what the unplug may have left sounding.)
	func connect(_ engine: MIDIEngine?, _ fm1: MIDIEndpointInfo?) {
		let was = output.isConnected
		output.set(engine, fm1?.id)
		if fm1 == nil { hands.forget(); if everConnected { lost = true } }
		else if !was && lost { hands.panic(); lost = false }
		if fm1 != nil { everConnected = true }
	}
	private var everConnected = false
	private var lost = false

	func start() {
		guard tiltAvailable, !motion.isDeviceMotionActive else { return }
		motion.deviceMotionUpdateInterval = 1.0 / 100
		let st = tiltState, hands = hands
		motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] m, _ in
			guard let m else { return }
			let angle = m.attitude.roll
			let (on, value, target) = st.lock.withLock { () -> (Bool, Double, ControlTarget) in
				st.lastAngle = angle
				if st.zeroNext { st.mapper.setZero(angle); st.zeroNext = false }
				let v = st.mapper.value(angle)
				return (st.engaged, v, st.target)
			}
			if on {
				hands.control(.tilt, target, target == .pitchBend ? value : max(0, value))
			}
			Task { @MainActor [weak self] in self?.tiltValue = value }
		}
	}

	/// Leaving the screen or the app: every note off, tilt stopped.
	func stop() {
		hands.releaseAll()
		setTilt(false)
		motion.stopDeviceMotionUpdates()
	}

	func setTilt(_ on: Bool) {
		guard on != tiltOn else { return }
		tiltOn = on
		let target = tiltState.lock.withLock { () -> ControlTarget in tiltState.engaged = on; return tiltState.target }
		if !on { hands.endControl(.tilt, target) }
	}

	/// The way the phone is held now is the tilt's centre.
	func zeroTilt() { tiltState.lock.withLock { tiltState.zeroNext = true } }

	func xyMoved(_ p: CGPoint) {
		xy = p
		hands.control(.x, settings.x, settings.x == .pitchBend ? Double(p.x) * 2 - 1 : Double(p.x))
		hands.control(.y, settings.y, settings.y == .pitchBend ? Double(p.y) * 2 - 1 : Double(p.y))
	}

	func xyEnded() {
		hands.endControl(.x, settings.x); hands.endControl(.y, settings.y)
		if settings.xyReturns { xyMoved(CGPoint(x: 0.5, y: 0.5)) }
	}
}

struct HandsView: View {
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	@Environment(\.scenePhase) private var phase
	@State private var model = HandsModel()
	@State private var showSettings = false

	var body: some View {
		@Bindable var model = model
		GeometryReader { geo in
			let wide = geo.size.width > geo.size.height
			VStack(spacing: 8) {
				if app.fm1 == nil {
					Label("No FM-1 connected: plug it in to play it from here.", systemImage: "cable.connector.slash")
						.font(.footnote.weight(.semibold)).frame(maxWidth: .infinity).padding(8)
						.background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
				}
				controlsBar
				Group {
					if wide {
						HStack(spacing: 8) { xyPad; tiltPanel.frame(width: min(220, geo.size.width * 0.3)) }
					} else {
						VStack(spacing: 8) { xyPad; tiltPanel.frame(height: 90) }
					}
				}
				KeyboardHost(model: model).frame(height: wide ? geo.size.height * 0.42 : min(220, geo.size.height * 0.3))
			}
			.padding(.horizontal, 10).padding(.bottom, 6)
			.disabled(app.fm1 == nil)
			.opacity(app.fm1 == nil ? 0.45 : 1)
		}
		.navigationTitle("Hands")
		.navigationBarTitleDisplayMode(.inline)
		.navigationBarBackButtonHidden(true)
		.toolbar {
			ToolbarItem(placement: .topBarLeading) {
				Button { model.stop(); dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
			}
			ToolbarItem(placement: .principal) { ConnectionPill() }
			ToolbarItem(placement: .topBarTrailing) {
				Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Settings")
			}
		}
		.defersSystemGestures(on: .all)
		.persistentSystemOverlays(.hidden)
		.onAppear { model.connect(app.engine, app.fm1); model.start() }
		.onDisappear { model.stop() }
		.onChange(of: app.fm1?.id) { model.connect(app.engine, app.fm1) }
		.onChange(of: phase) { if phase != .active { model.hands.releaseAll(); model.setTilt(false) } }
		.onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
			model.hands.releaseAll(); model.setTilt(false)
		}
		.sheet(isPresented: $showSettings) { HandsSettingsView(settings: $model.settings) }
	}

	private var controlsBar: some View {
		@Bindable var model = model
		return HStack(spacing: 8) {
			Menu {
				Picker("Channel", selection: $model.settings.channel) { ForEach(0..<16, id: \.self) { Text("Channel \($0 + 1)").tag($0) } }
			} label: { Text("Ch \(model.settings.channel + 1)").font(.subheadline.monospacedDigit()) }
			Divider().frame(height: 22)
			Button { model.settings.lowestNote = max(12, model.settings.lowestNote - 12) } label: { Image(systemName: "minus") }
			Text(noteName(model.settings.lowestNote)).font(.subheadline.monospacedDigit()).frame(minWidth: 30)
			Button { model.settings.lowestNote = min(96, model.settings.lowestNote + 12) } label: { Image(systemName: "plus") }
			Spacer(minLength: 4)
			Toggle(isOn: $model.settings.latch) { Image(systemName: "pin") }.toggleStyle(.button).accessibilityLabel("Latch")
			Toggle(isOn: $model.settings.scaleLock) { Text(model.settings.scaleLock ? model.settings.scale.label : "Scale") }
				.toggleStyle(.button).font(.subheadline)
			Button(role: .destructive) { model.hands.panic() } label: { Text("Panic").font(.subheadline.weight(.bold)) }
				.buttonStyle(.borderedProminent).tint(.red)
		}
		.buttonStyle(.bordered)
	}

	private var xyPad: some View {
		ZStack(alignment: .topLeading) {
			XYPadHost(point: model.xy, moved: { model.xyMoved($0) }, ended: { model.xyEnded() })
			Text("X \(model.settings.x.label) · Y \(model.settings.y.label)").font(.caption2).foregroundStyle(.secondary).padding(8)
				.allowsHitTesting(false)
		}
		.clipShape(RoundedRectangle(cornerRadius: 14))
	}

	private var tiltPanel: some View {
		VStack(spacing: 6) {
			HStack {
				Text("Tilt → \(model.settings.tilt.label)").font(.caption).foregroundStyle(.secondary)
				Spacer()
				Button("Centre") { model.zeroTilt() }.font(.caption).buttonStyle(.bordered)
			}
			GeometryReader { g in
				ZStack(alignment: .leading) {
					Capsule().fill(Color.secondary.opacity(0.2))
					let v = model.settings.tilt == .pitchBend ? (model.tiltValue + 1) / 2 : max(0, model.tiltValue)
					Capsule().fill(model.tiltOn ? Color.accentColor : Color.secondary).frame(width: max(8, g.size.width * v))
				}
			}
			.frame(height: 8)
			Text(model.tiltAvailable ? (model.tiltOn ? "Tilting…" : "Hold to tilt") : "No motion sensor")
				.font(.headline).frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(model.tiltOn ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15),
				            in: RoundedRectangle(cornerRadius: 12))
				.gesture(DragGesture(minimumDistance: 0)
					.onChanged { _ in model.setTilt(true) }
					.onEnded { _ in model.setTilt(false) })
				.disabled(!model.tiltAvailable)
				.accessibilityLabel("Hold to tilt")
		}
	}
}

func noteName(_ n: Int) -> String {
	["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][((n % 12) + 12) % 12] + String(n / 12 - 1)
}

struct HandsSettingsView: View {
	@Binding var settings: HandsSettings
	@Environment(\.dismiss) private var dismiss
	var body: some View {
		NavigationStack {
			Form {
				Section("XY pad") {
					targetPicker("Across (X)", $settings.x)
					targetPicker("Up (Y)", $settings.y)
					Toggle("Springs back to the centre", isOn: $settings.xyReturns)
				}
				Section {
					targetPicker("Tilt sends", $settings.tilt)
					LabeledContent("Range") {
						Slider(value: $settings.tiltRangeDegrees, in: 10...90, step: 5)
						Text("\(Int(settings.tiltRangeDegrees))°").monospacedDigit()
					}
					LabeledContent("Smoothing") { Slider(value: $settings.tiltSmoothing, in: 0...0.9) }
				} header: { Text("Tilt") } footer: {
					Text("Tilt the phone left and right while you hold the tilt pad; Centre makes the way you hold it now the middle. Letting go returns pitch bend and aftertouch to rest.")
				}
				Section("Keys") {
					Stepper("\(settings.octaves) octaves", value: $settings.octaves, in: 1...4)
					Picker("Scale", selection: $settings.scale) { ForEach(Scale.allCases, id: \.self) { Text($0.label).tag($0) } }
					Picker("Root", selection: $settings.root) { ForEach(0..<12, id: \.self) { Text(noteName($0 + 12).dropLast()).tag($0) } }
					Toggle("Haptic tick on each key", isOn: $settings.haptics)
				}
				Section {
					Button("Back to the defaults", role: .destructive) { settings = HandsSettings() }
				} footer: {
					Text("On fm1-dock the knob CCs are 74, 71, 73, 72: a module hears them as KNOB1 to KNOB4.")
				}
			}
			.navigationTitle("Hands")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { Button("Done") { dismiss() } }
		}
	}

	private func targetPicker(_ title: String, _ b: Binding<ControlTarget>) -> some View {
		Picker(title, selection: b) { ForEach(ControlTarget.choices, id: \.self) { Text($0.label).tag($0) } }
	}
}

// MARK: the keyboard (UIKit: many touches at once, slides, no gesture delays)

struct KeyboardHost: UIViewRepresentable {
	let model: HandsModel
	func makeUIView(context: Context) -> KeyboardView { KeyboardView(model: model) }
	func updateUIView(_ v: KeyboardView, context: Context) { v.settings = model.settings }
}

final class KeyboardView: UIView {
	private let model: HandsModel
	var settings: HandsSettings { didSet { if settings != oldValue { setNeedsDisplay() } } }
	private var down: [ObjectIdentifier: Int] = [:]        // touch -> the note it plays
	private let tick = UIImpactFeedbackGenerator(style: .light)

	init(model: HandsModel) {
		self.model = model
		settings = model.settings
		super.init(frame: .zero)
		isMultipleTouchEnabled = true
		isOpaque = false
		contentMode = .redraw
		accessibilityLabel = "Keyboard"
	}
	required init?(coder: NSCoder) { fatalError() }

	private static let black: Set<Int> = [1, 3, 6, 8, 10]
	private var notes: ClosedRange<Int> { settings.lowestNote...min(127, settings.lowestNote + 12 * settings.octaves) }
	private var whites: [Int] { notes.filter { !Self.black.contains($0 % 12) } }

	private func rects() -> [(note: Int, rect: CGRect, black: Bool)] {
		let w = whites, kw = bounds.width / CGFloat(max(1, w.count))
		var out: [(Int, CGRect, Bool)] = []
		for (i, n) in w.enumerated() { out.append((n, CGRect(x: CGFloat(i) * kw, y: 0, width: kw, height: bounds.height), false)) }
		for n in notes where Self.black.contains(n % 12) {
			guard let i = w.firstIndex(of: n - 1) else { continue }
			out.append((n, CGRect(x: CGFloat(i + 1) * kw - kw * 0.32, y: 0, width: kw * 0.64, height: bounds.height * 0.6), true))
		}
		return out
	}

	/// The note under a point (black keys on top) and the velocity from how far down the key it is.
	private func hit(_ p: CGPoint) -> (note: Int, velocity: Int)? {
		let r = rects()
		guard let k = r.last(where: { $0.black && $0.rect.contains(p) }) ?? r.first(where: { !$0.black && $0.rect.contains(p) }) else { return nil }
		let depth = max(0, min(1, (p.y - k.rect.minY) / max(1, k.rect.height)))
		var note = k.note
		if settings.scaleLock { note = settings.scale.snap(note, root: settings.root) }
		return (note, Int(35 + depth * 92))
	}

	override func draw(_ rect: CGRect) {
		let on = model.hands.soundingNotes
		for k in rects() {
			let off = settings.scaleLock && !settings.scale.contains(k.note, root: settings.root)
			let lit = on.contains(UInt8(k.note))
			let fill: UIColor = lit ? .tintColor : k.black ? (off ? .systemGray3 : .label) : (off ? .systemGray5 : .systemBackground)
			let path = UIBezierPath(roundedRect: k.rect.insetBy(dx: 1, dy: 0), byRoundingCorners: [.bottomLeft, .bottomRight],
			                        cornerRadii: CGSize(width: 6, height: 6))
			fill.setFill(); path.fill()
			UIColor.separator.setStroke(); path.lineWidth = 1; path.stroke()
			if !k.black && k.note % 12 == 0 {
				(noteName(k.note) as NSString).draw(at: CGPoint(x: k.rect.minX + 6, y: k.rect.maxY - 22),
				                                   withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.secondaryLabel])
			}
		}
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		for t in touches {
			guard let h = hit(t.location(in: self)) else { continue }
			let id = ObjectIdentifier(t)
			down[id] = h.note
			model.hands.touchDown(id.hashValue, note: h.note, velocity: h.velocity)
			if settings.haptics { tick.impactOccurred(intensity: 0.5) }
		}
		setNeedsDisplay()
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		var changed = false
		for t in touches {
			let id = ObjectIdentifier(t)
			guard let h = hit(t.location(in: self)), down[id] != nil, down[id] != h.note else { continue }
			down[id] = h.note
			model.hands.touchMoved(id.hashValue, note: h.note, velocity: h.velocity)
			if settings.haptics { tick.impactOccurred(intensity: 0.35) }
			changed = true
		}
		if changed { setNeedsDisplay() }
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		for t in touches { let id = ObjectIdentifier(t); if down.removeValue(forKey: id) != nil { model.hands.touchUp(id.hashValue) } }
		setNeedsDisplay()
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		for t in touches { let id = ObjectIdentifier(t); if down.removeValue(forKey: id) != nil { model.hands.touchCancelled(id.hashValue) } }
		setNeedsDisplay()
	}

	override func willMove(toWindow newWindow: UIWindow?) {
		if newWindow == nil { for id in down.keys { model.hands.touchCancelled(id.hashValue) }; down.removeAll() }
	}
}

// MARK: the XY pad

struct XYPadHost: UIViewRepresentable {
	let point: CGPoint
	let moved: (CGPoint) -> Void
	let ended: () -> Void
	func makeUIView(context: Context) -> XYPadView { XYPadView() }
	func updateUIView(_ v: XYPadView, context: Context) { v.point = point; v.moved = moved; v.ended = ended }
}

final class XYPadView: UIView {
	var point = CGPoint(x: 0.5, y: 0.5) { didSet { if point != oldValue { setNeedsDisplay() } } }
	var moved: (CGPoint) -> Void = { _ in }
	var ended: () -> Void = {}
	private var tracking: UITouch?

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundColor = .secondarySystemBackground
		contentMode = .redraw
		accessibilityLabel = "XY pad"
	}
	required init?(coder: NSCoder) { fatalError() }

	private func value(_ t: UITouch) -> CGPoint {
		let p = t.location(in: self)
		return CGPoint(x: max(0, min(1, p.x / max(1, bounds.width))), y: max(0, min(1, 1 - p.y / max(1, bounds.height))))
	}

	override func draw(_ rect: CGRect) {
		let c = CGPoint(x: point.x * bounds.width, y: (1 - point.y) * bounds.height)
		UIColor.separator.setStroke()
		let cross = UIBezierPath()
		cross.move(to: CGPoint(x: c.x, y: 0)); cross.addLine(to: CGPoint(x: c.x, y: bounds.height))
		cross.move(to: CGPoint(x: 0, y: c.y)); cross.addLine(to: CGPoint(x: bounds.width, y: c.y))
		cross.stroke()
		UIColor.tintColor.setFill()
		UIBezierPath(ovalIn: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)).fill()
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		guard tracking == nil, let t = touches.first else { return }
		tracking = t
		moved(value(t))
	}
	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		if let t = tracking, touches.contains(t) { moved(value(t)) }
	}
	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		if let t = tracking, touches.contains(t) { tracking = nil; ended() }
	}
	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }
}
