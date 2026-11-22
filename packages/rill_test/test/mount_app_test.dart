// mountApp mounts like runApp: a toast region that writes from a plain effect
// trips the frame guard under it, and the same region on
// ReactiveState.watch cannot.
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';
import 'package:rill_test/rill_test.dart';

class _Toasts extends StatefulWidget {
  const _Toasts(this.queue, this.shown, {this.sniffPhase = false});
  final Signal<List<String>> queue;
  final Signal<List<String>> shown;
  final bool sniffPhase;
  @override
  State<_Toasts> createState() => _ToastsState();
}

class _ToastsState extends State<_Toasts> with ReactiveState {
  void Function()? _plain;

  @override
  void initState() {
    super.initState();
    if (widget.sniffPhase) {
      // A plain effect, writing at once while "idle".
      // ignore: rill_lint/rill_effect_in_lifecycle
      _plain = effect(() => widget.queue.value, (queue, _, _) {
        final phase = SchedulerBinding.instance.schedulerPhase;
        if (phase == SchedulerPhase.idle) {
          widget.shown.value = queue;
        } else {
          SchedulerBinding.instance.addPostFrameCallback(
            (_) => widget.shown.value = queue,
          );
        }
      });
    } else {
      watch(() => widget.queue.value, (queue, _, _) {
        widget.shown.value = queue;
      });
    }
  }

  @override
  void dispose() {
    _plain?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  final errors = <Object>[];
  setUp(() {
    errors.clear();
    Rill.onError = (error, _) => errors.add(error);
  });
  tearDown(() => Rill.onError = null);

  testWidgets('pumpWidget hides the phase-sniffing bug', (tester) async {
    final shown = signal(const <String>[]);
    await tester.pumpWidget(
      _Toasts(signal(const ['queued']), shown, sniffPhase: true),
    );
    expect(errors, isEmpty);
    expect(shown.peek(), ['queued']);
  });

  testWidgets('mountApp builds synchronously in idle phase and catches it', (
    tester,
  ) async {
    final shown = signal(const <String>[]);
    // No RillScope or reactive Element: mountApp installs the guards.
    await tester.mountApp(
      _Toasts(signal(const ['queued']), shown, sniffPhase: true),
    );
    expect(errors.single.toString(), contains('RILL_WRITE_DURING_FRAME'));
    expect(shown.peek(), isEmpty);
  });

  testWidgets('on ReactiveState.watch the bug cannot recur', (tester) async {
    final queue = signal(const ['queued']);
    final shown = signal(const <String>[]);
    await tester.mountApp(_Toasts(queue, shown));
    expect(errors, isEmpty);
    expect(shown.peek(), ['queued'], reason: 'applied after the warm-up frame');
    queue.value = const ['queued', 'next'];
    expect(shown.peek(), ['queued', 'next']);
    await tester.expectIdle();
  });

  testWidgets('wakes ignores a constant', (tester) async {
    final fixed = Readable.constant(1);
    expect(wakes([fixed], during: () => signal(0).value = 1), isEmpty);
  });
}
