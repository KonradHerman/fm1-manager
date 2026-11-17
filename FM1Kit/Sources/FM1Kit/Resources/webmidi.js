// SPDX-License-Identifier: GPL-3.0-only
// FM-1 Manager: navigator.requestMIDIAccess for a WKWebView page, over CoreMIDI in the app (WebMIDIBridge.swift).
// Injected at document start, before the page's own scripts, on the origins the app allows (__FM1_ORIGINS__ is put
// in by the app). The shape follows the Web MIDI API as Chrome has it, and fm1-dock's own simulated device
// (docs/demo.js), which its pages are tested against:
//   - one MIDIAccess per page, every request answers it (with sysex: true, no prompt: the app asked the person);
//   - inputs / outputs are Maps (MIDIInputMap / MIDIOutputMap) kept up to date in place; a port that goes away
//     stays in its map with state "disconnected" and comes back as the same object (the same id) when it returns;
//   - statechange (MIDIConnectionEvent, .port) on the port and on the access, by handler and by listener, a task
//     later (as Chrome posts it), when a port's state or connection changes;
//   - midimessage (MIDIMessageEvent, .data a Uint8Array) by handler and listener; a SysEx is one event, F0 ... F7;
//   - MIDIOutput.send(data, timestamp) takes an Array or a typed array and throws at once on a disconnected port.
(() => {
  "use strict";
  const ORIGINS = __FM1_ORIGINS__;
  if (!ORIGINS.includes(location.origin)) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fm1midi;
  if (!handler || window.__fm1midi) return;
  const post = (msg) => handler.postMessage(msg);

  class MIDIConnectionEvent extends Event {
    constructor(type, init = {}) { super(type, init); Object.defineProperty(this, "port", { value: init.port || null, enumerable: true }); }
  }
  class MIDIMessageEvent extends Event {
    constructor(type, init = {}) { super(type, init); Object.defineProperty(this, "data", { value: init.data || null, enumerable: true }); }
  }
  class MIDIInputMap extends Map {}
  class MIDIOutputMap extends Map {}

  const S = new WeakMap();                       // a port's or the access's own state
  const later = (fn) => setTimeout(fn, 0);
  const inputs = new MIDIInputMap(), outputs = new MIDIOutputMap();
  const mapSet = Map.prototype.set;
  let access = null, sysex = false;

  // an EventTarget with an on<type> handler that sits in the listener list where it was first set (as the
  // platform's event handler attributes do)
  function handlerProperty(proto, type, onSet) {
    Object.defineProperty(proto, "on" + type, {
      configurable: true, enumerable: true,
      get() { return S.get(this)["on" + type] || null; },
      set(fn) {
        const s = S.get(this), key = "on" + type;
        if (!s[key + "L"]) { s[key + "L"] = (e) => { const f = s[key]; if (typeof f === "function") f.call(this, e); }; EventTarget.prototype.addEventListener.call(this, type, s[key + "L"]); }
        s[key] = typeof fn === "function" ? fn : null;
        if (onSet && s[key]) onSet(this);
      },
    });
  }

  function statechange(port) {
    later(() => {
      const ev = () => new MIDIConnectionEvent("statechange", { port });
      port.dispatchEvent(ev());
      if (access) access.dispatchEvent(ev());
    });
  }
  function setConnection(port, c) {
    const s = S.get(port);
    if (s.connection === c) return;
    s.connection = c;
    statechange(port);
  }
  const openPort = (port) => {
    const s = S.get(port);
    if (s.connection !== "open") setConnection(port, s.state === "connected" ? "open" : "pending");
  };

  class MIDIPort extends EventTarget {
    constructor(info, type) {
      super();
      if (!info || !info.id) throw new TypeError("Illegal constructor");
      S.set(this, { id: info.id, type, name: info.name, manufacturer: info.manufacturer || "", version: info.version || "",
        state: "connected", connection: "closed" });
    }
    get id() { return S.get(this).id; }
    get name() { return S.get(this).name; }
    get manufacturer() { return S.get(this).manufacturer; }
    get version() { return S.get(this).version; }
    get type() { return S.get(this).type; }
    get state() { return S.get(this).state; }
    get connection() { return S.get(this).connection; }
    open() { openPort(this); return Promise.resolve(this); }
    close() { setConnection(this, "closed"); return Promise.resolve(this); }
  }
  handlerProperty(MIDIPort.prototype, "statechange");

  class MIDIInput extends MIDIPort {
    addEventListener(type, fn, opts) {
      super.addEventListener(type, fn, opts);
      if (type === "midimessage" && fn) openPort(this);   // (implicitly opened, as onmidimessage does)
    }
  }
  handlerProperty(MIDIInput.prototype, "midimessage", openPort);

  class MIDIOutput extends MIDIPort {
    send(data, timestamp) {
      const s = S.get(this);
      if (s.state === "disconnected") throw new DOMException("The port is disconnected.", "InvalidStateError");
      if (data == null || typeof data[Symbol.iterator] !== "function") throw new TypeError("send: data is not a sequence of bytes");
      const bytes = Array.from(data, (x) => {
        const n = Number(x);
        if (!Number.isInteger(n) || n < 0 || n > 255) throw new TypeError(`send: ${x} is not a byte`);
        return n;
      });
      if (!bytes.length) return;
      if (!sysex && bytes.includes(0xF0)) throw new DOMException("System exclusive messages are not allowed.", "InvalidAccessError");
      openPort(this);
      const delay = timestamp ? Math.max(0, timestamp - performance.now()) : 0;
      post({ op: "send", id: s.id, data: bytes, delay });
    }
    clear() { /* (nothing is held back here) */ }
  }

  class MIDIAccess extends EventTarget {
    constructor(key) { super(); if (key !== S) throw new TypeError("Illegal constructor"); S.set(this, {}); }
    get inputs() { return inputs; }
    get outputs() { return outputs; }
    get sysexEnabled() { return sysex; }
  }
  handlerProperty(MIDIAccess.prototype, "statechange");

  // the app's list of ports, at the first request and on every change: new ports are added, gone ones disconnected
  function applyPorts(list) {
    const seen = new Set();
    for (const p of list || []) {
      const map = p.kind === "input" ? inputs : outputs;
      seen.add(p.kind + ":" + p.id);
      let port = map.get(p.id);
      if (!port) {
        port = p.kind === "input" ? new MIDIInput(p, "input") : new MIDIOutput(p, "output");
        mapSet.call(map, p.id, port);
        if (access) statechange(port);
        continue;
      }
      const s = S.get(port);
      s.name = p.name; s.manufacturer = p.manufacturer || ""; s.version = p.version || "";
      if (s.state !== "connected") {
        s.state = "connected";
        if (s.connection === "pending") s.connection = "open";
        statechange(port);
      }
    }
    for (const [kind, map] of [["input", inputs], ["output", outputs]]) {
      for (const port of map.values()) {
        const s = S.get(port);
        if (seen.has(kind + ":" + s.id) || s.state === "disconnected") continue;
        s.state = "disconnected";
        if (s.connection === "open") s.connection = "pending";
        statechange(port);
      }
    }
  }

  // messages from the app: [[input id, [bytes]], ...], in the order they came
  function receive(batch) {
    for (const [id, bytes] of batch || []) {
      const port = inputs.get(id);
      if (!port || S.get(port).state !== "connected") continue;
      port.dispatchEvent(new MIDIMessageEvent("midimessage", { data: Uint8Array.from(bytes) }));
    }
  }

  // an install under way: a page that would ask before it is left (both installers' beforeunload handlers), or an
  // element marked busy (fm1install.js's data-busy)
  function busy() {
    if (document.querySelector("[data-busy]")) return true;
    const e = new Event("beforeunload", { cancelable: true });
    try { window.dispatchEvent(e); } catch (_) { return false; }
    return e.defaultPrevented;
  }

  let pending = null;
  function requestMIDIAccess(options) {
    if (options && options.sysex) sysex = true;   // (the person installed this app to do exactly that)
    pending ||= post({ op: "access" }).then((list) => {
      applyPorts(list);
      access = new MIDIAccess(S);
      return access;
    }, (e) => { pending = null; throw new DOMException(String(e && e.message || e), "SecurityError"); });
    return pending;
  }

  Object.defineProperty(Navigator.prototype, "requestMIDIAccess", {
    configurable: true, enumerable: true, writable: true,
    value: { requestMIDIAccess(options) { return requestMIDIAccess(options); } }.requestMIDIAccess,
  });
  for (const [k, v] of Object.entries({ MIDIAccess, MIDIPort, MIDIInput, MIDIOutput, MIDIInputMap, MIDIOutputMap,
    MIDIMessageEvent, MIDIConnectionEvent }))
    Object.defineProperty(window, k, { configurable: true, writable: true, value: v });
  Object.defineProperty(window, "__fm1midi", { value: Object.freeze({ ports: applyPorts, receive, busy }) });
})();
