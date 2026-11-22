import 'dart:async';

import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:test/test.dart';

final class _Observer extends Subscriber {
  _Observer(this.read);
  final int Function() read;
  final values = <int>[];
  int? consumed;

  void attach() => consumed = track(read);

  @override
  void notify() => afterFlush(this, () {
    final next = track(read);
    if (next != consumed) {
      values.add(next);
      consumed = next;
    }
  });
}

Matcher _code(String code) => isA<StateError>().having(
  (error) => error.message,
  'code',
  startsWith(code),
);

void main() {
  tearDown(() {
    Rill.onError = null;
    diagnosticHook = null;
  });

  test('typed reads, equality and prepare before install', () {
    final source = signal([1], equals: Equality.deep);
    final before = source.value;
    final Readable<List<int>> view = computed(() => source.value);
    final derived = view.value;
    source.value = [1];
    expect(source.value, same(before));
    expect(view.value, same(derived));
    source.update((value) => [...value, 2]);
    expect(view.peek(), [1, 2]);

    final mixedNumber = signal<num>(-0.0);
    final mixedRevision = nodeRevision(mixedNumber);
    mixedNumber.value = 0;
    expect(mixedNumber.value.isNegative, isTrue);
    expect(nodeRevision(mixedNumber), mixedRevision);
    final byIdentity = signal<num>(-0.0, equals: Equality.identity);
    byIdentity.value = 0;
    expect(byIdentity.value, isA<int>());

    final sameObject = signal(Object(), equals: Equality.never);
    final previousRevision = nodeRevision(sameObject);
    sameObject.value = sameObject.value;
    expect(nodeRevision(sameObject), greaterThan(previousRevision));

    final rejected = Object();
    final guarded = signal(
      0,
      equals: (a, b) {
        if (a == 0 && b == 2) throw rejected;
        return a == b;
      },
    );
    final observed = <int>[];
    final stop = effect(() => guarded.value, (value, _, _) {
      observed.add(value);
    });
    addTearDown(stop);
    batch(() {
      guarded.value = 1;
      final installed = nodeRevision(guarded);
      expect(() => guarded.value = 2, throwsA(same(rejected)));
      expect(nodeRevision(guarded), installed);
    });
    expect(observed, [0, 1]);
  });

  test('equal computed output prevents effect apply', () {
    final source = signal(0);
    final parity = computed(() => source.value.isEven);
    final values = <bool>[];
    final stop = effect(() => parity.value, (value, _, _) {
      values.add(value);
    });
    addTearDown(stop);
    source.value = 2;
    expect(values, [true]);
    source.value = 3;
    expect(values, [true, false]);
  });

  test('installs advance inside batch and ABA stays quiet', () {
    final source = signal('A');
    final values = <String>[];
    final stop = effect(() => source.value, (value, _, _) {
      values.add(value);
    });
    addTearDown(stop);
    final initial = nodeRevision(source);
    batch(() {
      source.value = 'B';
      expect(nodeRevision(source), initial + 1);
      expect(source.peek(), 'B');
      source.value = 'A';
      expect(nodeRevision(source), initial + 2);
      source.value = 'A';
      expect(nodeRevision(source), initial + 2);
      expect(revisionClock, initial + 2);
      expect(values, ['A']);
    });
    // Peeking B is an explicit intermediate consumption. A subsequent
    // unconsumed ABA is coalesced by the graph while advancing revisions.
    values.clear();
    batch(() {
      source.value = 'B';
      source.value = 'A';
    });
    expect(nodeRevision(source), initial + 4);
    expect(values, isEmpty);
    expect(batch(() => 31), 31);
    source.value = 'C';
    expect(values, ['C']);
  });

  test('rft #50 split write-back, shared compute phase and cleanup', () {
    final a = signal(0);
    final b = signal(0);
    final hidden = signal(0);
    final log = <String>[];
    final scope = Scope();
    addTearDown(scope.dispose);
    scope.effect(
      () {
        log.add('c1:${a.value}');
        return a.value;
      },
      (value, previous, onCleanup) {
        log.add('a1:$value:$previous');
        hidden.value;
        b.value = value * 2;
        onCleanup(() => log.add('cleanup:$value'));
      },
    );
    scope.effect(
      () {
        log.add('c2:${a.value}:${b.value}');
        return b.value;
      },
      (value, previous, _) {
        log.add('a2:$value:$previous');
      },
    );
    log.clear();
    a.value = 5;
    expect(b.value, 10);
    expect(log, [
      'c1:5',
      'c2:5:0',
      'cleanup:0',
      'a1:5:0',
      'a2:0:0',
      'c2:5:10',
      'a2:10:0',
    ]);
    log.clear();
    hidden.value = 10;
    expect(log, isEmpty);
    scope.dispose();
    expect(log, ['cleanup:5']);
  });

  test('notify after all rounds, dedupe and compare final value', () {
    final gate = signal(false);
    final source = signal(0);
    final observer = _Observer(() => source.value)..attach();
    addTearDown(observer.dispose);
    final stop = effect(() => source.value, (value, _, _) {
      if (gate.peek() && value == 1) source.value = 0;
    });
    addTearDown(stop);
    final initial = nodeRevision(source);
    gate.value = true;
    source.value = 1;
    expect(nodeRevision(source), greaterThanOrEqualTo(initial + 2));
    expect(observer.values, isEmpty);
    source.value = 2;
    expect(observer.values, [2]);
  });

  test('untracked blocks dependency collection and preserves write guard', () {
    final a = signal(0, name: 'a');
    final b = signal(0);
    final invalid = computed(() => untracked(() => a.value = 1));
    expect(() => invalid.value, throwsA(_code('RILL_WRITE_IN_COMPUTATION')));
    expect(a.peek(), 0);
    final errors = <Object>[];
    Rill.onError = (error, _) => errors.add(error);
    final fail = effect(() => b.value = 1, (_, _, _) {});
    addTearDown(fail);
    expect(errors.single, _code('RILL_WRITE_IN_COMPUTATION'));
    final views = <int>[];
    final stop = effect<int>(() => a.value + untracked(() => b.value), (
      value,
      _,
      _,
    ) {
      views.add(value);
    });
    addTearDown(stop);
    b.value = 2;
    expect(views, [0]);
    a.value = 1;
    expect(views, [0, 3]);
  });

  test('preserve exception and stack, update branch after failed read', () {
    final choose = signal(false);
    final fail = signal(false);
    final unused = signal(7);
    final error = Object();
    final stack = StackTrace.fromString('original');
    final broken = computed(() {
      if (fail.value) Error.throwWithStackTrace(error, stack);
      return 7;
    });
    var runs = 0;
    final wrapped = computed(() {
      runs++;
      return choose.value ? unused.value : broken.value;
    });
    final results = <int>[];
    final errors = <Object>[];
    Rill.onError = (actual, trace) {
      errors.add(actual);
      expect(trace.toString(), stack.toString());
    };
    final stop = effect(() => wrapped.value, (value, _, _) {
      results.add(value);
    });
    addTearDown(stop);
    final before = nodeRevision(wrapped);
    fail.value = true;
    expect(errors.single, same(error));
    expect(() => wrapped.peek(), throwsA(same(error)));
    expect(nodeRevision(wrapped), greaterThan(before));
    expect(runs, 2);
    unused.value = 8;
    expect(runs, 2);
    fail.value = false;
    expect(results, [7, 7]);
    fail.value = true;
    choose.value = true;
    expect(results, [7, 7, 8]);
    fail.value = false;
    expect(runs, 5);
  });

  test('report only after sibling applies and route via current zone', () {
    final source = signal(0);
    final log = <Object>[];
    final failure = Object();
    final scope = Scope();
    addTearDown(scope.dispose);
    scope.effect(() {
      if (source.value == 1) throw failure;
      return source.value;
    }, (value, _, onCleanup) => onCleanup(() => log.add('release:$value')));
    scope.effect(() => source.value, (value, _, _) {
      log.add(value);
    });
    runZonedGuarded(() => source.value = 1, (error, _) => log.add(error));
    expect(log, [0, 'release:0', 1, failure]);
    source.value = 2;
    expect(log, [0, 'release:0', 1, failure, 2]);
  });

  test('recovering a failed read with a fallback is legal and silent', () {
    final trigger = signal(false);
    final failing = computed(() {
      if (trigger.value) throw 'failed';
      return 1;
    });
    final fallback = computed(() {
      try {
        return failing.value;
      } on Object {
        return 2;
      }
    }, name: 'fallback');
    final diagnostics = <(String, String?)>[];
    diagnosticHook = (code, name) => diagnostics.add((code, name));
    expect(fallback.value, 1);
    trigger.value = true;
    expect(fallback.value, 2);
    expect(diagnostics, isEmpty);
  });

  test('cold reads cache, first watch reconnects and last watch detaches', () {
    final events = <String>[];
    final selector = signal(false);
    final a = signal(
      1,
      watched: () => events.add('watch a'),
      unwatched: () => events.add('unwatch a'),
    );
    final b = signal(
      2,
      watched: () => events.add('watch b'),
      unwatched: () => events.add('unwatch b'),
    );
    var computes = 0;
    final child = computed(() {
      computes++;
      return selector.value ? b.value : a.value;
    });
    final tail = computed(() => child.value * 10);
    expect(tail.value, 10);
    expect(tail.value, 10);
    expect(computes, 1);
    expect(events, isEmpty);
    a.value = 3;
    expect(tail.value, 30);
    expect(computes, 2);
    final observed = <int>[];
    final stop1 = effect(() => tail.value, (_, _, _) {});
    final stop2 = effect(() => tail.value, (value, _, _) {
      observed.add(value);
    });
    addTearDown(stop1);
    addTearDown(stop2);
    expect(events, ['watch a']);
    expect(computes, 2);
    a.value = 4;
    stop1();
    a.value = 5;
    expect(observed, [30, 40, 50]);
    expect(events, ['watch a']);
    stop2();
    expect(events, ['watch a', 'unwatch a']);
    selector.value = true;
    final stop3 = effect(() => tail.value, (value, _, _) {
      observed.add(value);
    });
    expect(events, ['watch a', 'unwatch a', 'watch b']);
    b.value = 3;
    expect(observed, [30, 40, 50, 20, 30]);
    stop3();
    expect(events, ['watch a', 'unwatch a', 'watch b', 'unwatch b']);
    checkGraph([a, b, selector, child, tail]);
  });

  test('Scope: children first, reverse registration and disposed at entry', () {
    final root = Scope();
    final source = signal(0);
    final events = <String>[];
    final child = root.child();
    root.onDispose(() {
      expect(root.disposed, isTrue);
      events.add('root first');
    });
    final derived = computed(() => source.value);
    root.effect(
      () => derived.value,
      (_, _, onCleanup) => onCleanup(() => events.add('root effect')),
    );
    final nested = child.child();
    nested.onDispose(() => events.add('grandchild'));
    child.onDispose(() {
      expect(root.disposed && child.disposed, isTrue);
      events.add('child');
    });
    root.dispose();
    root.dispose();
    expect(events, ['grandchild', 'child', 'root effect', 'root first']);
    // The computed belongs to no owner: it outlives the Scope.
    expect(derived.value, 0);
    expect(subscriberCount(source), 0);
    checkGraph([source, derived]);
  });

  test('actual split effects reach exactly 100 feedback rounds', () {
    final source = signal(0, name: 'feedback');
    final witness = signal(0, name: 'witness');
    final enabled = signal(false);
    var feedback = 0;
    final stop = effect(() => (enabled.value, source.value), (value, _, _) {
      if (value.$1) {
        feedback++;
        source.value = value.$2 + 1;
        witness.value = feedback;
      }
    });
    addTearDown(stop);
    expect(
      () => enabled.value = true,
      throwsA(
        allOf(
          _code('RILL_INFINITE_LOOP'),
          predicate((Object error) => error.toString().contains('feedback')),
          predicate((Object error) => error.toString().contains('witness')),
        ),
      ),
    );
    expect(feedback, 100);
    enabled.value = false;
    source.value = 0;
    expect(source.value, 0);
  });

  test('sibling apply writes and fan-in settle in one following round', () {
    final scope = Scope();
    addTearDown(scope.dispose);
    final source = signal(0);
    final left = signal(0);
    final right = signal(0);
    final last = signal(0);
    final values = <(int, int, int)>[];
    scope.effect(() => source.value, (value, _, _) {
      left.value = value + 1;
      right.value = value + 2;
    });
    scope.effect(() => source.value, (value, _, _) {
      last.value = value + 3;
    });
    final pair = computed(() => (left.value, right.value, last.value));
    scope.effect(() => pair.value, (value, _, _) {
      values.add(value);
    });
    source.value = 10;
    expect(values, [(1, 2, 3), (11, 12, 13)]);
  });

  test('write-back settles on the initial run and on later writes', () {
    final source = signal(1);
    final derived = computed(() => source.value);
    final values = <int>[];
    final stop = effect(() => derived.value, (value, _, _) {
      values.add(value);
      if (value > 0) source.value = 0;
    });
    addTearDown(stop);
    expect(source.value, 0);
    expect(values, [1, 0]);
    source.value = 2;
    expect(source.value, 0);
    expect(values, [1, 0, 2, 0]);
  });

  test(
    'Scope: nested effects track independently and release with their owner',
    () {
      final root = Scope();
      final child = root.child();
      final a = signal(0);
      final b = signal(0);
      final events = <String>[];
      // The inner effect names its owner: it is not the outer run's.
      final stopOuter = root.effect(() => a.value, (value, _, onCleanup) {
        events.add('outer $value');
        if (value == 0) {
          child.effect(() => b.value, (value, _, onCleanup) {
            events.add('inner $value');
            onCleanup(() => events.add('release $value'));
          });
        }
        onCleanup(() => events.add('outer release $value'));
      });
      b.value = 1;
      expect(events, ['outer 0', 'inner 0', 'release 0', 'inner 1']);
      stopOuter();
      b.value = 2;
      expect(events.last, 'inner 2');
      root.dispose();
      expect(events.last, 'release 2');
      checkGraph([a, b]);
    },
  );

  test('apply write switches the other effect to its new dependencies', () {
    final selection = signal(false);
    final input = signal(false);
    final left = signal(1);
    final right = signal(2);
    final drive = effect(() => input.value, (value, _, _) {
      selection.value = value;
    });
    addTearDown(drive);
    final results = <int>[];
    final consume = effect(() => selection.value ? right.value : left.value, (
      value,
      _,
      _,
    ) {
      results.add(value);
    });
    addTearDown(consume);
    input.value = true;
    left.value = 3;
    right.value = 4;
    expect(results, [1, 2, 4]);
  });

  test('a three-effect feedback loop through a computed is bounded', () {
    final scope = Scope();
    addTearDown(scope.dispose);
    final enabled = signal(false);
    final a = signal(0, name: 'a');
    final b = signal(0, name: 'b');
    final c = signal(0, name: 'c');
    final derived = computed(() => c.value);
    scope.effect(() => a.value, (value, _, _) {
      b.value = value;
    });
    scope.effect(() => b.value, (value, _, _) {
      c.value = value;
    });
    scope.effect(() => (enabled.value, derived.value), (value, _, _) {
      if (value.$1) a.value = value.$2 + 1;
    });
    expect(() => enabled.value = true, throwsA(_code('RILL_INFINITE_LOOP')));
    expect(a.value, greaterThan(0));
    expect(b.value, greaterThan(0));
    expect(c.value, greaterThan(0));
    enabled.value = false;
    a.value = 400;
    expect(derived.value, 400);
  });
  test(
    'a conditional computed cycle errors and recovers without a back edge',
    () {
      final enabled = signal(false);
      late Computed<int> a;
      final b = computed(() => a.value + 1);
      a = computed(() => enabled.value ? b.value : 3);
      expect(b.value, 4);
      enabled.value = true;
      expect(() => b.value, throwsA(_code('RILL_CYCLE')));
      enabled.value = false;
      expect(b.value, 4);

      final values = <int>[];
      final errors = <Object>[];
      Rill.onError = (error, _) => errors.add(error);
      final stop = effect(() => b.value, (value, _, _) {
        values.add(value);
      });
      enabled.value = true;
      expect(errors.single, _code('RILL_CYCLE'));
      expect(values, [4]);
      enabled.value = false;
      expect(values, [4, 4]);
      stop();
      checkGraph([enabled, a, b]);
    },
  );

  test(
    'Scope unlinks a stopped effect without shifting its other cleanups',
    () {
      final scope = Scope();
      final log = <String>[];
      final child = scope.child();
      child.onDispose(() => log.add('child'));
      void repeated() => log.add('repeated');
      scope.onDispose(repeated);
      scope.onDispose(() => log.add('first'));
      final stop = scope.effect(
        () => 0,
        (_, _, onCleanup) => onCleanup(() => log.add('effect')),
      );
      scope.onDispose(() => log.add('last'));
      scope.onDispose(repeated);
      stop();
      stop();
      expect(log, ['effect']);
      scope.dispose();
      expect(log, ['effect', 'child', 'repeated', 'last', 'first', 'repeated']);
    },
  );
}
