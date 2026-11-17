// SPDX-License-Identifier: GPL-3.0-only
// FM-1 Manager app icons: every concept, the colour variants, the contact sheet and the app's icon assets.
// Regenerate (from anywhere, nothing to install):   swift ios/icons/src/render.swift
// Writes ios/icons/concepts/*.png, ios/icons/variants/*.png, ios/icons/sheet.png,
// and App/Assets.xcassets/{AppIcon*.appiconset, IconPreview-*.imageset}.
// Coordinates below are in icon pixels (1024 square), y downwards.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: colour

struct RGB {
	var r, g, b: CGFloat
	init(_ hex: UInt32) { r = CGFloat(hex >> 16 & 255) / 255; g = CGFloat(hex >> 8 & 255) / 255; b = CGFloat(hex & 255) / 255 }
	init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
	func mix(_ o: RGB, _ t: CGFloat) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
	func lighter(_ t: CGFloat) -> RGB { mix(RGB(0xFFFFFF), t) }
	func darker(_ t: CGFloat) -> RGB { mix(RGB(0x000000), t) }
	func cg(_ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: sRGB, components: [r, g, b, a])! }
	/// WCAG relative luminance, for the contrast check printed at the end
	var luminance: CGFloat {
		func lin(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
		return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
	}
}
func contrast(_ a: RGB, _ b: RGB) -> CGFloat { let (x, y) = (a.luminance, b.luminance); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }

/// One colourway. `asset` is the app icon set name (nil = the primary icon, "AppIcon").
struct Palette {
	var id: String, label: String, asset: String?
	var panel: RGB, key: RGB, slot: RGB
	var led = RGB(0xFFF4D8), glow = RGB(0xFFC46B)
}

// Terracotta: sampled from the owner's photo of his unit (keys ~#8F5548, panel ~#8E5346: same hue, the photo is dim),
// lifted a little in lightness and saturation so it does not look muddy on a home screen.
// The others: the FM-1's colourways as sellers list them (see the report); which part of a two-tone
// unit is which colour is unconfirmed, so "panel / keys" below is an interpretation.
let palettes: [Palette] = [
	Palette(id: "terracotta", label: "Terracotta", asset: nil, panel: RGB(0x934F40), key: RGB(0xB2644F), slot: RGB(0x3A211C)),
	Palette(id: "black", label: "Black", asset: "AppIcon-Black", panel: RGB(0x18181B), key: RGB(0x3C3D43), slot: RGB(0x09090A)),
	Palette(id: "blackgreen", label: "Black & green", asset: "AppIcon-BlackGreen", panel: RGB(0x1A1D1C), key: RGB(0x3FA07C), slot: RGB(0x0E241C)),
	Palette(id: "greyblack", label: "Grey & black", asset: "AppIcon-GreyBlack", panel: RGB(0x8C9095), key: RGB(0x2E3034), slot: RGB(0x7A7D84)),
	Palette(id: "greyblue", label: "Grey & blue", asset: "AppIcon-GreyBlue", panel: RGB(0x8E9298), key: RGB(0x3C77C4), slot: RGB(0x15284A)),
	Palette(id: "whitegrey", label: "White & grey", asset: "AppIcon-WhiteGrey", panel: RGB(0xEEECE7), key: RGB(0xA4A8AE), slot: RGB(0x45484E)),
	Palette(id: "whitegreen", label: "White & green", asset: "AppIcon-WhiteGreen", panel: RGB(0xEEECE7), key: RGB(0x45A87F), slot: RGB(0x173A2C)),
	Palette(id: "purple", label: "Purple", asset: "AppIcon-Purple", panel: RGB(0x5A3E8E), key: RGB(0x8462C0), slot: RGB(0x24173B)),
]
let terracotta = palettes[0]

// MARK: geometry

func pill(_ r: CGRect) -> CGPath { let c = min(r.width, r.height) / 2; return CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil) }

