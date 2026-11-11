// OmniPlay SDK (JavaScript): talk to fitness devices from any game. Plain ES module, no
// dependencies: browsers, Node, Electron, React Native, Capacitor... The same core as
// sdk/lua/omniplay.lua; both run the same test file (tests/sdk/vectors.json).
//
// It doesn't do Bluetooth itself: the platform hands it the bytes it receives and sends the
// bytes it asks for. connectWebBluetooth() at the bottom is that for browsers (Chrome, Edge,
// Android Chrome); for other platforms see docs/SDK.md.
//
//   import { OmniPlay, connectWebBluetooth } from "./omniplay.js";
//   const op = OmniPlay.create({ onEvent: (name, value) => {} });
//   button.onclick = () => connectWebBluetooth(op);   // must come from a click
//   function frame(dt) { op.update(dt); const v = op.values(); ... }
//   op.setGrade(4.5);  op.setBeltSpeed(3.2);
//
// License: OmniPlay SDK License (MIT + don't sell OmniPlay support separately).

const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
const u16 = (b, i) => (b[i] ?? 0) + (b[i + 1] ?? 0) * 256;
const s16 = (b, i) => { const v = u16(b, i); return v >= 0x8000 ? v - 0x10000 : v; };
const u32 = (b, i) => u16(b, i) + u16(b, i + 2) * 65536;
const le16 = (v) => { v = ((Math.floor(v) % 65536) + 65536) % 65536; return [v & 0xff, v >> 8]; };
const bit = (v, n) => ((v >> n) & 1) === 1;

export function shortUuid(u) {
  u = String(u).toLowerCase();
  const m = u.match(/^0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb$/) || u.match(/^([0-9a-f]{4})$/);
  return m ? m[1] : u;
}
export const fullUuid = (s) => (s.length === 4 ? `0000${s}-0000-1000-8000-00805f9b34fb` : s);

export const KINDS = {
  ftms_bike: { service: "1826", notify: ["2ad2", "2ad9", "2ada"], write: "2ad9", label: "Bike (FTMS)", move: true },
  ftms_treadmill: { service: "1826", notify: ["2acd", "2ad9", "2ada"], write: "2ad9", label: "Treadmill (FTMS)", move: true },
  sperax: { service: "fff0", notify: ["fff1"], write: "fff2", label: "Sperax walking pad", move: true },
  rsc: { service: "1814", notify: ["2a53"], label: "Footpod", move: true },
  csc: { service: "1816", notify: ["2a5b"], label: "Speed / cadence sensor" },
  hr: { service: "180d", notify: ["2a37"], label: "Heart-rate strap" },
};
export const SERVICES = ["1826", "1816", "1814", "180d", "fff0"].map(fullUuid);

export function detect(uuids, name) {
  const has = new Set((uuids || []).map(shortUuid));
  const speraxName = String(name || "").toUpperCase().includes("SPERAX");
  if (has.has("fff0") && speraxName) return "sperax";
  if (has.has("2ad2")) return "ftms_bike";
  if (has.has("2acd")) return "ftms_treadmill";
  if (has.has("1826")) return "ftms_bike";
  if (has.has("2a53") || has.has("1814")) return "rsc";
  if (has.has("2a5b") || has.has("1816")) return "csc";
  if (has.has("fff1") && has.has("fff2")) return "sperax";
  if (has.has("2a37") || has.has("180d")) return "hr";
  return null;
}

