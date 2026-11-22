import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

import 'budget_test.dart' show Frames, page;

/// Counts its paints.
class _Counted extends CustomPainter {
  int paints = 0;
  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRect(Offset.zero & size, Paint());
  }

  @override
  bool shouldRepaint(_Counted old) => false;
}

/// Counts its builds and paints, and is a labelled semantics node.
class _Child extends StatelessWidget {
  const _Child(this.painter, this.builds);
  final _Counted painter;
  final List<int> builds;

  @override
  Widget build(BuildContext context) {
    builds[0]++;
    return Semantics(
      label: 'child',
      container: true,
      child: GestureDetector(
        onTap: () => builds[1]++,
        child: CustomPaint(size: const Size(100, 50), painter: painter),
      ),
    );
  }
}

void main() {
  testWidgets('F13 opacity: a change updates the layer only; crossing zero '
      'drops paint and semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    final opacity = signal(0.5);
    final painter = _Counted();
    final counts = [0, 0];
    final frames = Frames(tester);
    await tester.pumpWidget(
      page(
        Align(
          alignment: Alignment.topLeft,
          child: ReactiveOpacity(
            opacity: opacity,
            child: _Child(painter, counts),
          ),
        ),
      ),
    );
    final render = tester.renderObject<RenderReactiveOpacity>(
      find.byType(ReactiveOpacity),
    );
    expect(subscriberCount(opacity), 1);
    final before = (frames.count, counts[0], painter.paints);

    for (var i = 1; i <= 10; i++) {
      opacity.value = 0.5 + i / 40;
      await tester.pump();
    }
    expect(render.opacity, closeTo(0.75, 1e-9));
    expect((render.debugLayer! as OpacityLayer).alpha, (0.75 * 255).round());
    expect(
      (frames.count, counts[0], painter.paints),
      (before.$1 + 10, before.$2, before.$3),
      reason: '10 frames, no build, no paint below',
    );
    expect(find.semantics.byLabel('child'), findsOne);

    opacity.value = 0;
    await tester.pump();
    expect(find.semantics.byLabel('child'), findsNothing);
    final atZero = painter.paints;
    opacity.value = 0.4;
    await tester.pump();
    expect(find.semantics.byLabel('child'), findsOne);
    expect(painter.paints, atZero + 1, reason: 'repaints once leaving zero');
    expect(counts[0], before.$2);
    semantics.dispose();
  });

  testWidgets('F13 opacity policy across 1 → 0.5 → 0 → 1: hit testing is '
      'unchanged (as Opacity), semantics leave only at 0', (tester) async {
    final semantics = tester.ensureSemantics();
    final opacity = signal(1.0);
    final counts = [0, 0];
    await tester.pumpWidget(
      page(
        Align(
          alignment: Alignment.topLeft,
          child: ReactiveOpacity(
            opacity: opacity,
            child: _Child(_Counted(), counts),
          ),
        ),
      ),
    );
    final seen = <(double, int, bool)>[];
    for (final value in [1.0, 0.5, 0.0, 1.0]) {
      opacity.value = value;
      await tester.pump();
      await tester.tapAt(const Offset(50, 25));
      seen.add((
        value,
        counts[1],
        find.semantics.byLabel('child').evaluate().isNotEmpty,
      ));
    }
    expect(seen, [
      (1.0, 1, true),
      (0.5, 2, true),
      (0.0, 3, false),
      (1.0, 4, true),
    ]);
    semantics.dispose();
  });

  testWidgets('F13 opacity keeps semantics at zero when asked', (tester) async {
    final semantics = tester.ensureSemantics();
    final opacity = signal(0.0);
    await tester.pumpWidget(
      page(
        ReactiveOpacity(
          opacity: opacity,
          alwaysIncludeSemantics: true,
          child: _Child(_Counted(), [0, 0]),
        ),
      ),
    );
    expect(find.semantics.byLabel('child'), findsOne);
    semantics.dispose();
  });

  testWidgets('F13 transform: a translation moves the layer, hit tests and '
      'semantics bounds, without build, layout or paint below', (tester) async {
    final semantics = tester.ensureSemantics();
    final offset = signal(Offset.zero);
    final painter = _Counted();
    final counts = [0, 0];
    var layouts = 0;
    final frames = Frames(tester);
    await tester.pumpWidget(
      page(
        Align(
          alignment: Alignment.topLeft,
          child: ReactiveTransform.translate(
            offset: offset,
            child: LayoutBuilder(
              builder: (_, _) {
                layouts++;
                return _Child(painter, counts);
              },
            ),
          ),
        ),
      ),
    );
    final render = tester.renderObject<RenderReactiveTransform>(
      find.byType(ReactiveTransform),
    );
    final before = (frames.count, counts[0], layouts, painter.paints);
    for (var i = 1; i <= 60; i++) {
      offset.value = Offset(0, i * 5.0);
      await tester.pump();
    }
    expect(
      (frames.count, counts[0], layouts, painter.paints),
      (before.$1 + 60, before.$2, before.$3, before.$4),
      reason: '60 frames, 0 build, 0 layout, 0 paint below',
    );
    expect(
      (render.debugLayer! as TransformLayer).transform,
      Matrix4.translationValues(0, 300, 0),
    );

    // Hit tests follow the matrix: the old place is empty, the new one hits.
    await tester.tapAt(const Offset(50, 25));
    expect(counts[1], 0);
    await tester.tapAt(const Offset(50, 325));
    expect(counts[1], 1);
    expect(tester.getRect(find.byType(CustomPaint).last).top, 300);

    // Semantics bounds follow too.
    final node = tester.getSemantics(find.bySemanticsLabel('child'));
    final global = MatrixUtils.transformRect(_toGlobal(node), node.rect);
    // In physical pixels: the root scales by the device pixel ratio.
    expect(global.top / tester.view.devicePixelRatio, 300);
    semantics.dispose();
  });

  testWidgets('F7 for composite readers: detach unsubscribes, re-attach syncs '
      'at once, a replaced source switches', (tester) async {
    final a = signal(const Offset(0, 10));
    final b = signal(const Offset(0, 90));
    final key = GlobalKey();
    Widget tree({required bool right, Readable<Offset>? source}) => page(
      Row(
        textDirection: TextDirection.ltr,
        children: [
          Center(
            child: right
                ? null
                : ReactiveTransform.translate(
                    key: key,
                    offset: source ?? a,
                    child: const MetaData(
                      behavior: HitTestBehavior.opaque,
                      child: SizedBox(width: 10, height: 10),
                    ),
                  ),
          ),
          Center(
            child: !right
                ? null
                : Builder(
                    builder: (_) {
                      // Moved between frames: detached here, input changes.
                      expect(subscriberCount(a), 0);
                      writeBindingSignal(a, const Offset(0, 39));
                      return ReactiveTransform.translate(
                        key: key,
                        offset: source ?? a,
                        child: const MetaData(
                          behavior: HitTestBehavior.opaque,
                          child: SizedBox(width: 10, height: 10),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
    await tester.pumpWidget(tree(right: false));
    final render = tester.renderObject<RenderReactiveTransform>(
      find.byType(ReactiveTransform),
    );
    expect(subscriberCount(a), 1);
    await tester.pumpWidget(tree(right: true));
    expect(
      tester.renderObject<RenderReactiveTransform>(
        find.byType(ReactiveTransform),
      ),
      same(render),
    );
    expect(subscriberCount(a), 1);
    expect(render.matrix, Matrix4.translationValues(0, 39, 0));
    expect((render.debugLayer! as TransformLayer).transform, render.matrix);
    // The first frame after re-attach hits at the value written while detached.
    final box = tester.getTopLeft(find.byKey(key));
    final hit = tester.hitTestOnBinding(box + const Offset(5, 44));
    expect(hit.path.any((entry) => entry.target is RenderMetaData), true);
    final miss = tester.hitTestOnBinding(box + const Offset(5, 5));
    expect(miss.path.any((entry) => entry.target is RenderMetaData), false);

    await tester.pumpWidget(
      page(
        ReactiveTransform.translate(
          key: key,
          offset: b,
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
    );
    expect((subscriberCount(a), subscriberCount(b)), (0, 1));
    expect(render.matrix, Matrix4.translationValues(0, 90, 0));
    final frames = Frames(tester);
    a.value = const Offset(0, 1);
    await tester.pump();
    expect(frames.count, 0, reason: 'the old source is not read');
    await tester.pumpWidget(const SizedBox());
    expect((subscriberCount(a), subscriberCount(b)), (0, 0));
  });

  testWidgets('F13 equal values are idle; a matrix source works', (
    tester,
  ) async {
    final scale = signal(1.0);
    final matrix = computed(
      () => Matrix4.diagonal3Values(scale.value, scale.value, 1),
    );
    await tester.pumpWidget(
      page(
        ReactiveTransform(
          transform: matrix,
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
    );
    final frames = Frames(tester);
    scale.value = 1.0;
    await tester.pump();
    expect(frames.count, 0);
    scale.value = 2;
    await tester.pump();
    expect(frames.count, 1);
    final render = tester.renderObject<RenderReactiveTransform>(
      find.byType(ReactiveTransform),
    );
    expect(render.matrix.getMaxScaleOnAxis(), 2);
  });
  group('F13 origin and alignment (v0.7.2)', () {
    // The child is 100 × 50 at (100, 100). Expected rects are global.
    const at = Offset(100, 100);

    Widget placed(Widget transform, {TextDirection? direction}) =>
        Directionality(
          textDirection: direction ?? TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: EdgeInsets.only(left: at.dx, top: at.dy),
              child: transform,
            ),
          ),
        );

    Matrix4 scale(double x, double y) => Matrix4.diagonal3Values(x, y, 1);

    final cases = <(String, AlignmentGeometry?, Offset?, Matrix4, Rect)>[
      (
        'dialog: scale 0.97 about the centre',
        Alignment.center,
        null,
        scale(0.97, 0.97),
        const Rect.fromLTRB(101.5, 100.75, 198.5, 149.25),
      ),
      (
        'popup below its anchor: scaleY 0.96 about the top edge',
        Alignment.topCenter,
        null,
        scale(1, 0.96),
        const Rect.fromLTRB(100, 100, 200, 148),
      ),
      (
        'popup above its anchor: scaleY 0.96 about the bottom edge',
        Alignment.bottomCenter,
        null,
        scale(1, 0.96),
        const Rect.fromLTRB(100, 102, 200, 150),
      ),
      (
        'origin alone: the centre in child coordinates',
        null,
        const Offset(50, 25),
        scale(0.5, 0.5),
        const Rect.fromLTRB(125, 112.5, 175, 137.5),
      ),
      (
        'origin is added to the alignment point',
        Alignment.topCenter,
        const Offset(0, 50),
        scale(1, 0.96),
        const Rect.fromLTRB(100, 102, 200, 150),
      ),
    ];

    for (final (name, alignment, origin, matrix, expected) in cases) {
      testWidgets('transform_origin_first_frame_corners: $name', (t) async {
        final semantics = t.ensureSemantics();
        await t.pumpWidget(
          placed(
            ReactiveTransform(
              transform: signal(matrix),
              alignment: alignment,
              origin: origin,
              child: _Child(_Counted(), [0, 0]),
            ),
          ),
        );
        // Layout: the child's four corners through applyPaintTransform.
        _expectCorners(_corners(t), expected);
        // Paint: the same corners through the composited layer.
        final render = t.renderObject<RenderReactiveTransform>(
          find.byType(ReactiveTransform),
        );
        final layer = render.debugLayer! as TransformLayer;
        _expectCorners([
          for (final p in _rectCorners(Offset.zero & render.size))
            layer.offset + MatrixUtils.transformPoint(layer.transform!, p),
        ], expected);
        // Semantics geometry.
        final node = t.getSemantics(find.bySemanticsLabel('child'));
        final global = MatrixUtils.transformRect(_toGlobal(node), node.rect);
        final dpr = t.view.devicePixelRatio;
        expect(
          Rect.fromLTRB(
            global.left / dpr,
            global.top / dpr,
            global.right / dpr,
            global.bottom / dpr,
          ),
          within(distance: 1e-6, from: expected),
        );
        semantics.dispose();
      });
    }

    testWidgets('transform_origin_hit_tests_about_the_alignment', (t) async {
      final counts = [0, 0];
      await t.pumpWidget(
        placed(
          ReactiveTransform(
            transform: signal(scale(0.5, 0.5)),
            alignment: Alignment.center,
            child: _Child(_Counted(), counts),
          ),
        ),
      );
      // Scaled about the centre: (125, 112.5)–(175, 137.5). About the top
      // left it would be (100, 100)–(150, 125).
      await t.tapAt(const Offset(110, 105));
      expect(counts[1], 0, reason: 'inside the unscaled box only');
      await t.tapAt(const Offset(170, 135));
      expect(counts[1], 1, reason: 'inside the box scaled about the centre');
    });

    testWidgets('transform_origin_directional_alignment_resolves_rtl', (
      t,
    ) async {
      final counts = [0, 0];
      var layouts = 0;
      final painter = _Counted();
      // The child keeps its own direction: its Semantics depends on the
      // ambient one and would repaint for its own reason.
      final child = Directionality(
        textDirection: TextDirection.ltr,
        child: LayoutBuilder(
          builder: (_, _) {
            layouts++;
            return _Child(painter, counts);
          },
        ),
      );
      final matrix = signal(scale(0.5, 0.5));
      Widget tree(TextDirection direction) => placed(
        direction: direction,
        ReactiveTransform(
          transform: matrix,
          alignment: AlignmentDirectional.centerStart,
          child: child,
        ),
      );
      await t.pumpWidget(tree(TextDirection.rtl));
      // Start is the right edge in RTL.
      _expectCorners(_corners(t), const Rect.fromLTRB(150, 112.5, 200, 137.5));
      await t.tapAt(const Offset(190, 130));
      expect(counts[1], 1);

      final before = (counts[0], layouts, painter.paints);
      await t.pumpWidget(tree(TextDirection.ltr));
      _expectCorners(_corners(t), const Rect.fromLTRB(100, 112.5, 150, 137.5));
      expect(
        (counts[0], layouts, painter.paints),
        before,
        reason: 'a new direction updates the render object only',
      );
    });

    testWidgets('transform_origin_alignment_change_updates_the_render_object_'
        'only', (t) async {
      final counts = [0, 0];
      var layouts = 0;
      final painter = _Counted();
      final child = LayoutBuilder(
        builder: (_, _) {
          layouts++;
          return _Child(painter, counts);
        },
      );
      final matrix = signal(scale(1, 0.96));
      Widget tree(Alignment alignment) => placed(
        ReactiveTransform(
          transform: matrix,
          alignment: alignment,
          child: child,
        ),
      );
      await t.pumpWidget(tree(Alignment.topCenter));
      _expectCorners(_corners(t), const Rect.fromLTRB(100, 100, 200, 148));
      final render = t.renderObject<RenderReactiveTransform>(
        find.byType(ReactiveTransform),
      );
      final before = (counts[0], layouts, painter.paints);

      // The popup flips to the other side of its anchor.
      await t.pumpWidget(tree(Alignment.bottomCenter));
      expect(
        t.renderObject<RenderReactiveTransform>(find.byType(ReactiveTransform)),
        same(render),
      );
      expect(
        (counts[0], layouts, painter.paints),
        before,
        reason: '0 build, 0 layout, 0 paint below',
      );
      _expectCorners(_corners(t), const Rect.fromLTRB(100, 102, 200, 150));
      final layer = render.debugLayer! as TransformLayer;
      _expectCorners([
        for (final p in _rectCorners(Offset.zero & render.size))
          layer.offset + MatrixUtils.transformPoint(layer.transform!, p),
      ], const Rect.fromLTRB(100, 102, 200, 150));
    });

    testWidgets('transform_origin_animation_is_0_build_0_layout', (t) async {
      final counts = [0, 0];
      var layouts = 0;
      final painter = _Counted();
      final s = signal(0.97);
      final frames = Frames(t);
      await t.pumpWidget(
        placed(
          ReactiveTransform(
            transform: computed(() => scale(s.value, s.value)),
            alignment: Alignment.center,
            child: LayoutBuilder(
              builder: (_, _) {
                layouts++;
                return _Child(painter, counts);
              },
            ),
          ),
        ),
      );
      final before = (frames.count, counts[0], layouts, painter.paints);
      for (var i = 1; i <= 30; i++) {
        s.value = 0.97 + 0.03 * i / 30;
        await t.pump();
        final half = Offset(50 * s.value, 25 * s.value);
        const centre = Offset(150, 125);
        _expectCorners(
          _corners(t),
          Rect.fromPoints(centre - half, centre + half),
        );
      }
      expect(
        (frames.count, counts[0], layouts, painter.paints),
        (before.$1 + 30, before.$2, before.$3, before.$4),
        reason: '30 frames, 0 build, 0 layout, 0 paint below',
      );
    });
  });
  group('F13 host', () {
    testWidgets('composite_host_guards_its_build_owner_on_activate', (t) async {
      // Like a reactive Element and a painter host, the composite host
      // installs the guards again when a GlobalKey move activates it. The
      // tree has no View, so no render object attaches and reads: the
      // Element is the only one that installs them (as for a painter host).
      final s = signal(1, name: 's');
      final key = GlobalKey();
      final opacity = signal(0.5);
      Object? failure;
      Widget tree(bool left, {bool read = false}) => page(
        Column(
          children: [
            if (left)
              Padding(
                padding: EdgeInsets.zero,
                child: ReactiveOpacity(key: key, opacity: opacity),
              )
            else
              SizedBox(
                child: ReactiveOpacity(key: key, opacity: opacity),
              ),
            Builder(
              builder: (_) {
                if (read) {
                  try {
                    s.value;
                  } on Object catch (error) {
                    failure = error;
                  }
                }
                return const SizedBox();
              },
            ),
          ],
        ),
      );
      // GlobalKey moves resolve in the binding's BuildOwner. Without a
      // View the render tree cannot attach; only the guards matter.
      final owner = t.binding.buildOwner!;
      final onError = FlutterError.onError;
      FlutterError.onError = (_) {};
      try {
        final root = RootWidget(child: tree(true)).attach(owner);
        bindingReadGuard = null;
        bindingWriteGuard = null;
        RootWidget(child: tree(false, read: true)).attach(owner, root);
        owner.buildScope(root);
        owner.finalizeTree();
        RootWidget(child: const SizedBox()).attach(owner, root);
        owner.buildScope(root);
        owner.finalizeTree();
      } finally {
        FlutterError.onError = onError;
      }
      expect(failure.toString(), contains('RILL_UNTRACKED_READ'));
    });

    testWidgets('composite_reader_pulse_follows_tickermode', (t) async {
      final phase = Pulse.phase(const Duration(milliseconds: 100));
      final opacity = computed(() => 0.5 + phase.value / 4);
      Widget tree(bool enabled) => page(
        TickerMode(
          enabled: enabled,
          child: ReactiveOpacity(opacity: opacity, child: const SizedBox()),
        ),
      );
      await t.pumpWidget(tree(true));
      expect(activePulseCount, 1);
      await t.pumpWidget(tree(false));
      expect(activePulseCount, 0, reason: 'hidden: the phase stops');
      await t.pumpWidget(tree(true));
      expect(activePulseCount, 1);
      await t.pumpWidget(const SizedBox());
      expect(activePulseCount, 0);
    });

    testWidgets(
      'composite_reader_phase_follows_reduced_motion_without_a_parent_rebuild',
      (t) async {
        // The same widget instance: only the dependency marks the Element.
        final phase = Pulse.phase(const Duration(milliseconds: 100));
        final reader = ReactiveOpacity(
          opacity: computed(() => 0.5 + phase.value / 4),
          child: const SizedBox(),
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
      },
    );

    testWidgets('composite_reader_phase_follows_reduced_motion', (t) async {
      final phase = Pulse.phase(const Duration(milliseconds: 100));
      final offset = computed(() => Offset(phase.value * 10, 0));
      Widget tree(bool reduced) => page(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: ReactiveTransform.translate(
            offset: offset,
            child: const SizedBox(),
          ),
        ),
      );
      await t.pumpWidget(tree(false));
      expect(activePulseCount, 1);
      await t.pumpWidget(tree(true));
      expect(activePulseCount, 0, reason: 'reduced motion stops a phase');
      expect(t.binding.hasScheduledFrame, isFalse);
      await t.pumpWidget(tree(false));
      expect(activePulseCount, 1);
      await t.pumpWidget(const SizedBox());
    });
  });
}

/// The semantics node's transform to the root.
Matrix4 _toGlobal(SemanticsNode node) {
  final m = Matrix4.identity();
  SemanticsNode? n = node;
  while (n != null) {
    final t = n.transform;
    if (t != null) m.leftMultiply(t);
    n = n.parent;
  }
  return m;
}

/// A rect's corners: top left, top right, bottom left, bottom right.
List<Offset> _rectCorners(Rect r) => [
  r.topLeft,
  r.topRight,
  r.bottomLeft,
  r.bottomRight,
];

/// The global corners of the child's painted box.
List<Offset> _corners(WidgetTester t) {
  final box = t.renderObject<RenderBox>(find.byType(CustomPaint).last);
  return [
    for (final p in _rectCorners(Offset.zero & box.size)) box.localToGlobal(p),
  ];
}

void _expectCorners(List<Offset> actual, Rect expected) {
  final want = _rectCorners(expected);
  for (var i = 0; i < 4; i++) {
    expect(
      actual[i],
      within(distance: 1e-6, from: want[i]),
      reason: 'corner $i',
    );
  }
}
