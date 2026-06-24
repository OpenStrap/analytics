// §14 Notification engine — deterministic per-user nudges.
import 'util.dart';

class NotifyCoachTop {
  final String title;
  final String body;
  const NotifyCoachTop(this.title, this.body);
}

class NotifyBodyAlert {
  final String kind;
  final String note;
  const NotifyBodyAlert(this.kind, this.note);
}

class NotifyStreaks {
  final int? wear;
  final int? strain_target;
  final int? sleep;
  const NotifyStreaks({this.wear, this.strain_target, this.sleep});
}

class NotifyInputs {
  final String date;
  final double? readiness;
  final String coach_summary;
  final NotifyCoachTop? coach_top;
  final NotifyBodyAlert? body_alert;
  final double? stress_score;
  final bool nocturnal_elevated;
  final double sleep_debt_min;
  final double? acwr;
  final double? strain_today;
  final double? strain_target_low;
  final double? strain_target_high;
  final NotifyStreaks? streaks;
  final List<String>? new_records;
  const NotifyInputs({
    required this.date,
    required this.readiness,
    required this.coach_summary,
    required this.coach_top,
    required this.body_alert,
    required this.stress_score,
    required this.nocturnal_elevated,
    required this.sleep_debt_min,
    required this.acwr,
    required this.strain_today,
    required this.strain_target_low,
    required this.strain_target_high,
    this.streaks,
    this.new_records,
  });
}

class AppNotification {
  final String id;
  final String kind;
  final String category;
  final int priority;
  final String title;
  final String body;
  final String window;
  final bool quiet_ok;
  const AppNotification({
    required this.id,
    required this.kind,
    required this.category,
    required this.priority,
    required this.title,
    required this.body,
    required this.window,
    required this.quiet_ok,
  });
  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'category': category,
        'priority': priority,
        'title': title,
        'body': body,
        'window': window,
        'quiet_ok': quiet_ok,
      };
}

const _milestones = {3, 7, 14, 21, 30, 50, 75, 100, 150, 200, 365};
const _maxNotifications = 6;

String _hm(double min) {
  final m = jsRound(min < 0 ? 0 : min).toInt();
  final h = m ~/ 60, r = m % 60;
  if (h == 0) return '${r}m';
  if (r == 0) return '${h}h';
  return '${h}h ${r}m';
}

String _slug(String label) => label
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '_');

List<AppNotification> buildNotifications(NotifyInputs i) {
  final out = <AppNotification>[];
  void push({
    required String kind,
    required String category,
    required int priority,
    required String title,
    required String body,
    required String window,
    required bool quiet_ok,
  }) {
    out.add(AppNotification(
      id: '${i.date}:$kind',
      kind: kind,
      category: category,
      priority: priority,
      title: title,
      body: body,
      window: window,
      quiet_ok: quiet_ok,
    ));
  }

  if (i.body_alert != null) {
    final k = i.body_alert!.kind;
    final title = k == 'overtraining'
        ? 'High training load'
        : k == 'both'
            ? 'Recovery + load signal'
            : 'Recovery signal';
    push(
      kind: 'body_alert',
      category: 'health',
      priority: 3,
      window: 'morning',
      quiet_ok: false,
      title: title,
      body: i.body_alert!.note,
    );
  } else if (i.nocturnal_elevated) {
    push(
      kind: 'overnight_hr',
      category: 'health',
      priority: 3,
      window: 'morning',
      quiet_ok: false,
      title: 'Overnight heart rate was high',
      body:
          'Your sleeping heart rate ran above your baseline — often an early cue of under-recovery or fighting something off. Consider an easier day. A signal, not a diagnosis.',
    );
  }

  for (final label in i.new_records ?? const <String>[]) {
    push(
      kind: 'record_${_slug(label)}',
      category: 'milestone',
      priority: 2,
      window: 'any',
      quiet_ok: false,
      title: 'New personal record 🎉',
      body: '$label — a new best. Nice work.',
    );
  }

  if (i.readiness != null) {
    final r = jsRound(i.readiness!).toInt();
    final tip = i.coach_top != null
        ? '${i.coach_top!.title}: ${i.coach_top!.body}'
        : (i.coach_summary.isNotEmpty
            ? i.coach_summary
            : 'Carry on with your day.');
    push(
      kind: 'morning_readiness',
      category: 'recovery',
      priority: 1,
      window: 'morning',
      quiet_ok: false,
      title: 'Recovery $r/100',
      body: tip,
    );
  }

  if (i.sleep_debt_min >= 120) {
    push(
      kind: 'sleep_debt',
      category: 'sleep',
      priority: 2,
      window: 'evening',
      quiet_ok: false,
      title: "You're carrying ${_hm(i.sleep_debt_min)} of sleep debt",
      body: 'An earlier night would help you pay it down. Aim to wind down soon.',
    );
  }

  if (i.stress_score != null && i.stress_score! >= 70) {
    push(
      kind: 'high_stress',
      category: 'health',
      priority: 1,
      window: 'evening',
      quiet_ok: false,
      title: 'A high-arousal day',
      body:
          'Stress read ${jsRound(i.stress_score!).toInt()}/100 — some downtime or slow breathing tonight could help you settle.',
    );
  }

  if (i.strain_target_low != null && i.strain_today != null) {
    if (i.strain_today! < i.strain_target_low! - 1) {
      push(
        kind: 'strain_room',
        category: 'activity',
        priority: 0,
        window: 'midday',
        quiet_ok: false,
        title: 'Room to move today',
        body:
            "You're at ${i.strain_today!.toStringAsFixed(1)} — your target is around ${i.strain_target_low!.toStringAsFixed(0)}–${(i.strain_target_high ?? i.strain_target_low!).toStringAsFixed(0)}.",
      );
    }
  }

  final s = i.streaks ?? const NotifyStreaks();
  if (s.wear != null && _milestones.contains(s.wear)) {
    push(
      kind: 'streak_wear',
      category: 'milestone',
      priority: 1,
      window: 'any',
      quiet_ok: false,
      title: '${s.wear}-day wear streak 🔥',
      body:
          "You've worn your strap ${s.wear} days running. Consistency is the whole game.",
    );
  }
  if (s.strain_target != null && _milestones.contains(s.strain_target)) {
    push(
      kind: 'streak_strain',
      category: 'milestone',
      priority: 1,
      window: 'any',
      quiet_ok: false,
      title: '${s.strain_target} days on target 🔥',
      body: "You've hit your strain target ${s.strain_target} days in a row.",
    );
  }

  final order = <String, int>{};
  for (var idx = 0; idx < out.length; idx++) {
    order[out[idx].id] = idx;
  }
  out.sort((a, b) {
    final p = b.priority - a.priority;
    if (p != 0) return p;
    return order[a.id]! - order[b.id]!;
  });
  return out.take(_maxNotifications).toList();
}
