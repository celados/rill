import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

import 'budget_test.dart' show Frames, page;

void main() {
  for (final seed in [17, 319, 61453]) {
    testWidgets('frame pump fuzz seed $seed', (tester) async {
      final random = Random(seed);
      final inputs = [signal(0), signal(0)];
      final model = [0, 0];
      final frames = Frames(tester);
      final key = GlobalKey();
      var slot = -1;
      var selected = 0;
      var builds = 0;
      Reactive reader() {
        final readFrom = selected;
        return Reactive(
          key: key,
          builder: (_) {
            builds++;
            return Text('value ${inputs[readFrom].value}');
          },
        );
      }

      Widget current = reader();
      Widget tree({VoidCallback? before}) => page(
        Column(
          children: [
            Builder(
              builder: (_) {
                before?.call();
                return const SizedBox();
              },
            ),
            Row(
              children: [
                Center(child: slot == 0 ? current : null),
                Center(child: slot == 1 ? current : null),
              ],
            ),
          ],
        ),
      );

      await tester.pumpWidget(tree());
      for (var step = 0; step < 96; step++) {
        final operation = random.nextInt(8);
        final at = random.nextInt(inputs.length);
        final next = random.nextInt(4);
        final wasVisible = slot >= 0;
        final changesView = wasVisible && at == selected && model[at] != next;
        final beforeBuild = builds;
        final beforeFrames = frames.count;
        var expectedBuilds = 0;
        var expectedFrames = 1;
        void write({bool inFrame = false}) {
          model[at] = next;
          if (inFrame) {
            writeBindingSignal(inputs[at], next);
          } else {
            inputs[at].value = next;
          }
        }

        switch (operation) {
          case 0:
            slot = 0;
            expectedBuilds = wasVisible ? 0 : 1;
            if (wasVisible && key.currentContext != null) {
              final oldAtZero =
                  tester.widgetList<Center>(find.byType(Center)).first.child !=
                  null;
              if (!oldAtZero) expectedBuilds = 1;
            }
            await tester.pumpWidget(tree());
          case 1:
            slot = -1;
            await tester.pumpWidget(tree());
          case 2:
            slot = slot == 0 ? 1 : 0;
            expectedBuilds = 1;
            await tester.pumpWidget(tree());
          case 3:
            selected = 1 - selected;
            current = reader();
            expectedBuilds = wasVisible ? 1 : 0;
            await tester.pumpWidget(tree());
          case 4:
            write();
            expectedBuilds = changesView ? 1 : 0;
            expectedFrames = expectedBuilds;
            await tester.pump();
          case 5:
            tester.binding.scheduleFrameCallback((_) => write());
            expectedBuilds = changesView ? 1 : 0;
            await tester.pump();
          case 6:
            tester.binding.addPostFrameCallback((_) => write());
            tester.binding.scheduleFrame();
            await tester.pump();
            expectedBuilds = changesView ? 1 : 0;
            expectedFrames += expectedBuilds;
            expect(builds, beforeBuild);
            await tester.pump();
          case 7:
            await tester.pumpWidget(tree(before: () => write(inFrame: true)));
            expectedBuilds = changesView ? 1 : 0;
            expectedFrames += expectedBuilds;
            expect(builds, beforeBuild);
            await tester.pump();
        }
        final context = 'seed=$seed step=$step operation=$operation';
        expect(builds - beforeBuild, expectedBuilds, reason: context);
        expect(frames.count - beforeFrames, expectedFrames, reason: context);
        expect(tester.binding.hasScheduledFrame, false, reason: context);
        for (var i = 0; i < inputs.length; i++) {
          expect(
            subscriberCount(inputs[i]),
            slot >= 0 && selected == i ? 1 : 0,
            reason: context,
          );
        }
        expect(
          find.byType(Text),
          slot >= 0 ? findsOneWidget : findsNothing,
          reason: context,
        );
        if (slot >= 0) {
          expect(
            find.text('value ${model[selected]}'),
            findsOneWidget,
            reason: context,
          );
        }
      }
      await tester.pumpWidget(const SizedBox());
      expect(inputs.map(subscriberCount), [0, 0]);
    });
  }
  for (final seed in [17, 319, 61453]) {
    testWidgets('composition frame fuzz seed $seed', (tester) async {
      final random = Random(seed);
      final nav = GlobalKey<NavigatorState>();
      final native = ValueNotifier(0);
      final bridged = native.toReadable();
      final nativeReader = bridged.toListenable();
      final number = signal<int?>(2);
      final held = linger(number, const Duration(milliseconds: 40));
      final clock = Pulse.every(const Duration(milliseconds: 100));
      final displayed = signal(0);
      var bridgePaint = -1;
      var visibleA = false, visibleB = false;
      var mutateInReader = false;
      Widget reader() => Reactive(
        builder: (_) {
          final value = bridged.value;
          if (mutateInReader) {
            mutateInReader = false;
            native.value = value + 1;
          }
          return Text('native $value');
        },
      );
      final readerKey = GlobalKey();
      final visibility = ValueNotifier((false, false));
      final home = Column(
        children: [
          KeyedSubtree(
            key: readerKey,
            child: _HotReader(builder: reader),
          ),
          ValueListenableBuilder(
            valueListenable: nativeReader,
            builder: (_, value, _) => Text('listenable $value'),
          ),
          ValueListenableBuilder(
            valueListenable: visibility,
            builder: (_, modes, _) => Column(
              children: [
                TickerMode(
                  enabled: modes.$1,
                  child: Reactive(builder: (_) => Text('a ${clock.value}')),
                ),
                TickerMode(
                  enabled: modes.$2,
                  child: Reactive(builder: (_) => Text('b ${clock.value}')),
                ),
              ],
            ),
          ),
          Reactive(builder: (_) => Text('held ${held.value}')),
        ],
      );
      await tester.pumpWidget(
        WidgetsApp(
          navigatorKey: nav,
          color: const Color(0xFF000000),
          home: home,
          pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
            settings: settings,
            pageBuilder: (context, _, _) => builder(context),
          ),
        ),
      );
      for (var step = 0; step < 42; step++) {
        final operation = random.nextInt(7);
        final reason = 'seed=$seed step=$step operation=$operation';
        switch (operation) {
          case 0:
            mutateInReader = true;
            (readerKey.currentContext! as Element).visitChildren(
              (child) => child.markNeedsBuild(),
            );
            await tester.pump();
            await tester.pump();
            expect(
              find.text('listenable ${native.value}'),
              findsOneWidget,
              reason: reason,
            );
            expect(
              find.text('native ${native.value}'),
              findsOneWidget,
              reason: reason,
            );
          case 1:
            final bridge = displayed.toListenable();
            late VoidCallback listener;
            listener = () {
              bridgePaint = bridge.value;
              bridge.removeListener(listener);
            };
            bridge.addListener(listener);
            displayed.value++;
            expect(bridgePaint, displayed.peek(), reason: reason);
            expect(subscriberCount(displayed), 0, reason: reason);
          case 2:
            number.value = random.nextInt(7);
            await tester.pump();
            final old = number.peek();
            number.value = null;
            await tester.pump();
            expect(find.text('held $old'), findsOneWidget, reason: reason);
            await tester.pump(const Duration(milliseconds: 40));
            expect(
              find.text('held null'),
              findsOneWidget,
              reason: '$reason previous=$old',
            );
          case 3:
            visibleA = !visibleA;
            visibility.value = (visibleA, visibleB);
            await tester.pump();
            expect(
              activePulseCount,
              visibleA || visibleB ? 1 : 0,
              reason: reason,
            );
          case 4:
            visibleB = !visibleB;
            visibility.value = (visibleA, visibleB);
            await tester.pump();
            expect(
              activePulseCount,
              visibleA || visibleB ? 1 : 0,
              reason: reason,
            );
          case 5:
            final pending = showGeneralDialog<void>(
              context: readerKey.currentContext!,
              transitionDuration: Duration.zero,
              pageBuilder: (_, _, _) =>
                  Reactive(builder: (_) => Text('route ${displayed.value}')),
            );
            await tester.pump();
            displayed.value++;
            await tester.pump();
            expect(
              find.text('route ${displayed.peek()}'),
              findsOneWidget,
              reason: reason,
            );
            nav.currentState!.pop();
            await tester.pump();
            await tester.pump();
            await pending;
            expect(subscriberCount(displayed), 0, reason: reason);
          case 6:
            tester.binding.buildOwner!.reassemble(tester.binding.rootElement!);
            await tester.pump();
            expect(subscriberCount(bridged), 2, reason: reason);
        }
      }
      await tester.pumpWidget(const SizedBox());
      expect(activeBindingTimerCount, 0);
      expect(subscriberCount(bridged), 0);
      native.dispose();
      visibility.dispose();
    });
  }
}

class _HotReader extends StatelessWidget {
  const _HotReader({required this.builder});
  final Widget Function() builder;

  @override
  Widget build(BuildContext context) => builder();
}
