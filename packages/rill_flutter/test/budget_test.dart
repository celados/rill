import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

Widget page(Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

class Frames {
  Frames(WidgetTester tester) {
    tester.binding.addPersistentFrameCallback((_) => count++);
  }
  int count = 0;
}

class ProbeBinding extends AutomatedTestWidgetsFlutterBinding {
  int deferred = 0;

  @override
  void addPostFrameCallback(
    FrameCallback callback, {
    String debugLabel = 'callback',
  }) {
    if (debugLabel == 'rill.invalidate') deferred++;
    super.addPostFrameCallback(callback, debugLabel: debugLabel);
  }
}

void main() {
  final binding = ProbeBinding();

  for (final warm in [false, true]) {
    testWidgets('equal derived output is idle (warm: $warm)', (tester) async {
      final count = signal(1);
      var evaluations = 0;
      final busy = computed(() {
        evaluations++;
        return count.value > 0;
      });
      if (warm) expect(busy.peek(), true);
      expect(evaluations, warm ? 1 : 0);
      var builds = 0;
      final frames = Frames(tester);
      await tester.pumpWidget(
        page(
          Reactive(
            builder: (_) {
              builds++;
              return Text('${busy.value}');
            },
          ),
        ),
      );
      expect(subscriberCount(count), 1);
      expect(subscriberCount(busy), 1);
      final initial = frames.count;

      count.value = 2;
      expect(tester.binding.hasScheduledFrame, false);
      await tester.pump();
      batch(() {
        count.value = 0;
        count.value = 2;
      });
      expect(tester.binding.hasScheduledFrame, false);
      await tester.pump();
      expect((builds, frames.count - initial), (1, 0));

      count.value = 0;
      await tester.pump();
      expect(find.text('false'), findsOneWidget);
      expect((builds, frames.count - initial), (2, 1));
    });
  }

  testWidgets(
    'applies can consume intermediate values without scheduling a frame',
    (tester) async {
      final input = signal(false);
      final output = signal(0);
      final intermediate = <int>[];
      final stop = effect(() => input.value, (active, _, _) {
        if (active) output.value = 1;
      });
      final settle = effect(() => output.value, (value, _, _) {
        intermediate.add(value);
        if (value == 1) output.value = 0;
      });
      addTearDown(stop);
      addTearDown(settle);
      final frames = Frames(tester);
      var builds = 0;
      await tester.pumpWidget(
        page(
          Reactive(
            builder: (_) {
              builds++;
              return Text('${output.value}');
            },
          ),
        ),
      );
      final initial = frames.count;
      input.value = true;
      expect(intermediate, [0, 1, 0]);
      expect(tester.binding.hasScheduledFrame, false);
      await tester.pump();
      expect((frames.count - initial, builds), (0, 1));
    },
  );

  for (final phase in ['ticker', 'tap', 'post-frame']) {
    testWidgets('$phase writes render at the first available frame', (
      tester,
    ) async {
      final count = signal(0);
      var builds = 0;
      final frames = Frames(tester);
      await tester.pumpWidget(
        page(
          GestureDetector(
            onTap: () => count.value = 1,
            child: Reactive(
              builder: (_) {
                builds++;
                return Text('${count.value}');
              },
            ),
          ),
        ),
      );
      final initial = frames.count;
      late final Ticker ticker;
      ticker = Ticker((_) {
        ticker.stop();
        count.value = 1;
      });
      if (phase == 'ticker') ticker.start();
      if (phase == 'tap') await tester.tap(find.text('0'));
      if (phase == 'post-frame') {
        tester.binding.addPostFrameCallback((_) => count.value = 1);
        tester.binding.scheduleFrame();
      }
      await tester.pump(const Duration(milliseconds: 16));
      ticker.dispose();
      expect(find.text(phase == 'post-frame' ? '0' : '1'), findsOneWidget);
      expect(builds, phase == 'post-frame' ? 1 : 2);
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      expect(builds, 2);
      expect(frames.count - initial, phase == 'post-frame' ? 2 : 1);
    });
  }

  testWidgets('one frame for two Now page readers', (tester) async {
    final rates = signal(1);
    final vitals = signal(1);
    final samples = signal(1);
    final frames = Frames(tester);
    final builds = <String, int>{};
    void built(String type) =>
        builds.update(type, (n) => n + 1, ifAbsent: () => 1);

    await tester.pumpWidget(
      page(
        Builder(
          builder: (_) {
            built('page');
            return Column(
              children: [
                Reactive(
                  builder: (_) {
                    built('reading');
                    return Text('rate ${rates.value}');
                  },
                ),
                Reactive(
                  builder: (_) {
                    built('pill');
                    return Text('vitals ${vitals.value}');
                  },
                ),
                Reactive(
                  builder: (_) {
                    built('chart');
                    return Text('samples ${samples.value}');
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
    final initial = frames.count;
    builds.clear();
    batch(() {
      rates.value = 7;
      vitals.value = 9;
    });
    await tester.pump();
    expect(builds, {'reading': 1, 'pill': 1});
    expect(frames.count - initial, 1);
    expect(find.text('rate 7'), findsOneWidget);
    expect(find.text('vitals 9'), findsOneWidget);
  });

  testWidgets('persistent marks are deduplicated and discarded on detach', (
    tester,
  ) async {
    final source = signal(0);
    final reader = Reactive(builder: (_) => Text('${source.value}'));
    await tester.pumpWidget(page(reader));
    final initial = binding.deferred;

    await tester.pumpWidget(
      page(
        Row(
          children: [
            reader,
            Builder(
              builder: (_) {
                writeBindingSignal(source, 1);
                writeBindingSignal(source, 2);
                writeBindingSignal(source, 3);
                return const SizedBox();
              },
            ),
          ],
        ),
      ),
    );
    // First exercise a live reader on a later sibling's build.
    final marks = binding.deferred;
    final stable = Row(children: [reader, const SizedBox()]);
    await tester.pumpWidget(page(stable));
    await tester.pumpWidget(
      page(
        Row(
          children: [
            reader,
            Builder(
              builder: (_) {
                writeBindingSignal(source, 4);
                writeBindingSignal(source, 5);
                return const SizedBox();
              },
            ),
          ],
        ),
      ),
    );
    expect(binding.deferred - marks, 1);
    await tester.pump();
    expect(find.text('5'), findsOneWidget);
    expect(binding.deferred, greaterThan(initial));

    await tester.pumpWidget(
      page(
        Row(
          children: [
            Builder(builder: (_) => const SizedBox()),
            reader,
          ],
        ),
      ),
    );
    final beforeDetach = binding.deferred;
    await tester.pumpWidget(
      page(
        Row(
          children: [
            Builder(
              builder: (_) {
                writeBindingSignal(source, 6);
                return const SizedBox();
              },
            ),
          ],
        ),
      ),
    );
    expect(subscriberCount(source), 0);
    expect(binding.deferred - beforeDetach, 1);
    expect(tester.binding.hasScheduledFrame, false);
  });

  testWidgets('a moved painter repaints a value written while detached', (
    tester,
  ) async {
    // No layout in the moved subtree: the repaint boundary keeps its layer
    // unless the reattached observer asks for paint.
    final a = signal(10);
    final pixels = <int>[];
    final key = GlobalKey();
    final picture = RepaintBoundary(
      key: key,
      child: ReactivePaint(
        size: const Size(40, 40),
        painter: _Painter(computed(() => a.value ~/ 10), pixels),
      ),
    );
    Widget tree(bool left) => page(
      Row(
        children: [
          SizedBox(width: 50, height: 50, child: left ? picture : null),
          SizedBox(
            width: 50,
            height: 50,
            child: left
                ? null
                : Builder(
                    builder: (_) {
                      writeBindingSignal(a, 39);
                      return picture;
                    },
                  ),
          ),
        ],
      ),
    );
    await tester.pumpWidget(tree(true));
    expect(pixels.last, 1);
    await tester.pumpWidget(tree(false));
    expect(pixels.last, 3);
    await tester.pumpWidget(const SizedBox());
  });

  // A ReactivePainter only mounts through ReactivePaint.
  for (final withVisibility in [true]) {
    testWidgets(
      'painter reattaches, replaces and filters equal pixels (ReactivePaint: $withVisibility)',
      (tester) async {
        final a = signal(10);
        final b = signal(90);
        final key = GlobalKey();
        final frames = Frames(tester);
        final pixels = <int>[];
        final left = _Painter(computed(() => a.value ~/ 10), pixels);
        final right = _Painter(computed(() => b.value ~/ 10), pixels);
        var layouts = 0;
        var builds = 0;
        Widget picture(ReactivePainter painter) => RepaintBoundary(
          key: key,
          child: Builder(
            builder: (_) {
              builds++;
              return LayoutBuilder(
                builder: (_, _) {
                  layouts++;
                  // The native path can retain its layer without another widget update.
                  // It must repaint even when attach is the only invalidation.
                  return ReactivePaint(
                    size: const Size(40, 40),
                    painter: painter,
                  );
                },
              );
            },
          ),
        );

        final first = picture(left);
        await tester.pumpWidget(
          page(
            Row(
              children: [
                Center(child: first),
                const Center(),
              ],
            ),
          ),
        );
        final render = tester.renderObject<RenderCustomPaint>(
          find.byType(CustomPaint),
        );
        expect((subscriberCount(a), pixels.last), (1, 1));
        final baseline = (frames.count, pixels.length, builds, layouts);

        a.value = 19;
        await tester.pump();
        expect((frames.count, pixels.length, builds, layouts), baseline);
        a.value = 25;
        await tester.pump();
        expect(
          (frames.count, pixels.length, builds, layouts),
          (baseline.$1 + 1, baseline.$2 + 1, baseline.$3, baseline.$4),
        );

        var detached = false;
        final beforeMove = pixels.length;
        await tester.pumpWidget(
          page(
            Row(
              children: [
                const Center(),
                Center(
                  child: Builder(
                    builder: (_) {
                      detached = subscriberCount(a) == 0;
                      writeBindingSignal(a, 39);
                      return first;
                    },
                  ),
                ),
              ],
            ),
          ),
        );
        expect(detached, true);
        expect(
          tester.renderObject<RenderCustomPaint>(find.byType(CustomPaint)),
          same(render),
        );
        expect(
          (subscriberCount(a), pixels.last, pixels.length - beforeMove),
          (1, 3, 1),
        );

        await tester.pumpWidget(
          page(
            Row(
              children: [
                const Center(),
                Center(child: picture(right)),
              ],
            ),
          ),
        );
        expect(
          (subscriberCount(a), subscriberCount(b), pixels.last),
          (0, 1, 9),
        );
        final beforeOldWrite = (frames.count, pixels.length);
        a.value = 52;
        await tester.pump();
        expect((frames.count, pixels.length), beforeOldWrite);
        await tester.pumpWidget(const SizedBox());
        expect((subscriberCount(a), subscriberCount(b)), (0, 0));
      },
    );
  }
}

class _Painter extends ReactivePainter {
  _Painter(this.input, this.pixels);
  final Readable<int> input;
  final List<int> pixels;

  @override
  void paint(Canvas canvas, Size size) {
    final value = input.value;
    pixels.add(value);
    canvas.drawRect(Rect.fromLTWH(0, 0, value.toDouble(), 10), Paint());
  }
}
