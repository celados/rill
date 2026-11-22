import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:rill_lint/src/adapter/fix.dart';
import 'package:test/test.dart';
import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:rill_lint/src/adapter/rules.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CastTest);
    defineReflectiveTests(ComputeTest);
    defineReflectiveTests(FrameWriteTest);
    defineReflectiveTests(FrameCreateTest);
    defineReflectiveTests(UntrackedTest);
    defineReflectiveTests(AfterAwaitTest);
    defineReflectiveTests(EffectLifecycleTest);
    defineReflectiveTests(AsyncStarStreamTest);
  });
}

abstract class RillTest extends AnalysisRuleTest {
  RillLint get kind;

  @override
  bool get dumpAstOnFailures => false;

  @override
  void setUp() {
    rule = RillRule(kind);
    super.setUp();
    newPackage('rill').addFile('lib/rill.dart', '''
abstract class Readable<T> {
  T get value;
  T peek() => value;
}
class Signal<T> extends Readable<T> {
  Signal(this.value);
  T value;
  void update(T Function(T) fn) { value = fn(value); }
}
class Wire<T> {
  Wire(T initial, T Function(Object?) decode);
  Readable<T> get readable => throw 0;
}
abstract class Computed<T> extends Readable<T> {}
abstract class AsyncComputed<T> extends Computed<T> {}
Signal<T> signal<T>(T value) => Signal(value);
Computed<T> computed<T>(T Function() fn) => throw 0;
AsyncComputed<T> computedAsync<T>(Future<T> Function(Object) fn) => throw 0;
AsyncComputed<T> computedStream<T>(Stream<T> Function(Object) fn) => throw 0;
typedef OnCleanup = void Function(void Function() cleanup);
void Function() effect<T>(
  T Function() compute, void Function(T, T?, OnCleanup) apply,
) => throw 0;
class Scope {
  Scope();
  Scope child() => throw 0;
  void Function() effect<T>(
    T Function() compute, void Function(T, T?, OnCleanup) apply,
  ) => throw 0;
  Slot slot() => throw 0;
}
class Events<T> { Events({bool hold = false}); }
abstract class Slot {
  Future<T> run<T>(Future<T> Function(Task) body);
}
abstract class Task {
  bool publish(void Function(Tx) stage);
}
abstract class Tx {
  void set<T>(Signal<T> target, T value);
}
bool transact(void Function(Tx) stage) => throw 0;
''');
  }

