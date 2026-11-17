// SPDX-License-Identifier: GPL-3.0-only
// FM-1 Manager's offline page: the library's files (served by the app at library/), installed with fm1-dock's installer.
import { checkPackage, installOn, addModule, removeModule, inspectDevice, explain, productOf } from "./install/fm1install.js";
import { moduleInfo } from "./dock.js";

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const kib = (n) => `${Math.round(n / 1024)} KiB`;
let busy = false, midi = null;

addEventListener("beforeunload", (e) => { if (busy) { e.preventDefault(); e.returnValue = ""; } });

function say(text, cls = "") {
  $("progress-card").hidden = false;
  $("status").textContent = text;
  $("status").className = cls;
}
const bar = (v) => { $("bar").value = v; };

async function access() {
  if (!navigator.requestMIDIAccess) throw new Error("No MIDI here: open this page in the FM-1 Manager app.");
  midi ||= await navigator.requestMIDIAccess({ sysex: true });
  return midi;
}

// one job at a time, the page marked busy (the app keeps the screen on and asks before it is left)
async function job(fn) {
  if (busy) return;
  busy = true;
  document.body.dataset.busy = "1";
  for (const b of document.querySelectorAll("button")) b.disabled = true;
  try { await fn(); } catch (e) { say(explain(e), "bad"); console.error(e); }
  busy = false;
  delete document.body.dataset.busy;
  for (const b of document.querySelectorAll("button")) b.disabled = false;
}

const ask = async (q) => confirm(q);

// ------------------------------------------------------------------ the device ---

async function check() {
  $("dev-text").textContent = "Asking the FM-1…";
  $("dev-mods").innerHTML = "";
  const d = await inspectDevice(await access());
  if (!d.identity && !d.dock) { $("dev-text").textContent = "No FM-1 answered. Plug it in with a USB data cable and switch it on."; return; }
  if (d.ota) { $("dev-text").textContent = `In update mode (${d.identity}): an install was cut off. Install the same firmware again to finish it.`; return; }
  if (!d.dock) { $("dev-text").textContent = `${d.model} running ${d.identity}, not fm1-dock: modules need fm1-dock.`; return; }
  $("dev-text").textContent = `${d.model} running fm1-dock ${d.dock.version || ""} (${d.identity}), ${kib(d.dock.hello.free)} free for modules`;
  for (const m of d.dock.modules) {
    const el = document.createElement("span");
    el.className = "mod";
    el.textContent = m.name;
    if (m.kind === "deployed") {
      const b = Object.assign(document.createElement("button"), { textContent: "Remove", type: "button" });
      b.onclick = () => job(async () => {
        const r = await removeModule(await access(), m.name, ask);
        if (r === null) say("Cancelled: nothing was changed.");
        else say(r === "done" ? `${m.name} removed.` : `fm1-dock says: ${r}`, r === "done" ? "ok" : "bad");
        await check();
      });
      el.append(b);
    }
    $("dev-mods").append(el);
  }
}

// ------------------------------------------------------------------ the library ---

async function fileBytes(name) {
  const r = await fetch("library/" + encodeURIComponent(name), { cache: "no-store" });
  if (!r.ok) throw new Error(`${name}: ${r.status}`);
  return new Uint8Array(await r.arrayBuffer());
}

async function installFirmware(name) {
  say(`Checking ${name}…`); bar(0);
  const pkg = await checkPackage(await fileBytes(name), { file: name });
  const reads = Math.ceil(pkg.image.length / 512);
  const SAY = { start: "Starting the update", verify: "The FM-1 checks the package", loader: "Switching to update mode",
    write: "Writing: do not unplug the FM-1", reboot: "Restarting" };
  const step = (k, n) => {
    if (k === "verify") bar(Math.min(10, n / 8));
    if (k === "write") bar(10 + Math.min(89, (89 * n) / reads));
    if (k === "done") { bar(100); return; }
    if (SAY[k]) say(SAY[k] + (k === "write" ? ` (${Math.round($("bar").value)} %)` : "…"));
  };
  say("Looking for the FM-1…");
  const got = await installOn(await access(), pkg, `${name} (${pkg.product})`, ask, step);
  if (got === null) say("Cancelled: nothing was written.");
  else say(`Done: the FM-1 runs ${got}.`, "ok");
}

async function addDock(name) {
  say(`Reading ${name}…`); bar(0);
  const blob = await fileBytes(name);
  const info = moduleInfo(blob);
  if (info.probe) throw new Error(`${info.name} is a probe, not a module: run it from fm1-dock's console on a computer.`);
  if (info.boot) throw new Error(`${info.name} is a boot firmware: it is not added this way.`);
  say("Looking for fm1-dock on the FM-1…");
  const got = await addModule(await access(), { blob, info }, ask, (x, t) => { bar(Math.round(x * 100)); say(`Sending: ${t}`); });
  if (got === null) say("Cancelled: nothing was sent.");
  else { bar(100); say(`Done: ${got} is in fm1-dock. Hold HOME on the FM-1 and pick it.`, "ok"); }
}

async function describe(f) {
  const ext = f.name.split(".").pop().toLowerCase();
  if (ext === "fwsc") {
    try { const raw = await fileBytes(f.name); return { kind: "fwsc", what: `firmware ${productOf(raw)}` }; } catch (_) { return { kind: "fwsc", what: "firmware" }; }
  }
  if (ext === "dock" || ext === "hrbr") {
    try {
      const i = moduleInfo(await fileBytes(f.name));
      return { kind: "dock", what: `module ${i.name} v${i.version}, ABI ${i.abi}${i.probe ? " (a probe)" : ""}${i.boot ? " (boot)" : ""}` };
    } catch (e) { return { kind: "", what: e.message }; }
  }
  return { kind: "", what: "not a firmware or a module" };
}

async function list() {
  const box = $("files");
  let files = [];
  try { files = await (await fetch("library/index.json", { cache: "no-store" })).json(); } catch (_) { /* none */ }
  if (!files.length) {
    box.innerHTML = `<p class="empty">No files yet. Add .fwsc and .dock files in the app's Library (Import, or Share → FM-1 Manager
      from Files, Safari or Mail).</p>`;
    return;
  }
  box.innerHTML = "";
  for (const f of files) {
    const d = await describe(f);
    const card = document.createElement("div");
    card.className = "card";
    card.innerHTML = `<div class="row"><div><div class="name">${esc(f.name)}</div><div class="meta">${esc(d.what)} · ${kib(f.size)}</div></div></div>`;
    if (d.kind) {
      const b = Object.assign(document.createElement("button"), { type: "button", textContent: d.kind === "fwsc" ? "Install" : "Add" });
      b.dataset.file = f.name;
      b.onclick = () => job(() => (d.kind === "fwsc" ? installFirmware(f.name) : addDock(f.name)));
      card.querySelector(".row").append(b);
    }
    box.append(card);
  }
}

$("check").onclick = () => job(check);
list();