/// Two keys over three, the upper pair over the lower gaps: the "M".
struct Keys {
	var w: CGFloat = 226, h: CGFloat = 356, gap: CGFloat = 34, rowGap: CGFloat = 20, cy: CGFloat = 512
	var slotW: CGFloat = 0.12, slotH: CGFloat = 0.46
	var rects: [CGRect] {
		let pitch = w + gap, top = cy - (2 * h + rowGap) / 2, bottom = top + h + rowGap
		return [-0.5, 0.5].map { CGRect(x: 512 + $0 * pitch - w / 2, y: top, width: w, height: h) }
			+ [-1.0, 0, 1].map { CGRect(x: 512 + $0 * pitch - w / 2, y: bottom, width: w, height: h) }
	}
	func slot(_ r: CGRect) -> CGRect {
		let sw = r.width * slotW, sh = r.height * slotH
		return CGRect(x: r.midX - sw / 2, y: r.midY - sh / 2, width: sw, height: sh)
	}
}

// MARK: drawing helpers (context is flipped: y down; CG shadow offsets stay y-up, hence the negative heights)

func fill(_ c: CGContext, _ p: CGPath, _ col: CGColor) { c.addPath(p); c.setFillColor(col); c.fillPath() }
func vGradient(_ c: CGContext, _ clip: CGPath, _ rect: CGRect, _ top: RGB, _ bottom: RGB) {
	c.saveGState(); c.addPath(clip); c.clip()
	let g = CGGradient(colorsSpace: sRGB, colors: [top.cg(), bottom.cg()] as CFArray, locations: [0, 1])!
	c.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
	c.restoreGState()
}
func radial(_ c: CGContext, _ at: CGPoint, _ radius: CGFloat, _ col: RGB, _ a: CGFloat) {
	let g = CGGradient(colorsSpace: sRGB, colors: [col.cg(a), col.cg(a * 0.45), col.cg(0)] as CFArray, locations: [0, 0.4, 1])!
	c.drawRadialGradient(g, startCenter: at, startRadius: 0, endCenter: at, endRadius: radius, options: [])
}
let square = CGRect(x: 0, y: 0, width: S, height: S)

// MARK: concepts

/// A: flat. Keys a step lighter than the panel, a darker recess ring around each, dark slots.
func drawFlat(_ c: CGContext, _ p: Palette, _ k: Keys = Keys()) {
	fill(c, CGPath(rect: square, transform: nil), p.panel.cg())
	let recess = p.panel.luminance > 0.5 ? p.panel.darker(0.12) : p.panel.darker(0.22)
	for r in k.rects {
		fill(c, pill(r.insetBy(dx: -7, dy: -7).offsetBy(dx: 0, dy: 5)), recess.cg())
		fill(c, pill(r), p.key.cg())
		fill(c, pill(k.slot(r)), p.slot.cg())
	}
}

/// B: soft 3D moulded silicone. C: the same with one key's slot lit. E: the same, bigger keys and bolder slots.
func drawSoft(_ c: CGContext, _ p: Palette, _ k: Keys = Keys(), lit: Int? = nil, dots: Bool = true, background: Bool = true) {
	if background { vGradient(c, CGPath(rect: square, transform: nil), square, p.panel.lighter(0.07), p.panel.darker(0.10)) }
	let light = p.panel.luminance > 0.5
	if dots { // the small dark marks on the panel beside the upper keys
		let r0 = k.rects[0], r1 = k.rects[1]
		for x in [r0.minX - k.gap * 2.2, r1.maxX + k.gap * 2.2] {
			fill(c, CGPath(ellipseIn: CGRect(x: x - 10, y: r0.maxY - 40, width: 20, height: 20), transform: nil), p.panel.darker(light ? 0.35 : 0.45).cg())
		}
	}
	for (i, r) in k.rects.enumerated() {
		// recess the key sits in, then a soft contact shadow under it
		c.saveGState()
		c.setShadow(offset: CGSize(width: 0, height: -12), blur: 26, color: RGB(0).cg(light ? 0.30 : 0.55))
		fill(c, pill(r), p.key.cg())
		c.restoreGState()
		// body: lit from above
		vGradient(c, pill(r), r, p.key.lighter(0.14), p.key.darker(0.12))
		c.saveGState(); c.addPath(pill(r)); c.clip()
		radial(c, CGPoint(x: r.midX - r.width * 0.08, y: r.minY + r.width * 0.30), r.width * 0.75, RGB(0xFFFFFF), light ? 0.22 : 0.18)
		// rim: light along the top edge, darker along the bottom
		c.setLineWidth(6)
		c.addPath(pill(r.insetBy(dx: 3, dy: 3))); c.setStrokeColor(RGB(0xFFFFFF).cg(0.16)); c.strokePath()
		c.restoreGState()
		// the slot, pressed in: a light lip below it, dark inside, darker at its top
		let s = k.slot(r)
		if i == lit {
			c.saveGState(); c.addPath(pill(r)); c.clip()
			radial(c, CGPoint(x: s.midX, y: s.midY), r.width * 1.05, p.glow, 0.85)
			c.restoreGState()
			c.saveGState()
			c.setShadow(offset: .zero, blur: 26, color: p.glow.cg(1))
			fill(c, pill(s.insetBy(dx: -3, dy: -3)), p.glow.lighter(0.3).cg())
			c.restoreGState()
			vGradient(c, pill(s), s, p.led, p.led.mix(p.glow, 0.25))
		} else {
			fill(c, pill(s.offsetBy(dx: 0, dy: 5)), p.key.lighter(0.30).cg(0.7))
			vGradient(c, pill(s), s, p.slot.darker(0.35), p.slot)
		}
	}
}

