import 'package:alien_signals/alien_signals.dart' as alien;
import 'package:alien_signals/preset.dart' as alien_preset;
import 'package:rill/internal.dart' as graph;
import 'package:rill/rill.dart' as rill;
import 'package:signals_core/signals_core.dart' as signals;

typedef Dispose = void Function();

final class Readable<T> {
  Readable(this.read);

  final T Function() read;
}

final class Writable<T> {
  Writable(this.read, this.write);

  final T Function() read;
  final void Function(T) write;
}

abstract interface class ReactiveAdapter {
  Writable<T> signal<T>(T initial);
  Readable<T> computed<T>(T Function() read);
  Dispose effect(Function() action);
  void run(void Function() action);
  Object? batch(Function() action);
  T untracked<T>(T Function() action);
}

final class AlienAdapter implements ReactiveAdapter {
  const AlienAdapter();

  @override
  Writable<T> signal<T>(T initial) {
    final value = alien.signal(initial);
    return Writable(value.call, value.set);
  }

  @override
  Readable<T> computed<T>(T Function() read) =>
      Readable(alien.computed<T>((_) => read()).call);

  @override
  Dispose effect(Function() action) => alien.effect(action).call;

  @override
  void run(void Function() action) => alien.effectScope(action)();

  @override
  Object? batch(Function() action) {
    alien.startBatch();
    try {
      action();
    } finally {
      alien.endBatch();
    }
    return null;
  }

  @override
  T untracked<T>(T Function() action) {
    final previous = alien_preset.setActiveSub();
    try {
      return action();
    } finally {
      alien_preset.setActiveSub(previous);
    }
  }
}

final class SignalsAdapter implements ReactiveAdapter {
  List<Dispose>? _scope;

  @override
  Writable<T> signal<T>(T initial) {
    final value = signals.signal(initial);
    return Writable(() => value.value, (next) => value.value = next);
  }

  @override
  Readable<T> computed<T>(T Function() read) {
    final value = signals.computed(read);
    return Readable(() => value.value);
  }

  @override
  Dispose effect(Function() action) {
    final stop = signals.effect(action);
    _scope?.add(stop);
    return stop;
  }

  @override
  void run(void Function() action) {
    // signals_core has no native scope. Track handles for fixture teardown.
    final previous = _scope;
    final scope = <Dispose>[];
    _scope = scope;
    try {
      action();
    } finally {
      _scope = previous;
      for (final stop in scope.reversed) {
        stop();
      }
    }
  }

  @override
  Object? batch(Function() action) => signals.batch<dynamic>(() => action());

  @override
  T untracked<T>(T Function() action) => signals.untracked(action);
}

final class RillAdapter implements ReactiveAdapter {
  RillAdapter({this.inspect = false});

  final bool inspect;
  final _roots = <graph.ReactiveNode>{};

  void validate() => graph.checkGraph(_roots);

  @override
  Writable<T> signal<T>(T initial) {
    final node = rill.signal(initial);
    if (inspect) _roots.add(node);
    return Writable(() => node.value, (next) => node.value = next);
  }

  @override
  Readable<T> computed<T>(T Function() read) {
    final node = rill.computed(read);
    if (inspect) _roots.add(node);
    return Readable(() => node.value);
  }

  /// The fixture's scope. rill has no ambient owner: the adapter
  /// plays alien's `effectScope(fn)` by handing its effects to this Scope.
  rill.Scope? _scope;

  @override
  Dispose effect(Function() action) {
    // Hand `action` over as is when not inspecting: a wrapper closure is a
    // second call per run and costs CellX about 15% (docs/bench.md).
    final compute = inspect
        ? () {
            _roots.add(graph.activeSub!);
            return action();
          }
        : action;

    void apply(Object? result, Object? _, rill.OnCleanup onCleanup) {
      if (result is Dispose) onCleanup(result);
    }

    final scope = _scope;
    // One call site for both owners: conformance.md records its location.
    // ignore: unused_result
    final start = scope == null ? rill.effect<Object?> : scope.effect<Object?>;
    return start(compute, apply);
  }

  @override
  void run(void Function() action) {
    final scope = rill.Scope();
    final previous = rill.Rill.onError;
    final outer = _scope;
    // Fixtures have a synchronous exception channel. Let the rill error
    // handler forward failures after the entire flush has completed.
    rill.Rill.onError = Error.throwWithStackTrace;
    try {
      _scope = scope;
      action();
    } finally {
      _scope = outer;
      try {
        scope.dispose();
        if (inspect) validate();
      } finally {
        rill.Rill.onError = previous;
      }
    }
  }

  @override
  Object? batch(Function() action) => rill.batch<dynamic>(() => action());

  @override
  T untracked<T>(T Function() action) => rill.untracked(action);
}

ReactiveAdapter adapterFor(String name) => switch (name) {
  'alien_signals' => const AlienAdapter(),
  'signals_core' => SignalsAdapter(),
  'rill' => RillAdapter(),
  _ => throw ArgumentError.value(name, 'adapter'),
};

const adapterNames = ['alien_signals', 'signals_core', 'rill'];
