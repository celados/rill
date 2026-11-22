import 'dart:async';

import 'package:rill/rill.dart';
import 'package:test/test.dart';

// Answers that outlive their owners need GC and run as process tests
// (test/process/query_process_test.dart); a known limit is pinned here.

/// A chain of [n] queries over a base, each waiting on the one before, read
/// cold from its far end.
Future<String> coldChain(int n) async {
  final seed = signal(1);
  var leaf = computedAsync<int>((_) async => seed.value);
  for (var i = 0; i < n; i++) {
    final up = leaf;
    leaf = computedAsync<int>((q) async => await q.wait(up) + 1);
  }
  try {
    return '${await leaf.settled()}';
  } on StateError catch (e) {
    return e.message.split(':').first;
  }
}

void main() {
  test('a_cold_wait_chain_unfolds_one_round_per_level '
      '(known limit)', () async {
    // Each level of a cold chain is found only when the level below it
    // runs, one flush round apiece, and the round bound is 100. Pinned
    // until v0.5.x (a known limit, docs/diagnostics/
    // RILL_INFINITE_LOOP.md).
    expect(await coldChain(99), 'AsyncData<int>(100)');
    expect(await coldChain(100), 'RILL_INFINITE_LOOP');
  });
}
