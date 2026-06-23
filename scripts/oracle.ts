// Parity oracle: decode the 550 REAL R24 frames in whoop_hist.jsonl, run the
// real TS analytics, and emit (a) the decoded inputs and (b) the TS outputs.
// The Rust crate's parity test reads the same inputs and must reproduce (b).
import { readFileSync, writeFileSync } from 'fs';
import { timeDomainHrv } from '../src/hrv';
import { calcStrain } from '../src/strain';
import { calcRestingHR } from '../src/resting';
import type { Minute, Baseline } from '../src/types';

const HIST = process.env.HOME + '/Documents/whoop-master/whoop_hist.jsonl';
const lines = readFileSync(HIST, 'utf8').trim().split('\n');

const rr: number[] = [];
// per-minute aggregation: floor(ts/60) -> {sum,n,max}
const buckets = new Map<number, { sum: number; n: number; max: number }>();

for (const line of lines) {
  const { t, hex } = JSON.parse(line) as { t: number; hex: string };
  if (t !== 24) continue;
  const b = Uint8Array.from(Buffer.from(hex, 'hex'));
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const ts = dv.getUint32(7, true);
  const hr = b[17];
  const rrCount = b[18];
  for (let i = 0; i < rrCount; i++) {
    const off = 19 + 2 * i;
    if (off + 2 <= b.length) rr.push(dv.getInt16(off, true));
  }
  if (hr > 0) {
    const min = Math.floor(ts / 60);
    const cur = buckets.get(min) ?? { sum: 0, n: 0, max: 0 };
    cur.sum += hr; cur.n += 1; cur.max = Math.max(cur.max, hr);
    buckets.set(min, cur);
  }
}

const minutes: Minute[] = [...buckets.entries()]
  .sort((a, b) => a[0] - b[0])
  .map(([min, v]) => ({
    ts: min * 60,
    hr_avg: v.sum / v.n,
    hr_min: 0,
    hr_max: v.max,
    hr_n: v.n,
    activity: 0,
    steps: 0,
    wrist_on: true,
  }));

const baseline: Baseline = { resting_hr: 50, max_hr: 190, sleep_need_min: 480 };
const sleep_window = { onset_ts: minutes[0]?.ts ?? 0, wake_ts: minutes[minutes.length - 1]?.ts ?? 0 };

const input = {
  rr: { rr },
  strain: { minutes, baseline },
  resting: { minutes, sleep_window },
};
const tsOut = {
  hrv: timeDomainHrv(rr),
  strain: calcStrain(minutes, baseline),
  resting: calcRestingHR(minutes, sleep_window),
};

writeFileSync('core/parity_input.json', JSON.stringify(input));
writeFileSync('core/parity_ts.json', JSON.stringify(tsOut, null, 2));
console.log(`decoded ${lines.length} frames → ${rr.length} RR, ${minutes.length} minutes`);
console.log('TS outputs:\n', JSON.stringify(tsOut, null, 2));
