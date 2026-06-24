/// RESPIRATION & SpO₂ family — 1 Hz-native, pure-Dart, no ML.
///
/// Per docs/ALGORITHM_CATALOG_1HZ.md (LAYER 1 → Respiration & SpO₂):
///   * [rsaRespRate]      — RSA respiratory rate (Lomb-Scargle HF-peak on RR).
///                          PRIMARY 24/7 respiration source. `HIGH`.
///   * [riivRespRate]     — RIIV band-pass on 1 Hz green ADC. `RELATIVE/MED`.
///   * [fuseRespRate]     — Karlen SD-gate fusion of RSA + RIIV.
///   * [cvhrApneaScreen]  — CVHR/ACAT (Hayano) apnea SCREEN from RR. NOT a
///                          diagnosis, NOT an AHI.
///   * [relativeOdi]      — relative-R index + relative ODI from red/IR ADC.
///                          NEVER an absolute SpO₂ %. A SCREEN only.
///   * [breathingRateVariability] — BRV trend (within-user).
///
/// HONESTY CEILINGS encoded throughout:
///   * 1 Hz Nyquist caps respiratory rate at 0.5 Hz = 30 br/min (aliased peaks
///     are refused, not reported).
///   * Relative SpO₂ only — no absolute % is ever emitted.
///   * CVHR & relative ODI are SCREENS, never diagnoses; single-night CVHR has
///     substantial night-to-night variability.
///   * Absent / insufficient input => null + confidence 0, never a heuristic.
library onehz_respiration;

export 'resp_rate.dart';
export 'cvhr_apnea.dart';
export 'relative_odi.dart';
export 'brv_trend.dart';
