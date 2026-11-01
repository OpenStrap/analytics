/// Stateful counterparts of the independent batch calculations.
library;

import 'dart:math' as math;
import 'types.dart';
import 'clinical/hrv_time.dart';
import 'clinical/load_trimp.dart';
import 'motion/enmo.dart';
import 'workout/calories.dart';
import 'incremental_core.dart';

export 'motion/enmo.dart' show defaultGravityWindowS;
export 'incremental_core.dart';

part 'incremental_hrv.dart';
part 'incremental_enmo.dart';
part 'incremental_minutes.dart';
part 'incremental_state.dart';

enum CalculationMode {
  periodicAwake,
  sleep,
  heavy,
  forced;

  bool get canReuse => this == periodicAwake;
}
