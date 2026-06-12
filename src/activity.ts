// REMOVED in v0. Steps + active/sedentary classification are gone:
//   - `steps` had no source field on this firmware (always 0) → misleading.
//   - active/sedentary used a relative (median-split) threshold → tautological
//     (~50% "active" by construction), not a real classifier.
// Activity-type detection (walk/run/cycle) was intentionally NOT added: too
// uncertain to ship in v0.
//
// The per-minute `activity` motion signal still exists in the Minute rollup and
// is consumed by sleep (Cole-Kripke) and session detection — only the daily
// activity METRIC is removed. Nothing is exported here.
export {};