// ---------- FTMS ----------
export const FTMS = {
  REQUEST_CONTROL: [0x00], RESET: [0x01], START: [0x07], STOP: [0x08, 0x01],
  // the machine answers each control point command (0x80, opcode, result); commands go one at a
  // time, the next when the answer comes or after this long without one (as qdomyos-zwift does)
  ANSWER_WAIT: 0.3,
  simulation(grade) { const [lo, hi] = le16(Math.floor(grade * 100 + 0.5)); return [0x11, 0x00, 0x00, lo, hi, 40, 51]; },
  targetSpeed(kmh) { const [lo, hi] = le16(Math.floor(kmh * 100 + 0.5)); return [0x02, lo, hi]; },
  targetIncline(pct) { const [lo, hi] = le16(Math.floor(pct * 10 + 0.5)); return [0x03, lo, hi]; },
  bike(b) {
    const f = u16(b, 0); let i = 2; const d = {};
    if (!bit(f, 0)) { d.speed_kmh = u16(b, i) / 100; i += 2; }
    if (bit(f, 1)) { d.avg_speed_kmh = u16(b, i) / 100; i += 2; }
    if (bit(f, 2)) { d.cadence = u16(b, i) / 2; i += 2; }
    if (bit(f, 3)) { d.avg_cadence = u16(b, i) / 2; i += 2; }
    if (bit(f, 4)) { d.distance_m = u16(b, i) + (b[i + 2] ?? 0) * 65536; i += 3; }
    if (bit(f, 5)) { d.resistance = s16(b, i); i += 2; }
    if (bit(f, 6)) { d.power = s16(b, i); i += 2; }
    if (bit(f, 7)) i += 2;
    if (bit(f, 8)) { d.kcal = u16(b, i); i += 5; }
    if (bit(f, 9)) { d.hr = b[i]; i += 1; }
    return d;
  },
  treadmill(b) {
    const f = u16(b, 0); let i = 2; const d = {};
    if (!bit(f, 0)) { d.speed_kmh = u16(b, i) / 100; i += 2; }
    if (bit(f, 1)) { d.avg_speed_kmh = u16(b, i) / 100; i += 2; }
    if (bit(f, 2)) { d.distance_m = u16(b, i) + (b[i + 2] ?? 0) * 65536; i += 3; }
    if (bit(f, 3)) { d.incline = s16(b, i) / 10; i += 4; }
    if (bit(f, 4)) i += 4;
    if (bit(f, 5)) i += 1;
    if (bit(f, 6)) i += 1;
    if (bit(f, 7)) { d.kcal = u16(b, i); i += 5; }
    if (bit(f, 8)) { d.hr = b[i]; i += 1; }
    return d;
  },
};

// ---------- Sperax walking pads ----------
// Protocol from github.com/Guhan-SenSam/sperax-walkpad (MIT), checked on a SPERAX_RM01.
function spxCrc(b, i, j) {
  let crc = 0xffff;
  for (let k = i; k <= j; k++) {
    crc ^= b[k];
    for (let n = 0; n < 8; n++) crc = crc & 1 ? (crc >> 1) ^ 0xa327 : crc >> 1;
  }
  return [crc & 0xff, crc >> 8];
}
function spxEncode(payload) {
  const f = [0xf5, payload.length + 6, 0x00, ...payload];
  const [lo, hi] = spxCrc(f, 0, f.length - 1);
  f.push(lo, hi, 0xfa);
  const e = [f[0], 0, f[2]];
  for (let i = 3; i < f.length - 1; i++) { if (f[i] >= 0xf0) e.push(0xf0, f[i] - 0xf0); else e.push(f[i]); }
  e.push(0xfa);
  e[1] = e.length;
  return e;
}
const SPX_STATES = { 0x00: "idle", 0x13: "countdown", 0x12: "countdown", 0x11: "countdown", 0x10: "running", 0x0f: "slowing",
  0x01: "paused", 0x02: "stopped", 0x50: "vibrating" };
