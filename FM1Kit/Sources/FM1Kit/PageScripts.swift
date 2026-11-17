// SPDX-License-Identifier: GPL-3.0-only

/// Scripts the app runs in a page (callAsyncJavaScript bodies; their arguments are named in the comment).
public enum PageScripts {
	/// Hands a file to the page's file input that takes it, as if it had been chosen there: arguments `name`
	/// (the file name, whose extension picks the input by its accept list) and `base64` (the bytes). The first
	/// input that takes it and is enabled gets it, else the first that takes it; then input and change events.
	/// Returns the input's id ("input" if it has none), or "" when no input on the page takes such a file.
	public static let giveFile = """
	const bin = atob(base64), bytes = new Uint8Array(bin.length);
	for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
	const file = new File([bytes], name, { type: "application/octet-stream" });
	const ext = "." + name.split(".").pop().toLowerCase();
	const takes = (el) => !el.accept || el.accept.split(",").map((s) => s.trim().toLowerCase())
	  .some((a) => a === ext || a === "*/*" || a === "application/octet-stream");
	const all = [...document.querySelectorAll("input[type=file]")].filter(takes);
	const el = all.find((x) => !x.disabled) || all[0];
	if (!el) return "";
	const dt = new DataTransfer();
	dt.items.add(file);
	el.files = dt.files;
	el.dispatchEvent(new Event("input", { bubbles: true }));
	el.dispatchEvent(new Event("change", { bubbles: true }));
	return el.id || "input";
	"""

	/// The extensions the page's file inputs take (lower case, with the dot; "*" for an input that takes anything).
	public static let acceptedExtensions = """
	const out = new Set();
	for (const el of document.querySelectorAll("input[type=file]")) {
	  if (!el.accept) { out.add("*"); continue; }
	  for (const a of el.accept.split(",")) { const t = a.trim().toLowerCase(); if (t.startsWith(".")) out.add(t); else if (t === "*/*") out.add("*"); }
	}
	return [...out];
	"""
}
