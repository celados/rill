import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signals_flutter/signals_flutter.dart';

enum Binding {
  signals,
  listenable;

  Widget reader<T>(FlutterReadonlySignal<T> source, Widget Function(T) build) {
    return switch (this) {
      signals => SignalBuilder(builder: (_) => build(source.value)),
      listenable => ValueListenableBuilder<T>(
        valueListenable: source,
        builder: (_, value, _) => build(value),
      ),
    };
  }

  Widget painter<T>(
    FlutterReadonlySignal<T> source,
    bool Function(T) lit,
    DrawSample sample,
  ) {
    return switch (this) {
      signals => SignalCustomPaint(
        painter: SignalPaint(source, lit, sample),
        child: const SizedBox.square(dimension: 20),
      ),
      listenable => CustomPaint(
        painter: ListenablePaint(source, lit, sample),
        size: const Size.square(20),
      ),
    };
  }
}

typedef DrawSample = void Function(bool);

void draw(Canvas canvas, Size size, bool lit, DrawSample sample) {
  sample(lit);
  canvas.drawRect(
    Offset.zero & size,
    Paint()..color = lit ? const Color(0xffffffff) : const Color(0xff000000),
  );
}

class SignalPaint<T> extends SignalCustomPainter {
  SignalPaint(this.source, this.lit, this.sample) : super(signals: [source]);

  final FlutterReadonlySignal<T> source;
  final bool Function(T) lit;
  final DrawSample sample;

  @override
  void paint(Canvas canvas, Size size) =>
      draw(canvas, size, lit(source.value), sample);

  @override
  bool shouldRepaint(SignalPaint<T> oldDelegate) =>
      source != oldDelegate.source;
}

class ListenablePaint<T> extends CustomPainter {
  ListenablePaint(this.source, this.lit, this.sample) : super(repaint: source);

  final FlutterReadonlySignal<T> source;
  final bool Function(T) lit;
  final DrawSample sample;

  @override
  void paint(Canvas canvas, Size size) =>
      draw(canvas, size, lit(source.value), sample);

  @override
  bool shouldRepaint(ListenablePaint<T> oldDelegate) =>
      source != oldDelegate.source;
}

// Count the live subscribe calls used by both bindings, without registering
// an extra observer that could change the source's lifetime.
class CountedSignal<T> extends FlutterSignal<T> {
  CountedSignal(super.value);

  int subscriptions = 0;
  VoidCallback? onLastCancel;

  @override
  VoidCallback subscribe(void Function(T) fn) {
    final cancel = super.subscribe(fn);
    subscriptions++;
    return () {
      cancel();
      subscriptions--;
      if (subscriptions == 0) onLastCancel?.call();
    };
  }
}

class ReaderClock {
  ReaderClock(this.now) : epoch = now() {
    tick = signal(
      0,
      options: SignalOptions(watched: start, unwatched: stop),
    );
  }

  final DateTime Function() now;
  final DateTime epoch;
  late final FlutterSignal<int> tick;
  Timer? timer;
  int fires = 0;

  int get seconds => now().difference(epoch).inSeconds;
  int get activeTimers => timer?.isActive == true ? 1 : 0;

  void start() {
    timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      fires++;
      tick.value = seconds;
    });
  }

  void stop() {
    timer?.cancel();
    timer = null;
  }
}

