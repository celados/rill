part of 'runtime.dart';

/// What a [Slot.run] call delivered to its caller, decided at the moment of
/// delivery: the owner Scope is checked then, not when the body ended.
sealed class Outcome<T> {
  const Outcome._();
}

final class Done<T> extends Outcome<T> {
  const Done._(this.value) : super._();
  final T value;
}

/// Why a task that ran lost its right to publish.
enum StaleReason { superseded, ownerDisposed }

/// The body ran, but the task lost its right to publish.
final class Stale<T> extends Outcome<T> {
  const Stale._(this.reason) : super._();
  final StaleReason reason;
}

final class Failed<T> extends Outcome<T> {
  const Failed._(this.error, this.stack) : super._();
  final Object error;
  final StackTrace stack;
}

/// [OnBusy.skip] found a task in flight: the body did not run.
final class Skipped<T> extends Outcome<T> {
  const Skipped._() : super._();
}

final _taskZone = Object();

enum OnBusy { supersede, skip, queue, parallel }

final class Slot {
  Slot._(this._owner, this._policy, String? name)
    : _busy = signal(false, name: name) {
    assert(_debugCreated(this) && _debugOwn(_busy, this));
  }

  final Scope _owner;
  final OnBusy _policy;
  final Signal<bool> _busy;

  /// Runs whose body has not ended, queued ones included.
  final _tasks = <_SlotRun<Object?>>{};
  final _waiting = ListQueue<_SlotRun<Object?>>();
  _SlotRun<Object?>? _serial;

  Readable<bool> get busy => _busy;

  Future<Outcome<R>> run<R>(Future<R> Function(Task t) body, {Object? key}) {
    assert(_checkStaging('start a task on ${_describe(this)}'));
    if (!_owner._alive) {
      return _verdict(const Stale._(StaleReason.ownerDisposed));
    }
    if (key != null) {
      for (final run in _tasks) {
        if (run.resultType == R && run.key == key && run is _SlotRun<R>) {
          return run.result.future;
        }
      }
    }
    if (_policy == OnBusy.skip && _tasks.isNotEmpty) {
      return _verdict(const Skipped._());
    }
    final run = _SlotRun<R>(Task._(_owner), body, key);
    assert(_debugTask(run.task, this));
    _commandBoundary(() {
      if (_policy == OnBusy.supersede) {
        _cancelAll(StaleReason.superseded);
      }
      _tasks.add(run);
      _activeTaskCount++;
      bindingActivity++;
      _busy._write(true);
      if (_policy == OnBusy.queue) {
        _waiting.add(run);
        _drain();
      } else {
        _start(run);
      }
    });
    return run.result.future;
  }

  /// An outcome decided without a body, delivered like any other: in its own
  /// microtask, with the owner checked at that moment.
  Future<Outcome<R>> _verdict<R>(Outcome<R> outcome) {
    final result = Completer<Outcome<R>>.sync();
    scheduleMicrotask(
      () => result.complete(
        _owner._alive ? outcome : Stale<R>._(StaleReason.ownerDisposed),
      ),
    );
    return result.future;
  }

  void _drain() {
    if (_serial != null || _waiting.isEmpty || !_owner._alive) return;
    final run = _serial = _waiting.removeFirst();
    _start(run);
  }

  void _start(_SlotRun<Object?> run) => run.start(() {
    // The body ended. A run already invalidated has had its verdict scheduled.
    if (!_tasks.remove(run)) return;
    _activeTaskCount--;
    _settle(run);
  });

  /// The bookkeeping after a body ends, then delivery. A body that ended
  /// inside someone else's batch, flush or computation (a synchronous
  /// completer) waits for it to unwind: the next queued body must not start
  /// there.
  void _settle(_SlotRun<Object?> run) {
    if (_boundary != 0 || _flushing || _computing != 0) {
      run.zone.scheduleMicrotask(() => _settle(run));
      return;
    }
    _commandBoundary(() {
      if (identical(_serial, run)) {
        _serial = null;
        _drain();
      }
      _busy._write(_tasks.isNotEmpty);
    });
    run.deliver();
  }