  void addFlutterApi() {
    final flutter = newPackage('flutter');
    flutter.addFile('lib/src/widgets/framework.dart', '''
class BuildContext {}
abstract class Widget {}
abstract class StatelessWidget extends Widget {
  Widget build(BuildContext context);
}
abstract class State<T extends Widget> {
  Widget build(BuildContext context);
}
''');
    flutter.addFile('lib/src/rendering/custom_paint.dart', '''
class Canvas {}
class Size {}
abstract class CustomPainter { void paint(Canvas canvas, Size size); }
''');
    for (final (type, file, parameters) in [
      ('LayoutBuilder', 'layout_builder', 'BuildContext, Object'),
      ('AnimatedBuilder', 'transitions', 'BuildContext, Widget?'),
      (
        'TweenAnimationBuilder',
        'tween_animation_builder',
        'BuildContext, double, Widget?',
      ),
      (
        'DraggableScrollableSheet',
        'draggable_scrollable_sheet',
        'BuildContext, Object',
      ),
    ]) {
      flutter.addFile('lib/src/widgets/$file.dart', '''
import 'framework.dart';
class $type extends Widget {
  $type({required Widget Function($parameters) builder});
}
''');
    }
    for (final (name, file) in [
      ('showDialog', 'dialog'),
      ('showModalBottomSheet', 'bottom_sheet'),
    ]) {
      flutter.addFile('lib/src/material/$file.dart', '''
import '../widgets/framework.dart';
Future<T?> $name<T>({required Widget Function(BuildContext) builder}) =>
    throw 0;
''');
    }
    flutter.addFile('lib/src/widgets/routes.dart', '''
import 'framework.dart';
abstract class Route<T> {}
class PageRouteBuilder<T> extends Route<T> {
  PageRouteBuilder({required Widget Function(BuildContext, Object, Object) pageBuilder});
}
class OverlayEntry {
  OverlayEntry({required Widget Function(BuildContext) builder});
}
Future<T?> showGeneralDialog<T>({
  required Widget Function(BuildContext, Object, Object) pageBuilder,
}) => throw 0;
class Builder extends Widget {
  Builder({required Widget Function(BuildContext) builder});
}
class FutureBuilder<T> extends Widget {
  FutureBuilder({required Widget Function(BuildContext, Object) builder});
}
class StreamBuilder<T> extends Widget {
  StreamBuilder({required Widget Function(BuildContext, Object) builder});
}
class ListView extends Widget {
  ListView.builder({required Widget? Function(BuildContext, int) itemBuilder});
}
abstract class SliverChildDelegate {}
class SliverChildBuilderDelegate extends SliverChildDelegate {
  SliverChildBuilderDelegate(Widget? Function(BuildContext, int) builder);
}
class PopupMenuButton extends Widget {
  PopupMenuButton({required List<Widget> Function(BuildContext) itemBuilder});
}
''');
    flutter.addFile('lib/widgets.dart', '''
export 'src/widgets/framework.dart';
export 'src/widgets/layout_builder.dart';
export 'src/widgets/transitions.dart';
export 'src/widgets/tween_animation_builder.dart';
export 'src/widgets/draggable_scrollable_sheet.dart';
export 'src/rendering/custom_paint.dart';
export 'src/widgets/routes.dart';
''');
    flutter.addFile('lib/material.dart', '''
export 'widgets.dart';
export 'src/material/dialog.dart';
export 'src/material/bottom_sheet.dart';
''');
    newPackage('rill_flutter').addFile('lib/rill_flutter.dart', '''
import 'package:flutter/widgets.dart';
import 'package:rill/rill.dart';
abstract class ReactiveWidget extends StatelessWidget {}
class Reactive extends Widget {
  Reactive({required Widget Function(BuildContext) builder});
}
class ReactiveLayoutBuilder extends Widget {
  ReactiveLayoutBuilder({required Widget Function(BuildContext, Object) builder});
}
mixin ReactiveState<W extends Widget> on State<W> {
  Scope get scope => throw 0;
  void Function() watch<T>(
    T Function() compute, void Function(T, T?, OnCleanup) apply,
  ) => throw 0;
  WidgetInput<T> input<T>(T initial) => throw 0;
}
final class WidgetInput<T> {
  Readable<T> get readable => throw 0;
  void sync(T value) {}
}
abstract class ReactivePainter {
  void paint(Canvas canvas, Size size);
}
Readable<T?> linger<T>(Readable<T?> source, Duration duration) => throw 0;
''');
  }

  Future<void> check(
    String marked, {
    String imports = "import 'package:rill/rill.dart';",
  }) async {
    writeTestPackageConfig2();
    final input = '$imports\n$marked';
    final source = StringBuffer();
    final spans = <(int, int)>[];
    var previousEnd = 0;
    for (final match in RegExp(
      r'/\*\[\*/(.*?)/\*\]\*/',
      dotAll: true,
    ).allMatches(input)) {
      source.write(input.substring(previousEnd, match.start));
      final span = match.group(1)!;
      spans.add((source.length, span.length));
      source.write(span);
      previousEnd = match.end;
    }
    source.write(input.substring(previousEnd));
    await assertDiagnostics(source.toString(), [
      for (final (offset, length) in spans) lint(offset, length),
    ]);
  }
}

const widgetImports = '''
import 'package:flutter/material.dart';
import 'package:rill/rill.dart';
''';

@reflectiveTest
class CastTest extends RillTest {
  @override
  RillLint get kind => RillLint.castToSignal;

  Future<void> test_resolvedTypes() => check('''
bool f(Readable<int> a, Computed<int> b, AsyncComputed<int> c) =>
    a is /*[*/Signal<int>/*]*/ &&
    b as /*[*/Signal<int>/*]*/ == c as /*[*/Signal<int>/*]*/;
''');

  Future<void> test_unrelatedAndWritableTypes() => check(
    '''
class Signal {}
bool f(Readable<int> a, Object b) => a is Signal || b is rill.Signal<int>;
bool g(Object value, Wire<int> w) => value is rill.Signal<int>;
''',
    imports: '''
import 'package:rill/rill.dart' hide Signal;
import 'package:rill/rill.dart' as rill show Signal;
''',
  );
}

