// R3b: effects woken by a managed binding write made during a frame apply
// after the frame. The reachable hazard is the bridge listener: Flutter code
// sets a ValueNotifier in build, didUpdateWidget or layout, the bridge
// mirrors it with writeBindingSignal, and before R3b the live effect applied
// inside buildScope. Pulse and linger carry the same marking; see
// docs/conformance.md#帧内托管写r3b for the registered cases.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

import 'budget_test.dart' show page;

/// A live watch whose apply writes, as a component's controller may: inside a
/// build that write is RILL_WRITE_DURING_FRAME.
class _Watcher extends StatefulWidget {
  const _Watcher(this.source, this.out, this.log);
  final Readable<Object?> source;
  final Signal<Object?> out;
  final List<String> log;
  @override
  State<_Watcher> createState() => _WatcherState();
}

class _WatcherState extends State<_Watcher> with ReactiveState {
  @override
  void initState() {
    super.initState();
    watch(() => widget.source.value, (v, previous, onCleanup) {
      final building = WidgetsBinding.instance.buildOwner!.debugBuilding;
      widget.log.add('apply $v $previous${building ? ' IN BUILD' : ''}');
      widget.out.value = v;
      onCleanup(() => widget.log.add('cleanup $v'));
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

/// Mirrors its configuration into a native notifier, the Flutter way.
class _Setter extends StatefulWidget {
  const _Setter(this.notifier, this.value);
  final ValueNotifier<int> notifier;
  final int value;
  @override
  State<_Setter> createState() => _SetterState();
}

class _SetterState extends State<_Setter> {
  @override
  void didUpdateWidget(_Setter old) {
    super.didUpdateWidget(old);
    widget.notifier.value = widget.value;
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

  group('R3b bridge listener written during a frame', () {
    testWidgets('a live watch applies after the build, in the same frame', (
      tester,
    ) async {
      final native = ValueNotifier(1);
      final source = native.toReadable();
      final out = signal<Object?>(0);
      final log = <String>[];
      Widget tree(int value) => page(
        Column(
          children: [
            _Watcher(source, out, log),
            _Setter(native, value),
            Reactive(builder: (_) => Text('${out.value}')),
          ],
        ),
      );
      await tester.pumpWidget(tree(1));
      expect(log, ['apply 1 null']);
      await tester.pumpWidget(tree(2));
      expect(errors, isEmpty);
      expect(log, ['apply 1 null', 'cleanup 1', 'apply 2 1']);
      expect(out.peek(), 2);
      // The post-frame write marks the reader for the next frame, which the
      // write itself asks for; the deferral adds none of its own.
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump();
      expect(find.text('2'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('it does not request a frame beyond the one it is in', (
      tester,
    ) async {
      final native = ValueNotifier(1);
      final source = native.toReadable();
      final applied = <Object?>[];
      final key = GlobalKey<_PlainState>();
      Widget tree(int value) => page(
        Column(
          children: [
            _Plain(key: key, source: source, applied: applied),
            _Setter(native, value),
          ],
        ),
      );
      await tester.pumpWidget(tree(1));
      await tester.pumpWidget(tree(2));
      expect(applied, [1, 2]);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('later Reactive track exits in the frame do not drain it', (
      tester,
    ) async {
      final native = ValueNotifier(1);
      final source = native.toReadable();
      final other = signal(0);
      final log = <String>[];
      // Fresh Reactive widgets rebuild after the setter in the same build.
      Widget tree(int value) => page(
        Column(
          children: [
            _Watcher(source, signal<Object?>(0), log),
            _Setter(native, value),
            for (var i = 0; i < 3; i++)
              Reactive(
                builder: (_) {
                  log.add('reader $i ${other.value}');
                  return const SizedBox();
                },
              ),
          ],
        ),
      );
      await tester.pumpWidget(tree(1));
      log.clear();
      await tester.pumpWidget(tree(2));
      expect(errors, isEmpty);
      expect(log, [
        'reader 0 0',
        'reader 1 0',
        'reader 2 0',
        'cleanup 1',
        'apply 2 1',
      ]);
    });

    testWidgets('a State unmounted in the same frame cancels its apply', (
      tester,
    ) async {
      final native = ValueNotifier(1);
      final source = native.toReadable();
      final log = <String>[];
      Widget tree(bool watching, int value) => page(
        Column(
          children: [
            if (watching) _Watcher(source, signal<Object?>(0), log),
            _Setter(native, value),
          ],
        ),
      );
      await tester.pumpWidget(tree(true, 1));
      await tester.pumpWidget(tree(false, 2));
      expect(errors, isEmpty);
      expect(log, ['apply 1 null', 'cleanup 1']);
      expect(subscriberCount(source), 0);
    });

    testWidgets('a watch created in the same build applies once, latest', (
      tester,
    ) async {
      final native = ValueNotifier(1);
      final source = native.toReadable();
      final log = <String>[];
      Widget tree(bool watching, int value) => page(
        Column(
          children: [
            if (watching) _Watcher(source, signal<Object?>(0), log),
            _Setter(native, value),
          ],
        ),
      );
      await tester.pumpWidget(tree(false, 1));
      await tester.pumpWidget(tree(true, 2));
      expect(errors, isEmpty);
      expect(log, ['apply 2 null']);
    });

    testWidgets('a watch through linger applies after the frame', (
      tester,
    ) async {
      final native = ValueNotifier(1);
      final held = linger(native.toReadable(), Duration.zero);
      final log = <String>[];
      Widget tree(int value) => page(
        Column(
          children: [
            _Watcher(held, signal<Object?>(0), log),
            _Setter(native, value),
          ],
        ),
      );
      await tester.pumpWidget(tree(1));
      await tester.pumpWidget(tree(2));
      expect(errors, isEmpty);
      expect(log, ['apply 1 null', 'cleanup 1', 'apply 2 1']);
    });

    testWidgets('a notifier set during layout applies after the frame', (
      tester,
    ) async {
      final native = ValueNotifier(0.0);
      final log = <String>[];
      final out = signal<Object?>(0);
      Widget tree(double width) => page(
        Column(
          children: [
            _Watcher(native.toReadable(), out, log),
            SizedBox(
              width: width,
              child: LayoutBuilder(
                builder: (_, constraints) {
                  native.value = constraints.maxWidth;
                  return const SizedBox();
                },
              ),
            ),
          ],
        ),
      );
      await tester.pumpWidget(tree(10));
      await tester.pumpWidget(tree(20));
      expect(errors, isEmpty);
      expect(log.last, 'apply 20.0 10.0');
      expect(out.peek(), 20.0);
    });

    testWidgets('a notifier set from an event applies after the next frame', (
      tester,
    ) async {
      final native = ValueNotifier(1);
      final log = <String>[];
      await tester.pumpWidget(
        _Watcher(native.toReadable(), signal<Object?>(0), log),
      );
      native.value = 2;
      expect(log, ['apply 1 null']);
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump();
      expect(log, ['apply 1 null', 'cleanup 1', 'apply 2 1']);
    });
  });

  group('R3b leaves ordinary writes alone', () {
    testWidgets('an event write applies synchronously', (tester) async {
      final source = signal(1);
      final log = <String>[];
      await tester.pumpWidget(_Watcher(source, signal<Object?>(0), log));
      source.value = 2;
      expect(log, ['apply 1 null', 'cleanup 1', 'apply 2 1']);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a deferred effect hit again by an event write runs once', (
      tester,
    ) async {
      final native = ValueNotifier(1);
      final other = signal(10);
      final log = <String>[];
      final source = native.toReadable();
      final both = computed(() => '${source.value}/${other.value}');
      await tester.pumpWidget(_Watcher(both, signal<Object?>(0), log));
      native.value = 2;
      other.value = 11;
      expect(log, ['apply 1/10 null']);
      await tester.pump();
      expect(log, ['apply 1/10 null', 'cleanup 1/10', 'apply 2/11 1/10']);
    });

    testWidgets('a Pulse tick still applies synchronously', (tester) async {
      final log = <String>[];
      final time = Pulse.every(const Duration(seconds: 1));
      final seconds = computed(() => time.value.millisecondsSinceEpoch ~/ 1000);
      await tester.pumpWidget(_Watcher(seconds, signal<Object?>(0), log));
      expect(log, hasLength(1));
      // The timer fires inside pump's fake-async elapse, before its frame.
      tester.binding.scheduleFrame();
      await tester.pump(const Duration(seconds: 1));
      expect(log, hasLength(3));
      expect(log.where((entry) => entry.contains('IN BUILD')), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// A watch without writes, to count frames.
class _Plain extends StatefulWidget {
  const _Plain({super.key, required this.source, required this.applied});
  final Readable<Object?> source;
  final List<Object?> applied;
  @override
  State<_Plain> createState() => _PlainState();
}

class _PlainState extends State<_Plain> with ReactiveState {
  @override
  void initState() {
    super.initState();
    watch(() => widget.source.value, (v, _, _) {
      widget.applied.add(v);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
