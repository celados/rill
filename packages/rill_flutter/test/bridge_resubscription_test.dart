import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

// An upstream resubscription through a real ValueNotifier bridge, from each
// frame phase: the bridge write asks upstream B a new question; B's new
// subscription sends D its latest event while D's earlier answer waits to
// install. Stream events are asynchronous: D may show 2 for a
// moment, and ends on 3, the latest event, never lost.

final class _PaintCall extends CustomPainter {
  _PaintCall(this.call);

  final VoidCallback call;

  @override
  void paint(Canvas canvas, Size size) => call();

  @override
  bool shouldRepaint(_PaintCall oldDelegate) => true;
}

void main() {
  for (final phase in ['build', 'layout', 'paint']) {
    testWidgets('an_upstream_resubscription_in_$phase sends the answer D '
        'ends_on', (tester) async {
      debugInstallRillGuards(tester.binding.buildOwner!);
      final native = ValueNotifier(1), mirror = native.toReadable();
      final downFeed = StreamController<int>.broadcast(sync: true);
      final bs = <StreamController<int>>[];
      final seen = <int?>[];
      var armed = false, touched = false;
      final b = computedStream<int>((_) {
        mirror.value;
        final c = StreamController<int>.broadcast(
          sync: true,
          onListen: () {
            if (armed) downFeed.add(3);
          },
        );
        bs.add(c);
        return c.stream;
      });
      final keep = effect(() => b.value, (_, _, _) {});
      bs.last.add(1);
      await tester.pump();
      final stable = computed(() => b.value.valueOrNull);
      final d = computedStream<int>((_) {
        stable.value;
        return downFeed.stream;
      });
      final off = effect(() => d.value, (s, _, _) => seen.add(s.valueOrNull));
      downFeed.add(1);
      await tester.pump();
      armed = true;
      void update() {
        if (touched) return;
        touched = true;
        batch(() {
          downFeed.add(2);
          native.value = 2;
          b.peek();
        });
      }

      await tester.pumpWidget(
        Builder(
          builder: (_) {
            if (phase == 'build') update();
            return LayoutBuilder(
              builder: (_, _) {
                if (phase == 'layout') update();
                return CustomPaint(
                  painter: _PaintCall(() {
                    if (phase == 'paint') update();
                  }),
                );
              },
            );
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      final state = d.peek();
      expect(tester.takeException(), isNull);
      off();
      keep();
      await tester.pumpWidget(const SizedBox());
      for (final c in [...bs, downFeed]) {
        await c.close();
      }
      native.dispose();
      expect(touched, isTrue);
      expect(seen.last, 3);
      expect(state, const AsyncData(3));
    });
  }
}