@reflectiveTest
class ComputeTest extends RillTest {
  @override
  RillLint get kind => RillLint.writeInComputed;

  Future<void> test_widgetInputSync() {
    addFlutterApi();
    return check(
      '''
class Demo extends Widget {}
class _DemoState extends State<Demo> with ReactiveState {
  late final a = input(0);
  late final doubled = computed(() { /*[*/a.sync(1)/*]*/; return 0; });
  void start() {
    watch(() { /*[*/a.sync(2)/*]*/; return 0; }, (_, _, _) { a.sync(3); });
  }
  Widget build(BuildContext context) => throw 0;
}
''',
      imports:
          "$widgetImports\nimport 'package:rill_flutter/rill_flutter.dart';",
    );
  }

  Future<void> test_computeParameters() => check('''
void f(Signal<int> s, bool guard) {
  computed(() => guard ? (/*[*/s.value = 1/*]*/) : 0);
  computedAsync((_) async {
    try { return (s/*[*/..update((n) => n + 1)/*]*/).value; }
    finally { /*[*/s.value = 3/*]*/; }
  });
  effect(() => /*[*/s.value = 2/*]*/, (_, _, _) {});
  computedStream((_) {
    /*[*/s.value = 4/*]*/;
    return Stream.value(0);
  });
}
''');

  Future<void> test_transactInComputed() => check('''
void f(Signal<int> s) {
  computed(() => /*[*/transact((p) => p.set(s, 1))/*]*/);
  effect(() => /*[*/transact((p) => p.set(s, 2))/*]*/, (_, _, _) {
    transact((p) => p.set(s, 3));
  });
}
''');

  Future<void> test_watchCompute() async {
    addFlutterApi();
    await check(
      '''
class Demo extends State<Widget> with ReactiveState<Widget> {
  final s = signal(0);
  void initState() {
    watch(() => /*[*/s.value = 1/*]*/, (_, _, _) { s.value = 2; });
  }
  Widget build(BuildContext context) => throw 0;
}
''',
      imports:
          "$widgetImports\nimport 'package:rill_flutter/rill_flutter.dart';",
    );
  }

  Future<void> test_effectApplyAndLookalike() => check('''
void f(Signal<int> s) {
  effect(() => s.value, (_, _, _) { s.update((n) => n + 1); });
  computed(() { final later = () => s.value = 1; return later; });
  void computedAsync(void Function(Object) fn) {}
  computedAsync((_) { s.value = 2; });
}
''');
}

abstract class FrameTest extends RillTest {
  @override
  void setUp() {
    super.setUp();
    addFlutterApi();
  }
}

@reflectiveTest
class FrameWriteTest extends FrameTest {
  @override
  RillLint get kind => RillLint.writeInBuild;

  Future<void> test_frameMethods() => check('''
class Demo extends State<Widget> {
  final s = signal(0);
  Widget build(BuildContext context) {
    if (s.value == 0) { /*[*/s.value += 1/*]*/; }
    else { /*[*/s.update((n) => n + 1)/*]*/; }
    return throw 0;
  }
}
class Painter extends CustomPainter {
  final s = signal(0);
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < 2; i++) { /*[*/s.value = i/*]*/; }
  }
}
''', imports: widgetImports);

  Future<void> test_widgetInputSync() => check(
    '''
class Demo extends Widget {}
class _DemoState extends State<Demo> with ReactiveState {
  late final width = input(0.0);
  late final items = input(0);
  void didUpdateWidget(Demo old) {
    items.sync(1);
    _syncConfig();
  }
  void didChangeDependencies() => _syncConfig();
  void _syncConfig() { width.sync(2); }
  Widget build(BuildContext context) {
    /*[*/items.sync(3)/*]*/;
    final later = () => items.sync(4);
    return LayoutBuilder(builder: (_, _) {
      /*[*/width.sync(5)/*]*/;
      return Builder(builder: (_) {
        [0].forEach((_) => items.sync(6));
        /*[*/items.sync(7)/*]*/;
        return throw 0;
      });
    });
  }
}
class Lookalike extends StatelessWidget {
  void sync(int value) {}
  Widget build(BuildContext context) { sync(0); return throw 0; }
}
''',
    imports:
        "import 'package:flutter/material.dart';\n"
        "import 'package:rill_flutter/rill_flutter.dart';",
  );

