part of 'incremental.dart';

class MinuteMetrics {
  final Metric<double> trimp;
  final Metric<double> strain;
  final ({double total, double active, double basal, double walking})? energy;
  final MinuteEnergySeries? minutes;
  const MinuteMetrics(
      {required this.trimp, required this.strain, this.energy, this.minutes});
}

class _MinuteBill {
  final double hr;
  final double? cadence;
  final double trimp;
  final MinuteEnergySource? source;
  final double active, walking;
  const _MinuteBill(this.hr, this.cadence, this.trimp, this.source, this.active,
      this.walking);
}

/// Retains nonlinear TRIMP and energy contributions by caller-supplied key.
/// Keys must be unique. Day duration must be a finite whole number of minutes,
/// matching the batch dailyEnergy API's integer duration.
// Banister 1991 / Morton 1990 TRIMP; Keytel 2005 / Mifflin-St Jeor 1990 / Tudor-
// Locke 2019 energy. Retains identical keyed minute contributions; edits replace
// them and dependency changes rebuild. Checked numeric field tolerance is
// max(1e-9 absolute, 1e-8 relative); presence, tier, inputs, notes, minute keys,
// counts, sources and abstention reasons match exactly.
class IncrementalMinuteMetrics {
  final Map<int, _MinuteBill> _bills = {};
  final List<int> _keys = [];
  final List<_MinuteBill> _orderedBills = [];
  List<Object?>? _parameters;
  double _trimpTotal = 0;
  double _hrActiveTotal = 0, _walkingTotal = 0;
  double? _basalPerMinute;
  MinuteEnergyPricer? _energyPricer;
  bool _pricerReady = false;
  int _processedMinutes = 0;
  IncrementalMinuteMetrics();

  factory IncrementalMinuteMetrics.fromJson(Map<String, dynamic> json) {
    _version(json, 'IncrementalMinuteMetrics');
    final state = IncrementalMinuteMetrics();
    state._processedMinutes = _count(json['processedMinutes']);
    state._trimpTotal = _number(json['trimpTotal'], finite: true);
    state._basalPerMinute = json['basalPerMinute'] == null
        ? null
        : _number(json['basalPerMinute'], finite: true);
    if (json['parameters'] != null) {
      final parameters = json['parameters'];
      if (parameters is! List ||
          parameters.length != 4 ||
          parameters[2] is! String ||
          !Sex.values.any((s) => s.name == parameters[2])) {
        throw const FormatException('Invalid minute parameters');
      }
      for (final i in [0, 1]) {
        if (parameters[i] != null) _number(parameters[i]);
      }
      final profile = parameters[3];
      if (profile != null) {
        if (profile is! List || profile.length != 4 || profile[3] is! String)
          throw const FormatException('Invalid minute profile');
        for (var i = 0; i < 3; i++) {
          _number(profile[i]);
        }
      }
      state._parameters = [
        parameters[0],
        parameters[1],
        parameters[2],
        profile == null ? null : List<Object?>.of(profile as List),
      ];
    }
    if (json['bills'] is! List)
      throw const FormatException('Invalid minute bills');
    var summedTrimp = 0.0;
    for (final raw in json['bills'] as List) {
      final data = _map(raw);
      if (data['key'] is! int)
        throw const FormatException('Invalid minute key');
      final key = data['key'] as int;
      if (state._bills.containsKey(key))
        throw const FormatException('Duplicate minute key');
      final hr = _number(data['hr']);
      final cadence = data['cadence'] == null ? null : _number(data['cadence']);
      final trimp = _number(data['trimp'], finite: true);
      final active = _number(data['active'], finite: true);
      final walking = _number(data['walking'], finite: true);
      final sourceName = data['source'];
      MinuteEnergySource? source;
      if (sourceName != null) {
        if (sourceName is! String ||
            !MinuteEnergySource.values.any((s) => s.name == sourceName))
          throw const FormatException('Invalid energy source');
        source = MinuteEnergySource.values.byName(sourceName);
      }
      if (trimp < 0 ||
          active < 0 ||
          walking < 0 ||
          (source != MinuteEnergySource.cadence && walking != 0) ||
          (source != MinuteEnergySource.hr && active != 0) ||
          (state._basalPerMinute == null && source != null))
        throw const FormatException('Invalid minute contribution');
      state._bills[key] =
          _MinuteBill(hr, cadence, trimp, source, active, walking);
      state._keys.add(key);
      state._orderedBills.add(state._bills[key]!);
      summedTrimp += trimp;
      state._hrActiveTotal += active;
      state._walkingTotal += walking;
    }
    if (state._processedMinutes < state._bills.length ||
        (state._parameters == null && state._bills.isNotEmpty) ||
        (summedTrimp - state._trimpTotal).abs() >
            1e-9 * math.max(1, summedTrimp))
      throw const FormatException('Inconsistent minute checkpoint');
    // Older version-one checkpoints have all minute contributions and can
    // reconstruct these totals. New checkpoints retain the unrounded sums.
    for (final field in ['hrActiveTotal', 'walkingTotal']) {
      if (!json.containsKey(field)) continue;
      final saved = _number(json[field], finite: true);
      final rebuilt =
          field == 'hrActiveTotal' ? state._hrActiveTotal : state._walkingTotal;
      if (saved < 0 || (saved - rebuilt).abs() > 1e-9 * math.max(1, rebuilt)) {
        throw const FormatException('Inconsistent energy total');
      }
      if (field == 'hrActiveTotal') {
        state._hrActiveTotal = saved;
      } else {
        state._walkingTotal = saved;
      }
    }
    return state;
  }
  int get processedMinutes => _processedMinutes;

