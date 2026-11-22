import 'dart:math';

import 'package:rill/internal.dart';
import 'package:rill/rill.dart';

enum _Mutation { write, dispose, stop }

String? _errorCode(void Function() read) {
  try {
    read();
    return null;
  } on StateError catch (error) {
    return error.message.split(':').first;
  }
}

void _expect(Object? actual, Object? expected) {
  if (actual != expected) throw StateError('expected $expected, got $actual');
}

/// A Scope owns an effect; an unowned effect is stopped by its disposer.
/// Derived nodes belong to no one: disposing the owner stops only
/// its effect, and the computed it read stays readable and observable.
int _lifetimeEpisode(Random random, void Function(String) trace) {
  final initial = random.nextInt(100);
  final source = signal(initial);
  final owner = Scope();
  final leaf = computed(() => source.value);
  final selected = signal(true);
  final parent = computed(() => selected.value ? leaf.value + 1 : source.value);
  var actual = -1;
  var owned = -1;
  owner.effect(() => leaf.value, (value, _, _) {
    owned = value;
  });
  void Function()? stop;
  final previous = Rill.onError;
  final errors = <String>[];
  Rill.onError = (error, _) {
    errors.add((error as StateError).message.split(':').first);
  };
  var steps = 0;
  void step(String name, void Function() action) {
    trace(name);
    action();
    checkGraph([source, selected, leaf, parent]);
    steps++;
  }

  void subscribe() {
    stop = effect(() => parent.value, (value, _, _) {
      actual = value;
    });
  }

  try {
    step('subscribe', () {
      subscribe();
      _expect(actual, initial + 1);
      _expect(owned, initial);
    });
    final order = [..._Mutation.values]..shuffle(random);
    batch(() {
      for (final operation in order) {
        step('batch: ${operation.name}', () {
          switch (operation) {
            case _Mutation.write:
              source.value = initial + 17;
            case _Mutation.dispose:
              owner.dispose();
            case _Mutation.stop:
              stop!();
          }
          _expect(actual, initial + 1);
        });
      }
    });
    step('cold read after disposal', () {
      _expect(owned, initial);
      _expect(parent.value, initial + 18);
      _expect(subscriberCount(leaf), 0);
    });
    step('resubscribe', () {
      subscribe();
      _expect(actual, initial + 18);
      _expect(errors.length, 0);
    });
    step('select surviving source', () {
      selected.value = false;
      _expect(actual, initial + 17);
    });
    step('write surviving source', () {
      source.value = initial - 5;
      _expect(actual, initial - 5);
      _expect(owned, initial);
    });
    step('unsubscribe again', () => stop!());
    step(
      'read surviving source cold',
      () => _expect(parent.value, initial - 5),
    );
    return steps;
  } finally {
    stop?.call();
    owner.dispose();
    Rill.onError = previous;
  }
}

int _cycleEpisode(Random random, void Function(String) trace) {
  final initial = random.nextInt(100);
  final input = signal(initial);
  final gate = signal(true);
  late final Computed<int> a;
  late final Computed<int> b;
  a = computed(() => gate.value ? b.value : input.value);
  b = computed(() => a.value + 1);
  final enterA = random.nextBool();
  final observed = random.nextBool();
  final first = enterA ? a : b;
  final second = enterA ? b : a;
  final previous = Rill.onError;
  String? error;
  int? applied;
  Rill.onError = (value, _) {
    error = (value as StateError).message.split(':').first;
  };
  void Function()? stop;
  var steps = 0;
  void step(String name, void Function() action) {
    trace(name);
    action();
    checkGraph([gate, input, a, b]);
    steps++;
  }

  try {
    step('first cycle via ${enterA ? 'a' : 'b'}, observed=$observed', () {
      if (observed) {
        stop = effect(() => first.value, (value, _, _) {
          applied = value;
        });
        _expect(error, 'RILL_CYCLE');
      } else {
        _expect(_errorCode(() => first.value), 'RILL_CYCLE');
      }
    });
    step('read other cyclic entry', () {
      _expect(_errorCode(() => second.value), 'RILL_CYCLE');
    });
    step('break cycle', () {
      gate.value = false;
      if (observed) _expect(applied, initial + (enterA ? 0 : 1));
    });
    final readOrder = [a, b]..shuffle(random);
    for (final node in readOrder) {
      step('read recovered entry', () {
        _expect(node.value, initial + (identical(node, b) ? 1 : 0));
      });
    }
    step('write after recovery', () {
      input.value = initial + 19;
      if (observed) _expect(applied, initial + (enterA ? 19 : 20));
    });
    step('stop observer', () => stop?.call());
    step('read recovered a cold', () => _expect(a.value, initial + 19));
    step('read recovered b cold', () => _expect(b.value, initial + 20));
    step('trace graph after recovery', () {
      input.value = initial + 20;
      _expect(b.value, initial + 21);
    });
    return steps;
  } finally {
    stop?.call();
    Rill.onError = previous;
  }
}

/// Generate mixed lifetime and first-cycle episodes against a value/error
/// oracle. The original differential fuzz still covers the shared API.
int runLifecycleFuzz(int seed, int episodes) {
  final random = Random(seed);
  var steps = 0;
  for (var index = 0; index < episodes; index++) {
    final trace = <String>[];
    try {
      steps += random.nextBool()
          ? _lifetimeEpisode(random, trace.add)
          : _cycleEpisode(random, trace.add);
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(
        StateError('seed=$seed episode=$index: ${trace.join(' → ')}: $error'),
        stack,
      );
    }
  }
  return steps;
}