  void _cancelAll(StaleReason reason) {
    final removed = _tasks.toList();
    _activeTaskCount -= removed.length;
    _tasks.clear();
    _waiting.clear();
    _serial = null;
    for (final run in removed) {
      run.cancel(reason);
    }
  }

  void _dispose() {
    _cancelAll(StaleReason.ownerDisposed);
    _busy._write(false);
  }
}

final class _SlotRun<R> {
  _SlotRun(this.task, Future<R> Function(Task) body, this.key) : _body = body;
  final Task task;
  final Object? key;
  final result = Completer<Outcome<R>>.sync();
  final zone = Zone.current;
  Outcome<R>? _ended;
  bool _delivering = false;
  Type get resultType => R;

  /// Held only until the run starts or is cancelled: a body is usually a
  /// method of the page model, and a queued run that is cancelled before it
  /// starts must not keep it.
  Future<R> Function(Task)? _body;

  /// What the body's Future reaches when it settles. A Future that never
  /// settles keeps this alive, not the run: cancelling cuts it, so a
  /// disposed scope's task holds nothing of its page.
  _RunLink<R>? _settle;

  void start(void Function() ended) => zone.run(() {
    final body = _body!;
    _body = null;
    final settle = _settle = _RunLink<R>(this, ended);
    // The body up to its first await runs here, synchronously. It is
    // nobody's computation: a reader that started the task (a build,
    // an initState) neither tracks those reads nor flags them as
    // untracked.
    Future<R>.sync(
      () => untracked(
        () => _debugZones
            ? runZoned(() => body(task), zoneValues: {_taskZone: task})
            : body(task),
      ),
    ).then(settle.done, onError: settle.failed);
  });

  void _end(Outcome<R> outcome, void Function() ended) {
    _settle = null;
    _ended = outcome;
    task._ended = true;
    ended();
  }

  void cancel(StaleReason reason) {
    // Off everything that outlives the run: a body not yet started, the
    // body's Future.
    _body = null;
    _settle?.cut();
    _settle = null;
    task._invalidate(reason);
    deliver();
  }

  /// Completes the caller's future in a microtask of its own, never inside
  /// the batch or the run call that ended or invalidated the task. The
  /// verdict is taken in that microtask, and a caller awaiting it directly
  /// resumes right after, while the owner is known to be alive.
  void deliver() {
    if (_delivering) return;
    _delivering = true;
    zone.scheduleMicrotask(() {
      final reason =
          task._reason ??
          (task._owner._alive ? null : StaleReason.ownerDisposed);
      result.complete(reason == null ? _ended! : Stale<R>._(reason));
    });
  }
}

/// The link from a body's Future back to its run. After [cut] a late
/// success or error is swallowed (the run was already delivered stale); it
/// only closes the task's handle (14.1). A cut link holds the task weakly: a
/// Future that never settles (a shared SDK-ready Future) must not keep a
/// disposed Scope alive through the task's owner, and a task nobody else
/// holds has no handle left to close.
final class _RunLink<R> {
  _RunLink(_SlotRun<R> run, void Function() ended) : _run = run, _ended = ended;
  _SlotRun<R>? _run;
  void Function()? _ended;
  WeakReference<Task>? _cutTask;

  void cut() {
    final run = _run;
    if (run == null) return;
    _cutTask = WeakReference(run.task);
    _run = null;
    _ended = null;
  }

  void done(R value) => _settle(Done<R>._(value));

  void failed(Object error, StackTrace stack) =>
      _settle(Failed<R>._(error, stack));

  void _settle(Outcome<R> outcome) {
    final run = _run, ended = _ended;
    _run = null;
    _ended = null;
    if (run == null || ended == null) {
      _cutTask?.target?._ended = true;
      _cutTask = null;
      return;
    }
    run._end(outcome, ended);
  }
}

final class Task {
  Task._(this._owner);

  final Scope _owner;
  final _cancelled = Completer<void>();
  StaleReason? _reason;
  bool _ended = false;

  /// Owner alive, not invalidated, and the body has not ended.
  bool get alive => _reason == null && !_ended && _owner._alive;