Widget page(Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

void main() {
  final scheduler = TestWidgetsFlutterBinding.ensureInitialized();
  var frames = 0;
  scheduler.addPersistentFrameCallback((_) => frames++);

  for (final binding in Binding.values) {
    for (final warm in [false, true]) {
      testWidgets('${binding.name}: equal derived value, warm=$warm', (
        tester,
      ) async {
        final count = signal(1);
        var evaluations = 0;
        final busy = computed(() {
          evaluations++;
          return count.value > 0;
        });
        if (warm) expect(busy.peek(), isTrue);
        expect(evaluations, warm ? 1 : 0);
        final values = <bool>[];
        await tester.pumpWidget(
          page(
            binding.reader(busy, (value) {
              values.add(value);
              return Text('$value');
            }),
          ),
        );
        expect(values, [true]);
        expect(scheduler.hasScheduledFrame, isFalse);

        final extra = binding == Binding.signals && !warm ? 1 : 0;
        final before = frames;
        count.value = 2;
        await tester.idle();
        expect(scheduler.hasScheduledFrame, extra == 1);
        await tester.pump();
        expect(frames - before, extra);
        expect(values, [true, if (extra == 1) true]);
        expect(scheduler.hasScheduledFrame, isFalse);

        count.value = 0;
        expect(scheduler.hasScheduledFrame, isTrue);
        await tester.pump();
        expect(frames - before, extra + 1);
        expect(values, [true, if (extra == 1) true, false]);
        expect(find.text('false'), findsOneWidget);
        expect(scheduler.hasScheduledFrame, isFalse);
      });
    }

    for (final origin in ['ticker', 'post-frame', 'tap']) {
      testWidgets('${binding.name}: first visible frame after $origin', (
        tester,
      ) async {
        final source = signal(0);
        final builds = <int>[];
        SchedulerPhase? writePhase;
        void write() {
          writePhase = scheduler.schedulerPhase;
          source.value = 1;
        }

        await tester.pumpWidget(
          page(
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: write,
              child: Center(
                child: binding.reader(source, (value) {
                  builds.add(value);
                  return Text('$value');
                }),
              ),
            ),
          ),
        );
        expect(scheduler.hasScheduledFrame, isFalse);
        final before = frames;
        late final Ticker ticker;
        ticker = Ticker((_) {
          ticker.stop();
          write();
        });
        addTearDown(ticker.dispose);
        switch (origin) {
          case 'ticker':
            ticker.start();
          case 'post-frame':
            scheduler.addPostFrameCallback((_) => write());
            expect(scheduler.hasScheduledFrame, isFalse);
            scheduler.scheduleFrame();
          case 'tap':
            await tester.tap(find.byType(GestureDetector));
        }
        expect(scheduler.hasScheduledFrame, isTrue);
        expect(find.text('0'), findsOneWidget);

        await tester.pump();
        expect(frames - before, 1);
        expect(writePhase, switch (origin) {
          'ticker' => SchedulerPhase.transientCallbacks,
          'post-frame' => SchedulerPhase.postFrameCallbacks,
          _ => SchedulerPhase.idle,
        });
        final deferred = origin == 'post-frame';
        expect(find.text(deferred ? '0' : '1'), findsOneWidget);
        expect(scheduler.hasScheduledFrame, deferred);
        await tester.pump();
        expect(frames - before, deferred ? 2 : 1);
        expect(find.text('1'), findsOneWidget);
        expect(builds, [0, 1]);
        expect(scheduler.hasScheduledFrame, isFalse);
      });
    }

    testWidgets('${binding.name}: reader-driven clock over fake seconds', (
      tester,
    ) async {
      final clock = ReaderClock(scheduler.clock.now);
      Widget clockReader() => binding.reader(clock.tick, (tick) {
        final seconds = binding == Binding.listenable ? clock.seconds : tick;
        return Text('seconds: $seconds');
      });
      Widget clockPage({required bool read, required bool visible}) => page(
        TickerMode(
          enabled: visible,
          child: Builder(
            builder: (context) {
              if (!read ||
                  (binding == Binding.listenable &&
                      !TickerMode.valuesOf(context).enabled)) {
                return const SizedBox();
              }
              return clockReader();
            },
          ),
        ),
      );

      Future<void> sample({required int active}) async {
        final beforeFrames = frames;
        final beforeFires = clock.fires;
        expect(clock.activeTimers, active);
        expect(scheduler.hasScheduledFrame, isFalse);
        for (var second = 0; second < 3; second++) {
          await tester.pump(const Duration(seconds: 1));
          expect(frames - beforeFrames, (second + 1) * active);
          expect(clock.fires - beforeFires, (second + 1) * active);
          expect(clock.activeTimers, active);
          expect(scheduler.hasScheduledFrame, isFalse);
        }
      }

      await tester.pumpWidget(clockPage(read: false, visible: true));
      await sample(active: 0);
      await tester.pumpWidget(clockPage(read: true, visible: true));
      await sample(active: 1);
      expect(find.text('seconds: 6'), findsOneWidget);
      await tester.pumpWidget(clockPage(read: true, visible: false));
      await sample(active: binding == Binding.signals ? 1 : 0);
      await tester.pumpWidget(clockPage(read: true, visible: true));
      expect(find.text('seconds: 9'), findsOneWidget);
      expect(clock.activeTimers, 1);
      await tester.pumpWidget(const SizedBox());
      expect(clock.activeTimers, 0);
    });

    for (final derive in [false, true]) {
      testWidgets('${binding.name}: same pixels, derived=$derive', (
        tester,
      ) async {
        final count = signal(1);
        final lit = computed(() => count.value > 0);
        // Both paths draw exactly the same rectangle for counts 1 and 2.
        final paints = <bool>[];
        final painter = derive
            ? binding.painter(lit, (value) => value, paints.add)
            : binding.painter(count, (value) => value > 0, paints.add);
        await tester.pumpWidget(
          page(Center(child: RepaintBoundary(child: painter))),
        );
        expect(paints, [true]);
        expect(scheduler.hasScheduledFrame, isFalse);

        final before = frames;
        count.value = 2;
        expect(scheduler.hasScheduledFrame, !derive);
        await tester.pump();
        expect(paints, [true, if (!derive) true]);
        expect(frames - before, derive ? 0 : 1);
        expect(scheduler.hasScheduledFrame, isFalse);

        count.value = 0;
        expect(scheduler.hasScheduledFrame, isTrue);
        await tester.pump();
        expect(paints, [true, if (!derive) true, false]);
        expect(frames - before, derive ? 1 : 2);
        expect(scheduler.hasScheduledFrame, isFalse);
      });
    }

    lifecycleTest(binding, () => frames);
    nowReaderTest(binding, () => frames);
  }
}

