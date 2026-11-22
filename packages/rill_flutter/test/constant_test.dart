// Readable.constant in the binding (conformance K7–K8, docs/conformance.md).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

void main() {
  testWidgets('K7 a Reactive reads a constant without a guard or rebuild', (
    tester,
  ) async {
    final codes = <String>[];
    diagnosticHook = (code, _) => codes.add(code);
    addTearDown(() => diagnosticHook = null);
    final fixed = Readable.constant('fixed');
    final input = signal(0);
    var builds = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Reactive(
          builder: (_) {
            builds++;
            return Text('${fixed.value} ${input.value}');
          },
        ),
      ),
    );
    input.value = 1;
    await tester.pump();
    expect((find.text('fixed 1').evaluate().length, builds), (1, 2));
    // Read outside any reader during a build: still no hint.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (_) => Text(fixed.value)),
      ),
    );
    expect(find.text('fixed'), findsOneWidget);
    expect(codes, ['RILL_REBUILD'], reason: 'only the signal write');
  });

  testWidgets('K8 its listenable never notifies', (tester) async {
    final fixed = Readable.constant(3);
    final listenable = fixed.toListenable();
    var calls = 0;
    void listener() => calls++;
    listenable.addListener(listener);
    signal(0).value = 1;
    await tester.pump();
    listenable.removeListener(listener);
    expect((listenable.value, calls), (3, 0));
  });
}