  Future<void> test_transactInBuild() => check('''
class Demo extends State<Widget> {
  final s = signal(0);
  Widget build(BuildContext context) {
    /*[*/transact((p) => p.set(s, 1))/*]*/;
    final later = () => transact((p) => p.set(s, 2));
    return throw 0;
  }
}
''', imports: widgetImports);

  Future<void> test_foreignBuildAndDeferredCallback() => check('''
class Local {
  void build(Signal<int> s) { s.value = 1; }
}
class Demo extends StatelessWidget {
  final s = signal(0);
  Widget build(BuildContext context) {
    final later = () => s.value = 1;
    return throw 0;
  }
}
''', imports: widgetImports);
}

@reflectiveTest
class FrameCreateTest extends FrameTest {
  @override
  RillLint get kind => RillLint.createInBuild;

  Future<void> test_allFactories() => check(
    '''
class Demo extends ReactiveWidget {
  final owned = signal(0);
  Widget build(BuildContext context) {
    final a = /*[*/signal(0)/*]*/;
    final b = /*[*/computed(() => a.value)/*]*/;
    final c = /*[*/computedAsync((_) async => b.value)/*]*/;
    final d = /*[*/Wire(0, (json) => json as int)/*]*/;
    final e = /*[*/Events<int>(hold: true)/*]*/;
    final f = /*[*/computedStream((_) => Stream.value(a.value))/*]*/;
    final g = /*[*/linger<int>(a, Duration.zero)/*]*/;
    final h = /*[*/Scope()/*]*/;
    final i = /*[*/h.child()/*]*/;
    final j = /*[*/h.effect(() => a.value, (_, _, _) {})/*]*/;
    final k = /*[*/h.slot()/*]*/;
    return throw 0;
  }
}
''',
    imports: "$widgetImports\nimport 'package:rill_flutter/rill_flutter.dart';",
  );

  Future<void> test_widgetInputInBuild() => check(
    '''
class Demo extends Widget {}
class _DemoState extends State<Demo> with ReactiveState {
  late final field = input(0);
  WidgetInput<int>? lazy;
  void initState() {
    lazy = input(0);
  }
  Widget build(BuildContext context) {
    final again = /*[*/input(1)/*]*/;
    return throw 0;
  }
}
class Lookalike extends StatelessWidget {
  int input(int value) => value;
  Widget build(BuildContext context) => throw input(0);
}
''',
    imports:
        "import 'package:flutter/material.dart';\n"
        "import 'package:rill_flutter/rill_flutter.dart';",
  );

  /// The same positions as
  /// rill_write_in_build's `WidgetInput.sync(` — directly in a widget builder
  /// closure, by parameter type; a closure nested in it is not.
  Future<void> test_widgetBuilderClosures() => check(
    '''
class Box extends Widget { Box(Object value); }
class Demo extends Widget {}
class _DemoState extends State<Demo> with ReactiveState {
  late final owned = signal(0);
  Signal<int>? lazy;
  void initState() {
    lazy = signal(0);
  }
  Widget build(BuildContext context) => Reactive(builder: (_) {
    final a = /*[*/signal(0)/*]*/;
    final later = () => signal(1);
    return Builder(builder: (_) {
      final b = /*[*/computed(() => a.value)/*]*/;
      return LayoutBuilder(builder: (_, _) {
        [0].forEach((_) => Events<int>());
        return Box(/*[*/Scope()/*]*/);
      });
    });
  });
}
''',
    imports: "$widgetImports\nimport 'package:rill_flutter/rill_flutter.dart';",
  );

  Future<void> test_lookalikeAndOwnedFields() => check('''
class Demo extends StatelessWidget {
  final owned = signal(0);
  final notices = Events<int>();
  Widget build(BuildContext context) {
    int signal(int initial) => initial;
    return throw signal(0);
  }
}
''', imports: widgetImports);
}

@reflectiveTest
class UntrackedTest extends FrameTest {
  @override
  RillLint get kind => RillLint.untrackedRead;

