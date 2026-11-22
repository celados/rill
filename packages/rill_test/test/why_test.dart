import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';
import 'package:rill_test/rill_test.dart';

void main() {
  test('recordWhy and causedBy follow an effect chain', () async {
    final count = signal(1, name: 'count');
    final doubled = computed(() => count.value * 2, name: 'doubled');
    final other = signal(0, name: 'other');
    final stop = effect(() => doubled.value + other.value, (_, _, _) {});
    addTearDown(stop);
    final records = await recordWhy(() => count.value = 2);
    expect(records.single, causedBy(count, via: [doubled]));
    expect(records.single, isNot(causedBy(other)));
    expect(records.single, isNot(causedBy(count)));
    expect(
      () => expect(records.single, causedBy(other)),
      throwsA(
        isA<TestFailure>().having(
          (failure) => failure.message,
          'message',
          allOf(
            contains('caused by a write of other'),
            contains('← computed doubled'),
          ),
        ),
      ),
    );
    expect(await recordWhy(() {}), isEmpty);
  });

  testWidgets('whyRebuilt narrows the records to one Element', (tester) async {
    final count = signal(0, name: 'count');
    final busy = computed(() => count.value > 0, name: 'busy');
    final other = signal(0, name: 'other');
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            _Busy(busy),
            Reactive(builder: (_) => Text('${other.value}')),
          ],
        ),
      ),
    );
    final rebuilt = await tester.whyRebuilt(
      find.byType(_Busy),
      during: () {
        count.value = 1;
        other.value = 1;
      },
    );
    expect(rebuilt.single, causedBy(count, via: [busy]));
    final none = await tester.whyRebuilt(
      find.byType(_Busy),
      during: () => count.value = 2,
    );
    expect(none, isEmpty);
  });
}

class _Busy extends ReactiveWidget {
  const _Busy(this.busy);
  final Readable<bool> busy;

  @override
  Widget build(BuildContext context) => Text('${busy.value}');
}
