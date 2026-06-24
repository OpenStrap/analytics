// HUMAN LAYER — single-night event detection (alcohol flag + rough-night).
// Catalog §B: Alcohol-night flag [PUB Pietilä 2018, dose-graded] and the
// "rough night" neutral fallback [HEUR].
//
// THE CENTRAL HONESTY RULE (catalog §B / governing rules): alcohol, a late
// meal, early illness, the luteal phase and a hot bedroom all produce a NEARLY
// IDENTICAL nocturnal signature — RHR↑, RMSSD↓, HR-dip blunted, skin-temp↑.
// So we:
//   * report the STATE confidently (an autonomically stressful night), and
//   * offer "alcohol" only as a TAG-CONFIRMABLE HYPOTHESIS, never an assertion;
//   * when the signature is ambiguous or weak, fall back to a neutral
//     "rough night" descriptor — or stay silent.
//
// Dose bands follow Pietilä's graded effects (light/moderate/heavy) expressed
// as deviations from the PERSONAL baseline (median+MAD), not absolute bpm/ms —
// we never hard-code another person's effect sizes onto this user's scale.

import '../types.dart';
import '../util.dart';
import '../foundations/baseline.dart';

/// One night's nocturnal summary vs the personal baseline window.
class NightSignature {
  final double rhr; // nocturnal RHR tonight (bpm)
  final double rmssd; // nightly RMSSD tonight (ms)
  final double? hrDipPct; // tonight's HR dip % (lower = blunted); optional
  final double? skinTempZ; // tonight's skin-temp z (relative); optional
  final double? respRate; // tonight's respiration (br/min); optional
  const NightSignature({
    required this.rhr,
    required this.rmssd,
    this.hrDipPct,
    this.skinTempZ,
    this.respRate,
  });
}

class EventState {
  /// 'normal' | 'mildly_off' | 'autonomically_stressed' — the STATE we will say.
  final String state;
  /// Dose-graded HYPOTHESIS band IF the user later tags alcohol: 'none' |
  /// 'light' | 'moderate' | 'heavy'. This is NOT an assertion that they drank.
  final String alcoholHypothesisBand;
  final double rhrDelta; // bpm vs baseline (positive = elevated)
  final double rmssdDelta; // ms vs baseline (negative = suppressed)
  final double? rhrZ;
  final double? rmssdZ;
  final int signsPresent; // how many of {RHR↑, RMSSD↓, dip-blunted, temp↑}
  final bool ambiguous; // signature not specific enough to even hypothesize
  const EventState({
    required this.state,
    required this.alcoholHypothesisBand,
    required this.rhrDelta,
    required this.rmssdDelta,
    required this.rhrZ,
    required this.rmssdZ,
    required this.signsPresent,
    required this.ambiguous,
  });
  Map<String, dynamic> toJson() => {
        'state': state,
        'alcohol_hypothesis_band': alcoholHypothesisBand,
        'rhr_delta_bpm': round6(rhrDelta),
        'rmssd_delta_ms': round6(rmssdDelta),
        if (rhrZ != null) 'rhr_z': round6(rhrZ!),
        if (rmssdZ != null) 'rmssd_z': round6(rmssdZ!),
        'signs_present': signsPresent,
        'ambiguous': ambiguous,
      };
}

