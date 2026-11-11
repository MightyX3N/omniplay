// The SDK's JS core against tests/sdk/vectors.json (same file as tests/test_sdk.lua)
import { readFileSync } from "node:fs";
import { OmniPlay, shortUuid, connectWebBluetooth, fullUuid } from "../../sdk/js/omniplay.js";
const scenarios = JSON.parse(readFileSync(new URL("./vectors.json", import.meta.url)));
const hex = (b) => Array.from(b, (x) => x.toString(16).toUpperCase().padStart(2, "0")).join(" ");
const bytes = (h) => Uint8Array.from(h.match(/[0-9a-f]{2}/gi).map((x) => parseInt(x, 16)));
const STATUS = hex(OmniPlay.SPERAX.STATUS);
function same(want, got, path) {
  if (want === null || want === undefined) { if (got != null) throw new Error(`${path}: want nil, got ${got}`); return; }
  if (typeof want === "number") { if (typeof got !== "number" || Math.abs(got - want) >= 0.15) throw new Error(`${path}: want ${want}, got ${got}`); return; }
  if (typeof want === "object") { for (const k of Object.keys(want)) same(want[k], got?.[k], `${path}.${k}`); return; }
  if (want !== got) throw new Error(`${path}: want ${want}, got ${got}`);
}
for (const sc of scenarios) {
  let writes = [], events = [];
  const op = OmniPlay.create({ send: (id, c, b) => writes.push(`${id} ${shortUuid(c)} ${hex(b)}`), onEvent: (n, v) => events.push(v === undefined ? [n] : [n, v]), ...(sc.opts || {}) });
  sc.steps.forEach((st, i) => {
    const where = `${sc.name} step ${i + 1}`;
    if (st.detect) same(st.kind, OmniPlay.detect(st.detect, st.name), `${where} detect ${st.name}`);
    else if (st.add) { const k = op.add(st.add, st.name, st.uuids); if (st.kind) same(st.kind, k, where); }
    else if (st.notify) { if (op.notifyChars(st.notify).join() !== st.chars.join()) throw new Error(where + " notify"); }
    else if (st.connected) op.connected(st.connected);
    else if (st.remove) op.remove(st.remove);
    else if (st.rx) op.receive(st.rx, st.char, bytes(st.hex));
    else if (st.update) op.update(st.update);
    else if (st.grade !== undefined) op.setGrade(st.grade);
    else if (st.belt !== undefined) op.setBeltSpeed(st.belt);
    else if (st.expect) same(st.expect, op.values(), where);
    else if (st.writes || st.writes_without_status) {
      const got = writes.filter((w) => st.writes || !w.includes(STATUS)), want = st.writes || st.writes_without_status;
      if (got.join(" | ") !== want.join(" | ")) throw new Error(`${where} writes:\n  want ${want.join(" | ")}\n  got  ${got.join(" | ")}`);
      writes = [];
    } else if (st.events) {
      const g = events.map((e) => e.join(":")).join(), w = st.events.map((e) => e.join(":")).join();
      if (g !== w) throw new Error(`${where} events: want ${w} got ${g}`);
      events = [];
    }
  });
  console.log("ok  " + sc.name);
}
console.log("sdk js tests passed");

// Web Bluetooth adapter against a fake browser Bluetooth stack with an FTMS bike
{
  const written = [], listeners = {};
  const mk = (u, props) => ({ uuid: fullUuid(u), properties: props,
    addEventListener: (ev, fn) => { listeners[u] = fn; }, startNotifications: async () => { mk.started = (mk.started || 0) + 1; },
    writeValueWithResponse: async (b) => { written.push(hex(b)); } });
  const chars = [mk("2ad2", { notify: true }), mk("2ad9", { write: true, indicate: true }), mk("2ada", { notify: true })];
  let onDisc;
  const device = { id: "dev1", name: "HT2405118", addEventListener: (e, fn) => { onDisc = fn; },
    gatt: { connect: async () => ({ disconnect() {}, getPrimaryServices: async () => [{ uuid: fullUuid("1826"), getCharacteristics: async () => chars }] }) } };
  let asked;
  Object.defineProperty(globalThis, "navigator", { value: { bluetooth: { requestDevice: async (o) => { asked = o; return device; } } }, configurable: true });
  const op = OmniPlay.create({});
  const kind = await connectWebBluetooth(op, { reconnect: false });
  if (kind !== "ftms_bike") throw new Error("web bluetooth: kind " + kind);
  if (!asked.filters.some((f) => f.services && f.services[0] === fullUuid("1826"))) throw new Error("web bluetooth: filters");
  if (written.join(",") !== "00") throw new Error("web bluetooth: start commands " + written.join(","));
  const answer = (h) => listeners["2ad9"]({ target: { value: new DataView(bytes(h).buffer) } });
  answer("80 00 01");
  if (written.join(",") !== "00,07") throw new Error("web bluetooth: start after answer " + written.join(","));
  answer("80 07 01");
  listeners["2ad2"]({ target: { value: new DataView(bytes("FE 1F 00 0A 00 00 AA 00 00 00 00 00 00 0C 00 8C 00 00 00 00 00 00 00 00 82 00 3D 00 00 00").buffer) } });
  op.setGrade(5); op.update(0.3);
  const v = op.values();
  if (v.speed_kmh !== 25.6 || v.power !== 140) throw new Error("web bluetooth: values " + JSON.stringify(v));
  if (written[written.length - 1] !== "11 00 00 F4 01 28 33") throw new Error("web bluetooth: hill " + written.join(","));
  onDisc();
  if (op.values().kind !== null) throw new Error("web bluetooth: removed on disconnect");
  console.log("ok  web bluetooth adapter (fake browser)");
}