void lifecycleTest(Binding binding, int Function() frames) {
  testWidgets('${binding.name}: reparent, replace and unmount', (tester) async {
    final scheduler = tester.binding;
    final firstReader = CountedSignal(10);
    final secondReader = CountedSignal(20);
    final firstPaint = CountedSignal(true);
    final secondPaint = CountedSignal(true);
    final key = GlobalKey();
    final builds = <int>[];
    final paints = <bool>[];

    Widget subtree(CountedSignal<int> reading, CountedSignal<bool> color) {
      return Column(
        key: key,
        mainAxisSize: MainAxisSize.min,
        children: [
          binding.reader(reading, (value) {
            builds.add(value);
            return Text('reading: $value');
          }),
          RepaintBoundary(
            child: binding.painter(color, (value) => value, paints.add),
          ),
        ],
      );
    }

    Widget tree(Widget child, {required bool right}) => page(
      Row(
        children: [
          Expanded(child: Center(child: right ? null : child)),
          Expanded(child: Center(child: right ? child : null)),
        ],
      ),
    );

    final original = subtree(firstReader, firstPaint);
    await tester.pumpWidget(tree(original, right: false));
    final element = key.currentContext;
    final paintFinder = find.descendant(
      of: find.byKey(key),
      matching: find.byType(
        binding == Binding.signals ? SignalCustomPaint : CustomPaint,
      ),
    );
    final render = tester.renderObject(paintFinder);
    List<int> subscriptions() => [
      firstReader.subscriptions,
      firstPaint.subscriptions,
      secondReader.subscriptions,
      secondPaint.subscriptions,
    ];

    expect(subscriptions(), [1, 1, 0, 0]);
    expect(builds, [10]);
    expect(paints, [true]);

    // Change the paint input at the moment the render listener goes away.
    // The move reuses the identical widgets and cannot call updateRenderObject.
    firstPaint.onLastCancel = () => firstPaint.value = false;
    final beforeMove = frames();
    firstReader.value = 11;
    await tester.pumpWidget(tree(original, right: true));
    expect(frames() - beforeMove, 1);
    expect(key.currentContext, same(element));
    expect(tester.renderObject(paintFinder), same(render));
    expect(find.text('reading: 11'), findsOneWidget);
    expect(builds, [10, 11]);
    expect(firstPaint.peek(), isFalse);
    expect(paints, [true]); // The retained layer still contains the old color.
    final losesPaintListener = binding == Binding.signals;
    expect(subscriptions(), [1, losesPaintListener ? 0 : 1, 0, 0]);
    expect(scheduler.hasScheduledFrame, isFalse);

    final beforeMovedWrite = frames();
    firstPaint.value = true;
    expect(scheduler.hasScheduledFrame, !losesPaintListener);
    await tester.pump();
    expect(frames() - beforeMovedWrite, losesPaintListener ? 0 : 1);
    expect(paints, [true, if (!losesPaintListener) true]);
    expect(scheduler.hasScheduledFrame, isFalse);

    final beforeReplace = frames();
    await tester.pumpWidget(
      tree(subtree(secondReader, secondPaint), right: true),
    );
    expect(frames() - beforeReplace, 1);
    expect(key.currentContext, same(element));
    expect(tester.renderObject(paintFinder), same(render));
    expect(find.text('reading: 20'), findsOneWidget);
    expect(builds, [10, 11, 20]);
    expect(paints, [true, if (!losesPaintListener) true, true]);
    expect(subscriptions(), [0, 0, 1, 1]);

    final beforeOldWrites = frames();
    firstReader.value = 12;
    firstPaint.value = false;
    expect(scheduler.hasScheduledFrame, isFalse);
    await tester.pump();
    expect(frames() - beforeOldWrites, 0);

    secondReader.value = 21;
    secondPaint.value = false;
    await tester.pump();
    expect(builds, [10, 11, 20, 21]);
    expect(paints, [true, if (!losesPaintListener) true, true, false]);
    expect(frames() - beforeOldWrites, 1);
    expect(scheduler.hasScheduledFrame, isFalse);
    // Replace again with both old subscriptions live, so painter replacement
    // is tested independently of the listener lost during the move.
    firstPaint.onLastCancel = null;
    firstPaint.value = true;
    await tester.pumpWidget(
      tree(subtree(firstReader, firstPaint), right: true),
    );
    expect(tester.renderObject(paintFinder), same(render));
    expect(find.text('reading: 12'), findsOneWidget);
    expect(paints.last, isTrue);
    expect(subscriptions(), [1, 1, 0, 0]);
    final beforeReplacedWrites = frames();
    secondReader.value = 22;
    secondPaint.value = true;
    expect(scheduler.hasScheduledFrame, isFalse);
    await tester.pump();
    expect(frames() - beforeReplacedWrites, 0);

    await tester.pumpWidget(const SizedBox());
    expect(subscriptions(), [0, 0, 0, 0]);
  });
}