  Future<void> test_allKnownBuilders() => check('''
class Box extends Widget { Box(int value); }
void f(Readable<int> s) {
  LayoutBuilder(builder: (_, _) => Box(s./*[*/value/*]*/));
  AnimatedBuilder(builder: (_, _) => Box((s)./*[*/value/*]*/));
  TweenAnimationBuilder(builder: (_, _, _) => Box(s./*[*/value/*]*/));
  DraggableScrollableSheet(builder: (_, _) => Box((s../*[*/value/*]*/).peek()));
  showDialog(builder: (_) => Box(s./*[*/value/*]*/));
  showModalBottomSheet(builder: (_) => Box(s./*[*/value/*]*/));
}
''', imports: widgetImports);

  // Builders by type, for callees that defer them.
  Future<void> test_buildersByType() => check(
    '''
class Box extends Widget { Box(int value); }
void f(Readable<int> s) {
  ListView.builder(itemBuilder: (_, _) => Box(s./*[*/value/*]*/));
  SliverChildBuilderDelegate((_, _) => Box(s./*[*/value/*]*/));
  OverlayEntry(builder: (_) => Box(s./*[*/value/*]*/));
  Builder(builder: (_) => Box(s./*[*/value/*]*/));
  FutureBuilder<int>(builder: (_, _) => Box(s./*[*/value/*]*/));
  StreamBuilder<int>(builder: (_, _) => Box(s./*[*/value/*]*/));
  PageRouteBuilder<void>(pageBuilder: (_, _, _) => Box(s./*[*/value/*]*/));
  showGeneralDialog<void>(pageBuilder: (_, _, _) => Box(s./*[*/value/*]*/));
  PopupMenuButton(itemBuilder: (_) => [Box(s./*[*/value/*]*/)]);
  OverlayEntry(builder: (_) => Reactive(builder: (_) => Box(s.value)));
}
''',
    imports: "$widgetImports\nimport 'package:rill_flutter/rill_flutter.dart';",
  );

  // Only Flutter's own deferring APIs are known
  // callees. A widget or function declared elsewhere may run the builder at
  // once — in an initializer list, or before returning its Future — inside
  // the Reactive that tracks it; the lint cannot tell and does not report.
  Future<void> test_calleesOutsideFlutterAreNotReported() => check('''
class Box extends Widget { Box(int value); }
class Card extends Widget { Card({required Widget Function(BuildContext) body}); }
class Prebuilt extends Widget {
  Prebuilt(BuildContext c, Widget Function(BuildContext) build)
    : child = build(c);
  final Widget child;
}
Future<void> runNow(BuildContext c, Widget Function(BuildContext) build) {
  build(c);
  return Future.value();
}
void f(Readable<int> s, BuildContext context) {
  Card(body: (_) => Box(s.value));
  Prebuilt(context, (_) => Box(s.value));
  runNow(context, (_) => Box(s.value));
  showDialog(builder: (_) => Box(s./*[*/value/*]*/));
}
''', imports: widgetImports);

  // A builder a local helper calls synchronously is tracked by the
  // Reactive around it; so are rill's own tracked readers.
  Future<void> test_synchronousHelperAndTrackedReaders() => check(
    '''
class Box extends Widget { Box(int value); }
Widget card(BuildContext c, Widget Function(BuildContext) body) => body(c);
void run(Widget Function(BuildContext) body) {}
void f(Readable<int> s, BuildContext context) {
  Reactive(builder: (c) => card(c, (_) => Box(s.value)));
  run((_) => Box(s.value));
  ReactiveLayoutBuilder(builder: (_, _) => Box(s.value));
}
''',
    imports: "$widgetImports\nimport 'package:rill_flutter/rill_flutter.dart';",
  );

