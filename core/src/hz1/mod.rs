// hz1 — the 1 Hz-native analytics family (device-side; higher-resolution / continuous
// versions of the same metric categories the cloud minute-family serves). Every metric
// here is a pure function over raw RR / per-minute RR / sleep-wake epochs, runs AFTER
// clean_rr (PRV not ECG-HRV), and is per-user-baseline-relative with no clinical cutoffs.
pub mod asymmetry;
pub mod circ_hrv;
pub mod cvhr;
pub mod longhrv;
pub mod prsa;
pub mod sri;