/// D: the whole instrument, front view, reduced: screen with bars, a knob each side, the two key rows.
func drawMini(_ c: CGContext, _ p: Palette) {
	vGradient(c, CGPath(rect: square, transform: nil), square, p.panel.lighter(0.06), p.panel.darker(0.08))
	// screen
	let screen = CGRect(x: 312, y: 128, width: 400, height: 330)
	c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: RGB(0).cg(0.4))
	fill(c, CGPath(roundedRect: screen, cornerWidth: 34, cornerHeight: 34, transform: nil), RGB(0x101012).cg())
	c.restoreGState()
	let bars: [UInt32] = [0xF0503C, 0x3CC8F0, 0xF5C832, 0x3CC8F0, 0xA066F0]
	let bw: CGFloat = 46, bgap = (screen.width - 64 - bw * 5) / 4
	for (i, col) in bars.enumerated() {
		let x = screen.minX + 32 + CGFloat(i) * (bw + bgap)
		let h: [CGFloat] = [150, 230, 110, 190, 140]
		fill(c, CGPath(roundedRect: CGRect(x: x, y: screen.maxY - 40 - h[i], width: bw, height: h[i]), cornerWidth: 8, cornerHeight: 8, transform: nil), RGB(col).cg())
	}
	// knobs
	for (x, ang) in [(CGFloat(168), CGFloat(-0.6)), (856, 0.5)] {
		let ctr = CGPoint(x: x, y: 260), rad: CGFloat = 92
		c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: RGB(0).cg(0.45))
		fill(c, CGPath(ellipseIn: CGRect(x: ctr.x - rad, y: ctr.y - rad, width: rad * 2, height: rad * 2), transform: nil), RGB(0x34363C).cg())
		c.restoreGState()
		vGradient(c, CGPath(ellipseIn: CGRect(x: ctr.x - rad + 8, y: ctr.y - rad + 8, width: rad * 2 - 16, height: rad * 2 - 16), transform: nil),
		          CGRect(x: ctr.x - rad, y: ctr.y - rad, width: rad * 2, height: rad * 2), RGB(0x5A5D65), RGB(0x2C2E33))
		c.setLineCap(.round); c.setLineWidth(16); c.setStrokeColor(RGB(0xF2F2F2).cg())
		c.move(to: CGPoint(x: ctr.x + sin(ang) * 20, y: ctr.y - cos(ang) * 20))
		c.addLine(to: CGPoint(x: ctr.x + sin(ang) * 66, y: ctr.y - cos(ang) * 66)); c.strokePath()
	}
	// key rows: upper row in the FM-1's groups (3, 2, 3, 2), lower row continuous
	let w: CGFloat = 92, h: CGFloat = 156, pitch: CGFloat = 112
	let lower = (0..<8).map { CGRect(x: 512 + (CGFloat($0) - 3.5) * pitch - w / 2, y: 768, width: w, height: h) }
	let upper = [0, 1, 3, 4, 5].map { CGRect(x: lower[$0].maxX + (pitch - w) / 2 - w / 2, y: 590, width: w, height: h) }
	let k = Keys(slotW: 0.12, slotH: 0.5)
	for r in upper + lower {
		c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: RGB(0).cg(0.45))
		fill(c, pill(r), p.key.cg()); c.restoreGState()
		vGradient(c, pill(r), r, p.key.lighter(0.12), p.key.darker(0.1))
		fill(c, pill(k.slot(r)), p.slot.cg())
	}
}