  // A subclass of a tracked reader is never a
  // deferring callee, however it forwards its builder (unchanged it is
  // tracked; otherwise the lint cannot tell). A read in a closure nested
  // inside a builder is left to the runtime guard: the lint only reports
  // the closure handed directly to a deferring callee (docs/lint.md#分层).
  Future<void> test_subclassesAndNestedClosuresAreNotReported() => check(
    '''
class Box extends Widget { Box(num value); }
class Column extends Widget { Column({List<Widget> children = const []}); }
class Named extends Reactive { Named({required super.builder}); }
class Explicit extends Reactive {
  Explicit(Widget Function(BuildContext) b) : super(builder: b);
}
class Redirect extends Reactive {
  Redirect(Widget Function(BuildContext) b) : this.named(b);
  Redirect.named(Widget Function(BuildContext) b) : super(builder: b);
}
class Chained extends Reactive {
  Chained(Widget Function(BuildContext) b) : super(builder: b);
}
class Again extends Chained {
  Again(Widget Function(BuildContext) c) : super(c);
}
class Wrapped extends Reactive {
  Wrapped(Widget Function(BuildContext) content)
    : super(builder: (_) => Builder(builder: content));
}
void f(Readable<int> s, List<int> items) {
  Named(builder: (_) => Box(s.value));
  Explicit((_) => Box(s.value));
  Redirect((_) => Box(s.value));
  Again((_) => Box(s.value));
  Wrapped((_) => Box(s.value));
  Builder(builder: (_) => Box([0, 1].map((_) => s.value).length));
  Builder(builder: (_) => Box([0].map((_) => s.value).toList().first));
  Builder(builder: (_) => Column(children: List.generate(1, (_) => Box(s.value))));
  Builder(builder: (_) { items.forEach((_) => s.value); return Box(0); });
  Builder(builder: (_) { Future(() => s.value); return Box(0); });
  Builder(builder: (_) { final widths = [0].map((_) => s.value); return Reactive(builder: (_) => Box(widths.first)); });
  List.generate(1, (_) => Box(s.value));
  Builder(builder: (_) => Box(s./*[*/value/*]*/));
}
''',
    imports: "$widgetImports\nimport 'package:rill_flutter/rill_flutter.dart';",
  );

  Future<void> test_plainCustomPainterPaint() => check(
    '''
class Plain extends CustomPainter {
  Plain(this.s);
  final Readable<int> s;
  void paint(Canvas canvas, Size size) {
    s./*[*/value/*]*/;
    s.peek();
  }
}
class Tracked extends ReactivePainter {
  Tracked(this.s);
  final Readable<int> s;
  void paint(Canvas canvas, Size size) => s.value;
}
''',
    imports: "$widgetImports\nimport 'package:rill_flutter/rill_flutter.dart';",
  );

  Future<void> test_fixAddsTrackingAndPreservesImports() async {
    const source = '''
import 'package:flutter/widgets.dart';
import 'package:rill/rill.dart';
class Box extends Widget { Box(int value); }
Widget f(Readable<int> rillWidgets) {
  return LayoutBuilder(builder: (_, _) {
    return Box(rillWidgets.value);
  });
}
''';
    writeTestPackageConfig2();
    final offset = source.indexOf('rillWidgets.value') + 'rillWidgets.'.length;
    await assertDiagnostics(source, [lint(offset, 'value'.length)]);
    final session = result.session;
    final library = await session.getResolvedLibrary(result.path);
    final builder = ChangeBuilder(session: session);
    await WrapInReactive(
      context: CorrectionProducerContext.createResolved(
        libraryResult: library as ResolvedLibraryResult,
        unitResult: result,
        diagnostic: result.diagnostics.single,
        selectionOffset: offset,
        selectionLength: 'value'.length,
      ),
    ).compute(builder);
    final fixed = SourceEdit.applySequence(
      source,
      builder.sourceChange.edits.single.edits,
    );
    expect(fixed, contains('as rillWidgets_ show Reactive'));
    expect(
      fixed,
      contains(
        'return rillWidgets_.Reactive(builder: (_) => Box(rillWidgets.value));',
      ),
    );
    final fixedFile = newFile("$testPackageRootPath/lib/fixed.dart", fixed);
    await assertNoDiagnosticsInFile(fixedFile.path);
  }

  Future<void> test_trackedDeferredAndLookalike() => check(
    '''
class Box extends Widget { Box(int value); }
void showDialog({required Widget Function(BuildContext) builder}) {}
void f(Signal<int> s) {
  showDialog(builder: (_) => Box(s.value));
  LayoutBuilder(builder: (_, _) {
    s.value = 7;
    final later = () => s.value;
    return Reactive(builder: (_) => Box(s.value + s.peek()));
  });
}
''',
    imports: '''
import 'package:flutter/widgets.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';
''',
  );
}

@reflectiveTest
class AfterAwaitTest extends RillTest {
  @override
  RillLint get kind => RillLint.writeAfterAwait;

