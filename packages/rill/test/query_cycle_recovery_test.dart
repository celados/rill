import 'dart:async';

import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:test/test.dart';

/// A plain observer standing in for a Reactive element: it reads in the
/// after-flush pass, not in the effect queue.
final class Reader extends Subscriber {
  @override
  void notify() => afterFlush(this, () {
    if (!disposed) changed();
  });

  R read<R>(R Function() fn) => track(fn);
}

// The reconcile as a one-step trampoline, cycles as programming errors that
// never wake themselves and never poison a node for good.

Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String read(Readable<int> node) {
  try {
    return '${node.value}';
  } on Object catch (e) {
    return '$e'.contains('RILL_CYCLE') ? 'cycle' : '$e';
  }
}

void main() {
  tearDown(() => Rill.onError = null);

  group('cycles never wake themselves or poison a node', () {
    test(
      'a_question_sample_that_drops_the_last_reader_starts_nothing',
      () async {
        // The reconcile samples its question first. Here that runs the
        // upstream comparator on the wait edge, which removes the only
        // reader: nothing may start on the observation seen before.
        final upEvents = StreamController<int>.broadcast(sync: true),
            downEvents = StreamController<int>.broadcast(sync: true);
        var hits = 0, loads = 0;
        late final Reader reader;
        final up = computedStream<int>(
          (_) => upEvents.stream,
          equals: (a, b) {
            // The first (1, 2) is up's own landing, the second the edge.
            if (a == 1 && b == 2 && ++hits == 2) reader.dispose();
            return a == b;
          },
        );
        final down = computedStream<int>((q) {
          loads++;
          q.wait(up).ignore();
          return downEvents.stream;
        });
        reader = Reader()..read(() => down.value);
        upEvents.add(1);
        await settle();
        expect(loads, 1);
        // down's stream ends first: its reconcile is scheduled before the
        // reader's, with no answer to take, so only the sample can stop it.
        batch(() {
          downEvents.close();
          upEvents.add(2);
        });
        await settle();
        expect(hits, 2);
        expect(loads, 1, reason: 'no attempt for a query nobody reads');
        expect(subscriberCount(down), 0);
        expect(activeQueryStreamCount, 0);
        await upEvents.close();
      },
    );

    test('a_cycle_found_through_a_pull_recovers_once_untied', () {
      final trigger = signal(false), breaker = signal(false);
      var runs = 0;
      late Computed<int> a, b, c;
      a = computed(() {
        runs++;
        return breaker.value ? 10 : b.value;
      });
      b = computed(() => c.value + 1);
      c = computed(() => trigger.value ? a.value : 1);
      Rill.onError = (_, _) {};
      final stops = [
        effect(() => read(a), (_, _, _) {}),
        effect(() => read(b), (_, _, _) {}),
        effect(() => read(c), (_, _, _) {}),
      ];
      expect([read(a), read(b), read(c)], ['2', '2', '1']);
      trigger.value = true;
      expect([read(a), read(b), read(c)], everyElement('cycle'));
      final cycled = runs;
      breaker.value = true;
      // a has the breaker as an input; the others re-entered it and hold no
      // edge to it: hot they keep the error (no L2), and nothing reruns.
      expect(read(a), '10');
      expect(runs, cycled + 1);
      for (final stop in stops) {
        stop();
      }
      // Cold, nothing is cached as validated.
      expect([read(a), read(b), read(c)], ['10', '11', '10']);
      checkGraph([trigger, breaker, a, b, c]);
    });

    test('a_cycle_through_a_query_question_recovers_once_untied', () async {
      final trigger = signal(false), breaker = signal(false);
      var loads = 0;
      late Computed<int> a, b;
      late AsyncComputed<int> q;
      b = computed(() => (q.value.valueOrNull ?? 0) + 1);
      a = computed(() => trigger.value ? b.value : 0);
      q = computedAsync((_) async {
        loads++;
        trigger.value;
        return breaker.value ? 10 : a.value;
      });
      Rill.onError = (_, _) {};
      final stops = [
        effect(() => read(a), (_, _, _) {}),
        effect(() => read(b), (_, _, _) {}),
        effect(() => q.value, (_, _, _) {}),
      ];
      await settle();
      trigger.value = true;
      await settle();
      final cycled = loads;
      expect(cycled, lessThan(5));
      breaker.value = true;
      await settle();
      // The breaker is an input of the query: it relaunches once and lands.
      expect(q.peek(), const AsyncData(10));
      expect(loads, cycled + 1);
      expect(read(b), '11', reason: 'b reads the query: pushed');
      for (final stop in stops) {
        stop();
      }
      // Cold, before the query cools: nothing kept the cycle.
      expect([read(a), read(b)], ['11', '11']);
      checkGraph([trigger, breaker, a, b, q]);
    });

    test('a_query_found_upstream_of_a_cycle_does_not_wake_it', () async {
      final gate = signal(false), e2 = signal(false);
      var loads = 0;
      late Computed<int> a, b;
      late AsyncComputed<int> q2;
      b = computed(() => e2.value ? a.value : 0);
      q2 = computedAsync((_) async {
        if (++loads > 30) return 0;
        return b.value;
      });
      a = computed(() => gate.value ? b.value : (q2.value.valueOrNull ?? 0));
      Rill.onError = (_, _) {};
      final stops = [
        effect(() => read(a), (_, _, _) {}),
        effect(() => q2.value, (_, _, _) {}),
      ];
      await settle();
      expect(loads, 1);
      batch(() {
        gate.value = true;
        e2.value = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(loads, 2, reason: 'a failing cycle lands once, then stays');
      for (final stop in stops) {
        stop();
      }
    });

    test('a_cycle_that_catches_its_own_failure_is_bounded', () async {
      final gate = signal(false);
      var loads = 0;
      late Computed<Object> a, b;
      late AsyncComputed<int> q2;
      b = computed<Object>(() => gate.value ? a.value : 0);
      q2 = computedAsync<int>((_) async {
        if (++loads > 25) return 0;
        final v = b.value;
        return v is int ? v : 0;
      });
      a = computed<Object>(() {
        if (gate.value) {
          try {
            b.value;
          } on Object {
            // the cycle error, caught
          }
        }
        return q2.value;
      });
      Rill.onError = (_, _) {};
      final stops = [
        effect(() => a.value, (_, _, _) {}),
        effect(() => b.value, (_, _, _) {}),
        effect(() => q2.value, (_, _, _) {}),
      ];
      await settle();
      final before = loads;
      gate.value = true;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(loads - before, lessThanOrEqualTo(2));
      for (final stop in stops) {
        stop();
      }
    });
  });

  group('cycle untying, landing rounds and cached waits', () {
    for (final reverse in [false, true]) {
      test('a_cycle_untied_from_the_other_end_recovers '
          '(reverse=$reverse)', () {
        final on = signal(false), escape = signal(false);
        var runs = 0;
        late Computed<int> a, b;
        a = computed(() {
          runs++;
          return on.value ? b.value : 0;
        });
        b = computed(() {
          runs++;
          return escape.value ? 7 : a.value;
        });
        Rill.onError = (_, _) {};
        final nodes = reverse ? [b, a] : [a, b];
        final stops = [
          for (final n in nodes) effect(() => read(n), (_, _, _) {}),
        ];
        expect([read(a), read(b)], ['0', '0']);
        on.value = true;
        expect([read(a), read(b)], everyElement('cycle'));
        escape.value = true;
        final settled = runs;
        expect(read(b), '7');
        // Reading again never reruns a hot cycle (L0: no self-wake).
        read(a);
        read(a);
        expect(runs, settled);
        for (final stop in stops) {
          stop();
        }
        // Cold, the cycle is gone: every node recovers.
        expect([read(a), read(b)], ['7', '7']);
        checkGraph([on, escape, a, b]);
      });
    }

    for (final count in [100, 120]) {
      test('independent_landings_of_one_batch_share_a_round '
          '(n=$count)', () async {
        final events = StreamController<int>.broadcast(sync: true);
        final queries = [
          for (var i = 0; i < count; i++)
            computedStream<int>((_) => events.stream),
        ];
        final latest = List<int?>.filled(count, null);
        final stops = [
          for (var i = 0; i < count; i++)
            effect(
              () => queries[i].value,
              (s, _, _) => latest[i] = s.valueOrNull,
            ),
        ];
        // Stream events are asynchronous: the batch returns, and
        // each query delivers in its own microtask, none owing a round.
        batch(() => events.add(1));
        await settle();
        expect(latest.where((v) => v == 1), hasLength(count));
        for (final stop in stops) {
          stop();
        }
        await events.close();
      });
    }

    test(
      'a_feedback_loop_through_after_flush_work_still_runs_out_of_rounds',
      () {
        // Each round an after-flush callback writes and breaks the pass while
        // another callback of the same pass is still carried: carried work is
        // the same round, but the loop itself is not.
        final n = signal(0);
        final stop = effect(() => n.value, (value, _, _) {
          if (value == 0) return;
          afterFlush(#write, () => n.value++);
          afterFlush(#carried, () {});
        });
        expect(
          () => n.value = 1,
          throwsA(predicate((e) => '$e'.contains('RILL_INFINITE_LOOP'))),
        );
        expect(n.peek(), lessThan(300));
        stop();
      },
    );

    test(
      'an_upstream_event_from_the_comparator_makes_the_install_stale',
      () async {
        final ctl = StreamController<int>.broadcast(sync: true),
            old = Completer<int>(),
            next = Completer<int>();
        final up = computedStream<int>((_) => ctl.stream), log = <String>[];
        final down = computedAsync<int>(
          (_) async {
            final target = up.value.valueOrNull;
            if (target == null) return 3;
            return target == 1 ? old.future : next.future;
          },
          equals: (a, b) {
            if (b == 77) ctl.add(2);
            return a == b;
          },
        );
        final stop = effect(() => down.value, (s, _, _) => log.add('$s'));
        await settle();
        ctl.add(1);
        old.complete(77);
        await settle();
        // The comparator's event reaches up a microtask later (no
        // cross-stream order): 77 may install for the old question, and the
        // new one makes it stale; it is never fresh once up moved on.
        final moved = log.lastIndexWhere((s) => s.contains('stale'));
        expect(moved, greaterThanOrEqualTo(0));
        expect(
          log.skip(moved).where((s) => s == 'AsyncData<int>(77)'),
          isEmpty,
        );
        expect(
          down.peek(),
          isA<AsyncData<int>>().having((s) => s.stale, 'stale', true),
        );
        next.complete(8);
        await settle();
        expect(down.peek(), const AsyncData(8));
        stop();
        await ctl.close();
      },
    );

    for (final upFirst in [true, false]) {
      test('an_upstream_event_in_the_same_batch_makes_the_install_stale '
          '(upFirst=$upFirst)', () async {
        final source = StreamController<int>.broadcast(sync: true);
        final packets = [
          for (var i = 0; i < 2; i++)
            StreamController<int>.broadcast(sync: true),
        ];
        final upstream = computedStream<int>((_) => source.stream);
        final query = computedStream<int>((_) {
          final n = upstream.value.valueOrNull ?? 0;
          return packets[n].stream;
        });
        final seen = <String>[];
        final stop = effect(() => query.value, (s, _, _) => seen.add('$s'));
        packets[0].add(3);
        batch(() {
          if (upFirst) source.add(1);
          packets[0].add(77);
          if (!upFirst) source.add(1);
        });
        await settle();
        // Both events are asynchronous; whichever lands first, the old
        // question's answer ends up stale and the new one is asked.
        expect(
          query.peek(),
          isA<AsyncData<int>>().having((s) => s.stale, 'stale', true),
        );
        packets[1].add(8);
        await settle();
        expect(query.peek(), const AsyncData(8));
        stop();
        await source.close();
        for (final p in packets) {
          await p.close();
        }
      });
    }

    test('an_event_during_the_comparator_is_the_answer_taken', () async {
      final ctl = StreamController<int>.broadcast(sync: true);
      final seen = <int>[];
      final q = computedStream<int>(
        (_) => ctl.stream,
        equals: (a, b) {
          if (b == 2) ctl.add(3);
          return a == b;
        },
      );
      final stop = effect(() => q.value, (s, _, _) {
        if (s is AsyncData<int>) seen.add(s.value);
      });
      ctl.add(1);
      batch(() => ctl.add(2));
      await settle();
      expect(q.peek(), const AsyncData(3));
      expect(seen.last, 3);
      stop();
      await ctl.close();
    });

    test('a_cached_tracked_wait_resumes_only_while_observed', () async {
      final lease = Scope(), view = Scope(), trigger = signal(false);
      final log = <String>[];
      final up = computedAsync<int>((_) async => 7, keepAlive: lease);
      await up.settled();
      await settle();
      late AsyncComputed<int> down;
      down = computedAsync<int>((q) async {
        if (!trigger.value) return 1;
        view.dispose();
        log.add('before wait readers=${subscriberCount(down)}');
        final v = await q.wait(up);
        log.add('after wait $v');
        return v;
      }, keepAlive: lease);
      view.effect(() => down.value, (_, _, _) {});
      await settle();
      trigger.value = true;
      await settle();
      expect(log, ['before wait readers=0'], reason: 'R7: unobserved');
      expect(await down.settled(), const AsyncData(7));
      expect(log, ['before wait readers=0', 'after wait 7']);
      lease.dispose();
    });

    test('a_cached_tracked_wait_of_a_replaced_attempt_never_resumes', () async {
      final lease = Scope(), branch = signal(false), log = <String>[];
      var armed = false;
      final bridge = bindingSignal(
        7,
        sample: () => 7,
        watched: () {
          if (armed) {
            log.add('attach');
            branch.value = true;
          }
        },
      );
      final up = computedAsync<int>(
        (_) async => bridge.value,
        keepAlive: lease,
      );
      await up.settled();
      await settle();
      armed = true;
      final down = computedAsync<int>((q) async {
        if (branch.value) {
          log.add('replacement');
          return 9;
        }
        final v = await q.wait(up);
        log.add('old continued $v');
        return v;
      });
      final stop = effect(() => down.value, (_, _, _) {});
      await settle();
      expect(log, isNot(contains('old continued 7')));
      expect(down.peek(), const AsyncData(9));
      stop();
      lease.dispose();
    });
  });
}
