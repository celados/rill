import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:test/test.dart';

Matcher code(String code) => isA<StateError>().having(
  (error) => error.message,
  'message',
  startsWith(code),
);

final class _Observer extends Subscriber {
  _Observer(this.onNotify);
  final void Function(_Observer) onNotify;

  @override
  void notify() => onNotify(this);
}

void main() {
  tearDown(() {
    Rill.onError = null;
    diagnosticHook = null;
  });

  for (final enterA in [true, false]) {
    for (final observed in [false, true]) {
      test('first cycle via ${enterA ? 'a' : 'b'}, observed=$observed', () {
        final gate = signal(true);
        late Computed<int> a;
        late Computed<int> b;
        a = computed(() => gate.value ? b.value : 3, name: 'a');
        b = computed(() => a.value + 1, name: 'b');
        final first = enterA ? a : b;
        final second = enterA ? b : a;
        final values = <int>[];
        final errors = <Object>[];
        Rill.onError = (error, _) => errors.add(error);
        if (observed) {
          final stop = effect(() => first.value, (value, _, _) {
            values.add(value);
          });
          addTearDown(stop);
          expect(errors, [code('RILL_CYCLE')]);
        } else {
          expect(() => first.value, throwsA(code('RILL_CYCLE')));
        }
        expect(() => second.value, throwsA(code('RILL_CYCLE')));
        gate.value = false;
        if (observed) expect(values, [enterA ? 3 : 4]);
        // Read the node that may have cached a cycle without any input first.
        expect(b.value, 4);
        expect(a.value, 3);
        checkGraph([gate, a, b]);
      });
    }
  }

  test('each deferred observer consumes the settled graph', () {
    final start = signal(0);
    final phase = signal(0);
    final derived = computed(() => start.value * phase.value);
    final consumed = <int>[];
    final stop = effect(() => phase.value, (value, _, _) {
      if (value == 1) phase.value = 0;
    });
    addTearDown(stop);
    final first = _Observer((self) {
      afterFlush(self, () => phase.value = 1);
    });
    final second = _Observer((self) {
      afterFlush(self, () => consumed.add(self.track(() => derived.value)));
    });
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    first.track(() => start.value);
    second.track(() {
      start.value;
      consumed.add(derived.value);
    });
    start.value = 1;
    expect(consumed, [0, 0]);
  });

  test('a fatal compute leaves earlier prepared and later effects armed', () {
    final early = signal(0);
    final x = signal(0);
    final y = signal(0);
    final fatal = StackOverflowError();
    final scope = Scope();
    addTearDown(scope.dispose);
    final before = <int>[];
    final after = <int>[];
    scope.effect(() => early.value, (v, _, _) {
      before.add(v);
    });
    scope.effect(() {
      if (x.value == 1) throw fatal;
      return x.value;
    }, (_, _, _) {});
    scope.effect(() => y.value, (v, _, _) {
      after.add(v);
    });
    expect(
      () => batch(() {
        early.value = 1;
        x.value = 1;
        y.value = 1;
      }),
      throwsA(same(fatal)),
    );
    expect(before, [0]);
    expect(after, [0]);
    y.value = 2;
    expect(after, [0, 2]);
    early.value = 2;
    expect(before, [0, 1, 2]);
  });

  test('a fatal refresh never exposes an obsolete hot or cold value', () {
    final source = signal(0);
    final fatal = StackOverflowError();
    final hot = computed(() {
      if (source.value == 1) throw fatal;
      return source.value;
    });
    final values = <int>[];
    final stop = effect(() => hot.value, (v, _, _) {
      values.add(v);
    });
    addTearDown(stop);
    expect(() => source.value = 1, throwsA(same(fatal)));
    expect(() => hot.value, throwsA(same(fatal)));
    source.value = 2;
    expect(values, [0, 2]);
    expect(() => source.value = 1, throwsA(same(fatal)));
    stop();
    expect(() => hot.value, throwsA(same(fatal)));
    source.value = 3;
    expect(hot.value, 3);
  });

  test('a fatal from apply wins over a throwing ordinary error handler', () {
    final source = signal(false);
    final fatal = OutOfMemoryError();
    final stack = StackTrace.fromString('fatal apply stack');
    final scope = Scope();
    addTearDown(scope.dispose);
    final reported = <Object>[];
    Rill.onError = (error, _) {
      reported.add(error);
      throw StateError('handler');
    };
    scope.effect(() => source.value, (on, _, _) {
      if (on) throw StateError('apply');
    });
    scope.effect(() => source.value, (on, _, _) {
      if (on) Error.throwWithStackTrace(fatal, stack);
    });
    try {
      source.value = true;
      fail('Expected fatal apply');
    } on Object catch (error, trace) {
      expect(error, same(fatal));
      expect(trace.toString(), stack.toString());
    }
    expect(reported, [isA<StateError>()]);
  });

  test('a fatal from the handler wins over its earlier ordinary error', () {
    final source = signal(false);
    final fatal = StackOverflowError();
    final stack = StackTrace.fromString('fatal handler stack');
    final scope = Scope();
    addTearDown(scope.dispose);
    final reported = <String>[];
    Rill.onError = (error, _) {
      reported.add((error as StateError).message);
      if (reported.length == 2) Error.throwWithStackTrace(fatal, stack);
      throw StateError('ordinary handler');
    };
    for (final name in ['one', 'two', 'three']) {
      scope.effect(() => source.value, (on, _, _) {
        if (on) throw StateError(name);
      });
    }
    try {
      source.value = true;
      fail('Expected fatal handler');
    } on Object catch (error, trace) {
      expect(error, same(fatal));
      expect(trace.toString(), stack.toString());
    }
    expect(reported, ['one', 'two', 'three']);
  });

  test('a throwing subscriber does not interrupt propagation', () {
    final source = signal(0);
    final failure = StateError('observer');
    final observer = _Observer((_) => throw failure);
    observer.track(() => source.value);
    addTearDown(observer.dispose);
    final values = <int>[];
    final errors = <Object>[];
    Rill.onError = (error, _) {
      errors.add(error);
      expect(values, [0, 1]);
    };
    final stop = effect(() => source.value, (v, _, _) {
      values.add(v);
    });
    addTearDown(stop);
    source.value = 1;
    expect(errors, [same(failure)]);
    observer.dispose();
    source.value = 2;
    expect(values, [0, 1, 2]);
  });

  test('deep Scope disposal is iterative, child-first and LIFO', () {
    final root = Scope();
    var leaf = root;
    for (var depth = 0; depth < 20000; depth++) {
      leaf = leaf.child();
    }
    final order = <String>[];
    root.onDispose(() => order.add('root first'));
    root.onDispose(() => order.add('root last'));
    leaf.onDispose(() {
      expect(root.disposed, isTrue);
      expect(leaf.disposed, isTrue);
      order.add('leaf');
    });
    root.dispose();
    root.dispose();
    expect(order, ['leaf', 'root last', 'root first']);
  });
}
