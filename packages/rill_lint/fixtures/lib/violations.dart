// The lint canary (tool/check.sh): each "expect:" line comment names the
// rules that must report an error on the line below it.
import 'package:flutter/widgets.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

Signal<int> cast(Readable<int> source) =>
    // expect: rill_cast_to_signal
    source as Signal<int>;

Computed<int> derive(Signal<int> source) => computed(() {
  // expect: rill_write_in_computed
  source.value = 1;
  return source.value;
});

class Canary extends ReactiveWidget {
  const Canary(this.source, {super.key});

  final Signal<int> source;

  @override
  Widget build(BuildContext context) {
    // expect: rill_write_in_build
    source.update((current) => current + 1);
    // expect: rill_create_in_build
    final local = signal(0);
    return LayoutBuilder(
      builder: (_, _) => SizedBox(
        // expect: rill_untracked_read
        width: (source.value + local.value).toDouble(),
      ),
    );
  }
}

AsyncComputed<int> watchStream(Signal<int> source) =>
    // expect: rill_async_star_stream
    computedStream((_) async* {
      yield source.value;
    });

Future<void> refresh(Signal<int> source) async {
  await Future<void>.value();
  // expect: rill_write_after_await
  source.value = 2;
  // expect: rill_write_after_await
  transact((p) => p.set(source, 3));
}

List<Widget> animationBuilders(
  Animation<double> animation,
  Readable<int> source,
) => [
  AnimatedBuilder(
    animation: animation,
    // expect: rill_untracked_read
    builder: (_, _) => Text('${source.value}'),
  ),
  TweenAnimationBuilder<double>(
    duration: Duration.zero,
    tween: Tween(begin: 0, end: 1),
    // expect: rill_untracked_read
    builder: (_, _, _) => Text('${source.value}'),
  ),
  // expect: rill_untracked_read
  DraggableScrollableSheet(builder: (_, _) => Text('${source.value}')),
];

void routes(BuildContext context, Readable<int> source) {
  showGeneralDialog<void>(
    context: context,
    // expect: rill_untracked_read
    pageBuilder: (_, _, _) => Text('${source.value}'),
  );
  Navigator.of(context).push(
    // expect: rill_untracked_read
    PageRouteBuilder<void>(pageBuilder: (_, _, _) => Text('${source.value}')),
  );
}

Widget rows(Readable<int> source) => ListView.builder(
  itemCount: 1,
  // expect: rill_untracked_read
  itemBuilder: (_, _) => Text('${source.value}'),
);

// A subclass of a tracked reader is never
// reported, however its constructors forward the builder; a read in a
// closure nested inside a builder is left to the runtime guard
// (docs/lint.md#分层). None of these report.
class NamedReactive extends Reactive {
  const NamedReactive({super.key, required super.builder});
}

Widget trackedSubclass(Readable<int> source) =>
    NamedReactive(builder: (_) => Text('${source.value}'));

class Redirect extends Reactive {
  Redirect(WidgetBuilder b, {Key? key}) : this.named(b, key: key);
  Redirect.named(WidgetBuilder b, {super.key}) : super(builder: b);
}

Widget redirect(Signal<int> source) =>
    Redirect((_) => SizedBox(width: source.value.toDouble()));

class WrappingReactive extends Reactive {
  WrappingReactive(WidgetBuilder content, {super.key})
    : super(builder: (_) => Builder(builder: content));
}

Widget wrapping(Signal<int> source) =>
    WrappingReactive((_) => SizedBox(width: source.value.toDouble()));

// A widget or function outside Flutter may run the
// builder at once (an initializer list, before returning its Future); the
// Reactive around it tracks the read. Only Flutter's own deferring APIs are
// known callees, so neither reports.
class Prebuilt extends StatelessWidget {
  Prebuilt(BuildContext context, WidgetBuilder buildChild, {super.key})
    : child = buildChild(context);
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

Future<void> runNow(BuildContext context, WidgetBuilder callback) {
  callback(context);
  return Future.value();
}

Widget eager(Signal<int> input) => Reactive(
  builder: (context) {
    var width = 0;
    runNow(context, (_) => SizedBox(width: (width = input.value).toDouble()));
    return Prebuilt(
      context,
      (_) => SizedBox(width: (input.value + width).toDouble()),
    );
  },
);

Widget nested(Signal<int> source) => Builder(
  builder: (_) {
    final n = [0, 1].map((_) => source.value).length;
    final widths = [0].map((_) => source.value).followedBy([2]).toList();
    return Column(
      children: [
        SizedBox(width: n.toDouble() + widths.first),
        ...List.generate(1, (_) => Text('${source.value}')),
      ],
    );
  },
);

class Region extends StatefulWidget {
  const Region(this.source, {super.key});

  final Signal<int> source;

  @override
  State<Region> createState() => _RegionState();
}

class _RegionState extends State<Region> {
  final _owned = Scope();
  late final void Function() _stop;

  @override
  void initState() {
    super.initState();
    // expect: rill_effect_in_lifecycle
    _stop = effect(() => widget.source.value, (_, _, _) {});
  }

  @override
  void dispose() {
    _stop();
    _owned.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // expect: rill_create_in_build
    final local = Scope();
    local.dispose();
    // expect: rill_create_in_build, rill_effect_in_lifecycle
    _owned.effect(() => widget.source.value, (_, _, _) {});
    return const SizedBox();
  }
}

class Configured extends StatefulWidget {
  const Configured(this.items, {super.key});

  final List<int> items;

  @override
  State<Configured> createState() => _ConfiguredState();
}

class _ConfiguredState extends State<Configured> with ReactiveState {
  late final _items = input(widget.items);

  @override
  void didUpdateWidget(Configured oldWidget) {
    super.didUpdateWidget(oldWidget);
    _items.sync(widget.items);
  }

  @override
  Widget build(BuildContext context) {
    // expect: rill_create_in_build
    final again = input(widget.items);
    return Text('${again.readable.peek()} ${_items.readable.peek()}');
  }
}

class Plain extends CustomPainter {
  Plain(this.source);

  final Readable<int> source;

  @override
  // expect: rill_untracked_read
  void paint(Canvas canvas, Size size) => source.value;

  @override
  bool shouldRepaint(Plain oldDelegate) => false;
}

class Dots extends ReactivePainter {
  Dots(this.source);

  final Readable<int> source;
  final stops = <void Function()>[];

  @override
  void paint(Canvas canvas, Size size) {
    // expect: rill_effect_in_lifecycle
    stops.add(effect(() => source.value, (_, _, _) {}));
  }
}

class InputCanary extends StatefulWidget {
  const InputCanary({super.key});

  @override
  State<InputCanary> createState() => _InputCanaryState();
}

class _InputCanaryState extends State<InputCanary> with ReactiveState {
  late final _width = input(0.0);

  @override
  void didUpdateWidget(InputCanary oldWidget) {
    super.didUpdateWidget(oldWidget);
    _width.sync(1);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, constraints) {
      // expect: rill_write_in_build
      _width.sync(constraints.maxWidth);
      return const SizedBox();
    },
  );
}

class BuilderCanary extends StatelessWidget {
  const BuilderCanary({super.key});

  @override
  Widget build(BuildContext context) => Reactive(
    builder: (context) {
      // expect: rill_create_in_build
      final open = signal(true);
      return Text('${open.peek()}');
    },
  );
}
