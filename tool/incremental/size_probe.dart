// JSON size of each carried state at the end of the real night (no timing).
import 'dart:convert';
import 'driver.dart';
import 'hrv_incr.dart';
import 'oracle_util.dart';
import 'resp_incr.dart';
import 'synth.dart';

void main() {
  final night = realNightRr()!;
  final noc = NocturnalRmssdState();
  final shape = NightShapeState();
  final tl = HrvTimelineState(night.ts.first - night.rr.first);
  final wins = RespWindowsState();
  final cuts = timeCuts(night.ts, 900);
  driveRr(night, cuts, (f) {
    noc.fold(f.settled.nn, f.settled.nnTimes);
    shape.fold(f.settled.nn, f.settled.nnTimes);
    tl.fold(f.settled.nn, f.settled.nnTimes);
    wins.fold(f.settled.nn, f.settled.nnTimes);
  });
  int sz(Object o) => jsonEncode(o).length;
  print('nocturnal recs=${noc.recs.length} bytes=${sz([for (final r in noc.recs) (r as dynamic).toJson()])}');
  print('night shape closed bins=${shape.closed.length} bytes=${sz(shape.closed)}');
  print('timeline points=${tl.out.length} bytes=${sz(tl.out)} (+ ring <= 900 beats x 2 doubles ~ 30 KB)');
  print('resp windows closed=${wins.closed.length} bytes=${sz(wins.closed)}');
}
