// ReactiveState.watch and the phase-sniffing probe: the
import 'dart:async';

// phase-sniffing toast pattern under each way of mounting a root.
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

/// A toast region with a plain effect: an effect created in initState whose
/// apply writes at once when the scheduler phase "looks" idle.
class _PhaseSniffing extends StatefulWidget {
  const _PhaseSniffing(this.source, this.out);
  final Signal<int> source;
  final Signal<int> out;
  @override
  State<_PhaseSniffing> createState() => _PhaseSniffingState();
}

class _PhaseSniffingState extends State<_PhaseSniffing> {
  late final void Function() _stop;

  @override
  void initState() {
    super.initState();
    // ignore: rill_lint/rill_effect_in_lifecycle
    _stop = effect(() => widget.source.value, (v, _, _) {
      final phase = SchedulerBinding.instance.schedulerPhase;
      if (phase == SchedulerPhase.idle ||
          phase == SchedulerPhase.postFrameCallbacks) {
        widget.out.value = v;
      } else {
        SchedulerBinding.instance.addPostFrameCallback(
          (_) => widget.out.value = v,
        );
      }
    });
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

/// The same region on ReactiveState: it writes unconditionally.
class _Region extends StatefulWidget {
  const _Region(this.source, this.out, {this.log});
  final Readable<int> source;
  final Signal<int> out;
  final List<String>? log;
  @override
  State<_Region> createState() => _RegionState();
}

class _RegionState extends State<_Region> with ReactiveState {
  @override
  void initState() {
    super.initState();
    watch(() => widget.source.value, (v, previous, onCleanup) {
      final building = WidgetsBinding.instance.buildOwner!.debugBuilding;
      widget.log?.add('apply $v $previous building=$building');
      widget.out.value = v;
      onCleanup(() => widget.log?.add('cleanup $v'));
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

/// runApp's bootstrap in a test: the binding already has a root, so
/// attachRootWidget only marks it dirty; building it here is the
/// synchronous, idle-phase first build runApp performs.
void _mountLikeRunApp(WidgetTester tester, Widget app) {
  tester.binding.attachRootWidget(tester.binding.wrapWithDefaultView(app));
  expect(SchedulerBinding.instance.schedulerPhase, SchedulerPhase.idle);
  tester.binding.buildOwner!.buildScope(tester.binding.rootElement!);
}

void main() {
  final errors = <Object>[];
  setUp(() {
    errors.clear();
    Rill.onError = (error, _) => errors.add(error);
  });
  tearDown(() => Rill.onError = null);

  group('the phase-sniffing pattern by mount path', () {
    testWidgets('pumpWidget builds in a frame: the guard never sees it', (
      tester,
    ) async {
      final out = signal(0);
      await tester.pumpWidget(_guarded(child: _PhaseSniffing(signal(1), out)));
      expect(errors, isEmpty);
      expect(out.peek(), 1);
    });

    testWidgets('attachRootWidget alone defers the build to the next pump', (
      tester,
    ) async {
      final out = signal(0);
      tester.binding.attachRootWidget(
        tester.binding.wrapWithDefaultView(
          _guarded(child: _PhaseSniffing(signal(1), out)),
        ),
      );
      expect(find.byType(_PhaseSniffing), findsNothing);
      await tester.pump();
      expect(errors, isEmpty);
      expect(out.peek(), 1);
    });

    testWidgets('runApp-like synchronous mount: the guard fires and reports', (
      tester,
    ) async {
      final out = signal(0);
      _mountLikeRunApp(tester, _guarded(child: _PhaseSniffing(signal(1), out)));
      expect(errors.single.toString(), contains('RILL_WRITE_DURING_FRAME'));
      expect(out.peek(), 0, reason: 'the guarded write is not installed');
    });

    testWidgets('without Rill.onError the error reaches the zone', (
      tester,
    ) async {
      Rill.onError = null;
      final out = signal(0);
      final zoneErrors = <Object>[];
      await runZonedGuarded(
        () async => _mountLikeRunApp(
          tester,
          _guarded(child: _PhaseSniffing(signal(1), out)),
        ),
        (error, _) => zoneErrors.add(error),
      );
      expect(zoneErrors.single.toString(), contains('RILL_WRITE_DURING_FRAME'));
    });
  });

  group('ReactiveState.watch', () {
    testWidgets('runApp-like mount: first apply after the frame, no error', (
      tester,
    ) async {
      final out = signal(0);
      final log = <String>[];
      _mountLikeRunApp(tester, _Region(signal(1), out, log: log));
      expect(log, isEmpty);
      expect(out.peek(), 0);
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump();
      expect(log, ['apply 1 null building=false']);
      expect(errors, isEmpty);
      expect(out.peek(), 1);
    });

    testWidgets('pumpWidget: the first apply runs in the same frame', (
      tester,
    ) async {
      final out = signal(0);
      final log = <String>[];
      await tester.pumpWidget(_Region(signal(1), out, log: log));
      expect(log, ['apply 1 null building=false']);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('compute tracks from mount; later applies are synchronous', (
      tester,
    ) async {
      final source = signal(1);
      final out = signal(0);
      final log = <String>[];
      _mountLikeRunApp(tester, _Region(source, out, log: log));
      source.value = 2; // before the frame: replaces the held value
      await tester.pump();
      expect(log, ['apply 2 null building=false']);
      source.value = 3;
      expect(log.skip(1), ['cleanup 2', 'apply 3 2 building=false']);
      expect(out.peek(), 3);
    });

    testWidgets('disposing the State stops its effects and runs cleanup', (
      tester,
    ) async {
      final source = signal(1);
      final log = <String>[];
      await tester.pumpWidget(_Region(source, signal(0), log: log));
      await tester.pumpWidget(const SizedBox());
      expect(log.last, 'cleanup 1');
      source.value = 2;
      expect(log, hasLength(2));
    });

    testWidgets('unmounted before the frame: the first apply never runs', (
      tester,
    ) async {
      final log = <String>[];
      _mountLikeRunApp(tester, _Region(signal(1), signal(0), log: log));
      tester.binding.attachRootWidget(
        tester.binding.wrapWithDefaultView(const SizedBox()),
      );
      await tester.pump();
      expect(log, isEmpty);
    });

    testWidgets('re-created in didUpdateWidget, it starts over', (
      tester,
    ) async {
      final a = signal(1), b = signal(5);
      final log = <String>[];
      await tester.pumpWidget(_Rebinding(a, log));
      await tester.pumpWidget(_Rebinding(b, log));
      expect(log, ['open 1 null', 'open 5 null']);
      b.value = 6;
      a.value = 2;
      expect(log, ['open 1 null', 'open 5 null', 'open 6 5']);
      expect(errors, isEmpty);
    });

    testWidgets('created while idle, it asks for the frame it waits on', (
      tester,
    ) async {
      final key = GlobalKey<_LateState>();
      final applied = <int>[];
      await tester.pumpWidget(_Late(key: key, applied: applied));
      expect(tester.binding.hasScheduledFrame, isFalse);
      key.currentState!.start(signal(4));
      expect(applied, isEmpty);
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump();
      expect(applied, [4]);
    });

    testWidgets('a constant input applies once', (tester) async {
      final out = signal(0);
      final log = <String>[];
      await tester.pumpWidget(_Region(Readable.constant(7), out, log: log));
      expect((log.single, out.peek()), ('apply 7 null building=false', 7));
    });
  });
}

/// A popup's shape: the effect follows a widget input the parent swaps.
class _Rebinding extends StatefulWidget {
  const _Rebinding(this.open, this.log);
  final Readable<int> open;
  final List<String> log;
  @override
  State<_Rebinding> createState() => _RebindingState();
}

class _RebindingState extends State<_Rebinding> with ReactiveState {
  void Function()? _stop;

  @override
  void initState() {
    super.initState();
    _watch();
  }

  @override
  void didUpdateWidget(_Rebinding old) {
    super.didUpdateWidget(old);
    if (!identical(old.open, widget.open)) _watch();
  }

  void _watch() {
    _stop?.call();
    final open = widget.open;
    _stop = watch(() => open.value, (v, previous, _) {
      widget.log.add('open $v $previous');
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

/// Starts a watch on demand, outside any build.
class _Late extends StatefulWidget {
  const _Late({super.key, required this.applied});
  final List<int> applied;
  @override
  State<_Late> createState() => _LateState();
}

class _LateState extends State<_Late> with ReactiveState {
  void start(Readable<int> source) => watch(() => source.value, (v, _, _) {
    widget.applied.add(v);
  });

  @override
  Widget build(BuildContext context) => const SizedBox();
}

/// Installs the debug guards a RillScope used to install.
Widget _guarded({required Widget child}) {
  debugInstallRillGuards(WidgetsBinding.instance.buildOwner!);
  return child;
}