  Future<void> test_branchesAndTry() => check('''
Future<void> f(Signal<int> s, bool b) async {
  if (b) { await Future<void>.value(); /*[*/s.value = 1/*]*/; }
  else { s.value = 2; }
  /*[*/s.value = 3/*]*/;
}
Future<void> g(Signal<int> s) async {
  try { await Future<void>.value(); }
  catch (_) { /*[*/s.value = 1/*]*/; }
  finally { /*[*/s.value = 2/*]*/; }
}
Future<void> h(Signal<int> s, int n) async {
  switch (n) {
    case 1: await Future<void>.value(); /*[*/s.value = 1/*]*/;
    case 2: s.value = 2;
  }
  /*[*/s.value = 3/*]*/;
}
''');

  Future<void> test_expressionOrder() => check('''
Future<void> f(Signal<int> s, bool b) async {
  b ? (await Future<int>.value(0)) : (s.value = 0);
  /*[*/s.value = await Future<int>.value(1)/*]*/;
}
Future<void> g(Signal<int> s) async {
  (await Future<bool>.value(true)) && (/*[*/s.value = 1/*]*/) > 0;
}
Future<void> h(Signal<int> s) async {
  await Future<int>.value(s.value = 1);
  s/*[*/..update((n) => n + 1)/*]*/;
}
Future<void> i(Signal<int> s, bool b) async {
  b ? 0 : (/*[*/s.value = await Future<int>.value(2)/*]*/);
}
''');

  Future<void> test_loopsAndCascade() => check('''
Future<void> f(Signal<int> s) async {
  for (var i = 0; i < 2; i++) {
    await Future<void>.value();
    s/*[*/..value = i/*]*/;
  }
}
Future<void> g(Signal<int> s) async {
  while (await Future<bool>.value(true)) { /*[*/s.value = 2/*]*/; }
}
Future<void> h(Signal<int> s) async {
  for (var i = 0; i < 2; await Future<void>.value()) {
    s.value = i++;
  }
}
Future<void> i(Signal<int> s) async {
  do { s.value = 1; } while (await Future<bool>.value(false));
}
Future<void> j(Signal<int> s, Stream<int> items) async {
  await for (final item in items) { /*[*/s.value = item/*]*/; }
  /*[*/s.value = 0/*]*/;
}
''');

  // A Timer or listener callback is a discrete event (like a tap), not a
  // continuation of the async body: intentionally not followed (decision E).
  Future<void> test_timerCallbackIsAnEvent() => check('''
Future<void> f(Signal<int> s, Stream<int> ticks) async {
  await Future<void>.value();
  Timer(Duration.zero, () { s.value = 1; });
  ticks.listen((_) => s.update((n) => n + 1));
  /*[*/s.value = 2/*]*/;
}
''', imports: "import 'dart:async';\nimport 'package:rill/rill.dart';");

  Future<void> test_transactAfterAwait() => check('''
Future<void> f(Signal<int> s, Slot slot) async {
  transact((p) => p.set(s, 0));
  await Future<void>.value();
  /*[*/transact((p) => p.set(s, 1))/*]*/;
  await slot.run((t) async {
    await Future<void>.value();
    t.publish((p) => p.set(s, 2));
  });
}
''');

  Future<void> test_publishAndClosureBoundary() => check('''
Future<void> f(Signal<int> s, Slot slot) async {
  final later = () async { await Future<void>.value(); };
  s.value = 0;
  await slot.run((t) async {
    await Future<void>.value();
    t.publish((p) => p.set(s, 1));
    /*[*/s.value = 2/*]*/;
  });
}
''');

  Future<void> test_testDirectoriesAreExempt() async {
    writeTestPackageConfig2();
    const code = '''
import 'package:rill/rill.dart';
Future<void> f(Signal<int> s) async {
  await Future<void>.value();
  s.value = 1;
}
''';
    for (final dir in ['test', 'integration_test']) {
      final file = newFile('$testPackageRootPath/$dir/write_test.dart', code);
      await assertDiagnosticsInFile(file.path, []);
    }
    final file = newFile('$testPackageRootPath/lib/write.dart', code);
    await assertDiagnosticsInFile(file.path, [
      lint(code.indexOf('s.value = 1'), 's.value = 1'.length),
    ]);
  }

