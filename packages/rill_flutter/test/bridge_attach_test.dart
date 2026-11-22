import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

// Bridge attaches and builders run at once, through the public Listenable
// bridge and real widgets.

class _Hooked extends ValueNotifier<int> {
  _Hooked() : super(7);
  VoidCallback? attach;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    attach?.call();
  }
}

class _Prebuilt extends StatelessWidget {
  _Prebuilt(BuildContext context, WidgetBuilder buildChild)
    : child = buildChild(context);
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

Future<void> _runNow(BuildContext context, WidgetBuilder callback) {
  callback(context);
  return Future.value();
}

Future<void> _turns() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('a_cached_tracked_wait_does_not_outrun_a_bridge_attach', () async {
    final native = _Hooked(),
        input = native.toReadable(),
        lease = Scope(),
        target = signal(false),
        log = <String>[];
    final up = computedAsync<int>((_) async => input.value, keepAlive: lease);
    expect(await up.settled(), const AsyncData(7));
    await _turns();
    native.attach = () {
      log.add('attach');
      target.value = true;
    };
    final down = computedAsync<int>((q) async {
      if (target.value) {
        log.add('replacement');
        return 9;
      }
      final data = await q.wait(up);
      log.add('old continued $data');
      return data;
    });
    final stop = effect(() => down.value, (_, _, _) {});
    await _turns();
    expect(log, isNot(contains('old continued 7')));
    expect(down.peek(), const AsyncData(9));
    stop();
    lease.dispose();
    await _turns();
    native.dispose();
  });

  // The lint does not report these (only Flutter's own deferring APIs are
  // known callees, docs/lint.md#分层): both run the builder at once, inside
  // the Reactive that tracks it.
  testWidgets('builders_run_at_once_outside_flutter_are_tracked', (
    tester,
  ) async {
    debugInstallRillGuards(tester.binding.buildOwner!);
    final input = signal(2);
    await tester.pumpWidget(
      Reactive(
        builder: (context) {
          var width = 0;
          _runNow(
            context,
            (_) => SizedBox(width: (width = input.value).toDouble()),
          );
          return _Prebuilt(
            context,
            (_) => SizedBox(width: (input.value + width).toDouble()),
          );
        },
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.widget<SizedBox>(find.byType(SizedBox)).width, 4);
    input.value = 3;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.widget<SizedBox>(find.byType(SizedBox)).width, 6);
  });
}