function spxFeed(r, chunk) {
  for (const v of chunk) r.push(v);
  const frames = [];
  for (;;) {
    const s = r.indexOf(0xf5);
    if (s < 0) { r.length = 0; break; }
    const e = r.indexOf(0xfa, s + 1);
    if (e < 0) { if (r.length > 1024) r.length = 0; break; }
    let raw = r.slice(s, e + 1);
    r.splice(0, e + 1);
    if (raw[1] !== raw.length) {
      for (let j = 2; j <= Math.min(4, raw.length - 6); j++) {
        if (raw[j] === raw.length - (j - 1)) { raw = [0xf5, ...raw.slice(j)]; break; }
      }
    }
    const b = [];
    for (let i = 0; i < raw.length; i++) {
      if (raw[i] === 0xf0 && i < raw.length - 1 && raw[i + 1] <= 0x0f) { b.push(0xf0 + raw[i + 1]); i++; } else b.push(raw[i]);
    }
    if (b.length >= 7) {
      const len = b[1];
      b[1] = b.length;
      const [lo, hi] = spxCrc(b, 0, b.length - 4);
      b[1] = len;
      frames.push({ b, cmd: b[3], ok: lo === b[b.length - 3] && hi === b[b.length - 2] });
    }
  }
  return frames;
}
function spxStatus(b) {
  if (b[3] !== 0x19 || b.length < 21) return null;
  const be = (i) => (b[i] ?? 0) * 256 + (b[i + 1] ?? 0);
  return { state: SPX_STATES[b[6]] || "unknown", seconds: be(9), distance_m: be(11) * 10, kcal: be(13), steps: be(15), speed_kmh: b[17] / 10 };
}
export const SPERAX = { encode: spxEncode, feed: spxFeed, status: spxStatus, STATUS: spxEncode([0x19]),
  speed: (kmh) => spxEncode([0x15, 0x01, Math.floor(kmh * 10 + 0.5), 0x00]), BELT_STOP: spxEncode([0x15, 0x00, 0x00, 0x00]) };

// ---------- RSC, CSC, heart rate ----------
function rsc(b) {
  const f = b[0] ?? 0;
  const d = { speed_kmh: (u16(b, 1) / 256) * 3.6, cadence: b[3] ?? 0 };
  let i = 4;
  if (bit(f, 0)) i += 2;
  if (bit(f, 1)) d.distance_m = u32(b, i) / 10;
  return d;
}
const heartRate = (b) => (bit(b[0] ?? 0, 0) ? u16(b, 1) : b[1] ?? 0);
function cscFeed(s, b, now) {
  const f = b[0] ?? 0; let i = 1;
  if (bit(f, 0)) {
    s.wheelSeen = now;
    const wr = u32(b, i), wt = u16(b, i + 4);
    if (s.wr !== undefined) {
      const dr = (((wr - s.wr) % 4294967296) + 4294967296) % 4294967296, dt = ((((wt - s.wt) % 65536) + 65536) % 65536) / 1024;
      if (dr > 0 && dr < 100 && dt > 0) {
        const rps = dr / dt;
        if (rps < 40) { s.rps = (s.rps || 0) > 0 ? s.rps * 0.3 + rps * 0.7 : rps; s.wperiod = dt / dr; }
        s.wheelAt = now;
      }
    }
    s.wr = wr; s.wt = wt; i += 6;
  }
  if (bit(f, 1)) {
    s.crankSeen = now;
    const cr = u16(b, i), ct = u16(b, i + 2);
    if (s.cr !== undefined) {
      const dr = (((cr - s.cr) % 65536) + 65536) % 65536, dt = ((((ct - s.ct) % 65536) + 65536) % 65536) / 1024;
      if (dr > 0 && dr < 20 && dt > 0) {
        const rpm = (dr / dt) * 60;
        if (rpm < 250) { s.rpm = (s.rpm || 0) > 0 ? s.rpm * 0.3 + rpm * 0.7 : rpm; s.cperiod = dt / dr; }
        s.crankAt = now;
      }
    }
    s.cr = cr; s.ct = ct;
  }
}
function cscValues(s, now, wheelM) {
  const d = {};
  const going = (at, period) => at !== undefined && now - at < Math.max(1.2, Math.min(3, (period || 1) * 2.2));
  if (s.crankSeen !== undefined && now - s.crankSeen < 5) {
    if (!going(s.crankAt, s.cperiod)) s.rpm = 0;
    d.cadence = Math.floor((s.rpm || 0) + 0.5); d.moving = going(s.crankAt, s.cperiod);
  }
  if (s.wheelSeen !== undefined && now - s.wheelSeen < 5) {
    if (!going(s.wheelAt, s.wperiod)) s.rps = 0;
    d.speed_kmh = Math.floor((s.rps || 0) * wheelM * 3.6 * 10 + 0.5) / 10;
    d.moving = d.moving || going(s.wheelAt, s.wperiod);
  }
  return d;
}

