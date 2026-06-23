// Decode parity oracle: run the REAL TS decoders (openstrap-protocol/ts) on the raw
// events we have — whoop_hist (550 R24 inner frames) + whoop_capture (live frames,
// deframed to inner) — and dump {kind, hex, out} cases. The Rust test decode_parity_vs_ts
// runs the same hex through the ported core and asserts byte-identical output.
import { readFileSync, writeFileSync } from 'fs';
import { parse_r24 } from '../../openstrap-protocol/ts/records';
import { decodeRecord, realtimeRr, frameAccel, hexToBytes } from '../../openstrap-protocol/ts/live';

const HOME = process.env.HOME!;
const cases: { kind: string; hex: string; out: any }[] = [];
const add = (kind: string, hex: string, out: any) => cases.push({ kind, hex, out: out ?? null });

// 1. whoop_hist — 550 inner R24 frames.
const hist = readFileSync(`${HOME}/Documents/whoop-master/whoop_hist.jsonl`, 'utf8').trim().split('\n');
for (const line of hist) {
  const { hex } = JSON.parse(line) as { hex: string };
  add('r24', hex, parse_r24(hexToBytes(hex)));
  add('record', hex, decodeRecord(hex));
  add('rr', hex, realtimeRr(hex));
}

// 2. whoop_capture — deframe each 0xAA frame to its inner record, then decode.
const cap = readFileSync(`${HOME}/Documents/whoop-master/whoop_capture.jsonl`, 'utf8').trim().split('\n');
const seenInner = new Set<string>();
for (const line of cap) {
  let d: any;
  try { d = JSON.parse(line); } catch { continue; }
  const b = hexToBytes(d.hex);
  if (b.length < 6 || b[0] !== 0xaa) continue;
  const size = b[1] | (b[2] << 8);
  const inner = b.slice(4, 4 + size - 4);
  if (inner.length < 2) continue;
  const ihex = Array.from(inner).map((x) => x.toString(16).padStart(2, '0')).join('');
  if (seenInner.has(ihex)) continue; // dedup identical frames
  seenInner.add(ihex);
  add('record', ihex, decodeRecord(ihex));
  add('rr', ihex, realtimeRr(ihex));
  add('accel', ihex, frameAccel(ihex));
}

writeFileSync('core/decode_parity_cases.json', JSON.stringify(cases));
const k = cases.reduce((m: Record<string, number>, c) => ((m[c.kind] = (m[c.kind] || 0) + 1), m), {});
const nonNull = cases.filter((c) => c.out != null).length;
console.log(`wrote ${cases.length} cases (${nonNull} non-null):`, k);