  /// Completes when the task is invalidated (superseded or its owner
  /// disposed): hand it to an RPC to cancel it.
  Future<void> get cancelled => _cancelled.future;

  /// Whether a bare write in this task's zone comes too late.
  bool get _lapsed => !alive;

  void _invalidate(StaleReason reason) {
    if (_reason != null) return;
    _reason = reason;
    _cancelled.complete();
  }

  /// A commit conditioned on this task being alive: [transact] with the
  /// task's right to publish. An invalidated task returns false; a handle
  /// used after its body ended also reports `RILL_CLOSED_PUBLICATION` in
  /// debug builds.
  bool publish(void Function(Tx tx) stage) {
    if (_ended) {
      assert(
        _fail(
          'RILL_CLOSED_PUBLICATION',
          '${_describe(this)} has ended; its handle can no longer publish.',
        ),
      );
      return false;
    }
    if (!alive) {
      assert(_debugRefused(this, this));
      return false;
    }
    return _commit(this, stage);
  }
}

/// A precondition taken as a value: [holds] while [source] has not
/// installed a new value since this was taken. A Signal is exact, every
/// valid install counts (A→B→A does not hold); a Computed is judged by its
/// output revision when pulled, so a round trip between pulls does not
/// count. Both the baseline and the check pull the source first, the way a
/// query pulls its inputs.
final class Unchanged {
  Unchanged(Readable<Object?> source)
    : _source = source,
      _baseline = _pulledRevision(source);

  final Readable<Object?> _source;
  final int _baseline;

  bool get holds => _pulledRevision(_source) == _baseline;
}

/// Brings [source] current the way a query samples an input ([_sampleInput]):
/// a binding signal samples (a cold bridge has no listener to tell it the
/// native value moved); a computed is made fresh (a cold one
/// with a sampled input re-evaluates), and a hot one calibrates its clocks
/// first.
int _pulledRevision(Readable<Object?> source) {
  _sampleInput(source);
  return source._revision;
}

/// Commits staged writes atomically. [stage] only stages: user
/// code (decoding, comparing) runs to the end before anything installs, and
/// a throw installs nothing. Returns false, installing nothing, when a root
/// condition fails; true otherwise, also for an equal or empty commit.
bool transact(void Function(Tx tx) stage) => _commit(null, stage);

int _staging = 0;

bool _checkStaging(String what) {
  if (_staging != 0) {
    _fail('RILL_WRITE_IN_COMPUTATION', 'Cannot $what during staging.');
  }
  return true;
}

bool _enterStaging(int delta) {
  _staging += delta;
  return true;
}

final class _Change<T> {
  _Change(
    this.target,
    this.value,
    this.changed,
    this.revision,
    this.changedFromCommitted, [
    this.matches,
  ]);

  final Signal<T> target;
  final T value;
  final bool changed;
  final int revision;
  final bool changedFromCommitted;
  final List<_EquivalentLink>? matches;

  /// Something installed into the target after it was staged: a reentrant
  /// write from user code that staging ran.
  bool get reentered => revision != target._revision;

  _Link? install(Task? task) {
    if (!changed) return null;

    // All comparison and validation finished before any call to install.
    final wasDirty = (target._flags & _dirty) != 0;
    target._changed = !wasDirty || changedFromCommitted;
    target._value = value;
    _writes = target._revision = ++_clock;
    target._installBindingOutputs(matches);
    assert(_debugWrote(target, publisher: task, committed: true));
    target._flags = _mutable | _dirty;
    return wasDirty ? null : target._subs;
  }
}

/// One layer of a commit: the root, or a [Tx.part].
final class _Layer {
  final entries = <Object>[];
  List<Unchanged>? conditions;

  /// What refuses this layer alone: an [Unchanged] that no longer holds, or
  /// a target written since it was staged. Null when it stands.
  Object? get refusal {
    for (final condition in conditions ?? const <Unchanged>[]) {
      if (!condition.holds) return condition;
    }
    for (final entry in entries) {
      if (entry is _Change<Object?> && entry.reentered) return entry.target;
    }
    return null;
  }