void nowReaderTest(Binding binding, int Function() frames) {
  testWidgets('${binding.name}: Now rate and status leaves', (tester) async {
    final pings = signal([35]);
    final rates = signal([(down: 1024, up: 0)]);
    final vitals = signal((uptime: 60, connections: 2));
    final connected = signal(true);

    // Keep the same narrow boundaries as NowPage: reading joins pings and
    // rates, the pill picks its connected branch, and the chart reads pings.
    final reading = computed(
      () => (ms: pings.value.last, rate: rates.value.last),
    );
    final pill = computed(
      () => connected.value
          ? 'Connected · ${vitals.value.uptime}s'
          : 'Connecting',
    );
    final builds = <String>[];
    Widget line(String name, String text) {
      builds.add(name);
      return Text(text);
    }

    Widget readout(({int ms, ({int down, int up}) rate}) value) =>
        line('reading', '${value.ms} ms · ↓ ${value.rate.down ~/ 1024} KB/s');
    Widget status(String text) => line('pill', text);
    final Widget readingWidget;
    final Widget statusWidget;
    if (binding == Binding.signals) {
      readingWidget = SignalBuilder(
        builder: (_) => readout((ms: pings.value.last, rate: rates.value.last)),
      );
      statusWidget = SignalBuilder(
        builder: (_) => status(
          connected.value
              ? 'Connected · ${vitals.value.uptime}s'
              : 'Connecting',
        ),
      );
    } else {
      readingWidget = binding.reader(reading, readout);
      statusWidget = binding.reader(pill, status);
    }

    await tester.pumpWidget(
      page(
        Builder(
          builder: (_) {
            builds.add('page');
            return ListView(
              children: [
                statusWidget,
                readingWidget,
                binding.reader(
                  pings,
                  (value) => line('chart', 'Chart: ${value.last}'),
                ),
              ],
            );
          },
        ),
      ),
    );
    expect(builds, unorderedEquals(['page', 'reading', 'pill', 'chart']));
    builds.clear();
    final before = frames();
    batch(() {
      rates.value = [(down: 2048, up: 0)];
      vitals.value = (uptime: 61, connections: 3);
    });
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump();
    expect(builds, unorderedEquals(['reading', 'pill']));
    expect(find.text('35 ms · ↓ 2 KB/s'), findsOneWidget);
    expect(find.text('Connected · 61s'), findsOneWidget);
    expect(frames() - before, 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