export const walkFactor = (grade) => Math.exp(-3.5 * (Math.abs(grade / 100 + 0.05) - 0.05));

// ---------- a session ----------
const DEFAULTS = {
  wheel_mm: 2105, allow_hills: true, allow_belt: false, max_belt_kmh: 4, belt_ramp: 0.5,
  gait: { walk: { pad_kmh: 1.0, rpm: 30 }, run: { pad_kmh: 3.5, rpm: 70 }, sprint: { pad_kmh: 5.0, watts: 200, rpm: 85 } },
};

export class Session {
  // opts: send(id, charUuid, Uint8Array) (connectWebBluetooth sets it), onEvent(name, value), and any DEFAULTS
  constructor(opts = {}) {
    Object.assign(this, structuredCloneSafe(DEFAULTS), opts);
    this.devices = new Map(); this.t = 0; this.distance_m = 0; this.elapsed_s = 0;
    this.grade = null; this.beltTarget = null; this.gaitNow = "stopped"; this.moving = false;
  }
  _write(d, bytes) { const k = KINDS[d.kind]; if (k.write && this.send) this.send(d.id, fullUuid(k.write), Uint8Array.from(bytes)); }
  // FTMS control point: one command at a time; a newer hill / speed / incline replaces one still waiting
  _pump(d) {
    if (d.busy !== undefined || d.q.length === 0) return;
    const c = d.q.shift();
    d.busy = 0;
    this._write(d, c);
  }
  _command(d, bytes) {
    const i = d.q.findIndex((c) => c[0] === bytes[0] && [0x11, 0x02, 0x03].includes(bytes[0]));
    if (i >= 0) { d.q[i] = bytes; return; }
    d.q.push(bytes);
    this._pump(d);
  }

  add(id, name, uuids, kind) {
    kind = kind || detect(uuids, name);
    if (!kind) return null;
    this.devices.set(id, { id, name: name || kind, kind, m: {}, seen: undefined, rx: [], csc: {}, steps: [], poll: 0, gradeT: 99, q: [] });
    return kind;
  }
  notifyChars(id) { const d = this.devices.get(id); return d ? KINDS[d.kind].notify.map(fullUuid) : []; }
  service(id) { const d = this.devices.get(id); return d ? fullUuid(KINDS[d.kind].service) : null; }
  writeChar(id) { const d = this.devices.get(id); return d && KINDS[d.kind].write ? fullUuid(KINDS[d.kind].write) : null; }

  connected(id) {
    const d = this.devices.get(id);
    if (!d) return;
    d.connected = true; d.seen = this.t;
    d.q = []; d.busy = undefined;
    // take control, then start. No reset: on most machines it clears the console's workout
    if (d.kind === "ftms_bike") { this._command(d, FTMS.REQUEST_CONTROL); this._command(d, FTMS.START); }
    else if (d.kind === "ftms_treadmill") this._command(d, FTMS.REQUEST_CONTROL);
    d.sentGrade = undefined; d.beltCmd = undefined;
  }
  remove(id) {
    const d = this.devices.get(id);
    if (!d) return;
    if (d.connected && d.kind === "sperax" && d.beltCmd !== undefined) this._write(d, SPERAX.BELT_STOP);
    if (d.connected && d.kind.startsWith("ftms")) this._write(d, FTMS.STOP);
    this.devices.delete(id);
  }

