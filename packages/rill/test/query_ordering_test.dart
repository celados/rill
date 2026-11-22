import 'dart:async';

import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:test/test.dart';

// Ordering
// between queries is a pull along dependency edges, not a yield through the
// queue; an unobserved reconcile never samples its question.

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

/// A chain of [n] stream queries, each asking only its upstream's parity,
/// all changed from 1 to 3 in one batch. Returns the observers that saw 3
/// and the factory runs.
Future<(int, int)> parityChain(int n, {required bool reverse}) async {
  final channels = <StreamController<int>>[],
      queries = <AsyncComputed<int>>[],
      stops = <void Function()>[],
      seen = <int?>[];
  var starts = 0;
  for (var i = 0; i < n; i++) {
    final c = StreamController<int>.broadcast(sync: true);
    final prev = i == 0 ? null : queries.last;
    final parity = prev == null
        ? null
        : computed(() => prev.value.valueOrNull?.isOdd);
    final q = computedStream<int>((_) {
      parity?.value;
      starts++;
      return c.stream;
    });
    seen.add(null);
    final index = i;
    stops.add(effect(() => q.value, (s, _, _) => seen[index] = s.valueOrNull));
    // Stream events are asynchronous: each level answers 1 before
    // the next is built, so the chain starts settled.
    c.add(1);
    await Future<void>.delayed(Duration.zero);
    channels.add(c);
    queries.add(q);
  }
  starts = 0;
  batch(() {
    for (final c in reverse ? channels.reversed : channels) {
      c.add(3);
    }
  });
  await settle();
  for (final stop in stops.reversed) {
    stop();
  }
  for (final c in channels) {
    await c.close();
  }
  return (seen.where((x) => x == 3).length, starts);
}

