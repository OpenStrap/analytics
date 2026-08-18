// SLEEP — the 3-class stage label shared across the sleep family.
//
// This file used to also host `sleepAccounting`, a second implementation of
// onset/offset/TST/WASO/efficiency/cycles. It was exported from the barrel,
// called by nothing outside one test, and defined efficiency against the sleep
// PERIOD (offset − onset + 1) while the figure that actually ships defines it
// against the observed in-bed window (`segment.dart`) — two different numbers
// under one name, waiting for a future caller to pick the wrong one. Deleted
// rather than reconciled: segmentation is the SINGLE source (ARCHITECTURE_V2
// invariant 2/4), and a second accounting path is exactly what that invariant
// exists to forbid.

/// 3-class label used across the sleep family. There is no 'unobserved' member:
/// unobserved time is carried per-second by `SleepSegmentation.stages4` and in
/// aggregate by `SleepSegmentation.unobservedSec`.
enum SleepStage { wake, nrem, rem }