  Future<void> test_knownLimitations() => check('''
void helper(Signal<int> s) { s.value = 3; }
Future<void> f(Signal<int> s) async {
  for (var i = 0; i < 2; i++) {
    // Known limitation: the previous iteration's await is a back edge.
    s.value = i;
    await Future<void>.value();
  }
  // Known limitation: invoking a delayed closure is a separate body.
  final deferred = () { s.value = 2; };
  deferred();
  // Known limitation: a helper's body is outside the local analysis.
  helper(s);
}
''');
}

@reflectiveTest
class EffectLifecycleTest extends FrameTest {
  @override
  RillLint get kind => RillLint.effectInLifecycle;

  static const imports =
      "$widgetImports\nimport 'package:rill_flutter/rill_flutter.dart';";

  Future<void> test_stateMembersBuildPaintAndScopeEffect() => check('''
class Demo extends State<Widget> with ReactiveState<Widget> {
  final s = signal(0);
  late final stop = /*[*/effect(() => s.value, (_, _, _) {})/*]*/;
  void initState() {
    /*[*/effect(() => s.value, (_, _, _) {})/*]*/;
    /*[*/scope.effect(() => s.value, (_, _, _) {})/*]*/;
    _watch();
  }
  void _watch() { /*[*/effect(() => s.value, (_, _, _) {})/*]*/; }
  Widget build(BuildContext context) {
    /*[*/effect(() => s.value, (_, _, _) {})/*]*/;
    return throw 0;
  }
}
class Page extends ReactiveWidget {
  final s = signal(0);
  Widget build(BuildContext context) {
    /*[*/effect(() => s.value, (_, _, _) {})/*]*/;
    return throw 0;
  }
}
class Dots extends ReactivePainter {
  final s = signal(0);
  void paint(Canvas canvas, Size size) {
    /*[*/effect(() => s.value, (_, _, _) {})/*]*/;
  }
}
class Plain extends CustomPainter {
  final scope = Scope();
  void paint(Canvas canvas, Size size) {
    /*[*/scope.effect(() => 0, (_, _, _) {})/*]*/;
  }
}
''', imports: imports);

  Future<void> test_watchCallbacksAndPlainCode() => check('''
class Demo extends State<Widget> with ReactiveState<Widget> {
  final s = signal(0);
  void initState() {
    watch(() => s.value, (_, _, _) {});
    final later = () => effect(() => s.value, (_, _, _) {});
  }
  static void Function() shared(Signal<int> s) =>
      effect(() => s.value, (_, _, _) {});
  Widget build(BuildContext context) => throw 0;
}
class Store {
  final s = signal(0);
  final scope = Scope();
  late final stop = effect(() => s.value, (_, _, _) {});
  void start() {
    effect(() => s.value, (_, _, _) {});
    scope.effect(() => s.value, (_, _, _) {});
  }
}
class Lookalike { void effect(Object a, Object b) {} }
class Other2 extends State<Widget> {
  final l = Lookalike();
  void initState() { l.effect(0, 0); }
  Widget build(BuildContext context) => throw 0;
}
class Plain extends StatelessWidget {
  final s = signal(0);
  void helper() { effect(() => s.value, (_, _, _) {}); }
  Widget build(BuildContext context) => throw 0;
}
void Function() effectLookalike(Object a, Object b) => throw 0;
class Other extends State<Widget> {
  Widget build(BuildContext context) {
    effectLookalike(0, 0);
    return throw 0;
  }
}
''', imports: imports);
}

@reflectiveTest
class AsyncStarStreamTest extends RillTest {
  @override
  RillLint get kind => RillLint.asyncStarStream;

  Future<void> test_asyncBodies() => check('''
final s = signal(0);
final a = computedStream(/*[*/(_) async* {
  yield s.value;
}/*]*/);
final c = computedStream((/*[*/(_) async* {}/*]*/));
''');

  Future<void> test_synchronousAndOthers() => check('''
final s = signal(0);
final a = computedStream((_) => Stream.value(s.value));
final b = computedStream((_) {
  final v = s.value;
  return Stream.value(v);
});
final c = computedAsync((_) async => s.value);
Stream<int> tear(Object q) async* {}
final d = computedStream(tear);
AsyncComputed<int> computedStreamLookalike(Object fn) => throw 0;
final e = computedStreamLookalike((_) async* {});
''');
}