  receive(id, char, bytes) {
    const d = this.devices.get(id);
    if (!d) return;
    const b = Array.from(bytes instanceof DataView ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) : bytes);
    const c = shortUuid(char), m = d.m, now = this.t;
    if (d.kind === "ftms_bike" || d.kind === "ftms_treadmill") {
      if (c === "2ad2" || c === "2acd") {
        d.seen = now;
        const x = d.kind === "ftms_bike" ? FTMS.bike(b) : FTMS.treadmill(b);
        Object.assign(m, x);
        // machines that only send averages: use those
        if (x.speed_kmh === undefined && x.avg_speed_kmh !== undefined && !m.has_speed) m.speed_kmh = x.avg_speed_kmh;
        if (x.cadence === undefined && x.avg_cadence !== undefined && !m.has_cadence) m.cadence = x.avg_cadence;
        if (x.speed_kmh !== undefined) m.has_speed = true;
        if (x.cadence !== undefined) m.has_cadence = true;
        m.moving = d.kind === "ftms_bike" ? (m.cadence || 0) > 5 || (m.power || 0) > 0 : (m.speed_kmh || 0) > 0.3;
        if (d.beltCmd !== undefined && x.speed_kmh !== undefined && Math.abs(x.speed_kmh - d.beltCmd) < 0.15) d.reached = true;
      } else if (c === "2ad9" && b[0] === 0x80) { d.busy = undefined; this._pump(d); }
      else if (c === "2ada" && b[0] === 0xff) this._command(d, FTMS.REQUEST_CONTROL);
    } else if (d.kind === "sperax") {
      for (const f of spxFeed(d.rx, b)) {
        const s = f.ok && spxStatus(f.b);
        if (!s) continue;
        d.seen = now;
        m.speed_kmh = s.speed_kmh; m.steps = s.steps; m.state = s.state;
        if (d.beltCmd !== undefined && Math.abs(s.speed_kmh - d.beltCmd) < 0.15) d.reached = true;
        const h = d.steps;
        h.push({ t: now, n: s.steps });
        while (h.length > 1 && now - h[0].t > 3) h.shift();
        const span = h.length >= 2 ? h[h.length - 1].t - h[0].t : 0;
        m.cadence = span > 0.5 ? ((h[h.length - 1].n - h[0].n) / span) * 60 : 0;
        m.moving = s.state === "running" && s.speed_kmh > 0;
      }
    } else if (d.kind === "rsc") {
      d.seen = now;
      const x = rsc(b);
      m.speed_kmh = x.speed_kmh; m.cadence = x.cadence; m.distance_m = x.distance_m;
      m.moving = x.speed_kmh > 0.3 || x.cadence > 20;
    } else if (d.kind === "csc") { d.seen = now; cscFeed(d.csc, b, now); }
    else if (d.kind === "hr") { d.seen = now; m.hr = heartRate(b); }
  }

  _first(pred) { for (const d of this.devices.values()) if (d.connected && pred(d)) return d; return null; }
  _fresh(d) { return !!d && d.seen !== undefined && this.t - d.seen < (["csc", "hr", "rsc"].includes(d.kind) ? 30 : 6); }
  _gait(v) {
    if (!v.moving) return "stopped";
    const walking = v.kind === "sperax" || v.kind === "ftms_treadmill" || v.kind === "rsc";
    const reached = (st) => {
      if (!st) return false;
      if (walking) return st.pad_kmh !== undefined && (v.speed_kmh || 0) >= st.pad_kmh;
      if (st.watts !== undefined && v.power != null && v.power >= st.watts) return true;
      const cad = v.cadence ?? (v.speed_kmh || 0) * 3;
      return st.rpm !== undefined && cad >= st.rpm;
    };
    return reached(this.gait.sprint) ? "sprint" : reached(this.gait.run) ? "run" : "walk";
  }

  update(dt) {
    this.t += dt;
    const now = this.t;
    for (const d of this.devices.values()) {
      if (!d.connected) continue;
      d.gradeT += dt;
      if (d.kind === "sperax") { d.poll += dt; if (d.poll >= 0.25) { d.poll = 0; this._write(d, SPERAX.STATUS); } }
      else if (d.busy !== undefined) {
        d.busy += dt;
        if (d.busy >= FTMS.ANSWER_WAIT) { d.busy = undefined; this._pump(d); }
      } else if (d.kind === "csc") d.m = cscValues(d.csc, now, this.wheel_mm / 1000);
    }
    const bike = this._first((d) => d.kind === "ftms_bike");
    const tread = this._first((d) => d.kind === "ftms_treadmill" && d.m.incline !== undefined);
    const g = this.allow_hills && this.grade != null ? this.grade : 0;
    if (bike && (bike.sentGrade === undefined || Math.abs(g - bike.sentGrade) >= 0.1) && bike.gradeT >= 0.25) {
      this._command(bike, FTMS.simulation(g)); bike.sentGrade = g; bike.gradeT = 0;
    }
    if (tread && (tread.sentGrade === undefined || Math.abs(g - tread.sentGrade) >= 0.5) && tread.gradeT >= 2) {
      this._command(tread, FTMS.targetIncline(clamp(g, -6, 15))); tread.sentGrade = g; tread.gradeT = 0;
    }
    const pad = this._first((d) => d.kind === "sperax" || d.kind === "ftms_treadmill");
    if (pad && this.allow_belt && this.beltTarget != null) {
      pad.beltT = (pad.beltT || 0) + dt;
      const ready = pad.kind === "ftms_treadmill" || pad.m.state === "running";
      if (!ready) { pad.beltCmd = undefined; pad.beltT = 0; }
      else if (pad.beltT >= 1) {
        const lo = pad.kind === "sperax" ? 1.0 : 0.5;
        const target = clamp(this.beltTarget, lo, this.max_belt_kmh);
        const cur = pad.beltCmd ?? Math.max(lo, pad.m.speed_kmh || 0);
        const step = this.belt_ramp * pad.beltT;
        let nxt = target > cur ? Math.min(target, cur + step) : Math.max(target, cur - step);
        pad.beltT = 0;
        const behind = pad.beltCmd !== undefined && !pad.reached && Math.abs((pad.m.speed_kmh || 0) - pad.beltCmd) > 0.3;
        if (behind) nxt = pad.beltCmd;
        let resend = behind && now - (pad.cmdT || 0) > 3;
        if (resend && (pad.resends || 0) >= 3) { pad.beltCmd = Math.max(lo, pad.m.speed_kmh || 0); pad.reached = true; pad.resends = 0; resend = false; }
        if (pad.beltCmd === undefined || Math.abs(nxt - pad.beltCmd) >= 0.1 || resend) {
          pad.resends = resend ? (pad.resends || 0) + 1 : 0;
          if (pad.beltCmd !== nxt) pad.reached = false;
          if (pad.kind === "sperax") this._write(pad, SPERAX.speed(nxt)); else this._command(pad, FTMS.targetSpeed(nxt));
          pad.beltCmd = nxt; pad.cmdT = now;
          if (Math.abs((pad.m.speed_kmh || 0) - nxt) < 0.15) pad.reached = true;
        }
      }
    }
    const v = this.values();
    if (v.moving) { this.distance_m += ((v.speed_kmh || 0) / 3.6) * dt; this.elapsed_s += dt; }
    if (v.moving !== this.moving) { this.moving = v.moving; this.onEvent?.(v.moving ? "start" : "stop"); }
    if (v.gait !== this.gaitNow) { this.gaitNow = v.gait; this.onEvent?.("gait", v.gait); }
  }

  // speed_kmh, cadence, power, hr, steps, moving, gait, kind, grade, distance_m, elapsed_s, devices, sources (null = unknown)
  values() {
    const mv = this._first((d) => KINDS[d.kind].move && this._fresh(d));
    const v = { speed_kmh: null, cadence: null, power: null, hr: null, steps: null, kind: null, sources: {} };
    const src = v.sources;
    if (mv) {
      v.kind = mv.kind;
      v.speed_kmh = mv.m.speed_kmh ?? null; v.cadence = mv.m.cadence ?? null; v.power = mv.m.power ?? null;
      v.hr = mv.m.hr ?? null; v.steps = mv.m.steps ?? null; v.moving = mv.m.moving;
      src.speed = mv.id; src.cadence = mv.id; src.moving = mv.id;
      if (v.power != null) src.power = mv.id;
      if (v.hr != null) src.hr = mv.id;
    }
    const s = this._first((d) => d.kind === "csc" && this._fresh(d));
    if (s) {
      if (s.m.cadence !== undefined) { v.cadence = s.m.cadence; src.cadence = s.id; }
      if (s.m.speed_kmh !== undefined) { v.speed_kmh = s.m.speed_kmh; src.speed = s.id; }
      if (s.m.moving !== undefined) { v.moving = s.m.moving; src.moving = s.id; }
      v.kind = v.kind || "csc";
    }
    const h = this._first((d) => d.kind === "hr" && this._fresh(d) && (d.m.hr || 0) > 0);
    if (h) { v.hr = h.m.hr; src.hr = h.id; }
    v.moving = !!v.moving;
    v.gait = this._gait(v);
    v.grade = this.allow_hills ? this.grade : null;
    v.distance_m = this.distance_m; v.elapsed_s = this.elapsed_s;
    v.devices = [...this.devices.values()].map((d) => ({ id: d.id, name: d.name, kind: d.kind, label: KINDS[d.kind].label, fresh: this._fresh(d) }));
    return v;
  }
  setGrade(pct) { this.grade = pct == null || Number.isNaN(pct) ? null : clamp(pct, -10, 20); }
  setBeltSpeed(kmh) { this.beltTarget = kmh; }
}
function structuredCloneSafe(o) { return JSON.parse(JSON.stringify(o)); }

