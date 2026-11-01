// Shared by the module aggregator tests: a mid-stream checkpoint must resume.

import 'dart:convert';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:test/test.dart';

/// Asserts that [agg] is persistable and that a mid-stream checkpoint resumes:
/// fold the first half of [batch], checkpoint it through JSON text, restore,
/// keep folding the second half, and compare with the one-pass result.
void expectCheckpointResumes<S, B extends Batch<B>, R>(
  Aggregator<S, B, R> agg,
  B batch, {
  ResultEquals<R>? equals,
}) {
  expect(agg.persistable, isTrue);
  final half = batch.length ~/ 2;
  final env = jsonDecode(jsonEncode(encodeCheckpoint(
      agg, agg.fold(batch, 0, half),
      kind: 'test', version: 1)));
  final restored = decodeCheckpoint<S>(agg, env, kind: 'test', version: 1);
  expect(restored, isNotNull);
  final got = agg.finish(agg.addSlice(restored as S, batch, half, batch.length));
  final want = agg.run(batch);
  final same = equals ?? (R a, R b) => a == b;
  expect(same(got, want), isTrue, reason: 'resumed $got vs one-pass $want');
}

/// The JSON-text form of [agg]'s state after folding all of [batch], inside a
/// checkpoint envelope (kind 'test', version 1).
Map<String, Object?> checkpointOf<S, B extends Batch<B>, R>(
        Aggregator<S, B, R> agg, B batch) =>
    (jsonDecode(jsonEncode(
            encodeCheckpoint(agg, agg.fold(batch), kind: 'test', version: 1)))
        as Map)
        .cast<String, Object?>();

/// Asserts that a checkpoint whose children disagree is refused with null.
///
/// The undamaged checkpoint of [batch] must restore; then [damage] edits a
/// deep copy of its state JSON (in place, or returning a replacement) and the
/// result must restore as null, because the damage is a relationship between
/// children that each decode on their own.
void expectDamagedCheckpointRefused<S, B extends Batch<B>, R>(
  Aggregator<S, B, R> agg,
  B batch,
  Object? Function(Object? state) damage, {
  String? reason,
}) {
  final good = checkpointOf(agg, batch);
  expect(decodeCheckpoint<S>(agg, good, kind: 'test', version: 1), isNotNull,
      reason: 'the undamaged checkpoint must restore');
  final state = jsonDecode(jsonEncode(good['state']));
  final damaged = damage(state) ?? state;
  expect(jsonEncode(damaged), isNot(jsonEncode(good['state'])),
      reason: 'the damage must change the state');
  final env = {...good, 'state': damaged};
  expect(decodeCheckpoint<S>(agg, env, kind: 'test', version: 1), isNull,
      reason: reason ?? jsonEncode(env));
}
