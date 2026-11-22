import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

import 'budget_test.dart' show Frames, page;

void main() {
  testWidgets('inherited_value_change_keeps_state_scope_and_tasks', (
    tester,
  ) async {
    // What RillScope(provide:) did by destroying the subtree's Scopes is an
    // InheritedWidget notification now: the reader follows the new value,
    // the State keeps its Scope and its in-flight tasks.
    final aSignal = signal(1), bSignal = signal(2);
    final key = GlobalKey<_ReaderState>();
    final child = _Reader(key);
    final completions = <Completer<void>>[];
    Widget tree(int position, Signal<int> right) => page(
      Row(
        children: [
          _Service(
            aSignal,
            child: Column(
              children: [
                Center(child: position == 0 ? child : null),
                Center(child: position == 1 ? child : null),
              ],
            ),
          ),
          _Service(right, child: Center(child: position == 2 ? child : null)),
        ],
      ),
    );

    await tester.pumpWidget(tree(0, bSignal));
    final state = key.currentState!;
    final owner = state.ownScope;
    final complete = Completer<void>();
    completions.add(complete);
    final task = owner.slot().run((_) => complete.future);
    expect(find.text('1'), findsOneWidget);
    await tester.pumpWidget(tree(1, bSignal));
    await tester.pumpWidget(tree(2, bSignal));
    expect(key.currentState, same(state));
    expect(find.text('2'), findsOneWidget);
    expect((subscriberCount(aSignal), subscriberCount(bSignal)), (0, 1));
    final cSignal = signal(3);
    await tester.pumpWidget(tree(2, cSignal));
    expect(find.text('3'), findsOneWidget);
    expect((subscriberCount(bSignal), subscriberCount(cSignal)), (0, 1));
    expect(state.ownScope, same(owner));
    expect(owner.disposed, isFalse);
    expect(activeTaskCount, 1);
    complete.complete();
    expect(await task, isA<Done<void>>());
    await tester.pumpWidget(const SizedBox());
    expect(owner.disposed, isTrue);
    expect(subscriberCount(cSignal), 0);
  });

  testWidgets('Pulse calls with the same arguments share one running timer', (
    tester,
  ) async {
    const second = Duration(seconds: 1);
    final frames = Frames(tester);
    Widget reader(String label) => Reactive(
      builder: (_) => Text(
        '$label ${Pulse.every(second).value.second} '
        '${Pulse.phase(second).value < 2}',
      ),
    );
    await tester.pumpWidget(page(Column(children: [reader('a'), reader('b')])));
    expect((activeBindingTimerCount, activePulseCount), (2, 2));
    expect(identical(Pulse.every(second), Pulse.every(second)), isTrue);
    for (var n = 0; n < 3; n++) {
      await tester.pump(second);
    }
    expect((activeBindingTimerCount, activePulseCount), (2, 2));
    expect(frames.count, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    expect((activeBindingTimerCount, activePulseCount), (0, 0));
    // Sharing does not depend on being watched; the table
    // holds sources weakly, so it still never outgrows the live handles.
    expect(
      identical(Pulse.every(second), Pulse.every(second)),
      isTrue,
      reason: 'live handles share one source, watched or not',
    );
  });

  testWidgets('wall clock aggregates readers through a shared computed', (
    tester,
  ) async {
    final wall = Pulse.every(const Duration(seconds: 1));
    final clockStart = wall.peek();
    final elapsed = computed(
      () =>
          (wall.value.millisecondsSinceEpoch ~/ 1000) -
          (clockStart.millisecondsSinceEpoch ~/ 1000),
    );
    final frames = Frames(tester);
    final left = Reactive(builder: (_) => Text('left ${elapsed.value}'));
    final right = Reactive(builder: (_) => Text('right ${elapsed.value}'));
    Widget tree(bool a, bool b) => page(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Column(
          children: [
            TickerMode(enabled: a, child: left),
            TickerMode(enabled: b, child: right),
          ],
        ),
      ),
    );

    await tester.pumpWidget(tree(true, true));
    expect((activeBindingTimerCount, activePulseCount), (1, 1));
    await tester.pumpWidget(tree(false, true));
    expect((activeBindingTimerCount, activePulseCount), (1, 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('right 1'), findsOneWidget);
    await tester.pumpWidget(tree(false, false));
    final baseline = frames.count;
    final revision = nodeRevision(wall);
    for (var n = 0; n < 3; n++) {
      await tester.pump(const Duration(seconds: 1));
      expect((activeBindingTimerCount, activePulseCount), (0, 0));
      expect(frames.count, baseline);
      expect(nodeRevision(wall), revision);
    }
    await tester.pumpWidget(tree(false, true));
    expect(find.text('right 4'), findsOneWidget);
    expect(activeBindingTimerCount, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(activeBindingTimerCount, 0);
    await tester.pump(const Duration(seconds: 2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('right 6'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect((activeBindingTimerCount, activePulseCount), (0, 0));
  });

  testWidgets('a cold derived clock samples before the remount build', (
    tester,
  ) async {
    final time = Pulse.every(const Duration(seconds: 1));
    final origin = time.peek().millisecondsSinceEpoch ~/ 1000;
    final seconds = computed(
      () => time.value.millisecondsSinceEpoch ~/ 1000 - origin,
    );
    final nested = computed(() => seconds.value);
    final child = page(Reactive(builder: (_) => Text('${nested.value}')));
    await tester.pumpWidget(child);
    expect(find.text('0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(subscriberCount(time), 0);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(child);
    expect(find.text('4'), findsOneWidget);
    expect(subscriberCount(time), 1);
    expect(tester.binding.hasScheduledFrame, false);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('decorative phase stops with reduced motion', (tester) async {
    final phase = Pulse.phase(const Duration(seconds: 1));
    final child = Reactive(builder: (_) => Text('${phase.value}'));
    Widget tree(bool reduced) => page(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: child,
      ),
    );
    await tester.pumpWidget(tree(false));
    expect(activePulseCount, 1);
    await tester.pumpWidget(tree(true));
    expect(activePulseCount, 0);
    await tester.pumpWidget(tree(false));
    expect(activePulseCount, 1);
    await tester.pumpWidget(const SizedBox());
    expect(activePulseCount, 0);
  });

  testWidgets(
    'linger counts from the null notification and releases its timer',
    (tester) async {
      final source = signal<int?>(1, equals: Equality.never);
      final lateValue = linger(source, const Duration(seconds: 3));
      await tester.pumpWidget(
        page(Reactive(builder: (_) => Text('${lateValue.value}'))),
      );
      await tester.pump(const Duration(seconds: 2));
      source.value = null;
      expect(activeBindingTimerCount, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('1'), findsOneWidget);
      source.value = null;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('null'), findsOneWidget);
      source.value = 2;
      await tester.pump();
      source.value = null;
      expect(activeBindingTimerCount, 1);
      await tester.pumpWidget(const SizedBox());
      expect(activeBindingTimerCount, 0);
      expect(subscriberCount(source), 0);
    },
  );

  testWidgets('I4 first visible clock reader calibrates in its first frame', (
    t,
  ) async {
    final wall = Pulse.every(const Duration(seconds: 1));
    final origin = wall.peek().millisecondsSinceEpoch ~/ 1000;
    final elapsed = computed(
      () => wall.value.millisecondsSinceEpoch ~/ 1000 - origin,
    );
    Widget reader() => Reactive(builder: (_) => Text('${elapsed.value}'));
    final hidden = TickerMode(enabled: false, child: reader());
    Widget tree(bool show) =>
        page(Column(children: [hidden, if (show) reader()]));
    await t.pumpWidget(tree(false));
    await t.pump(const Duration(seconds: 4));
    await t.pumpWidget(tree(true));
    expect(t.widgetList<Text>(find.byType(Text)).last.data, '4');
    expect(activePulseCount, 1);
    await t.pump();
    expect(t.widgetList<Text>(find.byType(Text)).last.data, '4');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('I6 clock through linger stays idle while hidden', (t) async {
    final wall = Pulse.every(const Duration(seconds: 1));
    final v = linger<DateTime>(wall, const Duration(seconds: 1));
    int reads = 0;
    await t.pumpWidget(
      TickerMode(
        enabled: false,
        child: Reactive(
          builder: (_) {
            reads++;
            v.value;
            return const SizedBox();
          },
        ),
      ),
    );
    await t.pump(const Duration(seconds: 3));
    expect((activePulseCount, activeBindingTimerCount, reads), (0, 0, 1));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'I4 a previously active clock calibrates through a retained linger',
    (tester) async {
      final time = Pulse.every(const Duration(seconds: 1));
      final origin = time.peek().millisecondsSinceEpoch ~/ 1000;
      final lingered = linger(time, Duration.zero);
      Widget reader() => Reactive(
        builder: (_) =>
            Text('${lingered.value!.millisecondsSinceEpoch ~/ 1000 - origin}'),
      );
      final first = reader();
      Widget tree(bool visible, bool add) => page(
        Column(
          children: [
            TickerMode(enabled: visible, child: first),
            if (add) reader(),
          ],
        ),
      );
      await tester.pumpWidget(tree(true, false));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1'), findsOneWidget);
      await tester.pumpWidget(tree(false, false));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(tree(false, true));
      expect(tester.widgetList<Text>(find.byType(Text)).last.data, '4');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('I5 inactive keeps the visible wall clock running', (t) async {
    final wall = Pulse.every(const Duration(seconds: 1));
    final origin = wall.peek().millisecondsSinceEpoch ~/ 1000;
    var age = -1;
    await t.pumpWidget(
      Reactive(
        builder: (_) {
          age = wall.value.millisecondsSinceEpoch ~/ 1000 - origin;
          return const SizedBox();
        },
      ),
    );
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump(const Duration(seconds: 2));
    expect((activePulseCount, age), (1, 2));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await t.pump(const Duration(seconds: 1));
    expect((activePulseCount, age), (0, 2));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump(const Duration(seconds: 1));
    expect((activePulseCount, age), (0, 2));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect((activePulseCount, age), (1, 4));
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('I13 reassemble keeps a single watch; the State owns it', (
    t,
  ) async {
    final data = signal(0);
    final received = <int>[];
    final reader = _Watcher(data, received);
    await t.pumpWidget(reader);
    await t.pump();
    t.binding.buildOwner!.reassemble(t.binding.rootElement!);
    await t.pump();
    data.value = 7;
    expect(received, [0, 7]);
    expect(subscriberCount(data), 1);
    await t.pumpWidget(const SizedBox());
    expect(subscriberCount(data), 0);
  });
}

class _Service extends InheritedWidget {
  const _Service(this.value, {required super.child});
  final Signal<int> value;

  static Signal<int> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Service>()!.value;

  @override
  bool updateShouldNotify(_Service oldWidget) =>
      !identical(value, oldWidget.value);
}

class _Reader extends ReactiveStatefulWidget {
  const _Reader(GlobalKey<_ReaderState> key) : super(key: key);

  @override
  State<_Reader> createState() => _ReaderState();
}

class _ReaderState extends State<_Reader> with ReactiveState {
  Scope get ownScope => scope;

  @override
  Widget build(BuildContext context) => Text('${_Service.of(context).value}');
}

class _Watcher extends StatefulWidget {
  const _Watcher(this.data, this.received);
  final Signal<int> data;
  final List<int> received;

  @override
  State<_Watcher> createState() => _WatcherState();
}

class _WatcherState extends State<_Watcher> with ReactiveState {
  @override
  void initState() {
    super.initState();
    watch(() => widget.data.value, (value, _, _) => widget.received.add(value));
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
