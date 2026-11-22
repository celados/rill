// Ownership in the binding: one reactive owner per component, visibility as
// a query, and regressions for element hosts, visibility and motion.
// ignore_for_file: invalid_use_of_protected_member
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

import 'budget_test.dart' show page;

final class _Store {
  final count = signal(1);
  late final doubled = computed(() => count.value * 2, name: 'doubled');
}

// Not the build method itself: rill_create_in_build would flag the call.
Readable<int?> _lingerOf(Readable<int?> source) =>
    linger(source, const Duration(seconds: 1));
Scope _scopeOf() => Scope(name: 'made in build');

bool _tickerListened(BuildContext context) =>
    (TickerMode.getValuesNotifier(context) as ChangeNotifier).hasListeners;

void main() {
  group('O1 / O2 derived nodes and builds own nothing', () {
    testWidgets('late_final_computed_survives_first_reader', (t) async {
      final store = _Store();
      await t.pumpWidget(
        page(Reactive(builder: (_) => Text('${store.doubled.value}'))),
      );
      await t.pumpWidget(const SizedBox());
      expect(store.doubled.peek(), 2);
    });

    testWidgets('linger_created_in_build_survives_its_creator', (t) async {
      final source = signal<int?>(1);
      Readable<int?>? made;
      await t.pumpWidget(
        page(
          Reactive(
            builder: (_) => Text('${(made ??= _lingerOf(source)).value}'),
          ),
        ),
      );
      await t.pumpWidget(const SizedBox());
      expect(made!.peek(), 1);
    });

    testWidgets('linger_timer_stops_when_unobserved', (t) async {
      final source = signal<int?>(1);
      final late = linger(source, const Duration(seconds: 2));
      await t.pumpWidget(page(Reactive(builder: (_) => Text('${late.value}'))));
      source.value = null;
      expect(activeBindingTimerCount, 1);
      await t.pumpWidget(const SizedBox());
      expect((activeBindingTimerCount, subscriberCount(source)), (0, 0));
    });

    testWidgets('computed_created_in_build_is_not_owned_by_element', (t) async {
      final source = signal(1);
      Computed<int>? made;
      await t.pumpWidget(
        page(
          Reactive(
            builder: (_) =>
                // The case under test creates in build on purpose.
                // ignore: rill_lint/rill_create_in_build
                Text('${(made ??= computed(() => source.value)).value}'),
          ),
        ),
      );
      await t.pumpWidget(const SizedBox());
      source.value = 4;
      expect(made!.value, 4);
    });

    testWidgets('scope_made_in_build_is_root', (t) async {
      Scope? made;
      await t.pumpWidget(
        page(
          Reactive(
            builder: (_) {
              made ??= _scopeOf();
              return const SizedBox();
            },
          ),
        ),
      );
      await t.pumpWidget(const SizedBox());
      expect(made!.disposed, isFalse);
      made!.dispose();
    });
  });

  group('one component owner: ReactiveState', () {
    testWidgets('reactive_stateful_with_reactive_state_has_one_scope / '
        'watch_owned_by_state_scope', (t) async {
      final source = signal(0);
      final key = GlobalKey<_OwnerState>();
      final seen = <int>[];
      await t.pumpWidget(page(_Owner(key, source, seen)));
      await t.pump();
      final state = key.currentState!;
      final scope = state.ownScope;
      source.value = 1;
      await t.pump();
      expect(state.ownScope, same(scope), reason: 'rebuilds keep it');
      expect(seen, [0, 1]);
      expect(state.builds, 2);
      await t.pumpWidget(const SizedBox());
      expect(scope.disposed, isTrue);
      expect(subscriberCount(source), 0);
    });
  });

  group('V1 / V2 visibility is a query', () {
    testWidgets('tickermode_flip_rebuilds_no_reader', (t) async {
      final data = signal(1);
      var builds = 0;
      final reader = Reactive(
        builder: (_) {
          builds++;
          return Text('${data.peek()}');
        },
      );
      Widget tree(bool on) => page(TickerMode(enabled: on, child: reader));
      await t.pumpWidget(tree(true));
      await t.pumpWidget(tree(false));
      await t.pumpWidget(tree(true));
      expect(builds, 1);
    });

    testWidgets('tickermode_flip_pauses_pulse_without_rebuild', (t) async {
      final wall = Pulse.every(const Duration(seconds: 1));
      var builds = 0;
      final reader = Reactive(
        builder: (_) {
          builds++;
          return Text('${wall.value.second}');
        },
      );
      Widget tree(bool on) => page(TickerMode(enabled: on, child: reader));
      await t.pumpWidget(tree(true));
      expect(activePulseCount, 1);
      await t.pumpWidget(tree(false));
      expect((activePulseCount, builds), (0, 1));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('reader_without_time_source_has_no_visibility_listener', (
      t,
    ) async {
      final data = signal(1);
      final wall = Pulse.every(const Duration(seconds: 1));
      late BuildContext plain, timed;
      await t.pumpWidget(
        page(
          Column(
            children: [
              TickerMode(
                enabled: true,
                child: Reactive(
                  builder: (context) {
                    plain = context;
                    return Text('${data.value}');
                  },
                ),
              ),
              TickerMode(
                enabled: true,
                child: Reactive(
                  builder: (context) {
                    timed = context;
                    return Text('${wall.value.second}');
                  },
                ),
              ),
            ],
          ),
        ),
      );
      expect(_tickerListened(plain), isFalse);
      expect(_tickerListened(timed), isTrue);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('reduce_motion_dependency_only_for_decorative_pulse', (
      t,
    ) async {
      final wall = Pulse.every(const Duration(seconds: 1));
      final phase = Pulse.phase(const Duration(seconds: 1));
      var wallBuilds = 0, phaseBuilds = 0;
      final readers = Column(
        children: [
          Reactive(
            builder: (_) {
              wallBuilds++;
              return Text('${wall.value.second}');
            },
          ),
          Reactive(
            builder: (_) {
              phaseBuilds++;
              return Text(phase.value.toStringAsFixed(1));
            },
          ),
        ],
      );
      Widget tree(bool reduced) => page(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: readers,
        ),
      );
      await t.pumpWidget(tree(false));
      expect(activePulseCount, 2);
      await t.pumpWidget(tree(true));
      expect(activePulseCount, 1);
      expect(wallBuilds, 1, reason: 'no MediaQuery dependency');
      expect(phaseBuilds, 2, reason: 'the aspect it asked for');
      await t.pumpWidget(const SizedBox());
    });
  });

  group('hosts, visibility and initState reads', () {
    testWidgets(
      'globalkey_move_of_a_reactive_without_inherited_dependencies_keeps_tracking',
      (t) async {
        final s = signal(1);
        final key = GlobalKey();
        final subtree = RepaintBoundary(
          key: key,
          child: Reactive(builder: (_) => Text('v=${s.value}')),
        );
        Widget tree(bool left) => page(
          Row(
            children: [
              Center(child: left ? subtree : null),
              Center(child: left ? null : subtree),
            ],
          ),
        );
        await t.pumpWidget(tree(true));
        await t.pumpWidget(tree(false));
        expect(subscriberCount(s), 1);
        s.value = 2;
        await t.pump();
        expect(find.text('v=2'), findsOneWidget);
      },
    );

    testWidgets(
      'tickermode_resume_shows_the_calibrated_pulse_in_the_same_frame',
      (t) async {
        final wall = Pulse.every(const Duration(seconds: 1));
        var builds = 0;
        Widget reader() => Reactive(
          builder: (_) {
            builds++;
            return Text('${wall.value.millisecondsSinceEpoch ~/ 1000}');
          },
        );
        // The same reader instances: only the host wake-up can rebuild them.
        final readers = Column(children: [reader(), reader()]);
        Widget tree(bool on) => page(TickerMode(enabled: on, child: readers));
        await t.pumpWidget(tree(false));
        expect(activePulseCount, 0);
        builds = 0;
        await t.pump(const Duration(seconds: 3));
        // One pump, as a route pop flips TickerMode: both readers show the
        // calibrated second in this frame and no extra frame is scheduled.
        await t.pumpWidget(tree(true));
        final now = '${clock.now().millisecondsSinceEpoch ~/ 1000}';
        expect(find.text(now), findsNWidgets(2));
        expect(builds, 2);
        expect(t.binding.hasScheduledFrame, isFalse);
        await t.pumpWidget(const SizedBox());
      },
    );

    testWidgets('pending_query_reading_a_pulse_follows_tickermode', (t) async {
      final wall = Pulse.every(const Duration(seconds: 1));
      final gate = Completer<int>();
      final q = computedAsync((_) {
        wall.value;
        return gate.future;
      });
      Widget tree(bool on) => page(
        TickerMode(
          enabled: on,
          child: Reactive(builder: (_) => Text('${q.value.valueOrNull}')),
        ),
      );
      await t.pumpWidget(tree(false));
      await t.pump();
      expect(subscriberCount(wall), greaterThan(0));
      expect(activePulseCount, 0, reason: 'its only reader is hidden');
      await t.pumpWidget(tree(true));
      expect(activePulseCount, 1);
      await t.pumpWidget(const SizedBox());
      gate.complete(0);
      await t.pump();
    });

    testWidgets('equal_computed_switching_into_a_pulse_follows_tickermode', (
      t,
    ) async {
      final wall = Pulse.every(const Duration(seconds: 1));
      final flag = signal(false);
      final year = clock.now().year;
      final c = computed(() => flag.value ? wall.value.year : year);
      var builds = 0;
      await t.pumpWidget(
        page(
          TickerMode(
            enabled: false,
            child: Reactive(
              builder: (_) {
                builds++;
                return Text('${c.value}');
              },
            ),
          ),
        ),
      );
      flag.value = true;
      await t.pump();
      expect(subscriberCount(wall), 1);
      expect((activePulseCount, builds), (0, 1));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('reduce_motion_flip_stops_a_painter_phase', (t) async {
      final phase = Pulse.phase(const Duration(milliseconds: 100));
      final painter = _PhasePainter(phase);
      // The same ReactivePaint instance: its slot keeps its delegate and
      // the render object does not repaint on the MediaQuery change.
      final paint = RepaintBoundary(
        child: ReactivePaint(painter: painter, size: const Size(4, 4)),
      );
      Widget tree(bool reduced) => page(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: paint,
        ),
      );
      await t.pumpWidget(tree(false));
      expect(activePulseCount, 1);
      final paints = painter.paints;
      await t.pumpWidget(tree(true));
      expect(activePulseCount, 0);
      expect(painter.paints, paints);
      await t.pumpWidget(tree(false));
      expect(activePulseCount, 1);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('reduce_motion_flip_stops_a_reader_phase', (t) async {
      final phase = Pulse.phase(const Duration(milliseconds: 100));
      final reader = Reactive(
        builder: (_) => Text(phase.value.toStringAsFixed(2)),
      );
      Widget tree(bool reduced) => page(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: reader,
        ),
      );
      await t.pumpWidget(tree(false));
      expect(activePulseCount, 1);
      await t.pumpWidget(tree(true));
      expect(activePulseCount, 0);
      await t.pumpWidget(tree(false));
      expect(activePulseCount, 1);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('slot_run_started_in_init_state_reads_untracked', (t) async {
      final flag = signal(42, name: 'store.flag');
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot();
      Future<Outcome<int>>? run;
      await t.pumpWidget(
        guarded(
          _InitState(
            () => run = slot.run((_) async {
              final v = flag.value;
              await Future<void>.value();
              return v;
            }),
          ),
        ),
      );
      expect(t.takeException(), isNull);
      expect(await run, isA<Done<int>>());
    });

    testWidgets('effect_apply_in_init_state_reads_untracked', (t) async {
      final a = signal(1, name: 'a'), b = signal(2, name: 'b');
      void Function()? stop;
      await t.pumpWidget(
        guarded(
          _InitState(
            // ignore: rill_lint/rill_effect_in_lifecycle
            () => stop = effect(() => a.value, (_, _, _) => b.value),
          ),
        ),
      );
      expect(t.takeException(), isNull);
      stop!();
    });

    testWidgets('async_helper_from_init_state_throws_with_untracked_advice', (
      t,
    ) async {
      final flag = signal(1, name: 'store.flag');
      Future<void> load() async {
        if (flag.value > 0) await Future<void>.value();
      }

      Object? error;
      await t.pumpWidget(
        guarded(_InitState(() => load().catchError((Object e) => error = e))),
      );
      await t.pump();
      expect(error.toString(), contains('untracked('));
      error = null;
      await t.pumpWidget(
        guarded(
          _InitState(
            key: UniqueKey(),
            () => untracked(load).catchError((Object e) => error = e),
          ),
        ),
      );
      await t.pump();
      expect(error, isNull);
    });

    testWidgets(
      'decorative_pulse_entered_outside_build_follows_reduce_motion',
      (t) async {
        final phase = Pulse.phase(const Duration(milliseconds: 100));
        final flag = signal(false);
        final c = computed(() => flag.value ? phase.value >= 0 : true);
        final reader = Reactive(builder: (_) => Text('${c.value}'));
        Widget tree(bool reduced) => page(
          MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: reader,
          ),
        );
        await t.pumpWidget(tree(true));
        // The motion query and its MediaQuery dependency happen outside
        // build, while the switch reconciles the source.
        flag.value = true;
        await t.pump();
        expect((subscriberCount(phase), activePulseCount), (1, 0));
        expect(t.takeException(), isNull);
        await t.pumpWidget(tree(false));
        expect(activePulseCount, 1);
        await t.pumpWidget(const SizedBox());
      },
    );
  });

  group('motion readers and painter hosts', () {
    // Readers of one Pulse under one MediaQuery: the source stops asking at
    // the first visible reader, so the second has never asked for motion
    // and is not a MediaQuery dependent. The flip notifies the first, whose
    // reconciliation then asks the second. Inside
    // InheritedElement.notifyClients that inserted into the map being
    // iterated (ConcurrentModificationError).
    Future<void> flipWithTwoReaders(
      WidgetTester t,
      Widget Function(Readable<double> fast, Readable<double> slow) readers, {
      int sources = 1,
    }) async {
      final fast = Pulse.phase(const Duration(milliseconds: 100));
      final slow = Pulse.phase(const Duration(milliseconds: 250));
      final body = readers(fast, slow);
      Widget tree(bool reduced) => page(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: body,
        ),
      );
      await t.pumpWidget(tree(false));
      expect(activePulseCount, sources);
      await t.pumpWidget(tree(true));
      expect(t.takeException(), isNull);
      // Reconciled within the flip's frame: no frame is left to finish it.
      expect(activePulseCount, 0);
      expect(t.binding.hasScheduledFrame, isFalse);
      await t.pumpWidget(tree(false));
      expect(t.takeException(), isNull);
      expect(activePulseCount, sources);
      await t.pumpWidget(const SizedBox());
    }

    testWidgets('reduce_motion_flip_with_two_reactive_readers', (t) async {
      await flipWithTwoReaders(
        t,
        (phase, _) => Column(
          children: [
            Reactive(builder: (_) => Text('a ${phase.value}')),
            Reactive(builder: (_) => Text('b ${phase.value}')),
          ],
        ),
      );
    });

    testWidgets('reduce_motion_flip_with_a_reactive_and_a_painter', (t) async {
      await flipWithTwoReaders(
        t,
        (phase, _) => Column(
          children: [
            Reactive(builder: (_) => Text('a ${phase.value}')),
            RepaintBoundary(
              child: ReactivePaint(
                painter: _PhasePainter(phase),
                size: const Size(4, 4),
              ),
            ),
          ],
        ),
      );
    });

    testWidgets('reduce_motion_flip_with_two_reactive_stateful_widgets', (
      t,
    ) async {
      await flipWithTwoReaders(
        t,
        (phase, _) =>
            Column(children: [_PhaseReader(phase), _PhaseReader(phase)]),
      );
    });

    testWidgets('reduce_motion_flip_with_readers_of_two_periods', (t) async {
      // The first reader answers for both periods; the second, reading
      // only the slow one, is first asked by the slow source.
      await flipWithTwoReaders(
        t,
        sources: 2,
        (fast, slow) => Column(
          children: [
            Reactive(builder: (_) => Text('a ${fast.value} ${slow.value}')),
            Reactive(builder: (_) => Text('b ${slow.value}')),
          ],
        ),
      );
    });

    testWidgets('reactive_paint_alone_guards_its_build_owner', (t) async {
      final s = signal(1);
      final owner = BuildOwner(focusManager: FocusManager());
      Object? failure;
      // No View under RootWidget: the render tree cannot attach. Only the
      // read guard matters here.
      final onError = FlutterError.onError;
      FlutterError.onError = (_) {};
      try {
        RootWidget(
          child: ReactivePaint(
            painter: _NoopPainter(),
            child: Builder(
              builder: (_) {
                try {
                  s.value;
                } on Object catch (error) {
                  failure = error;
                }
                return const SizedBox();
              },
            ),
          ),
        ).attach(owner);
      } finally {
        FlutterError.onError = onError;
      }
      expect(failure.toString(), contains('RILL_UNTRACKED_READ'));
    });

    testWidgets('painter_without_semantics_does_not_rebuild_semantics', (
      t,
    ) async {
      Future<bool> rebuilds(ReactivePainter Function() make) async {
        await t.pumpWidget(page(ReactivePaint(painter: make())));
        final render = t.renderObject<RenderCustomPaint>(
          find.byType(CustomPaint),
        );
        final old = render.painter!;
        await t.pumpWidget(page(ReactivePaint(painter: make())));
        return render.painter!.shouldRebuildSemantics(old);
      }

      expect(await rebuilds(_NoopPainter.new), isFalse);
      expect(await rebuilds(_LabelPainter.new), isTrue);
    });
  });
}

// Mounting a Reactive installs the guards for the test's BuildOwner.
Widget guarded(Widget child) => page(Reactive(builder: (_) => child));

class _InitState extends StatefulWidget {
  const _InitState(this.run, {super.key});
  final void Function() run;
  @override
  State<_InitState> createState() => _InitStateState();
}

class _InitStateState extends State<_InitState> {
  @override
  void initState() {
    super.initState();
    widget.run();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _Owner extends ReactiveStatefulWidget {
  const _Owner(GlobalKey<_OwnerState> key, this.source, this.seen)
    : super(key: key);
  final Signal<int> source;
  final List<int> seen;
  @override
  State<_Owner> createState() => _OwnerState();
}

class _OwnerState extends State<_Owner> with ReactiveState {
  var builds = 0;
  Scope get ownScope => scope;

  @override
  void initState() {
    super.initState();
    watch(() => widget.source.value, (v, _, _) => widget.seen.add(v));
  }

  @override
  Widget build(BuildContext context) {
    builds++;
    return Text('${widget.source.value}');
  }
}

class _PhasePainter extends ReactivePainter {
  _PhasePainter(this.phase);
  final Readable<double> phase;
  var paints = 0;
  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    phase.value;
  }
}

class _NoopPainter extends ReactivePainter {
  @override
  void paint(Canvas canvas, Size size) {}
}

class _LabelPainter extends ReactivePainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  SemanticsBuilderCallback? get semanticsBuilder =>
      (size) => [
        CustomPainterSemantics(
          rect: Offset.zero & size,
          properties: SemanticsProperties(
            label: 'dot',
            textDirection: TextDirection.ltr,
          ),
        ),
      ];
}

class _PhaseReader extends ReactiveStatefulWidget {
  const _PhaseReader(this.phase);
  final Readable<double> phase;
  @override
  State<_PhaseReader> createState() => _PhaseReaderState();
}

class _PhaseReaderState extends State<_PhaseReader> {
  @override
  Widget build(BuildContext context) => Text('${widget.phase.value}');
}
