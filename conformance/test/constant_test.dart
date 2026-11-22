// Readable.constant conformance: a fixed value is a Readable everywhere a
// Readable is accepted, and it never changes, notifies or links. Each case
// is registered in docs/conformance.md (§ Readable.constant).
import 'package:rill/debug.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:test/test.dart';

void main() {
  test('K1 value, peek and name', () {
    final yes = Readable.constant(true, name: 'yes');
    expect((yes.value, yes.peek(), yes.name), (true, true, 'yes'));
    expect(Readable.constant(0).name, isNull);
    final list = <int>[1];
    expect(identical(Readable.constant(list).value, list), isTrue);
  });

  test('K2 a computed over constants evaluates once, cold and hot', () {
    final a = Readable.constant(2);
    var runs = 0;
    final doubled = computed(() {
      runs++;
      return a.value * 2;
    });
    expect((doubled.value, doubled.value, runs), (4, 4, 1));
    final seen = <int>[];
    final stop = effect(() => doubled.value, (v, _, _) {
      seen.add(v);
    });
    signal(0).value = 1; // an unrelated write
    expect(runs, 1);
    expect(seen, [4]);
    stop();
  });

  test('K3 a constant beside a signal: only the signal drives', () {
    final fixed = Readable.constant(10);
    final input = signal(1);
    final seen = <int>[];
    final stop = effect(() => fixed.value + input.value, (v, _, _) {
      seen.add(v);
    });
    input.value = 2;
    expect(seen, [11, 12]);
    stop();
  });

  test('K4 readers keep no edge to a constant', () {
    final fixed = Readable.constant('x');
    final derived = computed(() => fixed.value);
    final stop = effect(() => derived.value, (_, _, _) {});
    expect(subscriberCount(fixed), 0);
    expect(subscriberCount(derived), 1);
    checkGraph([fixed, derived]);
    stop();
  });

  test('K5 Unchanged on a constant always holds', () async {
    final scope = Scope();
    final fixed = Readable.constant(1);
    final target = signal(0);
    final revision = nodeRevision(fixed);
    final outcome = await scope.slot().run((task) async {
      final asked = Unchanged(fixed);
      await Future<void>.value();
      return task.publish((p) {
        p.require(asked);
        p.set(target, 1);
      });
    });
    expect((outcome as Done<bool>).value, isTrue);
    expect((target.value, nodeRevision(fixed)), (1, revision));
    scope.dispose();
  });

  test('K6 diagnostics name the constant and list it in the graph', () {
    final fixed = Readable.constant(false, name: 'feature.off');
    final info = RillDebug.describe(fixed)!;
    expect((info.kind, info.label), ('constant', 'feature.off'));
    final nodes = (RillDebug.graph()['nodes']! as List).cast<Map>();
    final node = nodes.singleWhere((n) => n['id'] == info.id);
    expect(node['valueType'], 'bool');
    expect([node['deps'], node['subs']], [isEmpty, isEmpty]);
  });
}
