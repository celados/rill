import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

import 'budget_test.dart' show page;

void main() {
  testWidgets('both bridges attach lazily, resync and release listeners', (
    tester,
  ) async {
    final native = _CountedNotifier(1);
    final read = native.toReadable();
    final bridge = read.toListenable();
    final key = GlobalKey();
    Widget tree() => page(
      ValueListenableBuilder(
        key: key,
        valueListenable: bridge,
        builder: (_, value, _) => Text('$value'),
      ),
    );
    expect(native.listeners, 0);
    await tester.pumpWidget(tree());
    expect(find.text('1'), findsOneWidget);
    expect((native.listeners, subscriberCount(read)), (1, 1));
    native.value = 3;
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect((native.listeners, subscriberCount(read)), (0, 0));

    native.value = 9;
    await tester.pumpWidget(tree());
    expect(find.text('9'), findsOneWidget);
    expect(native.listeners, 1);
    await tester.pumpWidget(const SizedBox());
    native.dispose();
  });

  testWidgets('event hook resubscribes on replacement and cleans up', (
    tester,
  ) async {
    final a = Events<int>();
    final b = Events<int>();
    final observed = <int>[];
    Widget tree(Events<int> source) => EventListener(
      events: source,
      onEvent: (_, event) => observed.add(event),
      child: const SizedBox(),
    );
    await tester.pumpWidget(tree(a));
    a.emit(1);
    await tester.pumpWidget(tree(b));
    a.emit(2);
    b.emit(3);
    await tester.pumpWidget(const SizedBox());
    b.emit(4);
    expect(observed, [1, 3]);
  });

  testWidgets(
    'B2 a native bridge write after consumption reaches the next frame',
    (t) async {
      final n = ValueNotifier(0);
      final s = n.toReadable();
      var mutate = false;
      var last = -1;
      Widget tree() => Reactive(
        builder: (_) {
          last = s.value;
          if (mutate) n.value = 1;
          return Text('$last', textDirection: TextDirection.ltr);
        },
      );
      await t.pumpWidget(tree());
      mutate = true;
      await t.pumpWidget(tree());
      await t.pump();
      expect(find.text('1'), findsOneWidget);
    },
  );

  testWidgets('B3 last listener can remove itself and reattach', (t) async {
    final s = signal(1);
    final b = s.toListenable();
    late VoidCallback cb;
    cb = () {
      b.removeListener(cb);
    };
    b.addListener(cb);
    s.value = 2;
    expect(subscriberCount(s), 0);
    b.addListener(cb);
    expect(subscriberCount(s), 1);
    b.removeListener(cb);
  });

  testWidgets('B3 self-unsubscription stops clock timers', (t) async {
    final clock = Pulse.every(const Duration(seconds: 1));
    final b = clock.toListenable();
    int calls = 0;
    late VoidCallback listener;
    listener = () {
      calls++;
      b.removeListener(listener);
    };
    b.addListener(listener);
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 2));
    expect((calls, subscriberCount(clock), activeBindingTimerCount), (1, 0, 0));
    (b as ChangeNotifier).dispose();
  });

  testWidgets('I10 equality runs before installing the value', (t) async {
    final observed = <String>[];
    late Signal<int> s;
    s = signal(
      0,
      equals: (old, next) {
        observed.add('$old/$next@${s.peek()}');
        return old == next;
      },
    );
    await t.pumpWidget(
      Reactive(
        builder: (_) {
          s.value;
          return const SizedBox();
        },
      ),
    );
    s.value = 1;
    expect(observed, ['0/1@0']);
    await t.pump();
  });

  testWidgets('held events reach a listener mounted later, after its frame', (
    t,
  ) async {
    final e = Events<int>(hold: true)
      ..emit(1)
      ..emit(2);
    final seen = <(int, SchedulerPhase)>[];
    await t.pumpWidget(
      EventListener<int>(
        events: e,
        onEvent: (_, v) =>
            seen.add((v, SchedulerBinding.instance.schedulerPhase)),
        child: const SizedBox(),
      ),
    );
    expect(seen, [
      (1, SchedulerPhase.postFrameCallbacks),
      (2, SchedulerPhase.postFrameCallbacks),
    ]);
    e.emit(3);
    expect(seen.last, (3, SchedulerPhase.idle));
  });

  // The post-frame hand-over keeps emission order and survives
  // a throwing callback.
  testWidgets(
    'an event emitted while held ones are handed over comes after them',
    (t) async {
      final e = Events<int>(hold: true)
        ..emit(1)
        ..emit(2);
      final seen = <int>[];
      await t.pumpWidget(
        EventListener<int>(
          events: e,
          onEvent: (_, v) {
            seen.add(v);
            if (v == 1) e.emit(3);
          },
          child: const SizedBox(),
        ),
      );
      expect(seen, [1, 2, 3]);
      e.emit(4);
      expect(seen, [1, 2, 3, 4]);
    },
  );

  testWidgets(
    'a held event whose callback throws is reported; the rest still arrive',
    (t) async {
      final e = Events<int>(hold: true)
        ..emit(1)
        ..emit(2);
      final seen = <int>[];
      await t.pumpWidget(
        EventListener<int>(
          events: e,
          onEvent: (_, v) {
            seen.add(v);
            if (v == 1) throw StateError('callback');
          },
          child: const SizedBox(),
        ),
      );
      expect(t.takeException(), isA<StateError>());
      expect(seen, [1, 2]);
      e.emit(3);
      expect(seen, [1, 2, 3]);
    },
  );

  testWidgets('same event source resumes after a GlobalKey move', (t) async {
    final e = Events<int>();
    final key = GlobalKey();
    final seen = <int>[];
    final reader = EventListener<int>(
      key: key,
      events: e,
      onEvent: (_, v) => seen.add(v),
      child: const SizedBox(),
    );
    Widget tree(bool right) => Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        children: [
          Center(child: right ? null : reader),
          Center(child: right ? reader : null),
        ],
      ),
    );
    await t.pumpWidget(tree(false));
    e.emit(1);
    await t.pumpWidget(tree(true));
    e.emit(2);
    expect(identical(key.currentWidget, reader), true);
    expect(seen, [1, 2]);
  });
  testWidgets(
    'B3 duplicate registrations and re-adding during delivery share one observer',
    (t) async {
      final source = signal(0);
      final bridge = source.toListenable();
      final seen = <int>[];
      late VoidCallback callback;
      callback = () {
        seen.add(bridge.value);
        bridge.removeListener(callback);
        if (source.peek() == 2) bridge.addListener(callback);
      };
      bridge.addListener(callback);
      bridge.addListener(callback);
      source.value = 1;
      expect(seen, [1, 1]);
      expect(subscriberCount(source), 0);
      bridge.addListener(callback);
      source.value = 2;
      expect(seen, [1, 1, 2]);
      expect(subscriberCount(source), 1);
      source.value = 3;
      expect(seen, [1, 1, 2, 3]);
      expect(subscriberCount(source), 0);
    },
  );

  testWidgets(
    'I12 animated builder tracks its signal reads and reuses the child',
    (t) async {
      final animation = ValueNotifier(0);
      final data = signal(1);
      const child = SizedBox(key: ValueKey('child'));
      final builds = <(int, int)>[];
      await t.pumpWidget(
        page(
          ReactiveAnimatedBuilder(
            animation: animation,
            child: child,
            builder: (_, builtChild) {
              expect(builtChild, same(child));
              builds.add((animation.value, data.value));
              return builtChild!;
            },
          ),
        ),
      );
      animation.value = 3;
      await t.pump();
      data.value = 2;
      await t.pump();
      expect(builds, [(0, 1), (3, 1), (3, 2)]);
      await t.pumpWidget(const SizedBox());
      expect(subscriberCount(data), 0);
      animation.dispose();
    },
  );
}

class _CountedNotifier extends ValueNotifier<int> {
  _CountedNotifier(super.value);
  int listeners = 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    listeners++;
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    listeners--;
  }
}
