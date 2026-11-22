// The checks below exercise untracked reads on purpose.
// ignore_for_file: rill_lint/rill_untracked_read
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

import 'budget_test.dart' show page;

Matcher _untracked(String phase) => isA<FlutterError>().having(
  (e) => e.toString(),
  'message',
  allOf(
    contains('RILL_UNTRACKED_READ'),
    contains('during $phase'),
    contains('diagnostics_test.dart'),
    contains('peek()'),
    contains('untracked('),
  ),
);

void main() {
  // Mounting a Reactive installs the guards for the test's BuildOwner.
  Widget guarded(Widget child) => page(Reactive(builder: (_) => child));

  group('G1 / G2 / G3 read guard', () {
    testWidgets('untracked_read_in_plain_build_throws', (tester) async {
      final data = signal(42, name: 'sample');
      await tester.pumpWidget(
        guarded(Builder(builder: (_) => Text('${data.value}'))),
      );
      expect(tester.takeException(), _untracked('build'));
    });

    testWidgets('untracked_read_in_list_item_builder_throws', (tester) async {
      final data = signal(1, name: 'item');
      await tester.pumpWidget(
        guarded(
          ListView.builder(
            itemCount: 1,
            itemBuilder: (_, _) => Text('${data.value}'),
          ),
        ),
      );
      expect(tester.takeException(), _untracked('build'));
    });

    testWidgets('untracked_read_in_layout_throws', (tester) async {
      final data = signal(1, name: 'width');
      final errors = <Object>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details.exception);
      try {
        await tester.pumpWidget(
          guarded(
            CustomSingleChildLayout(
              delegate: _ReadingLayout(data),
              child: const SizedBox(),
            ),
          ),
        );
      } finally {
        FlutterError.onError = previous;
      }
      // The failed layout reports follow-up errors; the read is the first.
      expect(errors.first, _untracked('layout'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('untracked_read_in_plain_paint_throws', (tester) async {
      final data = signal(1, name: 'color');
      await tester.pumpWidget(
        guarded(
          CustomPaint(size: const Size(10, 10), painter: _ReadingPainter(data)),
        ),
      );
      expect(tester.takeException(), _untracked('paint'));
    });

    testWidgets('peek_in_frame_is_allowed / untracked_in_frame_is_allowed', (
      tester,
    ) async {
      final data = signal(7);
      await tester.pumpWidget(
        guarded(
          Column(
            children: [
              Builder(builder: (_) => Text('peek ${data.peek()}')),
              Builder(
                builder: (_) =>
                    Text('untracked ${untracked(() => data.value)}'),
              ),
              Reactive(builder: (_) => Text('tracked ${data.value}')),
              ReactiveLayoutBuilder(
                builder: (_, _) => Text('adapter ${data.value}'),
              ),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(subscriberCount(data), 2);
      // Outside any frame phase the guard is silent.
      expect(data.value, 7);
    });

    testWidgets('read_in_did_update_widget_requires_peek', (tester) async {
      final data = signal(1, name: 'input');
      Widget tree(int round, {required bool peek}) => guarded(
        _LifecycleReader(
          round: round,
          read: () => peek ? data.peek() : data.value,
        ),
      );
      await tester.pumpWidget(tree(0, peek: true));
      await tester.pumpWidget(tree(1, peek: true));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(tree(2, peek: false));
      expect(tester.takeException(), _untracked('build'));
    });

    testWidgets('read_guard_and_write_guard_agree_on_phase', (tester) async {
      final data = signal(0, name: 'both');
      final seen = <String>[];
      void probe() {
        for (final (name, action) in [
          ('read', () => data.value),
          ('write', () => data.value = 1),
        ]) {
          try {
            action();
            seen.add('$name ok');
          } on FlutterError catch (error) {
            seen.add('$name ${error.message.split(':').first}');
          }
        }
      }

      await tester.pumpWidget(
        guarded(
          Builder(
            builder: (_) {
              probe();
              return CustomPaint(painter: _Probe(probe));
            },
          ),
        ),
      );
      expect(seen, [
        'read RILL_UNTRACKED_READ',
        'write RILL_WRITE_DURING_FRAME',
        'read RILL_UNTRACKED_READ',
        'write RILL_WRITE_DURING_FRAME',
      ]);
      seen.clear();
      probe();
      expect(seen, ['read ok', 'write ok']);
    });
  });

  testWidgets('build and layout writes fail before installation', (
    tester,
  ) async {
    final data = signal(0, name: 'illegal');
    for (final child in [
      Reactive(
        builder: (_) {
          data.value = 1;
          return const SizedBox();
        },
      ),
      LayoutBuilder(
        builder: (_, _) {
          data.value = 1;
          return const SizedBox();
        },
      ),
    ]) {
      await tester.pumpWidget(guarded(child));
      expect(
        tester.takeException().toString(),
        contains('RILL_WRITE_DURING_FRAME'),
      );
      expect(data.peek(), 0);
    }
  });

  testWidgets('diagnostics identify the write, dependency path and reader', (
    tester,
  ) async {
    final input = signal(0, name: 'count');
    final busy = computed(() => input.value > 0, name: 'busy');
    final paths = <String>[];
    diagnosticHook = (code, path) {
      if (code == 'RILL_REBUILD') paths.add(path!);
    };
    addTearDown(() => diagnosticHook = null);
    expect(nodeCreationLocation(input), isNotNull);
    expect(nodeCreationLocation(busy), isNotNull);
    await tester.pumpWidget(
      page(Reactive(builder: (_) => Text('${busy.value}'))),
    );
    input.value = 1;
    await tester.pump();
    expect(
      paths.single,
      contains('count @${nodeRevision(input)} → busy → Reactive'),
    );
  });

  testWidgets('paint writes fail before installation', (tester) async {
    final data = signal(0);
    await tester.pumpWidget(
      guarded(
        ReactivePaint(size: const Size(10, 10), painter: _WritingPainter(data)),
      ),
    );
    expect(
      tester.takeException().toString(),
      contains('RILL_WRITE_DURING_FRAME'),
    );
    expect(data.peek(), 0);
  });

  group('routes and overlays: Reactive in the builder', () {
    testWidgets('dialog_with_reactive_builder_tracks', (tester) async {
      final data = signal(0);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        page(
          Navigator(
            key: navigator,
            onGenerateRoute: (_) => PageRouteBuilder<void>(
              pageBuilder: (_, _, _) => const SizedBox(),
            ),
          ),
        ),
      );
      final shown = showGeneralDialog<void>(
        context: navigator.currentContext!,
        transitionDuration: Duration.zero,
        pageBuilder: (_, _, _) =>
            Reactive(builder: (_) => Text('dialog ${data.value}')),
      );
      await tester.pump();
      expect(find.text('dialog 0'), findsOneWidget);
      data.value = 1;
      await tester.pump();
      expect(find.text('dialog 1'), findsOneWidget);
      expect(subscriberCount(data), 1);
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump();
      await shown;
      expect(subscriberCount(data), 0);
    });

    testWidgets('overlay_entry_with_reactive_builder_tracks', (tester) async {
      final data = signal(0);
      final overlay = GlobalKey<OverlayState>();
      await tester.pumpWidget(
        page(Overlay(key: overlay, initialEntries: const [])),
      );
      final entry = OverlayEntry(
        builder: (_) => Reactive(builder: (_) => Text('overlay ${data.value}')),
      );
      overlay.currentState!.insert(entry);
      await tester.pump();
      data.value = 2;
      await tester.pump();
      expect(find.text('overlay 2'), findsOneWidget);
      entry
        ..remove()
        ..dispose();
      await tester.pump();
      expect(subscriberCount(data), 0);
    });
  });

  testWidgets('S1 an independent BuildOwner is covered by F4', (t) async {
    final s = signal(1);
    final o = BuildOwner(focusManager: FocusManager());
    Object? failure;
    RootWidget(
      child: Reactive(
        builder: (_) => Builder(
          builder: (c) {
            expect(c.owner!.debugBuilding, true);
            try {
              s.value = 2;
            } on Object catch (error) {
              failure = error;
            }
            return const ViewCollection(views: []);
          },
        ),
      ),
    ).attach(o);
    expect(s.peek(), 1);
    expect(failure.toString(), contains('RILL_WRITE_DURING_FRAME'));
  });
}

class _WritingPainter extends ReactivePainter {
  _WritingPainter(this.data);
  final Signal<int> data;
  @override
  // ignore: rill_lint/rill_write_in_build
  void paint(Canvas canvas, Size size) => data.value = 1;
}

class _ReadingPainter extends CustomPainter {
  _ReadingPainter(this.data);
  final Readable<int> data;
  @override
  void paint(Canvas canvas, Size size) => data.value;
  @override
  bool shouldRepaint(_ReadingPainter oldDelegate) => false;
}

class _Probe extends CustomPainter {
  _Probe(this.probe);
  final void Function() probe;
  @override
  void paint(Canvas canvas, Size size) => probe();
  @override
  bool shouldRepaint(_Probe oldDelegate) => false;
}

class _ReadingLayout extends SingleChildLayoutDelegate {
  _ReadingLayout(this.data);
  final Readable<int> data;
  @override
  Size getSize(BoxConstraints constraints) => Size(data.value.toDouble(), 10);
  @override
  bool shouldRelayout(_ReadingLayout oldDelegate) => false;
}

class _LifecycleReader extends StatefulWidget {
  const _LifecycleReader({required this.round, required this.read});
  final int round;
  final int Function() read;
  @override
  State<_LifecycleReader> createState() => _LifecycleReaderState();
}

class _LifecycleReaderState extends State<_LifecycleReader> {
  @override
  void didUpdateWidget(_LifecycleReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.read();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
