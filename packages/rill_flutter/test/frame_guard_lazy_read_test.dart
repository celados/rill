import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

// Lazy reads in builders, judged by the frame guard rather than the lint.

class _Redirect extends Reactive {
  _Redirect(WidgetBuilder b) : this.named(b);
  _Redirect.named(WidgetBuilder b) : super(builder: b);
}

void main() {
  // The lint leaves these to the runtime guard (docs/lint.md#分层): what a
  // nested closure runs, G2 sees where it runs.
  testWidgets('guard_judges_what_the_lint_leaves', (tester) async {
    debugInstallRillGuards(tester.binding.buildOwner!);
    final s = signal(1);
    // A lazy view never iterated: no read, no error.
    await tester.pumpWidget(
      Builder(
        builder: (_) =>
            SizedBox(width: [0, 1].map((_) => s.value).length.toDouble()),
      ),
    );
    expect(tester.takeException(), isNull);
    // A lazy chain forced in the builder: the read runs untracked.
    await tester.pumpWidget(
      Builder(
        builder: (_) => SizedBox(
          width: [0]
              .map((_) => s.value)
              .followedBy([2])
              .toList()
              .first
              .toDouble(),
        ),
      ),
    );
    expect('${tester.takeException()}', contains('RILL_UNTRACKED_READ'));
    // A subclass redirecting its builder to Reactive tracks it.
    await tester.pumpWidget(
      _Redirect((_) => SizedBox(width: s.value.toDouble())),
    );
    expect(tester.takeException(), isNull);
    s.value = 3;
    await tester.pump();
    expect(tester.widget<SizedBox>(find.byType(SizedBox)).width, 3);
  });
}
