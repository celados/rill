import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

import 'budget_test.dart' show Frames, page;

// WidgetInput. Fixtures follow two raw widgets that need it: a listbox whose items
// are replaced in didUpdateWidget, and a sheet whose snap points and reduced
// motion are widget configuration.

Matcher _escaped(String fragment) => isA<FlutterError>().having(
  (e) => e.message,
  'message',
  allOf(contains('RILL_WIDGET_INPUT_ESCAPED'), contains(fragment)),
);

String get _phase => SchedulerBinding.instance.schedulerPhase.name;

// ---------------------------------------------------------------- listbox

typedef Item = ({String id, bool disabled});

/// A listbox controller in miniature: the focus order and the active
/// item are derived from the items it is handed, never written on change.
class ListboxController {
  ListboxController(this.items);

  final Readable<List<Item>> items;
  final highlighted = signal<String?>(null, name: 'listbox.highlighted');
  int orders = 0;

  late final Readable<List<String>> focusOrder = computed(() {
    orders++;
    return [
      for (final item in items.value)
        if (!item.disabled) item.id,
    ];
  }, name: 'listbox.focusOrder');

  /// The highlighted item, or the first enabled one once it is gone.
  late final Readable<String?> active = computed(() {
    final order = focusOrder.value;
    final current = highlighted.value;
    if (order.contains(current)) return current;
    return order.isEmpty ? null : order.first;
  }, name: 'listbox.active');
}

class RawListbox extends StatefulWidget {
  const RawListbox({super.key, required this.items, required this.log});
  final List<Item> items;
  final List<String> log;

  @override
  State<RawListbox> createState() => RawListboxState();
}

class RawListboxState extends State<RawListbox> with ReactiveState {
  late final WidgetInput<List<Item>> items = input(
    widget.items,
    equals: Equality.deep,
    name: 'listbox.items',
  );
  late final controller = ListboxController(items.readable);
  int builds = 0;

  /// Built once: a parent rebuild does not rebuild the reader by itself.
  late final Widget _body = Reactive(
    builder: (_) {
      builds++;
      return Text(
        '${controller.focusOrder.value.join(',')}|${controller.active.value}',
      );
    },
  );

  @override
  void initState() {
    super.initState();
    watch(
      () => controller.active.value,
      (active, previous, _) => widget.log.add('watch $active in $_phase'),
    );
  }

  @override
  void didUpdateWidget(RawListbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    items.sync(widget.items);
  }

  @override
  Widget build(BuildContext context) => _body;
}

// ------------------------------------------------------------------ sheet

class SheetController {
  SheetController(this.snapPoints, this.reducedMotion);

  final Readable<List<double>> snapPoints;
  final Readable<bool> reducedMotion;
  final detent = signal(0, name: 'sheet.detent');

  /// The sheet's resting translation for a 400 px tall viewport.
  late final Readable<Offset> offset = computed(() {
    final snaps = snapPoints.value;
    final extent = snaps[detent.value.clamp(0, snaps.length - 1)];
    return Offset(0, 400 * (1 - extent));
  }, name: 'sheet.offset');

  late final Readable<String> transition = computed(
    () => reducedMotion.value ? 'fade' : 'spring',
    name: 'sheet.transition',
  );
}

class RawSheet extends StatefulWidget {
  const RawSheet({super.key, required this.snapPoints, required this.log});
  final List<double> snapPoints;
  final List<String> log;

  @override
  State<RawSheet> createState() => _RawSheetState();
}

class _RawSheetState extends State<RawSheet> with ReactiveState {
  late final _snaps = input(
    widget.snapPoints,
    equals: Equality.deep,
    name: 'sheet.snapPoints',
  );

  /// MediaQuery cannot be read in initState: a placeholder, synced by the
  /// first didChangeDependencies before any reader builds.
  late final _reduced = input(false, name: 'sheet.reducedMotion');
  late final controller = SheetController(_snaps.readable, _reduced.readable);
  int contentBuilds = 0;
  int transitionBuilds = 0;

  late final Widget _body = ReactiveTransform.translate(
    offset: controller.offset,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Builder(
          builder: (_) {
            contentBuilds++;
            return const SizedBox(width: 100, height: 40);
          },
        ),
        Reactive(
          builder: (_) {
            transitionBuilds++;
            return Text(controller.transition.value);
          },
        ),
      ],
    ),
  );

  @override
  void initState() {
    super.initState();
    watch(
      () => controller.transition.value,
      (transition, previous, _) =>
          widget.log.add('watch $transition in $_phase'),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced.sync(MediaQuery.disableAnimationsOf(context));
  }

  @override
  void didUpdateWidget(RawSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    _snaps.sync(widget.snapPoints);
  }

  @override
  Widget build(BuildContext context) =>
      Align(alignment: Alignment.topLeft, child: _body);
}

