// Tiny assertion harness for tsx-runnable tests. Tracks pass/fail counts.
let passed = 0;
let failed = 0;

export function assert(cond: boolean, msg: string): void {
  if (cond) {
    passed++;
    console.log(`  ✅ ${msg}`);
  } else {
    failed++;
    console.error(`  ❌ ${msg}`);
  }
}

export function approx(actual: number, expected: number, eps: number, msg: string): void {
  assert(Math.abs(actual - expected) <= eps, `${msg} (got ${actual}, want ${expected}±${eps})`);
}

export function summary(label: string): void {
  console.log(`\n[${label}] ${passed} passed, ${failed} failed`);
  if (failed > 0) process.exitCode = 1;
}

export function counts(): { passed: number; failed: number } {
  return { passed, failed };
}

/** Build a Minute quickly. */
export function min(
  ts: number,
  hr: number,
  activity = 0,
  opts: Partial<{ steps: number; wrist_on: boolean; hr_max: number; act_class: import('../types').ActivityClass }> = {}
) {
  return {
    ts,
    hr_avg: hr,
    hr_min: hr,
    hr_max: opts.hr_max ?? hr,
    hr_n: hr > 0 ? 60 : 0,
    activity,
    steps: opts.steps ?? 0,
    wrist_on: opts.wrist_on ?? hr > 0,
    ...(opts.act_class ? { act_class: opts.act_class } : {}),
  };
}