export const OmniPlay = { create: (opts) => new Session(opts), detect, walkFactor, SERVICES, KINDS, FTMS, SPERAX, shortUuid, fullUuid, VERSION: 1 };
export default OmniPlay;

// ---------- browsers: Web Bluetooth (Chrome / Edge on desktop and Android) ----------
// Asks the player to pick a device (call it from a click), connects, subscribes and keeps it
// connected. Call it again to add more devices (bike + sensor + strap). Resolves to the kind.
export async function connectWebBluetooth(op, { reconnect = true } = {}) {
  if (!globalThis.navigator?.bluetooth) throw new Error("This browser has no Web Bluetooth (use Chrome or Edge)");
  const device = await navigator.bluetooth.requestDevice({
    filters: [...SERVICES.map((s) => ({ services: [s] })), { namePrefix: "SPERAX" }],
    optionalServices: SERVICES,
  });
  const chars = new Map(); // id -> write characteristic
  const prevSend = op.send;
  op.send = (id, char, bytes) => {
    const c = chars.get(id + " " + char);
    if (c) {
      const p = c.properties.writeWithoutResponse ? c.writeValueWithoutResponse(bytes) : c.writeValueWithResponse(bytes);
      p.catch(() => {});
    } else if (prevSend) prevSend(id, char, bytes);
  };
  async function open() {
    const server = await device.gatt.connect();
    const services = await server.getPrimaryServices();
    const uuids = [];
    const found = [];
    for (const s of services) {
      uuids.push(s.uuid);
      for (const c of await s.getCharacteristics()) { uuids.push(c.uuid); found.push(c); }
    }
    const kind = op.add(device.id, device.name, uuids);
    if (!kind) { server.disconnect(); throw new Error(`${device.name || "This device"} isn't a supported fitness device`); }
    const want = new Set(op.notifyChars(device.id));
    for (const c of found) {
      if (c.uuid === op.writeChar(device.id)) chars.set(device.id + " " + c.uuid, c);
      if (want.has(c.uuid)) {
        c.addEventListener("characteristicvaluechanged", (e) => op.receive(device.id, c.uuid, e.target.value));
        await c.startNotifications();
      }
    }
    op.connected(device.id);
    return kind;
  }
  device.addEventListener("gattserverdisconnected", () => {
    op.remove(device.id);
    if (reconnect) setTimeout(function retry() { open().catch(() => setTimeout(retry, 3000)); }, 1000);
  });
  return open();
}