void main() {
  tearDown(() => Rill.onError = null);

  test(
    'unmounting_the_last_reader_of_a_query_sampling_a_clock_cools_it',
    () async {
      // Every cold read of the clock samples and advances it. Unobserved, the
      // reconcile cancels without asking whether the question changed.
      var samples = 0;
      final pending = Completer<int>();
      final clock = bindingSignal(0, sample: () => ++samples);
      final query = computedAsync<int>((q) {
        clock.value;
        return pending.future;
      });
      final stop = effect(() => query.value, (_, _, _) {});
      expect(activeQueryCount, 1);
      final mounted = samples;
      stop();
      await settle();
      expect(samples, mounted);
      expect(activeQueryCount, 0);
      expect(query.peek(), const AsyncLoading<int>());
    },
  );

  test('an_unobserved_landing_is_installed_without_sampling', () async {
    // Retention keeps the attempt; it lands cold and is installed for the
    // question last judged. The next read samples and sees it current.
    var samples = 0;
    final pending = Completer<int>();
    final clock = bindingSignal(0, sample: () => ++samples);
    final query = computedAsync<int>((q) {
      clock.value;
      return pending.future;
    }, retain: const Duration(minutes: 1));
    final stop = effect(() => query.value, (_, _, _) {});
    stop();
    await settle();
    final cooled = samples;
    pending.complete(5);
    await settle();
    expect(samples, cooled);
    expect(activeQueryCount, 0);
    // The cold read samples the clock: the question moved, the answer is
    // the previous question's.
    expect(query.value, const AsyncData(5, refreshing: true, stale: true));
  });

  test('an_upstream_event_sent_from_onCancel_converges_on_its_value', () async {
    final source = StreamController<int>.broadcast(sync: true);
    final up = computedStream<int>((_) => source.stream);
    final keep = effect(() => up.value, (_, _, _) {});
    source.add(1);
    await settle();
    var advance = false;
    final events = <String>[], controllers = <StreamController<int>>[];
    final down = computedStream<int>((q) {
      final id = up.value.requireValue;
      events.add('factory $id');
      final c = StreamController<int>.broadcast(
        sync: true,
        onListen: () => events.add('listen $id'),
        onCancel: () {
          events.add('cancel $id');
          if (advance) {
            advance = false;
            events.add('source 2');
            source.add(2);
          }
        },
      );
      controllers.add(c);
      return c.stream;
    });
    final off = effect(() => down.value, (_, _, _) {});
    advance = true;
    down.invalidate();
    await settle();
    // The value onCancel sends is an asynchronous event (no
    // cross-stream order): the retry may start on 1, and 2 replaces it.
    // Eventually the query listens to 2 only.
    expect(events.take(4), ['factory 1', 'listen 1', 'cancel 1', 'source 2']);
    expect(events.sublist(events.length - 2), ['factory 2', 'listen 2']);
    expect(
      events.where((e) => e.startsWith('listen')).length -
          events.where((e) => e.startsWith('cancel')).length,
      1,
    );
    off();
    keep();
    for (final c in controllers) {
      await c.close();
    }
    await source.close();
  });

  for (final from in ['attach', 'loader']) {
    test(
      'a_replaced_loader_never_passes_its_cached_wait_after_replacement from $from',
      () async {
        // The tracked wait holds the cached 1; the attach hook (or the loader
        // itself) sends the upstream 2 before the wait is delivered.
        final feed = StreamController<int>.broadcast(sync: true);
        final up = computedStream<int>((_) => feed.stream);
        final stopUp = effect(() => up.value, (_, _, _) {});
        feed.add(1);
        var runs = 0;
        final events = <String>[];
        final attach = signal(
          0,
          watched: () {
            events.add('attach');
            feed.add(2);
          },
        );
        final down = computedAsync<int>((q) async {
          final id = ++runs;
          events.add('start $id');
          final value = q.wait(up);
          if (from == 'attach') {
            attach.value;
          } else if (id == 1) {
            feed.add(2);
          }
          final got = await value;
          events.add('resume $id:$got');
          return got;
        });
        final stop = effect(() => down.value, (_, _, _) {});
        await settle();
        // The upstream's 2 is an asynchronous event: round 1 may
        // be delivered 1 while 1 is the answer, never 2, and its answer
        // never replaces round 2's.
        expect(events, contains('resume 2:2'));
        expect(events, isNot(contains('resume 1:2')));
        expect(down.peek(), const AsyncData(2));
        stop();
        stopUp();
        await feed.close();
      },
    );
  }

  test('an_equal_upstream_request_still_delivers_the_cached_wait', () async {
    // The pulled request lands an equal answer: the question stands, the
    // first round resumes once.
    final feed = StreamController<int>.broadcast(sync: true);
    final up = computedStream<int>((_) => feed.stream);
    final stopUp = effect(() => up.value, (_, _, _) {});
    feed.add(1);
    final events = <String>[];
    final attach = signal(0, watched: () => feed.add(1));
    var runs = 0;
    final down = computedAsync<int>((q) async {
      final id = ++runs;
      final value = q.wait(up);
      attach.value;
      final got = await value;
      events.add('resume $id:$got');
      return got;
    });
    final stop = effect(() => down.value, (_, _, _) {});
    await settle();
    expect(events, ['resume 1:1']);
    stop();
    stopUp();
    await feed.close();
  });

  for (final reverse in [false, true]) {
    for (final n in [51, 120]) {
      test(
        'a_finite_chain_of_${n}_queries_changed_'
        '${reverse ? 'in_reverse' : 'in_order'}_in_one_batch_completes',
        () async {
          final (delivered, starts) = await parityChain(n, reverse: reverse);
          expect(delivered, n);
          expect(starts, 0, reason: 'the parities stay: nothing relaunches');
        },
      );
    }
  }

  test('a_pull_through_a_cycle_of_queries_stops_at_its_member', () async {
    // a's question reads b's state and b's reads a's through ordinary
    // computeds: a runtime cycle. Both have a request at once; each pull
    // reaches the other, never itself again.
    Rill.onError = (_, _) {};
    final ca = StreamController<int>.broadcast(sync: true),
        cb = StreamController<int>.broadcast(sync: true),
        linked = signal(false);
    late final AsyncComputed<int> a, b;
    final viaB = computed(() => linked.value ? b.value.valueOrNull : null);
    final viaA = computed(() => a.value.valueOrNull);
    var starts = 0;
    a = computedStream<int>((_) {
      viaB.value;
      starts++;
      return ca.stream;
    });
    b = computedStream<int>((_) {
      viaA.value;
      starts++;
      return cb.stream;
    });
    final stops = [
      effect(() => a.value, (_, _, _) {}),
      effect(() => b.value, (_, _, _) {}),
    ];
    ca.add(1);
    cb.add(1);
    linked.value = true;
    batch(() {
      cb.add(2);
      ca.add(2);
    });
    await settle();
    expect(starts, lessThan(20));
    for (final stop in stops) {
      stop();
    }
    await settle();
    expect(activeQueryStreamCount, 0);
    await ca.close();
    await cb.close();
  });

  test('a_cold_read_below_a_hot_cycle_error_inherits_it', () {
    // The L1 boundary, as specified: c keeps RILL_CYCLE while another page
    // observes it (no L2), so b, cold or remounted, reads it through c until
    // c cools or its own input changes. Unmounting and at once remounting
    // another page keeps c hot.
    final trigger = signal(false), breaker = signal(false);
    late Computed<int> a, b, c;
    a = computed(() => breaker.value ? 10 : b.value);
    b = computed(() => c.value + 1);
    c = computed(() => trigger.value ? a.value : 1);
    Rill.onError = (_, _) {};
    final nodes = [a, b, c];
    final stops = [for (final n in nodes) effect(() => read(n), (_, _, _) {})];
    trigger.value = true;
    breaker.value = true;
    expect(nodes.map(read), ['10', 'cycle', 'cycle']);
    stops[1]();
    expect(subscriberCount(b), 0);
    expect(read(b), 'cycle');
    String? remounted;
    effect(() => read(b), (v, _, _) => remounted = v)();
    expect(remounted, 'cycle');
    stops[0]();
    stops[0] = effect(() => read(a), (_, _, _) {});
    expect(read(b), 'cycle');
    // c cools: everything recovers on the next cold read.
    stops[0]();
    stops[2]();
    expect(nodes.map(read), ['10', '11', '10']);
  });
}
