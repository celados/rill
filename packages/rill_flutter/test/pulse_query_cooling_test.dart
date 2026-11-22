import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart' show activeQueryCount;
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

// Cooling a query that reads the real Pulse: a cold read of Pulse.minute samples the clock and writes.

void main() {
  for (final real in [false, true]) {
    test('unmounting_the_last_reader_of_a_query_on_Pulse_minute_cools_it '
        '${real ? 'real_clock' : 'counting_clock'}', () async {
      var reads = 0;
      await withClock(
        real
            ? const Clock()
            : Clock(() => DateTime.fromMicrosecondsSinceEpoch(++reads)),
        () async {
          final pending = Completer<int>();
          final query = computedAsync<int>((_) {
            Pulse.minute.value;
            return pending.future;
          });
          final stop = effect(() => query.value, (_, _, _) {});
          expect(activeQueryCount, 1);
          final mounted = reads;
          stop();
          await Future<void>.delayed(Duration.zero);
          expect(activeQueryCount, 0);
          // Cooling asks nobody what time it is.
          if (!real) expect(reads - mounted, lessThan(5));
        },
      );
    });
  }
}
