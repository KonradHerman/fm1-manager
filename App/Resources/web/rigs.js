// SPDX-License-Identifier: GPL-3.0-only
// FM-1 Manager's rigs: the app's Swift (WebDockLink) talks to fm1-dock through fm1-dock's own dock.js and installer,
// in a page nobody sees (rigs.html). Each call finds the FM-1 by its port names (never a wide probe of other gear),
// does one thing, and lets go of the ports. Nothing runs on load.
import { Updater } from "./install/fm1ota.js";
import { findDock } from "./install/fm1install.js";
import { CMD } from "./dock.js";

let midi = null;
const access = async () => (midi ||= await navigator.requestMIDIAccess({ sysex: true }));
const bytes = (b64) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
const fail = (code, msg) => Object.assign(new Error(msg), { code });

async function withDock(fn) {
  const found = await findDock(await access());
  if (!found) throw fail("nodock", "No FM-1 running fm1-dock answered.");
  try { return await fn(found.dock, found.hello); } finally { found.dock.close(); }
}

window.R = {
  ready: true,
  progress: 0,
  // { identity, dock: { hello, modules, info } | null }
  async state() {
    const m = await access();
    const dev = await new Updater(m).find();
    if (dev) dev.link.close();
    const found = await findDock(m);
    if (!found) return { identity: dev ? dev.id.text : null, dock: null };
    const { dock, hello } = found;
    try {
      const modules = await dock.modules();
      const info = await dock.info();
      return { identity: dev ? dev.id.text : null, dock: { hello, modules, info } };
    } finally { dock.close(); }
  },
  // BEGIN, DATA..., COMMIT (dock.js Dock.deploy: it checks the ABI and the size first) -> the address it went to
  async deploy(b64) {
    R.progress = 0;
    return withDock(async (dock) => (await dock.deploy(bytes(b64), (x) => { R.progress = x; })).at);
  },
  async remove(name) { return withDock((dock) => dock.command(CMD.DELETE, name)); },
  async select(name) { return withDock((dock) => dock.command(CMD.SELECT, name)); },
  async abort() { return withDock(async (dock) => { dock.send(CMD.ABORT); await new Promise((r) => setTimeout(r, 200)); return "done"; }); },
};
