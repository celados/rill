import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

import 'budget_test.dart' show page;

// Async state in the binding.

String show(AsyncState<Object?> state) => switch (state) {
  AsyncLoading() => 'loading',
  AsyncData(:final value) => '$value',
  AsyncError(:final error) => 'error $error',
};

class _Query {
  _Query({Duration retain = Duration.zero})
    : source = computedAsync((_) {
        final completion = Completer<int>();
        _pending.add(completion);
        _launches++;
        return completion.future;
      }, retain: retain);
  static final _pending = <Completer<int>>[];
  static var _launches = 0;
  final AsyncComputed<int> source;
}

void main() {
  setUp(() {
    _Query._pending.clear();
    _Query._launches = 0;
  });

  testWidgets(
    'a query in a test leaves no pending timer: retain 0 and a landed retain',
    (tester) async {
      final plain = _Query();
      final retained = _Query(retain: const Duration(seconds: 5));
      await tester.pumpWidget(
        page(
          Column(
            children: [
              Reactive(builder: (_) => Text('a ${show(plain.source.value)}')),
              Reactive(
                builder: (_) => Text('b ${show(retained.source.value)}'),
              ),
            ],
          ),
        ),
      );
      for (final pending in List.of(_Query._pending)) {
        pending.complete(1);
      }
      await tester.idle();
      await tester.pump();
      expect(find.text('a 1'), findsOneWidget);
      expect(find.text('b 1'), findsOneWidget);
      // flutter_test unmounts the tree and verifies no timers are pending.
    },
  );

  testWidgets(
    'siblings agree on the first frame and the request starts in it',
    (tester) async {
      final query = _Query();
      var frames = 0;
      tester.binding.addPersistentFrameCallback((_) => frames++);
      await tester.pumpWidget(
        page(
          Column(
            children: [
              Reactive(
                builder: (_) => Text('left ${show(query.source.value)}'),
              ),
              Reactive(
                builder: (_) => Text('right ${show(query.source.value)}'),
              ),
            ],
          ),
        ),
      );
      expect(find.text('left loading'), findsOneWidget);
      expect(find.text('right loading'), findsOneWidget);
      expect(_Query._launches, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
      final before = frames;
      _Query._pending.single.complete(3);
      await tester.idle();
      await tester.pump();
      expect(find.text('left 3'), findsOneWidget);
      expect(find.text('right 3'), findsOneWidget);
      expect(frames - before, 1);
    },
  );

  testWidgets('a Pulse input stops behind TickerMode through a wait chain', (
    tester,
  ) async {
    final clock = Pulse.every(const Duration(seconds: 1));
    final upstream = computedAsync((_) async => clock.value.second);
    final downstream = computedAsync((q) async => await q.wait(upstream) + 1);
    Widget tree(bool visible) => page(
      TickerMode(
        enabled: visible,
        child: Reactive(builder: (_) => Text(show(downstream.value))),
      ),
    );
    await tester.pumpWidget(tree(true));
    await tester.idle();
    await tester.pump();
    expect(activePulseCount, 1);
    await tester.pumpWidget(tree(false));
    await tester.pump(const Duration(seconds: 3));
    expect(activePulseCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'gate and leaf: requireValue is safe when the gate unmounts the leaf synchronously',
    (tester) async {
      final user = _Query();
      final feed = _Query();
      var leafBuilds = 0;
      await tester.pumpWidget(
        page(
          Reactive(
            builder: (_) =>
                switch ((user.source.value, feed.source.value).all) {
                  AsyncData() => Reactive(
                    builder: (_) {
                      leafBuilds++;
                      return Text('user ${user.source.value.requireValue}');
                    },
                  ),
                  AsyncLoading() => const Text('skeleton'),
                  AsyncError(:final error) => Text('failed $error'),
                },
          ),
        ),
      );
      expect(find.text('skeleton'), findsOneWidget);
      _Query._pending[0].complete(7);
      _Query._pending[1].complete(8);
      await tester.idle();
      await tester.pump();
      expect(find.text('user 7'), findsOneWidget);
      user.source.invalidate();
      await tester.pump();
      // A refresh keeps the value: still data for the gate.
      expect(find.text('user 7'), findsOneWidget);
      _Query._pending.last.completeError(StateError('down'));
      await tester.idle();
      await tester.pump();
      expect(find.textContaining('failed'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(leafBuilds, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a gate that passes the value down survives an AnimatedSwitcher',
    (tester) async {
      final user = _Query();
      await tester.pumpWidget(
        page(
          Reactive(
            builder: (_) => AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: switch (user.source.value) {
                AsyncData(:final value) => Text(
                  'user $value',
                  key: const ValueKey('page'),
                ),
                AsyncLoading() => const Text(
                  'skeleton',
                  key: ValueKey('loading'),
                ),
                AsyncError() => const Text('failed', key: ValueKey('error')),
              },
            ),
          ),
        ),
      );
      _Query._pending.single.complete(7);
      await tester.idle();
      await tester.pump();
      user.source.invalidate();
      await tester.pump();
      _Query._pending.last.completeError(StateError('down'));
      await tester.idle();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a parent rebuild with inline closures does not rebuild a retained reader',
    (tester) async {
      final count = signal(0);
      var builds = 0;
      final reader = Reactive(
        builder: (_) {
          builds++;
          return Text('${count.value}');
        },
      );
      late StateSetter rebuild;
      await tester.pumpWidget(
        page(
          StatefulBuilder(
            builder: (_, setState) {
              rebuild = setState;
              return Column(children: [Builder(builder: (_) => reader)]);
            },
          ),
        ),
      );
      expect(builds, 1);
      rebuild(() {});
      await tester.pump();
      expect(builds, 1);
    },
  );

  testWidgets('a page pop cools its queries: no query work is left', (
    tester,
  ) async {
    final query = _Query();
    final stream = StreamController<int>.broadcast();
    final live = computedStream((_) => stream.stream);
    await tester.pumpWidget(
      page(
        Column(
          children: [
            Reactive(builder: (_) => Text(show(query.source.value))),
            Reactive(builder: (_) => Text('s ${show(live.value)}')),
          ],
        ),
      ),
    );
    expect((activeQueryCount, activeQueryStreamCount), (1, 1));
    await tester.pumpWidget(const SizedBox());
    expect(activeQueryCount, 0);
    expect(activeQueryStreamCount, 0);
    expect(activeQueryTimerCount, 0);
    await stream.close();
  });

  testWidgets('an unmounted reader does not wake when its query lands', (
    tester,
  ) async {
    final query = _Query(retain: const Duration(seconds: 1));
    await tester.pumpWidget(
      page(Reactive(builder: (_) => Text(show(query.source.value)))),
    );
    expect(subscriberCount(query.source), 1);
    await tester.pumpWidget(const SizedBox());
    expect(subscriberCount(query.source), 0);
    _Query._pending.single.complete(13);
    await tester.idle();
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, false);
  });

  testWidgets('a synchronous computed error goes to ErrorWidget and recovers', (
    tester,
  ) async {
    final ok = signal(false);
    final failure = StateError('broken');
    final value = computed<int>(() => ok.value ? 1 : throw failure);
    await tester.pumpWidget(
      page(Reactive(builder: (_) => Text('${value.value}'))),
    );
    expect(tester.takeException(), same(failure));
    expect(find.byType(ErrorWidget), findsOneWidget);
    ok.value = true;
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('B4 linger rethrows the original failure and later recovers', (
    t,
  ) async {
    final ok = signal(false);
    final msg = StateError('not ready yet');
    final input = computed<int?>(() => ok.value ? 42 : throw msg);
    final held = linger(input, const Duration(seconds: 1));
    int builds = 0;
    int? last;
    await t.pumpWidget(
      Reactive(
        builder: (_) {
          builds++;
          last = held.value;
          return const SizedBox();
        },
      ),
    );
    expect(t.takeException(), same(msg));
    ok.value = true;
    await t.pump();
    expect(t.takeException(), isNull);
    expect((builds, last), (2, 42));
    expect(subscriberCount(input), 1);
  });

  test('B1 cold derived values skip retired managed inputs', () {
    final choose = signal(true);
    final bad = signal(false);
    final source = computed<int?>(
      () => bad.value ? throw StateError('retired input') : 4,
    );
    final held = linger(source, Duration.zero);
    var evals = 0;
    final selected = computed(() {
      evals++;
      return choose.value ? held.value : 9;
    });
    final first = selected.peek();
    batch(() {
      choose.value = false;
      bad.value = true;
    });
    Object? last;
    try {
      last = selected.peek();
    } catch (e) {
      last = e;
    }
    expect((first, last, evals), (4, 9, 2));
  });
}