  /// Verifies this layer and every part kept in it, collecting what to
  /// install. Any refusal refuses the whole commit: a part that
  /// returned true is never silently dropped.
  Object? collect(
    Map<Signal<Object?>, _Change<Object?>> writes,
    List<void Function()> events,
  ) {
    if (refusal case final refusal?) return refusal;
    for (final entry in entries) {
      switch (entry) {
        case _Change<Object?>():
          writes[entry.target] = entry;
        case _Layer():
          if (entry.collect(writes, events) case final refusal?) {
            return refusal;
          }
        case final void Function() event:
          events.add(event);
      }
    }
    return null;
  }
}

/// The staging handle of one commit: [transact] or [Task.publish]. It is
/// open only while the stage function runs.
final class Tx {
  Tx._(this._task);
  final Task? _task;
  final _root = _Layer();
  late _Layer _frame = _root;
  bool _open = true;

  void _checkOpen() {
    if (!_open) {
      final task = _task;
      _fail(
        'RILL_CLOSED_PUBLICATION',
        'Staging${task == null ? '' : ' for ${_describe(task)}'} has ended.',
      );
    }
  }

  /// Stages [value] for [target]. The equality check runs now, before
  /// anything installs; the last staging of a target wins.
  void set<T>(Signal<T> target, T value) {
    _checkOpen();
    final candidate = target._validateCandidate(value);
    final equals = target._equals;
    final current = target._value;
    final committed = target._committed;
    final dirty = (target._flags & _dirty) != 0;
    final equal = equals == null
        ? _equal(current, candidate)
        : equals(current, candidate);
    final changed = !equal;
    final differs =
        changed &&
        (!dirty ||
            !(equals == null
                ? _equal(committed, candidate)
                : equals(committed, candidate)));
    _frame.entries.add(
      _Change(
        target,
        candidate,
        changed,
        target._revision,
        differs,
        changed
            ? target._prepareBindingOutputs(candidate, current, equals)
            : null,
      ),
    );
  }

  void emit<T>(Events<T> target, T event) {
    _checkOpen();
    _frame.entries.add(target._prepareEvent(event));
  }

  /// A condition of the current layer: the whole commit at the root, or the
  /// enclosing [part]. It is registered, not thrown, and judged when the
  /// layer ends, so a catch in the stage function cannot swallow it.
  void require(Unchanged condition) {
    _checkOpen();
    (_frame.conditions ??= []).add(condition);
  }

  /// A savepoint. Keeps what [stage] staged and returns true when it returns
  /// and its conditions hold; drops it and returns false when a condition
  /// fails. When [stage] throws, drops it and rethrows the original error
  /// with its stack.
  bool part(void Function() stage) {
    _checkOpen();
    final parent = _frame;
    final layer = _frame = _Layer();
    try {
      stage();
    } finally {
      _frame = parent;
    }
    if (layer.refusal != null) return false;
    parent.entries.add(layer);
    return true;
  }
}

bool _commit(Task? task, void Function(Tx) stage) {
  assert(_checkWrite(null, bare: false));
  final handle = Tx._(task);
  _Failure? failure;
  try {
    // Staging is a computation with no irreversible effects: a
    // read it triggers (a binding sample) does not flush in the middle.
    batch(() {
      assert(_enterStaging(1));
      try {
        stage(handle);
      } finally {
        assert(_enterStaging(-1));
      }
    });
  } on Object catch (error, stack) {
    failure = _Failure(error, stack);
  } finally {
    handle._open = false;
  }

  // Decoders and equality can reenter. This is the final authorization check.
  if (task != null && !task.alive) {
    assert(_debugRefused(task, task));
    return false;
  }
  if (failure != null) failure.raise();
  final writes = Map<Signal<Object?>, _Change<Object?>>.identity();
  final events = <void Function()>[];
  if (handle._root.collect(writes, events) case final refusal?) {
    assert(_debugRefused(task, refusal));
    return false;
  }
  assert(task != null || _debugLateCommit(writes.keys));

  var installed = false;
  try {
    batch(() {
      final propagation = <_Link>[];
      for (final change in writes.values) {
        if (change.install(task) case final link?) propagation.add(link);
      }
      installed = true;
      for (final link in propagation) {
        _propagate(link, _computing != 0);
      }
      for (final event in events) {
        event();
      }
    });
  } on Object catch (error, stack) {
    if (!installed) rethrow;
    _reportAfterCommit(error, stack);
  }
  return true;
}