  MinuteMetrics sync(
    List<int> minuteKeys,
    List<double> hr, {
    List<double?>? cadenceSpm,
    double? restingHr,
    double? maxHr,
    Sex sex = Sex.male,
    WorkoutUserProfile? profile,
    int dayMinutes = 1440,
    double? quietHrr,
    // As in [strainScoreMetric]. Defaults to calibrating: leaving it out can
    // only understate confidence, never claim a settled level.
    bool quietSettled = false,
    bool force = false,
    bool includeMinuteSeries = true,
  }) {
    if (minuteKeys.length != hr.length ||
        (cadenceSpm != null && cadenceSpm.length != hr.length))
      throw ArgumentError('Minute keys, HR and cadence must align');
    // A proven ordered prefix already has unique retained keys. Validate only
    // new keys in that case; arbitrary edits use one set for validation and
    // removal. Keep our own keys so caller mutations cannot poison this proof.
    var keyPrefix = minuteKeys.length >= _keys.length;
    final changed = <int>[];
    if (keyPrefix) {
      for (var i = 0; i < _keys.length; i++) {
        if (minuteKeys[i] != _keys[i]) {
          keyPrefix = false;
          break;
        }
        final old = _orderedBills[i];
        if (!_same(old.hr, hr[i]) || !_same(old.cadence, cadenceSpm?[i])) {
          changed.add(i);
        }
      }
    }
    Set<int>? retained;
    if (keyPrefix) {
      final added = minuteKeys.length - _keys.length > 1 ? <int>{} : null;
      for (var i = _keys.length; i < minuteKeys.length; i++) {
        if (_bills.containsKey(minuteKeys[i]) ||
            (added != null && !added.add(minuteKeys[i]))) {
          throw ArgumentError('Minute keys must be unique');
        }
        changed.add(i);
      }
    } else {
      retained = minuteKeys.toSet();
      if (retained.length != minuteKeys.length) {
        throw ArgumentError('Minute keys must be unique');
      }
    }
    final parameters = <Object?>[
      restingHr == null ? null : _encode(restingHr),
      maxHr == null ? null : _encode(maxHr),
      sex.name,
      profile == null
          ? null
          : [
              _encode(profile.weightKg),
              _encode(profile.heightCm),
              _encode(profile.age),
              profile.sex
            ],
    ];
    final reprice = force || !_equalState(_parameters, parameters);
    final trimpValid = restingHr != null &&
        maxHr != null &&
        restingHr.isFinite &&
        maxHr.isFinite &&
        maxHr > restingHr;
    if (reprice || !_pricerReady) {
      _energyPricer = profile == null || restingHr == null || maxHr == null
          ? null
          : Calories.minuteEnergyPricer(
              profile: profile, hrmax: maxHr, restingHr: restingHr);
      _basalPerMinute = _energyPricer?.basalKcalPerMin;
      _pricerReady = true;
    }
    if (reprice) {
      _bills.clear();
      _trimpTotal = 0;
      _hrActiveTotal = _walkingTotal = 0;
    }
    if (!keyPrefix && !reprice) {
      for (final key in _bills.keys.toList()) {
        if (!retained!.contains(key)) {
          final old = _bills.remove(key)!;
          _trimpTotal -= old.trimp;
          _hrActiveTotal -= old.active;
          _walkingTotal -= old.walking;
        }
      }
    }
    final workIndices =
        reprice || !keyPrefix ? Iterable<int>.generate(hr.length) : changed;
    for (final i in workIndices) {
      final key = minuteKeys[i], value = hr[i];
      final cadence = cadenceSpm?[i];
      final old = _bills[key];
      if (old != null && _same(old.hr, value) && _same(old.cadence, cadence))
        continue;
      var trimp = 0.0;
      if (trimpValid && value.isFinite && value > 0) {
        final hrr = ((value - restingHr) / (maxHr - restingHr)).clamp(0.0, 1.0);
        trimp = hrr * StrainScorer.banisterY(hrr, female: sex == Sex.female);
      }
      MinuteEnergySource? source;
      var active = 0.0, walking = 0.0;
      if (_energyPricer != null) {
        final bill = _energyPricer!.price(value, cadence);
        source = bill.source;
        active = bill.active;
        walking = bill.walking;
      }
      _trimpTotal += trimp - (old?.trimp ?? 0);
      _hrActiveTotal += active - (old?.active ?? 0);
      _walkingTotal += walking - (old?.walking ?? 0);
      final bill = _MinuteBill(value, cadence, trimp, source, active, walking);
      _bills[key] = bill;
      if (keyPrefix && !reprice) {
        if (i < _orderedBills.length) {
          _orderedBills[i] = bill;
        } else {
          _orderedBills.add(bill);
        }
      }
      _processedMinutes++;
    }
    if (keyPrefix) {
      for (var i = _keys.length; i < minuteKeys.length; i++) {
        _keys.add(minuteKeys[i]);
      }
    } else {
      _keys
        ..clear()
        ..addAll(minuteKeys);
    }
    if (!keyPrefix || reprice) {
      _orderedBills
        ..clear()
        ..addAll([for (final key in minuteKeys) _bills[key]!]);
    }
    _parameters = parameters;
    // Rounding after removals can leave tiny negative residue in a zero day.
    if (_trimpTotal < 0 && _trimpTotal > -1e-9) _trimpTotal = 0;
    if (_hrActiveTotal < 0 && _hrActiveTotal > -1e-9) _hrActiveTotal = 0;
    if (_walkingTotal < 0 && _walkingTotal > -1e-9) _walkingTotal = 0;
    if (_bills.isEmpty) {
      _trimpTotal = _hrActiveTotal = _walkingTotal = 0;
    }
    final trimp = !trimpValid || hr.isEmpty
        ? banisterTrimp(const [], restingHr: restingHr, maxHr: maxHr, sex: sex)
        : Metric<double>(
            value: _trimpTotal,
            confidence: .6,
            tier: Tier.estimate,
            inputs_used: const ['hr_per_min', 'resting_hr', 'max_hr'],
            note: 'Banister exponential TRIMP (wrist HR estimate)');
    final strain = strainScoreMetric(trimp.value,
        wakeMinutes: hr.length.toDouble(),
        quietHrr: quietHrr,
        quietSettled: quietSettled,
        female: sex == Sex.female);
    final minutes = !includeMinuteSeries || _basalPerMinute == null
        ? null
        : Calories.assembleMinuteEnergySeries([
            for (final key in minuteKeys)
              (
                minute: key,
                source: _bills[key]!.source,
                active: _bills[key]!.active,
                walking: _bills[key]!.walking
              ),
          ], basalKcalPerMin: _basalPerMinute!);
    final basal = (_basalPerMinute ?? 0) * dayMinutes;
    final active = minutes?.active ?? (_hrActiveTotal + _walkingTotal);
    final walking = minutes?.walking ?? _walkingTotal;
    return MinuteMetrics(
        trimp: trimp,
        strain: strain,
        minutes: minutes,
        energy: _basalPerMinute == null
            ? null
            : (
                total: basal + active,
                active: active,
                basal: basal,
                walking: walking
              ));
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'type': 'IncrementalMinuteMetrics',
        'processedMinutes': _processedMinutes,
        'parameters': _parameters == null
            ? null
            : [
                _parameters![0],
                _parameters![1],
                _parameters![2],
                _parameters![3] == null
                    ? null
                    : List.of(_parameters![3] as List),
              ],
        'trimpTotal': _trimpTotal,
        'hrActiveTotal': _hrActiveTotal,
        'walkingTotal': _walkingTotal,
        'basalPerMinute': _basalPerMinute,
        'bills': [
          for (final entry in _bills.entries)
            {
              'key': entry.key,
              'hr': _encode(entry.value.hr),
              'cadence': entry.value.cadence == null
                  ? null
                  : _encode(entry.value.cadence!),
              'trimp': entry.value.trimp,
              'source': entry.value.source?.name,
              'active': entry.value.active,
              'walking': entry.value.walking,
            }
        ],
      };
}

bool _equalState(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_equalState(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