/// Alcohol-night flag (state-confident, cause-soft).
///
/// [tonight] tonight's nocturnal signature. [rhrHistory] / [rmssdHistory] the
/// personal baseline windows (oldest→newest, EXCLUDING tonight). Optional
/// [hrDipHistory] / [skinTempZHistory] sharpen specificity.
///
/// Decision logic:
///   * Compute robust deltas + modified-z vs baseline; MDC-gate each sign.
///   * STATE = how many of the four signs fire (RHR↑, RMSSD↓, dip blunted,
///     temp↑), past their MDC.
///   * The alcohol BAND is graded by the magnitude of the RHR↑ / RMSSD↓ pair
///     (Pietilä's dose ordering) — but only offered as a hypothesis.
Metric<EventState> alcoholNightFlag(
  NightSignature tonight, {
  required List<double> rhrHistory,
  required List<double> rmssdHistory,
  List<double> hrDipHistory = const [],
  List<double> skinTempZHistory = const [],
  int minNights = 7,
}) {
  final inputs = <String>['rhr_nightly', 'rmssd_nightly'];
  if (rhrHistory.length < minNights || rmssdHistory.length < minNights) {
    return Metric<EventState>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'need ≥$minNights baseline nights for a personal signature',
    );
  }
  final rhrBase = robustBaseline(rhrHistory, minValid: minNights);
  final rmsBase = robustBaseline(rmssdHistory, minValid: minNights);
  final rhrDelta = tonight.rhr - (rhrBase.center ?? tonight.rhr);
  final rmssdDelta = tonight.rmssd - (rmsBase.center ?? tonight.rmssd);
  final rhrZ = rhrBase.modZ(tonight.rhr);
  final rmssdZ = rmsBase.modZ(tonight.rmssd);

  // MDC gates: a sign only counts if it clears the metric's minimal detectable
  // change. When MDC is unavailable (degenerate scale) the sign cannot fire.
  final rhrMdc = mdc(rhrBase);
  final rmsMdc = mdc(rmsBase);
  final rhrUp = rhrMdc != null && rhrDelta > rhrMdc;
  final rmssdDown = rmsMdc != null && (-rmssdDelta) > rmsMdc;

  var signs = 0;
  if (rhrUp) signs++;
  if (rmssdDown) signs++;

  // HR-dip blunting (lower than usual) — supporting, if history present.
  if (tonight.hrDipPct != null && hrDipHistory.length >= minNights) {
    final dipBase = robustBaseline(hrDipHistory, minValid: minNights);
    final dipMdc = mdc(dipBase);
    if (dipMdc != null &&
        dipBase.center != null &&
        (dipBase.center! - tonight.hrDipPct!) > dipMdc) {
      signs++;
      inputs.add('hr_dip_nightly');
    }
  }

  // Skin-temp elevation (relative z). The temp+resp pair is the catalog's
  // disambiguator — included as a sign and noted in `note`.
  if (tonight.skinTempZ != null && skinTempZHistory.length >= minNights) {
    final tBase = robustBaseline(skinTempZHistory, minValid: minNights);
    final tMdc = mdc(tBase);
    if (tMdc != null &&
        tBase.center != null &&
        (tonight.skinTempZ! - tBase.center!) > tMdc) {
      signs++;
      inputs.add('skin_temp_z_nightly');
    }
  }

  // STATE.
  String state;
  if (signs >= 3) {
    state = 'autonomically_stressed';
  } else if (signs == 2) {
    state = 'autonomically_stressed';
  } else if (signs == 1) {
    state = 'mildly_off';
  } else {
    state = 'normal';
  }

  // The alcohol HYPOTHESIS requires the core autonomic pair (RHR↑ AND RMSSD↓):
  // that pairing is what Pietilä measured. Without both, we don't even
  // hypothesize alcohol (it would be indistinguishable from anything).
  final coreSignature = rhrUp && rmssdDown;
  // Dose band off the suppression magnitude vs baseline scale (within-user).
  // NOTE on calibration: the sign gate requires each axis to clear its MDC
  // (≈2.77 × baseline scale, i.e. |z|≳2.77), so the SMALLEST detectable
  // alcohol-like night already sits near z≈2.77. The bands are therefore
  // anchored above that floor — "light" is the just-detectable event, with
  // moderate/heavy reserved for progressively larger within-user deviations
  // (Pietilä's dose ORDERING preserved; we never print his absolute bpm/ms on
  // this user's scale).
  String band = 'none';
  if (coreSignature && rhrZ != null && rmssdZ != null) {
    final severity = (rhrZ.abs() + rmssdZ.abs()) / 2.0;
    if (severity >= 4.5) {
      band = 'heavy';
    } else if (severity >= 3.4) {
      band = 'moderate';
    } else {
      band = 'light';
    }
  }

  // AMBIGUITY: a confident STATE with NO disambiguating second axis (temp/resp
  // info absent) means alcohol vs illness vs hot-room can't be separated — we
  // surface the state but mark the hypothesis ambiguous.
  final hasDisambiguator = tonight.skinTempZ != null || tonight.respRate != null;
  final ambiguous = state == 'autonomically_stressed' && !hasDisambiguator;

  final note = state == 'normal'
      ? 'no autonomic signature tonight'
      : 'STATE = autonomic stress (confident). "Alcohol" is a tag-confirmable '
          'hypothesis only — late meal / early illness / luteal / hot room '
          'share this signature; disambiguate with temp + respiration, not HR.';

  return Metric<EventState>(
    value: EventState(
      state: state,
      alcoholHypothesisBand: band,
      rhrDelta: rhrDelta,
      rmssdDelta: rmssdDelta,
      rhrZ: rhrZ,
      rmssdZ: rmssdZ,
      signsPresent: signs,
      ambiguous: ambiguous,
    ),
    confidence: clamp(signs / 4.0, 0.2, 0.85),
    tier: Tier.high,
    inputs_used: inputs,
    note: note,
  );
}

class RoughNight {
  final bool rough;
  final int signsPresent;
  final String descriptor; // neutral, never a cause
  const RoughNight(this.rough, this.signsPresent, this.descriptor);
  Map<String, dynamic> toJson() => {
        'rough': rough,
        'signs_present': signsPresent,
        'descriptor': descriptor,
      };
}

/// Neutral "rough night" descriptor — the safe fallback when attribution is
/// ambiguous. It NEVER names a cause; it only describes that the night looked
/// physiologically harder than usual for this person.
///
/// Use when [alcoholNightFlag] reports `ambiguous` (or you simply don't want to
/// hypothesize): pass the same EventState through.
Metric<RoughNight> roughNight(EventState ev) {
  const inputs = ['event_state'];
  final rough = ev.signsPresent >= 2;
  final descriptor = rough
      ? 'a rougher night than usual for you — your body worked harder overnight'
      : (ev.signsPresent == 1
          ? 'a slightly off night'
          : 'a typical night for you');
  return Metric<RoughNight>(
    value: RoughNight(rough, ev.signsPresent, descriptor),
    confidence: clamp(ev.signsPresent / 4.0, 0.2, 0.8),
    tier: Tier.relative,
    inputs_used: inputs,
    note: 'neutral state descriptor — never attributes a cause',
  );
}
