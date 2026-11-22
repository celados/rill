import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';
import 'package:rill_test/rill_test.dart';

void main() {
  testWidgets('asserts exact rebuild types and restores the debug hook', (
    tester,
  ) async {
    final count = signal(0);
    await tester.pumpWidget(_page(_Reading(count)));
    final previous = debugOnRebuildDirtyWidget;
    await tester.expectRebuilds(only: {_Reading}, during: () => count.value++);
    expect(debugOnRebuildDirtyWidget, same(previous));
    expect(count.peek(), 1);
    await expectLater(
      tester.expectRebuilds(only: {}, during: () => count.value++),
      throwsA(isA<TestFailure>()),
    );
    expect(debugOnRebuildDirtyWidget, same(previous));
  });

  testWidgets('idle checks frames, tasks and timers before advancing time', (
    tester,
  ) async {
    final clock = Pulse.every(const Duration(seconds: 1));
    await tester.pumpWidget(
      _page(
        TickerMode(
          enabled: false,
          child: Reactive(builder: (_) => Text('${clock.value}')),
        ),
      ),
    );
    await tester.expectIdle(across: const Duration(seconds: 3));

    final scope = Scope();
    final done = Completer<void>();
    final task = scope.slot().run((_) => done.future);
    await expectLater(tester.expectIdle(), throwsA(isA<TestFailure>()));
    scope.dispose();
    done.complete();
    expect(await task, isA<Stale<void>>());

    tester.binding.scheduleFrame();
    await expectLater(tester.expectIdle(), throwsA(isA<TestFailure>()));
    await tester.pump();

    final input = signal<int?>(12);
    final retained = linger(input, const Duration(minutes: 1));
    await tester.pumpWidget(
      _page(Reactive(builder: (_) => Text('${retained.value}'))),
    );
    // Drive the widget harness directly to leave the linger timer pending.
    // ignore: rill_lint/rill_write_after_await
    input.value = null;
    expect(tester.binding.hasScheduledFrame, false);
    await expectLater(tester.expectIdle(), throwsA(isA<TestFailure>()));
    await tester.pumpWidget(const SizedBox());
    await tester.expectIdle();
  });

  testWidgets('idle sees query work: in flight, and started between pumps', (
    tester,
  ) async {
    final gate = Completer<int>();
    final pending = computedAsync((_) => gate.future);
    await tester.pumpWidget(
      _page(Reactive(builder: (_) => Text('${pending.value}'))),
    );
    await expectLater(tester.expectIdle(), throwsA(isA<TestFailure>()));
    await tester.pumpWidget(const SizedBox());
    await tester.expectIdle();

    // A query that starts and lands while expectIdle advances time leaves
    // no count behind; its start is still activity (I11).
    final transient = computedAsync((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return 1;
    });
    var settled = false;
    Timer(const Duration(milliseconds: 10), () {
      transient.settled().then((_) => settled = true);
    });
    // expectIdle pumps before it fails here, so no guarded expectLater.
    Object? failure;
    try {
      await tester.expectIdle(across: const Duration(seconds: 1));
    } on TestFailure catch (error) {
      failure = error;
    }
    expect(failure, isNotNull);
    expect(settled, isTrue);
    expect(activeQueryCount, 0);
  });

  testWidgets('idle tracks nested tasks through keyed joins and cancellation', (
    tester,
  ) async {
    final parentOwner = Scope();
    final childOwner = parentOwner.child();
    addTearDown(parentOwner.dispose);
    final parentGate = Completer<int>();
    final childGate = Completer<int>();
    final childSlot = childOwner.slot();
    late Future<Outcome<int>> child;
    final parent = parentOwner.slot().run((task) {
      child = childSlot.run((_) => childGate.future, key: 'child');
      return parentGate.future;
    });
    expect(activeTaskCount, 2);
    final joined = childSlot.run<int>((_) {
      fail('A keyed join must not start a second body.');
    }, key: 'child');
    expect(joined, same(child));
    expect(activeTaskCount, 2);
    await expectLater(tester.expectIdle(), throwsA(isA<TestFailure>()));

    parentOwner.dispose();
    expect(await parent, isA<Stale<int>>());
    expect(await child, isA<Stale<int>>());
    expect(activeTaskCount, 0);
    parentGate.complete(1);
    childGate.complete(2);
    await tester.expectIdle();
  });

  test(
    'wakes filters equal outputs and unregisters after success and failure',
    () {
      final count = signal(1);
      final busy = computed(() => count.value > 0);
      expect(wakes([count, busy], during: () => count.value = 2), {count});
      expect(wakes([count, busy, busy], during: () => count.value = 0), {
        count,
        busy,
      });
      expect(
        wakes(
          [count, busy],
          during: () => batch(() {
            count.value = 1;
            count.value = 0;
          }),
        ),
        isEmpty,
      );
      expect(
        () => wakes([count, busy], during: () => throw StateError('test')),
        throwsStateError,
      );
      expect((subscriberCount(count), subscriberCount(busy)), (0, 0));
    },
  );

  test('ManualAsync completes and fails calls in FIFO order', () async {
    final manual = ManualAsync<int>();
    final a = manual.call();
    final b = manual.call();
    final error = StateError('failure');
    final handled = expectLater(b, throwsA(same(error)));
    expect(manual.pending, 2);
    manual.complete(1);
    expect(await a, 1);
    expect(manual.pending, 1);
    manual.fail(error);
    await handled;
    expect(manual.pending, 0);
    expect(() => manual.complete(4), throwsStateError);
  });

  testWidgets('I11 idle rejects a task completed between pumps', (t) async {
    final owner = Scope();
    int maxTasks = 0;
    Timer(const Duration(milliseconds: 10), () {
      owner.slot().run((_) async {
        maxTasks = activeTaskCount;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
    });
    Object? failure;
    try {
      await t.expectIdle(across: const Duration(seconds: 1));
    } on TestFailure catch (error) {
      failure = error;
    }
    expect(failure.toString(), contains('A rill task, timer or query started'));
    expect((maxTasks, activeTaskCount), (1, 0));
    owner.dispose();
  });

  testWidgets('S2 a one-frame assertion rejects pending rebuilds', (t) async {
    final s = signal(0);
    var builds = 0;
    await t.pumpWidget(
      Reactive(
        builder: (_) {
          builds++;
          s.value;
          return const SizedBox();
        },
      ),
    );
    await expectLater(
      t.expectRebuilds(
        only: {},
        during: () {
          t.binding.addPostFrameCallback((_) {
            s.value = 1;
          });
          t.binding.scheduleFrame();
        },
      ),
      throwsA(isA<TestFailure>()),
    );
    expect(builds, 1);
    await t.pump();
    expect(builds, 2);
  });

  testWidgets('S3 wakes rejects an open batch', (t) async {
    final a = signal(0);
    expect(
      () => batch(() => wakes([a], during: () => a.value = 1)),
      throwsStateError,
    );
    expect(a.peek(), 0);
  });

  test('S4 completes and fails calls out of order', () async {
    final fake = ManualAsync<String>();
    final first = fake.call();
    final second = fake.call();
    final third = fake.call();
    final error = StateError('third');
    final handled = expectLater(third, throwsA(same(error)));
    fake.completeAt(1, 'second');
    expect(await second, 'second');
    fake.failAt(1, error);
    await handled;
    expect(fake.pending, 1);
    fake.complete('first');
    expect(await first, 'first');
  });
}

Widget _page(Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

class _Reading extends ReactiveWidget {
  const _Reading(this.count);
  final Readable<int> count;

  @override
  Widget build(BuildContext context) {
    count.value;
    return const SizedBox();
  }
}