// --------------------------------------------------------------- probes

/// An owner whose input is handed out through [holder].
class Owner extends StatefulWidget {
  const Owner({
    super.key,
    required this.value,
    required this.holder,
    this.syncIn = 'didUpdateWidget',
    this.child,
  });
  final int value;
  final List<WidgetInput<int>> holder;

  /// Where it syncs: didUpdateWidget, batch (didUpdateWidget, inside a
  /// batch), build, initState, dispose (before super.dispose; the error is
  /// kept in [disposeError]).
  final String syncIn;
  final Widget? child;

  @override
  State<Owner> createState() => _OwnerState();
}

class _OwnerState extends State<Owner> with ReactiveState {
  late final WidgetInput<int> value = input(widget.value, name: 'owner.value');

  @override
  void initState() {
    super.initState();
    widget.holder.add(value);
    if (widget.syncIn == 'initState') value.sync(widget.value);
  }

  @override
  void didUpdateWidget(Owner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.syncIn == 'didUpdateWidget') value.sync(widget.value);
    if (widget.syncIn == 'batch') batch(() => value.sync(widget.value));
  }

  @override
  void dispose() {
    if (widget.syncIn == 'dispose') {
      try {
        value.sync(widget.value + 1);
      } on Object catch (error) {
        disposeError = error;
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The runtime refusal is under test (the lint reports it too).
    // ignore: rill_lint/rill_write_in_build
    if (widget.syncIn == 'build') value.sync(widget.value);
    return widget.child ?? const SizedBox();
  }
}

/// What [Owner] caught when it synced in dispose.
Object? disposeError;

/// Reads the first input in [holder], wherever it is mounted.
class InputReader extends ReactiveWidget {
  const InputReader(this.holder, {super.key});
  final List<WidgetInput<int>> holder;

  @override
  Widget build(BuildContext context) =>
      Text('${holder.isEmpty ? '-' : holder.first.readable.value}');
}

void main() {
  group('WidgetInput', () {
    testWidgets(
      'listbox_items_replaced_in_did_update_widget_are_current_in_the_same_frame',
      (t) async {
        final log = <String>[];
        final frames = Frames(t);
        const a = (id: 'a', disabled: false);
        const b = (id: 'b', disabled: false);
        const c = (id: 'c', disabled: false);
        const d = (id: 'd', disabled: true);
        await t.pumpWidget(page(RawListbox(items: const [a, b, c], log: log)));
        final state = t.state<RawListboxState>(find.byType(RawListbox));
        state.controller.highlighted.value = 'b';
        await t.pump();
        expect(find.text('a,b,c|b'), findsOne);
        log.clear();
        final builds = state.builds, before = frames.count;

        // The highlighted item is removed; a disabled one arrives.
        await t.pumpWidget(page(RawListbox(items: const [a, c, d], log: log)));
        expect(t.takeException(), isNull);
        expect(find.text('a,c|a'), findsOne, reason: 'current in this frame');
        expect(state.builds, builds + 1, reason: 'one build, no second one');
        expect(frames.count, before + 1);
        expect(t.binding.hasScheduledFrame, isFalse);
        expect(log, [
          'watch a in postFrameCallbacks',
        ], reason: 'R3b: the watch it wakes applies after the frame');
      },
    );

    testWidgets('equal_configuration_object_propagates_nothing', (t) async {
      final log = <String>[];
      await t.pumpWidget(
        page(RawListbox(items: [(id: 'a', disabled: false)], log: log)),
      );
      final state = t.state<RawListboxState>(find.byType(RawListbox));
      final revision = nodeRevision(state.items.readable);
      final builds = state.builds, orders = state.controller.orders;
      log.clear();

      // A freshly built list with the same content.
      await t.pumpWidget(
        page(RawListbox(items: [(id: 'a', disabled: false)], log: log)),
      );
      expect(nodeRevision(state.items.readable), revision);
      expect(state.controller.orders, orders, reason: 'no recompute');
      expect(state.builds, builds);
      expect(log, isEmpty);
      expect(t.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('sheet_snap_points_move_the_layer_in_the_same_frame', (
      t,
    ) async {
      final log = <String>[];
      await t.pumpWidget(page(RawSheet(snapPoints: const [0.5, 1], log: log)));
      final state = t.state<_RawSheetState>(find.byType(RawSheet));
      final render = t.renderObject<RenderReactiveTransform>(
        find.byType(ReactiveTransform),
      );
      expect(render.matrix.getTranslation().y, 200);
      final content = state.contentBuilds, text = state.transitionBuilds;

      await t.pumpWidget(page(RawSheet(snapPoints: const [0.25, 1], log: log)));
      expect(t.takeException(), isNull);
      expect(render.matrix.getTranslation().y, 300);
      expect(
        t.layers.whereType<TransformLayer>().any((layer) {
          return layer.transform?.getTranslation().y == 300;
        }),
        isTrue,
        reason: 'the layer moved in this frame',
      );
      expect(state.contentBuilds, content, reason: 'no build below');
      expect(state.transitionBuilds, text);
      expect(t.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('sheet_reduced_motion_synced_in_did_change_dependencies', (
      t,
    ) async {
      final log = <String>[];
      Widget tree(bool reduced) => page(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: RawSheet(snapPoints: const [0.5, 1], log: log),
        ),
      );
      // Mounted reduced: the placeholder is never seen by a reader.
      await t.pumpWidget(tree(true));
      final state = t.state<_RawSheetState>(find.byType(RawSheet));
      expect(find.text('fade'), findsOne);
      expect(state.transitionBuilds, 1);
      expect(log, ['watch fade in postFrameCallbacks']);
      log.clear();

      await t.pumpWidget(tree(false));
      expect(t.takeException(), isNull);
      expect(find.text('spring'), findsOne, reason: 'current in this frame');
      expect(state.transitionBuilds, 2, reason: 'one build');
      expect(log, ['watch spring in postFrameCallbacks']);
      expect(t.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('effect_woken_by_sync_applies_after_the_frame', (t) async {
      final holder = <WidgetInput<int>>[];
      final applied = <String>[];
      final mirror = signal(0, name: 'mirror');
      await t.pumpWidget(page(Owner(value: 1, holder: holder)));
      final stop = effect(() => holder.first.readable.value, (
        value,
        previous,
        _,
      ) {
        applied.add('$value in $_phase');
        mirror.value = value; // a write in the apply is legal: not in build
      });
      addTearDown(stop);
      applied.clear();

      await t.pumpWidget(page(Owner(value: 2, holder: holder)));
      expect(t.takeException(), isNull);
      expect(applied, ['2 in postFrameCallbacks']);
      expect(mirror.peek(), 2);
    });

    testWidgets('overlay_portal_child_is_inside_the_owner_subtree', (t) async {
      final holder = <WidgetInput<int>>[];
      final portal = OverlayPortalController();
      final value = ValueNotifier(1);
      await t.pumpWidget(
        page(
          Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (_) => ValueListenableBuilder(
                  valueListenable: value,
                  builder: (_, value, _) => Owner(
                    value: value,
                    holder: holder,
                    child: OverlayPortal(
                      controller: portal,
                      overlayChildBuilder: (_) => Align(
                        alignment: Alignment.bottomRight,
                        child: InputReader(holder),
                      ),
                      child: const SizedBox(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      portal.show();
      await t.pump();
      expect(find.text('1'), findsOne);

      value.value = 2;
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.text('2'), findsOne, reason: 'current in this frame');
      expect(t.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('reader_outside_the_owner_subtree_is_escaped', (t) async {
      final holder = <WidgetInput<int>>[];
      // One reader instance across rebuilds: a fresh sibling widget would be
      // rebuilt by the parent and show the new value in the first frame,
      // which proves nothing about the deferred notification.
      final reader = InputReader(holder);
      Widget tree(int value) => page(
        Column(
          children: [
            Owner(value: value, holder: holder),
            reader,
          ],
        ),
      );
      await t.pumpWidget(tree(1));
      expect(find.text('1'), findsOne);
      await t.pumpWidget(tree(2));
      expect(t.takeException(), _escaped('by InputReader'));
      expect(find.text('1'), findsOne, reason: 'not current in this frame');
      expect(t.binding.hasScheduledFrame, isTrue);
      await t.pump();
      expect(find.text('2'), findsOne, reason: 'a frame late, as in release');
    });

    testWidgets('native_listener_of_an_input_is_escaped', (t) async {
      final holder = <WidgetInput<int>>[];
      await t.pumpWidget(page(Owner(value: 1, holder: holder)));
      final listenable = holder.first.readable.toListenable();
      void listener() {}
      listenable.addListener(listener);
      addTearDown(() => listenable.removeListener(listener));
      await t.pumpWidget(page(Owner(value: 2, holder: holder)));
      expect(t.takeException(), _escaped('by a listener'));
    });

    testWidgets('outside_reader_woken_by_a_pulse_during_sync_is_not_escaped', (
      t,
    ) async {
      // Syncing makes a computed below the owner start reading a stopped
      // Pulse; reconciling samples it and wakes a clock elsewhere, which
      // does not depend on the input.
      final clock = Pulse.every(const Duration(seconds: 1));
      final holder = <WidgetInput<int>>[];
      late final shown = computed(
        () =>
            holder.first.readable.value == 0 ? 'off' : '${clock.value.second}',
      );
      Widget tree(int value) => page(
        Column(
          children: [
            TickerMode(
              enabled: false,
              child: Reactive(builder: (_) => Text('${clock.value}')),
            ),
            Owner(
              value: value,
              holder: holder,
              child: Reactive(builder: (_) => Text('in ${shown.value}')),
            ),
          ],
        ),
      );
      await t.pumpWidget(tree(0));
      expect(activePulseCount, 0, reason: 'the clock is hidden');
      await t.pump(const Duration(seconds: 3));
      await t.pumpWidget(tree(1));
      expect(t.takeException(), isNull);
      expect(activePulseCount, 1);
      expect(find.textContaining('in '), findsOne);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('sync_in_an_event_handler_throws', (t) async {
      final holder = <WidgetInput<int>>[];
      await t.pumpWidget(page(Owner(value: 1, holder: holder)));
      expect(
        () => holder.first.sync(2),
        throwsA(_escaped('outside its owner')),
      );
    });

    testWidgets('sync_in_the_owner_build_throws', (t) async {
      final holder = <WidgetInput<int>>[];
      await t.pumpWidget(page(Owner(value: 1, holder: holder)));
      await t.pumpWidget(
        page(Owner(value: 2, holder: holder, syncIn: 'build')),
      );
      expect(t.takeException(), _escaped("in its owner's build"));
    });

    testWidgets('sync_from_another_build_in_a_later_frame_throws', (t) async {
      // The window opened at mount (didChangeDependencies) closes when that
      // frame ends; a descendant that later syncs from its build is refused.
      final holder = <WidgetInput<int>>[];
      final tick = signal(0, name: 'tick');
      await t.pumpWidget(
        page(
          Owner(
            value: 1,
            holder: holder,
            child: Reactive(
              builder: (_) {
                // ignore: rill_lint/rill_write_in_build
                if (tick.value > 0) holder.first.sync(tick.value);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      tick.value = 4;
      await t.pump();
      expect(t.takeException(), _escaped('outside its owner'));
    });

    testWidgets('sync_in_init_state_throws', (t) async {
      await t.pumpWidget(
        page(Owner(value: 1, holder: [], syncIn: 'initState')),
      );
      expect(t.takeException(), _escaped('outside its owner'));
    });

    testWidgets('sync_in_did_update_widget_is_exempt_from_the_write_guard', (
      t,
    ) async {
      // The same write through a plain signal is RILL_WRITE_DURING_FRAME.
      final holder = <WidgetInput<int>>[];
      await t.pumpWidget(page(Owner(value: 1, holder: holder)));
      await t.pumpWidget(page(Owner(value: 2, holder: holder)));
      expect(t.takeException(), isNull);
      expect(holder.first.readable.peek(), 2);
    });

    testWidgets('sync_inside_a_batch_throws', (t) async {
      // Inside a batch the flush waits for the batch, after the sync's
      // token is gone: readers below the owner would fall back to after the
      // frame and an escaped reader would go unreported.
      final holder = <WidgetInput<int>>[];
      await t.pumpWidget(
        page(Owner(value: 1, holder: holder, child: InputReader(holder))),
      );
      await t.pumpWidget(
        page(
          Owner(
            value: 2,
            holder: holder,
            syncIn: 'batch',
            child: InputReader(holder),
          ),
        ),
      );
      expect(t.takeException(), _escaped('inside a batch'));
      expect(holder.first.readable.peek(), 1, reason: 'refused, not written');
    });

    testWidgets('sync_in_the_owner_dispose_is_after_disposal', (t) async {
      // State.dispose runs before the State leaves its Element: the owner
      // is still mounted, but its Element is already defunct.
      disposeError = null;
      final holder = <WidgetInput<int>>[];
      await t.pumpWidget(
        page(Owner(value: 1, holder: holder, syncIn: 'dispose')),
      );
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
      expect(disposeError, _escaped('after its owner was disposed'));
      expect(holder.first.readable.peek(), 1);
    });

    testWidgets('owner_disposed_input_stays_readable_and_sync_throws', (
      t,
    ) async {
      final holder = <WidgetInput<int>>[];
      await t.pumpWidget(page(Owner(value: 1, holder: holder)));
      await t.pumpWidget(page(Owner(value: 7, holder: holder)));
      final doubled = computed(() => holder.first.readable.value * 2);
      await t.pumpWidget(const SizedBox());
      expect(holder.first.readable.peek(), 7);
      expect(doubled.peek(), 14);
      expect(
        () => holder.first.sync(8),
        throwsA(_escaped('after its owner was disposed')),
      );
    });
  });
}