/// E: the M keys under a slice of the FM-1's screen (its coloured level bars): the keys' shape plus the one
/// colourful thing everyone recognises the unit by, so the icon is not "five pills" alone at small sizes.
func drawScreenKeys(_ c: CGContext, _ p: Palette) {
	vGradient(c, CGPath(rect: square, transform: nil), square, p.panel.lighter(0.07), p.panel.darker(0.10))
	let screen = CGRect(x: 170, y: -60, width: 684, height: 400)
	c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: RGB(0).cg(0.45))
	fill(c, CGPath(roundedRect: screen, cornerWidth: 54, cornerHeight: 54, transform: nil), RGB(0x101012).cg())
	c.restoreGState()
	let bars: [UInt32] = [0xF0503C, 0x3CC8F0, 0xF5C832, 0x3CC8F0, 0xF0503C, 0x3CC8F0]
	let hs: [CGFloat] = [130, 200, 100, 170, 120, 190]
	let bw: CGFloat = 62, x0 = screen.minX + 52, step = (screen.width - 104 - bw) / CGFloat(bars.count - 1)
	for (i, col) in bars.enumerated() {
		fill(c, CGPath(roundedRect: CGRect(x: x0 + CGFloat(i) * step, y: screen.maxY - 44 - hs[i], width: bw, height: hs[i]), cornerWidth: 10, cornerHeight: 10, transform: nil), RGB(col).cg())
	}
	drawSoft(c, p, Keys(w: 158, h: 250, gap: 28, rowGap: 16, cy: 680, slotW: 0.13, slotH: 0.46), lit: nil, dots: false, background: false)
}

// MARK: rendering and files

func render(_ draw: (CGContext) -> Void) -> CGImage {
	let c = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
	c.interpolationQuality = .high; c.setShouldAntialias(true)
	c.translateBy(x: 0, y: S); c.scaleBy(x: 1, y: -1)
	draw(c)
	return c.makeImage()!
}
func scaled(_ img: CGImage, _ px: Int, rounded: Bool = false) -> CGImage {
	let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
	                  bitmapInfo: (rounded ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
	c.interpolationQuality = .high
	let r = CGRect(x: 0, y: 0, width: px, height: px)
	if rounded { // iOS mask, approximately (continuous corners, ~22.4% radius): preview only
		c.addPath(CGPath(roundedRect: r, cornerWidth: r.width * 0.2237, cornerHeight: r.width * 0.2237, transform: nil)); c.clip()
	}
	c.draw(img, in: r)
	return c.makeImage()!
}
func write(_ img: CGImage, _ url: URL) {
	try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
	let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
	CGImageDestinationAddImage(d, img, nil); precondition(CGImageDestinationFinalize(d))
}
func writeJSON(_ s: String, _ url: URL) {
	try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
	try! s.write(to: url, atomically: true, encoding: .utf8)
}

struct Concept { let id, title, note: String; let draw: (CGContext, Palette) -> Void }
let concepts: [Concept] = [
	Concept(id: "A-flat", title: "A  M keys, flat", note: "five pills, recess rings") { drawFlat($0, $1) },
	Concept(id: "B-soft3d", title: "B  M keys, soft 3D", note: "moulded silicone") { drawSoft($0, $1) },
	Concept(id: "C-lit", title: "C  M keys, one lit", note: "middle slot glows") { drawSoft($0, $1, lit: 3) },
	Concept(id: "D-mini-fm1", title: "D  Mini FM-1", note: "whole instrument") { drawMini($0, $1) },
	Concept(id: "E-screen-keys", title: "E  Screen + M keys", note: "the screen's bars over the keys") { drawScreenKeys($0, $1) },
]
/// The concept the colour variants and the app's icons use.
let shipped = concepts[2]

// MARK: contact sheet

func text(_ c: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, bold: Bool = false, color: RGB = RGB(0x1C1C1E)) {
	let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil)
	let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: color.cg()])
	let line = CTLineCreateWithAttributedString(attr)
	c.saveGState(); c.textMatrix = CGAffineTransform(scaleX: 1, y: -1); c.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, c); c.restoreGState()
}

