import 'dart:async';

import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:test/test.dart';

import 'process/fixtures/query_relaunch.dart' as cases;

// Stream events sent from one query's user code to another. Stream events
// are asynchronous and no cross-stream order is promised, so these assert eventual results: final values,
// no superseded round past its wait, resources released, no round owed by
// finite work. The cases are shared with the process test (debug and AOT).

/// A chain of [n] stream queries; each one's stream answers its upstream's
/// value plus one as soon as it is listened to. Changing the root's input
/// asks every query a new question in turn, each a microtask after its
/// upstream answered.
Future<(int, List<int?>)> relaunchChain(int n) async {
  final input = signal(0);
  final queries = <AsyncComputed<int>>[];
  final seen = List<int?>.filled(n, null);
  final stops = <void Function()>[];
  var launches = 0;
  for (var i = 0; i < n; i++) {
    final prev = i == 0 ? null : queries.last;
    final q = computedStream<int>((_) {
      final base = prev == null ? input.value : prev.value.valueOrNull ?? -1;
      launches++;
      late final StreamController<int> c;
      c = StreamController<int>.broadcast(
        sync: true,
        onListen: () => c.add(base + 1),
      );
      return c.stream;
    });
    queries.add(q);
    final index = i;
    stops.add(effect(() => q.value, (s, _, _) => seen[index] = s.valueOrNull));
  }
  for (var t = 0; t < 4 * n && seen.last != n; t++) {
    await Future<void>.delayed(Duration.zero);
  }
  launches = 0;
  input.value = 100;
  for (var t = 0; t < 4 * n && seen.last != 100 + n; t++) {
    await Future<void>.delayed(Duration.zero);
  }
  final result = (launches, [...seen]);
  for (final stop in stops.reversed) {
    stop();
  }
  return result;
}

void main() {
  tearDown(() => Rill.onError = null);

  test(
    'an_upstream_resubscription_that_sends_the_latest_answer_ends_on_it',
    () async {
      // D was about to install 2; B's resubscription sends D 3. The latest
      // event is the answer D ends on; it is never lost.
      final events = await cases.siblings('latest');
      expect(events.sublist(events.indexOf('B sends D=3')), contains('D 3'));
      expect(events.last, 'final AsyncData<int>(3)');
    },
  );

  for (final variant in ['install', 'launch']) {
    test('a_sibling_event_asks_the_new_question_after_the_$variant', () async {
      // B's resubscription sends D's other input A a new value: whatever D
      // did for the old question, it ends stale and asks the new one.
      final events = await cases.siblings(variant);
      final after = events.sublist(events.indexOf('B sends A=2'));
      expect(after, contains('D.start 2'));
      expect(
        after.sublist(after.indexOf('D.start 2')),
        isNot(contains('D.start 1')),
      );
      expect(events.last, endsWith('refreshing, stale)'));
    });
  }

  test(
    'a_sibling_event_never_resumes_the_old_round_with_the_new_answer',
    () async {
      final log = await cases.siblingWait();
      expect(log, isNot(contains('resume 1:2')));
      expect(log, containsAllInOrder(['B sends A=2', 'resume 2:2']));
      expect(log.last, 'final AsyncData<int>(2)');
    },
  );

  test('events_sent_by_comparators_down_a_chain_all_land', () async {
    // Each comparator sends its upstream 3, a microtask later: no flush
    // nests another or owes a round, at any depth.
    expect(await cases.cascade(2200), 'ok 2200/2200 runs=0');
  });

  test('a_chain_relaunching_every_query_costs_no_round', () async {
    // Finite DAG work, no feedback: no flush owes a round, and every query
    // ends on its new answer. Each query reads its upstream's state, so it
    // asks again when the upstream goes refreshing and again when it
    // answers (no cross-stream order).
    final (launches, seen) = await relaunchChain(150);
    expect(launches, greaterThanOrEqualTo(150));
    expect(seen, [for (var i = 1; i <= 150; i++) 100 + i]);
  });

  test('a_feedback_loop_through_a_query_still_runs_out_of_rounds', () {
    // Each subscription writes the query's own input: every relaunch is a
    // second launch in its wave, one round each, and no effect re-runs on
    // its own write — the scheduler's waves are all that counts it.
    final input = signal(0);
    var launches = 0;
    final q = computedStream<int>((_) {
      final n = input.value;
      launches++;
      late final StreamController<int> c;
      c = StreamController<int>.broadcast(
        sync: true,
        onListen: () {
          if (n < 1000) input.value = n + 1;
        },
      );
      return c.stream;
    });
    // The effect that throws on creation stops itself.
    expect(
      () => effect(() => q.value, (_, _, _) {}),
      throwsA(predicate((e) => '$e'.contains('RILL_INFINITE_LOOP'))),
    );
    expect(launches, inInclusiveRange(100, 105));
  });

  test('independent_after_flush_callbacks_that_wake_effects_are_one_round', () {
    // Queries no longer go through the after-flush queue; the carried pass
    // still serves every other after-flush callback.
    final count = 150;
    final cells = [for (var i = 0; i < count; i++) signal(0)];
    final seen = List.filled(count, 0);
    final stops = [
      for (var i = 0; i < count; i++)
        effect(() => cells[i].value, (v, _, _) => seen[i] = v),
    ];
    final trigger = signal(0);
    final stop = effect(() => trigger.value, (v, _, _) {
      if (v == 0) return;
      for (var i = 0; i < count; i++) {
        afterFlush(cells[i], () => cells[i].value = v);
      }
    });
    trigger.value = 1;
    expect(seen.where((v) => v == 1), hasLength(count));
    stop();
    for (final s in stops) {
      s();
    }
  });

  for (final how in ['peek', 'invalidate']) {
    test('a_leased_round_a_cold_$how made stale ends its producer', () async {
      final result = await cases.coldLease(how);
      expect(result['flight'], 0);
      expect(result['streams'], 0);
      expect(result['events'], ['opened 1', 'closed 1', 'cancelled 1']);
    });
  }

  test(
    'a_late_wait_on_a_replaced_leased_round_throws_and_opens_nothing',
    () async {
      expect(await cases.leaseAfterEnd(), {
        'threw': 'RILL_READ_AFTER_AWAIT',
        'opened': 0,
        'flight': 0,
        'streams': 0,
      });
    },
  );

  test(
    'a_cold_read_that_finds_a_new_question_cancels_the_retained_round',
    () async {
      // R4c: the round in flight is kept for retain only while no read has
      // found the question changed; a cold read is a pull and cancels it.
      expect(await cases.retainRead(read: true), {
        'before': [0, 0],
        'after': [0, 0],
        'state': 'AsyncLoading<int>()',
        'events': ['start 1', 'cancel 1'],
      });
      expect(await cases.retainRead(read: false), {
        'before': [1, 1],
        'after': [0, 0],
        'state': 'AsyncData<int>(11, refreshing, stale)',
        'events': ['start 1'],
      });
    },
  );
}
