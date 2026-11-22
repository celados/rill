import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/debug.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

import 'budget_test.dart' show page;

void main() {
  setUp(RillDebug.clear);

  testWidgets('D2 an Element rebuild names the write and the computed path', (
    tester,
  ) async {
    final count = signal(0, name: 'count');
    final busy = computed(() => count.value > 0, name: 'busy');
    final other = signal(0, name: 'other');
    await tester.pumpWidget(
      page(
        Column(
          children: [
            Reactive(
              key: const Key('busy'),
              builder: (_) => Text('${busy.value}'),
            ),
            Reactive(
              key: const Key('other'),
              builder: (_) => Text('${other.value}'),
            ),
          ],
        ),
      ),
    );
    final element = tester.element(find.byKey(const Key('busy')));
    expect(RillDebug.why(element), isEmpty);

    count.value = 1;
    final writeLine = _line() - 1;
    await tester.pump();
    final why = RillDebug.lastWhy(element)!;
    expect(why.kind, 'observer');
    expect(why.target, same(element));
    expect(why.node.kind, 'observer');
    expect(why.node.label, contains('Reactive'));
    final busyCause = why.causes.single;
    expect(busyCause.node.label, 'busy');
    final write = busyCause.causes.single;
    expect(write.node.label, 'count');
    expect(write.change, 'write');
    expect(write.site.toString(), 'test/why_test.dart:$writeLine');
    expect(why.toString(), contains('rebuilt (#1)'));
    expect(
      RillDebug.why(tester.element(find.byKey(const Key('other')))),
      isEmpty,
    );

    // F2: an equal derived value wakes no Element and records nothing.
    count.value = 2;
    await tester.pump();
    expect(RillDebug.why(element), hasLength(1));
  });

  testWidgets('D2 a painter repaint is attributed to the painter', (
    tester,
  ) async {
    final level = signal(0, name: 'level');
    final painter = _Painter(level);
    await tester.pumpWidget(
      page(ReactivePaint(painter: painter, size: const Size(10, 10))),
    );
    level.value = 3;
    await tester.pump();
    final why = RillDebug.lastWhy(painter)!;
    expect(why.target, same(painter));
    expect(why.causes.single.node.label, 'level');
  });

  testWidgets('D3 active lists running pulses', (tester) async {
    final clock = Pulse.every(const Duration(seconds: 1));
    await tester.pumpWidget(
      page(Reactive(builder: (_) => Text('${clock.value.second}'))),
    );
    final pulses = (RillDebug.active()['pulses']! as List).cast<Map>();
    final entry = pulses.single;
    expect(entry['periodMs'], 1000);
    expect(entry['running'], isTrue);
    expect(entry['readers'], 1);
    expect(entry['decorative'], isFalse);
    expect(entry['location'], startsWith('test/why_test.dart:'));
    await tester.pumpWidget(page(const SizedBox()));
    expect(RillDebug.active()['pulses'], isEmpty);
  });
}

int _line() {
  final frame = StackTrace.current.toString().split('\n')[1];
  return int.parse(RegExp(r':(\d+):\d+\)$').firstMatch(frame)![1]!);
}

class _Painter extends ReactivePainter {
  _Painter(this.level);
  final Readable<int> level;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Rect.fromLTWH(0, 0, level.value.toDouble(), 1), Paint());
  }
}