func sheet(_ rows: [(title: String, note: String, img: CGImage)], sections: [Int: String]) -> CGImage {
	let W = 1010, rowH: CGFloat = 288, secH: CGFloat = 56
	let H = Int(70 + CGFloat(rows.count) * rowH + CGFloat(sections.count) * secH + 20)
	let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
	c.interpolationQuality = .high
	c.translateBy(x: 0, y: CGFloat(H)); c.scaleBy(x: 1, y: -1)
	func put(_ img: CGImage, _ r: CGRect) { c.saveGState(); c.translateBy(x: r.minX, y: r.maxY); c.scaleBy(x: 1, y: -1); c.draw(img, in: CGRect(origin: .zero, size: r.size)); c.restoreGState() }
	fill(c, CGPath(rect: CGRect(x: 0, y: 0, width: W, height: H), transform: nil), RGB(0xFAFAF8).cg())
	text(c, "FM-1 Manager icons: 1024 shown at 256, then 120 px and 60 px with the iOS mask, on light and dark", 24, 42, size: 17, bold: true)
	var y: CGFloat = 70
	for (i, row) in rows.enumerated() {
		if let s = sections[i] { text(c, s, 24, y + 36, size: 20, bold: true); y += secH }
		text(c, row.title, 24, y + 40, size: 18, bold: true)
		text(c, row.note, 24, y + 64, size: 14, color: RGB(0x6E6E73))
		put(row.img, CGRect(x: 230, y: y + 12, width: 256, height: 256))
		for (bx, bg) in [(CGFloat(510), RGB(0xE9E9EE)), (CGFloat(760), RGB(0x1C1C1E))] {
			fill(c, CGPath(roundedRect: CGRect(x: bx, y: y + 12, width: 236, height: 256), cornerWidth: 14, cornerHeight: 14, transform: nil), bg.cg())
			put(scaled(row.img, 120, rounded: true), CGRect(x: bx + 18, y: y + 80, width: 120, height: 120))
			put(scaled(row.img, 60, rounded: true), CGRect(x: bx + 158, y: y + 110, width: 60, height: 60))
		}
		y += rowH
	}
	return c.makeImage()!
}

// MARK: main

var rows: [(title: String, note: String, img: CGImage)] = []
for k in concepts {
	let img = render { k.draw($0, terracotta) }
	write(img, ios.appendingPathComponent("icons/concepts/\(k.id).png"))
	rows.append((k.title, k.note, img))
}
let assets = ios.appendingPathComponent("App/Assets.xcassets")
for p in palettes {
	let img = render { shipped.draw($0, p) }
	write(img, ios.appendingPathComponent("icons/variants/\(shipped.id)-\(p.id).png"))
	rows.append((p.label, String(format: "keys/panel %.2f:1", contrast(p.key, p.panel)) + (p.asset == nil ? " · primary" : ""), img))
	// app icon set (primary or alternate) and a small preview image for the in-app chooser
	let set = (p.asset ?? "AppIcon") + ".appiconset"
	write(img, assets.appendingPathComponent("\(set)/icon-1024.png"))
	writeJSON("""
	{ "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
	  "info" : { "author" : "xcode", "version" : 1 } }

	""", assets.appendingPathComponent("\(set)/Contents.json"))
	let name = "IconPreview-\(p.id)"
	write(scaled(img, 180), assets.appendingPathComponent("\(name).imageset/\(name).png"))
	writeJSON("""
	{ "images" : [ { "filename" : "\(name).png", "idiom" : "universal", "scale" : "3x" } ],
	  "info" : { "author" : "xcode", "version" : 1 } }

	""", assets.appendingPathComponent("\(name).imageset/Contents.json"))
	print(String(format: "%-12@ keys/panel %.2f  slot/key %.2f", p.id, contrast(p.key, p.panel), contrast(p.slot, p.key)))
}
write(sheet(rows, sections: [0: "Concepts (terracotta)", concepts.count: "Colour variants of \(shipped.title.dropFirst(3))"]), ios.appendingPathComponent("icons/sheet.png"))
print("wrote concepts, variants (\(shipped.id)), sheet, \(palettes.count) icon sets")
