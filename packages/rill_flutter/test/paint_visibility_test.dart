import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

import 'budget_test.dart' show Frames, page;

void main() {
  testWidgets(
    'an opaque route stops phase timers and frames in the covered painter',
    (tester) async {
      const period = Duration(milliseconds: 73);
      final phase = Pulse.phase(period);
      final painter = _PulsePainter(phase);
      final frames = Frames(tester);
      final navigator = GlobalKey<NavigatorState>();
      final paint = RepaintBoundary(
        child: ReactivePaint(painter: painter, size: const Size(40, 40)),
      );
      Route<void> route(Widget child) => PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => child,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      );

      await tester.pumpWidget(
        page(Navigator(key: navigator, onGenerateRoute: (_) => route(paint))),
      );
      expect(activeBindingTimerCount, 1);
      await tester.pump(const Duration(milliseconds: 20));
      expect(painter.samples.length, 2);

      final covered = navigator.currentState!.push(
        route(const SizedBox.expand()),
      );
      await tester.pump();
      await tester.pump();
      expect(subscriberCount(phase), 1);
      final coveredFrames = frames.count;
      final coveredSamples = painter.samples.length;
      final coveredRevision = nodeRevision(phase);
      for (var i = 0; i < 3; i++) {
        await tester.pump(period);
        expect((activeBindingTimerCount, activePulseCount), (0, 0));
        expect(frames.count, coveredFrames);
        expect(painter.samples.length, coveredSamples);
        expect(nodeRevision(phase), coveredRevision);
      }

      navigator.currentState!.pop();
      await tester.pump();
      expect(activeBindingTimerCount, 1);
      expect(painter.samples.length, coveredSamples + 1);
      expect(painter.samples.last, phase.peek());
      expect(nodeRevision(phase), greaterThan(coveredRevision));
      await tester.pump();
      await covered;
      await tester.pumpWidget(const SizedBox());
      expect(activeBindingTimerCount, 0);
    },
  );

  testWidgets('phase frames follow the frame interval and share instants', (
    tester,
  ) async {
    const frame = Duration(microseconds: 1000000 ~/ 30);
    final slow = Pulse.phase(const Duration(seconds: 2), frame: frame);
    final fast = Pulse.phase(const Duration(milliseconds: 300), frame: frame);
    final a = _PulsePainter(slow), b = _PulsePainter(fast);
    final frames = Frames(tester);
    await tester.pumpWidget(
      page(
        Row(
          children: [
            ReactivePaint(painter: a, size: const Size(10, 10)),
            ReactivePaint(painter: b, size: const Size(10, 10)),
          ],
        ),
      ),
    );
    expect((activeBindingTimerCount, activePulseCount), (2, 2));
    final start = frames.count;
    final samples = a.samples.length;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(microseconds: 1000000 ~/ 60));
    }
    // One second of 60 Hz pumps: about 30 samples, and the two loops draw
    // in the same frames instead of each adding its own.
    final drawn = a.samples.length - samples;
    expect(drawn, inInclusiveRange(29, 31));
    expect(frames.count - start, drawn);
    expect(a.samples.length, b.samples.length);
    expect(
      () => Pulse.phase(const Duration(seconds: 1), frame: Duration.zero),
      throwsArgumentError,
    );
    await tester.pumpWidget(const SizedBox());
    expect(activeBindingTimerCount, 0);
  });

  testWidgets('reduced motion stops paint phase while the wall clock ticks', (
    tester,
  ) async {
    final phase = Pulse.phase(const Duration(milliseconds: 73));
    final wall = Pulse.every(const Duration(seconds: 1));
    final background = _PulsePainter(phase);
    final foreground = _PulsePainter(wall);
    final paint = RepaintBoundary(
      child: ReactivePaint(
        painter: background,
        foregroundPainter: foreground,
        size: const Size(40, 40),
      ),
    );
    Widget tree(bool reduced) => page(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: paint,
      ),
    );
    final frames = Frames(tester);

    await tester.pumpWidget(tree(false));
    expect((activeBindingTimerCount, activePulseCount), (2, 2));

    await tester.pumpWidget(tree(true));
    expect((activeBindingTimerCount, activePulseCount), (1, 1));
    final phaseRevision = nodeRevision(phase);
    final wallRevision = nodeRevision(wall);
    final before = frames.count;
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
      expect((activeBindingTimerCount, activePulseCount), (1, 1));
      expect(nodeRevision(phase), phaseRevision);
    }
    expect(frames.count - before, 3);
    expect(nodeRevision(wall), greaterThan(wallRevision));
    expect(foreground.samples.last, wall.peek());

    await tester.pumpWidget(tree(false));
    expect((activeBindingTimerCount, activePulseCount), (2, 2));
    expect(nodeRevision(phase), greaterThan(phaseRevision));
    expect(background.samples.last, phase.peek());
    expect(tester.binding.hasScheduledFrame, false);
    await tester.pumpWidget(const SizedBox());
    expect(activeBindingTimerCount, 0);
  });

  testWidgets('native listenable readers count as visible', (tester) async {
    final wall = Pulse.every(const Duration(seconds: 1));
    await tester.pumpWidget(
      page(
        TickerMode(
          enabled: false,
          child: ValueListenableBuilder(
            valueListenable: wall.toListenable(),
            builder: (_, _, _) => const SizedBox(),
          ),
        ),
      ),
    );
    expect(activeBindingTimerCount, 1);
    await tester.pumpWidget(const SizedBox());
    expect(activeBindingTimerCount, 0);
  });

  testWidgets('shared_painter_two_slots_two_observers', (t) async {
    final a = signal(1), b = signal(2);
    final painter = _SizedPainter(a, b);
    Widget tile(double width) => RepaintBoundary(
      child: ReactivePaint(painter: painter, size: Size(width, 10)),
    );
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Row(children: [tile(10), tile(20)]),
      ),
    );
    expect(painter.values, unorderedEquals([1, 2]));
    expect((subscriberCount(a), subscriberCount(b)), (1, 1));
    a.value = 3;
    await t.pump();
    expect(painter.values.last, 3, reason: 'only the slot that read a');
    expect(painter.values, hasLength(3));
    await t.pumpWidget(const SizedBox());
    expect((subscriberCount(a), subscriberCount(b)), (0, 0));
  });
}

class _PulsePainter<T> extends ReactivePainter {
  _PulsePainter(this.clock);

  final Readable<T> clock;
  final samples = <T>[];

  @override
  void paint(Canvas canvas, Size size) {
    samples.add(clock.value);
  }
}

class _SizedPainter extends ReactivePainter {
  _SizedPainter(this.small, this.large);
  final Signal<int> small, large;
  final values = <int>[];
  @override
  void paint(Canvas c, Size s) {
    values.add((s.width == 10 ? small : large).value);
  }
}