// Once installed, a throwing error handler is a separate uncaught error.
void _commandBoundary(void Function() action) {
  try {
    batch(action);
  } on Object catch (error, stack) {
    _reportAfterCommit(error, stack);
  }
}

void _reportAfterCommit(Object error, StackTrace stack) {
  final zone = Zone.current;
  zone.scheduleMicrotask(() => zone.handleUncaughtError(error, stack));
}

final class _EventListener<T> {
  _EventListener(this.callback);
  final void Function(T) callback;
}

/// One-off occurrences, such as a notice to show once. Unlike a signal, an
/// event is not a state: the same event twice is delivered twice, and a
/// listener that arrives later does not see what was emitted before.
///
/// With [hold], events emitted while nobody listens are kept, up to
/// [holdLimit] (the oldest is dropped beyond it, with a debug warning
/// `RILL_DROPPED_EVENT`), and handed in order to the first listener that
/// arrives. Use it for events that may fire before their UI is mounted.
final class Events<T> {
  Events({this.name, bool hold = false, int holdLimit = 16})
    : _held = hold ? ListQueue<T>() : null,
      _holdLimit = holdLimit {
    if (holdLimit < 1) throw ArgumentError.value(holdLimit, 'holdLimit');
    assert(_debugCreated(this));
  }

  /// The debug name, shown in diagnostics.
  final String? name;
  final ListQueue<T>? _held;
  final int _holdLimit;
  final _listeners = <_EventListener<T>>{};

  /// Events on their way out, each with the listeners it was emitted to, in
  /// emission order. A callback that emits again queues behind what is
  /// already going out, so every listener hears events in the order they
  /// were emitted.
  final _outgoing = ListQueue<(T, List<_EventListener<T>>)>();
  bool _delivering = false;

  /// Emits [event] now. Not allowed while a commit stages (it could not be
  /// taken back if the commit fails): stage it with [Tx.emit] instead.
  void emit(T event) {
    assert(_checkStaging('emit on ${_describe(this)}'));
    batch(() => _dispatch(event));
  }

  void Function() _prepareEvent(Object? event) {
    final value = event as T;
    return () => _dispatch(value);
  }

  void _dispatch(T event) {
    final held = _held;
    if (_listeners.isEmpty) {
      // Nobody listens: keep it (with hold) for the first listener.
      if (held == null) return;
      held.add(event);
      if (held.length > _holdLimit) {
        held.removeFirst();
        assert(
          _warn(
            'RILL_DROPPED_EVENT',
            this,
            'had no listener for more than $_holdLimit held events; '
                'the oldest was dropped.',
          ),
        );
      }
      return;
    }
    _outgoing.add((event, _listeners.toList()));
    _drain();
  }

  void _drain() {
    if (_delivering) return;
    _delivering = true;
    try {
      while (_outgoing.isNotEmpty) {
        final (event, listeners) = _outgoing.removeFirst();
        for (final listener in listeners) {
          // A listener that stopped meanwhile hears nothing more. A callback
          // that throws is reported on the error channel and the rest go on.
          if (_listeners.contains(listener))
            _invoke(() => listener.callback(event));
        }
      }
    } finally {
      _delivering = false;
    }
  }

  /// Calls [onEvent] for each later event, and with [hold] first for each
  /// held one, in order. What was held goes to this first listener alone;
  /// events emitted while it is handed over queue behind it, for whoever
  /// listens when they are emitted. Returns the function that stops
  /// listening.
  @useResult
  void Function() listen(void Function(T event) onEvent) {
    final listener = _EventListener(onEvent);
    _listeners.add(listener);
    final held = _held;
    if (held != null && held.isNotEmpty) {
      final backlog = List.of(held);
      held.clear();
      batch(() {
        for (final event in backlog) {
          _outgoing.add((event, [listener]));
        }
        _drain();
      });
    }
    return () => _listeners.remove(listener);
  }
}
