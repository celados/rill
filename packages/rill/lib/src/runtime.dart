import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:clock/clock.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

part 'graph.dart';
part 'command.dart';
part 'query.dart';
part 'debug.dart';

typedef Equals<T> = bool Function(T a, T b);

abstract final class Equality {
  static bool identity(Object? a, Object? b) => identical(a, b);
  static bool never(Object? a, Object? b) => false;
  static bool deep(Object? a, Object? b) =>
      const DeepCollectionEquality().equals(a, b);
}

@pragma('vm:prefer-inline')
bool _equal(Object? a, Object? b) {
  if (identical(a, b)) return true;
  // Native Dart compares int identity by value. A mixed int/double pair
  // still needs operator ==, as does any user-defined class.
  return !(a is int && b is int) && a == b;
}

int _clock = 0;
int _writes = 0;
int get revisionClock => _clock;
int nodeRevision(Readable<Object?> node) => node._revision;
StackTrace? nodeCreationLocation(ReactiveNode node) => _creationTraces[node];

_Tracking? _activeSub;
ReactiveNode? get activeSub => _activeSub;
int _computing = 0;
int _boundary = 0;
bool _flushing = false;

/// The zone a flush was entered from. Effects, watch hooks and after-flush
/// callbacks run synchronously inside it, so they inherit the zone of
/// whatever triggered the flush — often a task's publish. That zone says
/// nothing about who is writing: a write made in it during a flush is the
/// reaction's own. A task started from a reaction runs in its own zone and
/// stays attributed. Debug only, like the diagnostics that read it.
Zone? _flushZone;

/// Whether asserts run. The task and query zones exist only to attribute
/// debug diagnostics, so release builds never fork a zone for them.
final bool _debugZones = () {
  var on = false;
  assert(on = true);
  return on;
}();

bool _debugFlushZone(Zone? zone) {
  _flushZone = zone;
  return true;
}

/// The task a bare write belongs to, or null when the writer is a reaction
/// or code outside any task.
Task? _writerTask() {
  final zone = Zone.current;
  if (_flushing && identical(zone, _flushZone)) return null;
  final task = zone[_taskZone];
  return task is Task ? task : null;
}

void Function(String code, String? name)? diagnosticHook;
void Function(String? name)? bindingReadGuard;
void Function(String? name)? bindingWriteGuard;
void Function()? bindingGraphChanged;
int _activeTaskCount = 0;
int get activeTaskCount => _activeTaskCount;
int activeBindingTimerCount = 0;
int bindingActivity = 0;
bool get bindingBoundaryOpen => _boundary != 0 || _flushing || _computing != 0;
int activePulseCount = 0;

int subscriberCount(ReactiveNode node) {
  var count = 0;
  for (var link = node._subs; link != null; link = link.nextSub) {
    count++;
  }
  return count;
}

bool hasVisibleConsumer(
  ReactiveNode node,
  bool Function(ReactiveNode) visible,
) {
  final seen = <ReactiveNode>{node};
  final pending = [node];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    for (var link = current._subs; link != null; link = link.nextSub) {
      final sub = link.sub;
      if (!seen.add(sub)) continue;
      if (sub is Computed<Object?>) {
        pending.add(sub);
      } else if (sub is Subscriber && sub.visibilityTarget != null) {
        final target = sub.visibilityTarget!;
        if (seen.add(target)) pending.add(target);
      } else if (visible(sub)) {
        return true;
      }
    }
  }
  return false;
}

Signal<T> bindingSignal<T>(
  T initial, {
  required T Function() sample,
  void Function()? watched,
  void Function()? unwatched,
  void Function()? beforeRead,
}) => Signal._(
  initial,
  null,
  null,
  watched,
  unwatched,
  _BindingHooks(sample, beforeRead),
);

/// Read hooks of a binding signal, kept out of ordinary signals.
final class _BindingHooks<T> {
  _BindingHooks(this.sample, this.beforeRead);

  /// Samples the value on an unwatched read.
  final T Function()? sample;
  final void Function()? beforeRead;
}

void writeBindingSignal<T>(Signal<T> node, T value) => node._write(value);

/// Runs [write], a binding's managed write made on behalf of a frame
/// (a reader's calibration, a native listener the frame may notify). Every
/// effect woken before the boundary around it settles waits for the drain
/// that [schedule] is handed, instead of applying in that boundary: the
/// binding passes a post-frame scheduler. The write API decides, not the
/// phase, so debug and release behave alike. Pure Dart never calls this.
/// A call that installs nothing (an equal sample) marks nothing.
void frameBindingWrite(
  void Function(void Function() drain) schedule,
  void Function() write,
) {
  _drainSchedule = schedule;
  final marked = _frameWrite;
  final clock = _clock;
  _frameWrite = true;
  _boundary++;
  try {
    write();
  } finally {
    if (_clock == clock) _frameWrite = marked;
    if (--_boundary == 0) flush();
    _scheduleDeferred();
  }
}

/// Set by a managed frame write; cleared when the flush that settles its
/// boundary ends. Effects notified meanwhile go to [_deferred].
bool _frameWrite = false;
List<_Effect<Object?>> _deferred = [];
void Function(void Function() drain)? _drainSchedule;
bool _drainScheduled = false;

void _scheduleDeferred() {
  if (_drainScheduled || _deferred.isEmpty) return;
  _drainScheduled = true;
  _drainSchedule!(_drainDeferred);
}

void _drainDeferred() {
  _drainScheduled = false;
  if (_deferred.isEmpty) return;
  final nodes = _deferred;
  _deferred = [];
  batch(() {
    for (final node in nodes) {
      if (!node._disposed) _queued.add(node);
    }
  });
}

Never _fail(String code, String message) => throw StateError('$code: $message');

abstract base class ReactiveNode {
  ReactiveNode() {
    assert(_debugCreated(this));
  }

  bool get _maySample => false;
  Object? get _output => null;
  _Link? _deps;
  _Link? _depsTail;
  _Link? _subs;
  _Link? _subsTail;
  int _flags = 0;
  bool _disposed = false;
  int _version = 0;
  bool _refresh() => false;
  void _notify() {}
  void _watched() {}
  void _unwatched() {}
}

abstract base class _Tracking extends ReactiveNode {
  int _trackingCycle = 0;
  bool get _live => true;

  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    _flags = 0;
    batch(() => _clearDeps(this));
  }
}

/// A graph subscriber for bindings. Notification runs during propagation.
/// Defer work that executes user code with [afterFlush].
abstract base class Subscriber extends _Tracking {
  Subscriber({bool compareConsumedValues = false, this.visibilityTarget})
    : _compareConsumedValues = compareConsumedValues {
    _flags = _watching;
    if (compareConsumedValues) _comparingSubscribers++;
  }

  bool get disposed => _disposed;

  /// The object this subscriber reads for, such as a Flutter Element.
  /// Diagnostics name the subscriber after it.
  Object? get debugReader => null;

  /// A stable name for [debugReader]; defaults to its `toString`.
  String? get debugLabel => null;

  void notify();

  final bool _compareConsumedValues;
  final ReactiveNode? visibilityTarget;

  /// Pull dirty derived dependencies and compare the versions consumed by track.
  bool changed({void Function(String path)? onChange}) {
    if (_disposed) return false;
    var changed = false;
    for (var link = _deps; link != null; link = link.nextDep) {
      final dep = link.dep;
      if (dep case Computed<Object?> computed) {
        computed._ensureFresh();
      } else if ((dep._flags & _dirty) != 0 && dep._refresh()) {
        _shallowPropagate(dep._subs);
      }
      final consumedVersion = link.version;
      if (dep._version != consumedVersion && !link.matchesOutput) {
        changed = true;
        assert(() {
          if (onChange != null) {
            for (final path in _writePaths(dep, consumedVersion)) {
              onChange(path);
            }
          }
          return true;
        }());
      }
    }
    assert(_debugWake(this, changed));
    _flags = _watching;
    return changed;
  }

  @override
  void _notify() {
    _flags &= ~_watching;
    try {
      notify();
    } on Object catch (error, stack) {
      if (_isFatal(error)) rethrow;
      _errors.add(_Failure(error, stack));
    }
  }

  R track<R>(R Function() read) {
    if (_disposed || (_flags & _recursedCheck) != 0) {
      _fail('RILL_INVALID_SUBSCRIBER', 'Cannot track ${_describe(this)}.');
    }
    _boundary++;
    final previous = _begin(this, _watching);
    try {
      return read();
    } finally {
      try {
        _end(this, previous);
        if (!_disposed &&
            _flags & _recursed != 0 &&
            _flags & (_dirty | _pending) != 0) {
          _notify();
        }
      } finally {
        if (--_boundary == 0) flush();
      }
    }
  }

  void dispose() {
    _dispose();
  }

  @override
  void _dispose() {
    if (_disposed) return;
    super._dispose();
    // After the links are gone: none of this subscriber's value links remain.
    if (_compareConsumedValues) _comparingSubscribers--;
  }
}

sealed class Readable<T> implements ReactiveNode {
  /// A readable that never changes and never notifies, for fixed inputs
  /// such as `disabled: Readable.constant(false)`. Reading it registers no
  /// dependency: nothing can change, so there is nothing to track.
  factory Readable.constant(T value, {String? name}) = _Constant<T>;

  T get value;
  T peek();
  String? get name;

  int get _revision;
}

/// A fixed value in the Readable family. It links into no graph: its
/// readers have no edge to it, it is never dirty, and its revision is the
/// one it was born with.
final class _Constant<T> extends ReactiveNode implements Readable<T> {
  _Constant(this._value, {this.name}) : _revision = ++_clock {
    _version = _revision;
  }

  final T _value;
  @override
  final String? name;
  @override
  final int _revision;

  @override
  T get value => _value;

  @override
  T peek() => _value;

  @override
  T get _output => _value;
}

final class Signal<T> extends ReactiveNode implements Readable<T> {
  Signal._(
    this._value,
    this.name,
    this._equals,
    this._onWatch,
    this._onUnwatch, [
    this._hooks,
  ]) : _committed = _value {
    _flags = _mutable;
    _version = _revision = ++_clock;
  }

  @override
  final String? name;
  final Equals<T>? _equals;
  final void Function()? _onWatch;
  final void Function()? _onUnwatch;
  final _BindingHooks<T>? _hooks;
  T _value;
  T _committed;
  T _validateCandidate(Object? value) => value as T;
  bool _changed = false;
  @override
  int _revision = 0;

  @override
  @pragma('vm:prefer-inline')
  T get value {
    assert(_checkQueryRead(this));
    final hooks = _hooks;
    if (hooks != null) _runHooks(hooks);
    return _read();
  }

  @pragma('vm:never-inline')
  void _runHooks(_BindingHooks<T> hooks) {
    hooks.beforeRead?.call();
    final sample = hooks.sample;
    if (sample != null && _subs == null) _write(sample());
  }

  @override
  bool get _maySample => _hooks != null;

  @override
  T get _output => _value;

  @pragma('vm:prefer-inline')
  T _read() {
    if ((_flags & _dirty) != 0 && _refresh()) {
      _shallowPropagate(_subs);
    }
    final sub = _activeSub;
    if (sub != null) _link(this, sub);
    return _value;
  }

  @override
  T peek() => untracked(() => value);

  set value(T next) {
    assert(_checkWrite(this));
    _write(next);
  }

  @pragma('vm:prefer-inline')
  void _write(T next) {
    final equals = _equals;
    if (equals == null ? _equal(_value, next) : equals(_value, next)) return;
    // Prepare both comparisons before installing anything. The committed
    // value is the last value consumed by the graph.
    final changed =
        (_flags & _dirty) == 0 ||
        !(equals == null ? _equal(_committed, next) : equals(_committed, next));
    final matches = _comparingSubscribers == 0
        ? null
        : _prepareBindingOutputs(next, _value, equals);
    _changed = changed;
    _value = next;
    _writes = _revision = ++_clock;
    if (matches != null) _installBindingOutputs(matches);
    assert(_debugWrote(this));
    final subs = _subs;
    if (subs != null && (_flags & _dirty) == 0) {
      _flags = _mutable | _dirty;
      _propagate(subs, _computing != 0);
    } else {
      _flags = _mutable | _dirty;
    }
    if (_boundary == 0 && !_flushing) flush();
  }

  void update(T Function(T current) fn) => value = fn(peek());

  List<_EquivalentLink>? _prepareBindingOutputs(
    Object? next,
    T current,
    Equals<T>? equals,
  ) => _prepareEquivalent(this, current, next, equals);

  void _installBindingOutputs(List<_EquivalentLink>? matches) =>
      _stampEquivalent(matches, _revision);

  @override
  @pragma('vm:prefer-inline')
  bool _refresh() {
    _flags = _mutable;
    _committed = _value;
    if (!_changed) return false;
    _version = _revision;
    return true;
  }

  @override
  void _watched() {
    final callback = _onWatch;
    if (callback != null) _watchHooks.add(callback);
  }

  @override
  void _unwatched() {
    final callback = _onUnwatch;
    if (callback != null) _watchHooks.add(callback);
  }
}

bool _checkWrite(Signal<Object?>? node, {bool bare = true}) {
  bindingWriteGuard?.call(node == null ? 'a publication' : _describe(node));
  // Staging is checked like a computation, whatever the writer:
  // a write, a nested commit or an invalidation made while staging either
  // changes what staging reads or cannot be undone if the commit fails.
  if (_computing != 0 || _staging != 0) {
    _fail(
      'RILL_WRITE_IN_COMPUTATION',
      'Cannot ${node == null ? 'publish' : 'write ${_describe(node)}'} '
          'during ${_computing != 0 ? _computationLabel() : 'staging'}.',
    );
  }
  final task = _writerTask();
  if (bare && task != null && task._lapsed && node != null) {
    _warn(
      'RILL_LATE_WRITE',
      node,
      'was written after its task became stale. The write is installed '
          'without publication rights; stage it with task.publish.',
    );
  }
  return true;
}

/// A read of a node from inside its own evaluation. The reader gets no edge
/// to the node it re-entered, and nothing retries the cycle: a cycle between
/// derivations is a programming error.
///
/// The guarantees, as comments and tests name them: L0, a cycle never wakes
/// itself; L1, a computed that stores this failure is never cached as
/// validated ([Computed._storeFailure]), so the next pull or cold read
/// evaluates it again and recovers once the cycle is untied. L2, pushing the
/// recovery to members a change cannot reach through an edge, is not
/// provided: those keep the error while hot.
final class _CycleError extends StateError {
  _CycleError(super.message);
}

Never _failCycle(ReactiveNode node) =>
    throw _CycleError('RILL_CYCLE: Cycle detected in ${_describe(node)}.');

bool _isFatal(Object error) =>
    error is StackOverflowError || error is OutOfMemoryError;

final class _Failure {
  _Failure(this.error, this.stack);
  final Object error;
  final StackTrace stack;

  Never raise() => Error.throwWithStackTrace(error, stack);
}

final class Computed<T> extends _Tracking implements Readable<T> {
  Computed._(this._fn, this.name, this._equals);

  final T Function() _fn;
  final Equals<T>? _equals;
  @override
  final String? name;

  T? _value;
  _Failure? _failure;
  @override
  bool get _maySample => _hasSampledInput;
  bool _hasSampledInput = false;

  @override
  T? get _output => _value;

  int _validated = -1;

  @override
  int get _revision => _version;
  @override
  bool get _live => _subs != null;

  @override
  @pragma('vm:prefer-inline')
  T get value {
    assert(_checkQueryRead(this));
    final flags = _flags;
    if (flags == _mutable &&
        _subs != null &&
        _failure == null &&
        !_hasSampledInput) {
      final sub = _activeSub;
      if (sub != null) _link(this, sub);
      return _value as T;
    }
    if (flags == 0) return _firstRead();
    if (_subs == null && _hasSampledInput && flags & _recursedCheck == 0) {
      // Re-evaluate the branch before sampling any managed input.
      _refresh();
    } else {
      _ensureFresh();
      if (_hasSampledInput) {
        _prepareHotBindingSources(this);
        _ensureFresh();
      }
    }
    return _finishRead();
  }

  @pragma('vm:never-inline')
  T _firstRead() {
    // Keep the first user evaluation in a small frame, since user functions
    // still nest on the Dart stack even though graph walks are iterative.
    final previous = _begin(this, _mutable);
    try {
      _value = _fn();
      _version = ++_clock;
      if (_subs == null) _validated = _writes;
    } on Object catch (error, stack) {
      _storeFailure(error, stack);
    } finally {
      _end(this, previous);
    }
    return _finishRead();
  }

  @pragma('vm:never-inline')
  T _finishRead() {
    final sub = _activeSub;
    try {
      if (sub != null) _link(this, sub);
      final failure = _failure;
      if (failure != null) failure.raise();
      return _value as T;
    } finally {
      if (sub == null && _boundary == 0 && !_flushing) flush();
    }
  }

  @override
  T peek() => untracked(() => value);

  @pragma('vm:prefer-inline')
  void _ensureFresh() {
    final flags = _flags;
    if ((flags & _recursedCheck) != 0) _failCycle(this);
    if (_revision == 0) {
      _refresh();
    } else if (_subs == null) {
      if (_hasSampledInput) {
        // A sampled input (binding signal, clock) can change without a
        // write: re-evaluate, as a cold value read does.
        _refresh();
      } else if (_validated != _writes || (flags & _mustRefresh) != 0) {
        _validateCold(this);
      }
    } else if ((flags & (_dirty | _pending)) != 0) {
      if (_needsUpdate(this)) {
        if (_refresh()) _shallowPropagate(_subs);
      } else {
        _flags &= ~_pending;
      }
    }
  }

  @override
  bool _refresh() {
    final previous = _begin(this, _mutable);
    var changed = false;
    try {
      final next = _fn();
      final equals = _equals;
      final current = _value;
      final differs =
          _failure != null ||
          _revision == 0 ||
          !(equals == null
              ? _equal(current, next)
              : equals(current as T, next));
      if (differs) {
        final matches =
            _comparingSubscribers != 0 && _failure == null && _revision != 0
            ? _prepareEquivalent(this, current as T, next, equals)
            : null;
        _value = next;
        _failure = null;
        _version = ++_clock;
        if (matches != null) _stampEquivalent(matches, _version);
        changed = true;
      }
    } on Object catch (error, stack) {
      _finishFailedRefresh(previous, error, stack);
      return true;
    }
    if (_subs == null) _validated = _writes;
    _end(this, previous);
    return changed;
  }

  @pragma('vm:never-inline')
  void _finishFailedRefresh(
    _Tracking? previous,
    Object error,
    StackTrace stack,
  ) {
    try {
      _storeFailure(error, stack);
    } finally {
      _end(this, previous);
    }
  }

  void _storeFailure(Object error, StackTrace stack) {
    if (_isFatal(error)) {
      _requireRefresh();
      // Let the next source write propagate past the failed dirty node.
      _flags |= _recursed;
      Error.throwWithStackTrace(error, stack);
    }
    _value = null;
    _failure = _Failure(error, stack);
    _version = ++_clock;
    if (error is _CycleError) {
      // L1: never cached as validated, hot or cold; the next pull asks again.
      _flags |= _mustRefresh;
      _validated = -1;
    } else if (_subs == null) {
      _validated = _writes;
    }
  }

  /// Replaces the cached value of an unobserved computed with [now], the
  /// value it would derive at this point, so a node that cooled holds no
  /// answer until its next read. Readers still see a
  /// new version, and the next read validates as usual.
  void _replaceCold(T now) {
    assert(_subs == null, 'only a cold computed drops its cached value');
    if (_revision == 0 || _failure != null) return;
    _value = now;
    _version = ++_clock;
    _validated = -1;
  }

  void _requireRefresh() {
    _flags |= _dirty | _mustRefresh;
    _validated = -1;
  }

  @override
  void _watched() => _setLive(this, true);

  @override
  void _unwatched() => _setLive(this, false);
}

Signal<T> signal<T>(
  T initial, {
  String? name,
  Equals<T>? equals,
  void Function()? watched,
  void Function()? unwatched,
}) => Signal._(initial, name, equals, watched, unwatched);

/// A derived value. It belongs to no owner: while observed it holds
/// reverse edges to its inputs, and once unobserved only forward references
/// remain, so it goes with the last reference to it.
Computed<T> computed<T>(T Function() fn, {String? name, Equals<T>? equals}) =>
    Computed._(fn, name, equals);

@pragma('vm:prefer-inline')
_Tracking? _begin(_Tracking sub, int flags) {
  assert(_debugBegin(sub));
  final previous = _activeSub;
  _activeSub = sub;
  ++_computing;
  ++sub._trackingCycle;
  sub._depsTail = null;
  sub._flags = flags | _recursedCheck;
  return previous;
}

@pragma('vm:prefer-inline')
void _end(_Tracking sub, _Tracking? previous) {
  assert(_debugEnd(sub));
  --_computing;
  _activeSub = previous;
  sub._flags &= ~_recursedCheck;
  final tail = sub._depsTail;
  final obsolete = tail == null ? sub._deps : tail.nextDep;
  if (obsolete != null) _purgeDeps(obsolete);
}

@pragma('vm:never-inline')
void _purgeDeps(_Link first) {
  _Link? link = first;
  while (link != null) {
    link = _unlink(link);
  }
}

void _clearDeps(_Tracking node) {
  while (node._deps != null) {
    _unlink(node._deps!);
  }
}

R untracked<R>(R Function() fn) {
  final previous = _activeSub;
  _activeSub = null;
  assert(++_diagnosticUntrackedDepth > 0);
  try {
    return fn();
  } finally {
    assert(--_diagnosticUntrackedDepth >= 0);
    _activeSub = previous;
  }
}

R batch<R>(R Function() fn) {
  ++_boundary;
  try {
    return fn();
  } finally {
    if (--_boundary == 0) flush();
  }
}

abstract final class Rill {
  static void Function(Object error, StackTrace stack)? onError;
}

// Keep callback and reactive-node registrations in the same LIFO list.
// Effects retain their entry so an explicit stop can unlink it in O(1).
final class _ScopeCleanup extends LinkedListEntry<_ScopeCleanup> {
  _ScopeCleanup(this.target);
  final Object target;
  void run() => switch (target) {
    _Effect<Object?> node => node._stop(),
    final void Function() callback => callback(),
    _ => throw StateError('Invalid cleanup registration'),
  };
}

/// The owner of effects, Slots and external resources. A Scope
/// made with the constructor is always a root: nothing reads a current scope.
/// Derived nodes (computed, queries, bindings) belong to no Scope.
final class Scope {
  Scope({String? name}) : this._(name, null);

  Scope._(this._name, this._parent) {
    assert(_debugCreated(this));
  }

  final String? _name;
  List<Slot>? _slots;
  Scope? _parent;
  final _children = <Scope>{};
  final _cleanups = LinkedList<_ScopeCleanup>();
  bool _disposed = false;
  bool get disposed => _disposed;

  Scope child({String? name}) {
    _checkOpen();
    final child = Scope._(name, this);
    _children.add(child);
    return child;
  }

  /// An effect owned by this Scope: it stops when the Scope is disposed.
  /// The returned function stops it early; there is no need to keep it.
  void Function() effect<T>(
    T Function() compute,
    void Function(T value, T? previous, OnCleanup onCleanup) apply, {
    String? name,
  }) => _startEffect(_Effect(compute, apply, name), this);

  Slot slot({String? name, OnBusy onBusy = OnBusy.supersede}) {
    _checkOpen();
    final slot = Slot._(this, onBusy, name);
    (_slots ??= []).add(slot);
    return slot;
  }

  bool get _alive {
    for (Scope? scope = this; scope != null; scope = scope._parent) {
      if (scope._disposed) return false;
    }
    return true;
  }

  void _checkOpen() {
    if (!_alive)
      _fail('RILL_DISPOSED', 'Scope ${_describe(this)} is disposed.');
  }

  void onDispose(void Function() fn) {
    _register(fn);
  }

  _ScopeCleanup _register(Object target) {
    _checkOpen();
    final entry = _ScopeCleanup(target);
    _cleanups.add(entry);
    return entry;
  }

  void _beginDispose() {
    _disposed = true;
    _parent?._children.remove(this);
    _parent = null;
  }

  void dispose() {
    if (_disposed) return;
    _beginDispose();
    batch(() {
      // Revoke the entire subtree before any user cleanup can reenter.
      final pending = [this];
      while (pending.isNotEmpty) {
        final scope = pending.removeLast();
        final slots = scope._slots;
        scope._slots = null;
        if (slots != null) {
          for (final slot in slots) {
            slot._dispose();
          }
        }
        pending.addAll(scope._children);
      }
      final stack = [this];
      while (stack.isNotEmpty) {
        final current = stack.last;
        if (current._children.isNotEmpty) {
          final child = current._children.last;
          child._beginDispose();
          stack.add(child);
          continue;
        }
        while (current._cleanups.isNotEmpty) {
          final entry = current._cleanups.last;
          entry.unlink();
          _invoke(entry.run);
        }
        stack.removeLast();
      }
    });
  }
}

/// Schedule work once the effect queue has settled. Callbacks are deduplicated
/// by key for this boundary. A callback can request another round of work.
/// Adapter state must settle before consumers validate their visible output.
void beforeBindingObservers(void Function() update) => _watchHooks.add(update);

void afterFlush(Object key, void Function() callback) {
  _afterFlush[key] = callback;
}

final _afterFlush = <Object, void Function()>{};
final _watchHooks = ListQueue<void Function()>();
final _errors = <_Failure>[];
List<_Effect<Object?>> _queued = [];
List<_Effect<Object?>> _round = [];

void _invoke(void Function() fn) {
  try {
    untracked(fn);
  } on Object catch (error, stack) {
    if (error is StackOverflowError || error is OutOfMemoryError) rethrow;
    _errors.add(_Failure(error, stack));
  }
}

enum _Prepared { failed }

/// Registers a cleanup with the effect run that was handed it. It runs
/// before the effect's next apply and when the effect stops, last registered
/// first, even if the apply that registered it went on to throw.
typedef OnCleanup = void Function(void Function() cleanup);

final class _Effect<T> extends _Tracking {
  _Effect(this._compute, this._apply, this._name) {
    _flags = _watching | _dirty;
  }

  final T Function() _compute;
  final void Function(T, T?, OnCleanup) _apply;
  final String? _name;
  _ScopeCleanup? _registration;
  Object? _next;
  T? _previous;

  /// Null, one cleanup, or a list of them in registration order.
  Object? _cleanup;

  /// One per effect, not one per run: a late call (after the apply
  /// returned) joins the current run, or runs at once once stopped.
  late final OnCleanup _onCleanup = _addCleanup;

  void _addCleanup(void Function() cleanup) {
    if (_disposed) {
      batch(() => _invoke(cleanup));
      return;
    }
    final current = _cleanup;
    if (current == null) {
      _cleanup = cleanup;
    } else if (current is List<void Function()>) {
      current.add(cleanup);
    } else {
      _cleanup = <void Function()>[current as void Function(), cleanup];
    }
  }

  void _runCleanups() {
    final cleanup = _cleanup;
    _cleanup = null;
    if (cleanup is List<void Function()>) {
      for (var i = cleanup.length - 1; i >= 0; i--) {
        _invoke(cleanup[i]);
      }
    } else if (cleanup != null) {
      _invoke(cleanup as void Function());
    }
  }

  @override
  void _notify() {
    _flags &= ~_watching;
    (_frameWrite ? _deferred : _queued).add(this);
  }

  bool _prepare() {
    if (_disposed) return false;
    if (!_needsUpdate(this)) {
      _flags = _watching;
      return false;
    }
    final previous = _begin(this, _watching);
    try {
      _next = _compute();
      return !_disposed;
    } on Object catch (error, stack) {
      if (error is StackOverflowError || error is OutOfMemoryError) rethrow;
      _errors.add(_Failure(error, stack));
      _next = _Prepared.failed;
      return !_disposed && _cleanup != null;
    } finally {
      _end(this, previous);
    }
  }

  void _applyPrepared() {
    final next = _next;
    _next = null;
    if (_disposed) return;
    if (_cleanup != null) {
      _runCleanups();
      if (_disposed) return;
    }
    if (identical(next, _Prepared.failed)) return;
    final old = _previous;
    final value = next as T;
    _previous = value;
    assert(_debugApplyStart(this));
    // An apply is an explicit snapshot, like untracked.
    assert(++_diagnosticUntrackedDepth > 0);
    try {
      _apply(value, old, _onCleanup);
    } on Object catch (error, stack) {
      if (error is StackOverflowError || error is OutOfMemoryError) rethrow;
      _errors.add(_Failure(error, stack));
    } finally {
      assert(--_diagnosticUntrackedDepth >= 0);
      assert(_debugApplyEnd());
    }
  }

  void _stop() {
    if (_disposed) return;
    batch(() {
      final registration = _registration;
      _registration = null;
      if (registration?.list != null) registration!.unlink();
      _dispose();
      _previous = null;
      _next = null;
      _runCleanups();
    });
  }
}

/// An effect with no owner: the caller keeps the returned stop function.
@useResult
void Function() effect<T>(
  T Function() compute,
  void Function(T value, T? previous, OnCleanup onCleanup) apply, {
  String? name,
}) => _startEffect(_Effect(compute, apply, name), null);

void Function() _startEffect<T>(_Effect<T> node, Scope? owner) {
  node._registration = owner?._register(node);
  assert(_debugEffectOwner(node, owner));
  try {
    batch(() {
      if (_flushing || _computing != 0) {
        node._notify();
      } else if (node._prepare()) {
        // Initial execution is synchronous, including within an explicit batch.
        _applyNow(node);
      }
    });
  } on Object {
    // A throwing error handler or an initial feedback loop can prevent the
    // disposer from reaching its caller. A scope still owns scoped effects.
    if (owner == null) node._stop();
    rethrow;
  }
  return node._stop;
}

/// Runs one prepared apply outside a flush, as a flush would: its writes
/// wait for the enclosing batch and its errors reach the error channel.
void _applyNow(_Effect<Object?> node) {
  _flushing = true;
  assert(_debugFlushZone(Zone.current));
  try {
    node._applyPrepared();
  } finally {
    _flushing = false;
    assert(_debugFlushZone(null));
  }
}

/// An effect whose compute runs now and tracks from now, and whose first
/// apply waits until [schedule] calls the release it is given. Until then
/// every recompute only replaces the value the first apply will see; a
/// compute that fails withholds it until the next one succeeds. The first
/// apply gets `previous == null`; later applies run synchronously as usual.
/// [owner], when given, owns it as [Scope.effect] would. The binding passes a
/// post-frame scheduler (rill_flutter ReactiveState).
void Function() deferredEffect<T>(
  T Function() compute,
  void Function(T value, T? previous, OnCleanup onCleanup) apply, {
  required void Function(void Function() release) schedule,
  Scope? owner,
  String? name,
}) {
  final gate = _FirstApply<T>(apply);
  final node = _Effect<T>(gate.compute(compute), gate.call, name);
  gate.node = node;
  final stop = _startEffect(node, owner);
  schedule(gate.release);
  return stop;
}

final class _FirstApply<T> {
  _FirstApply(this._apply);

  final void Function(T value, T? previous, OnCleanup onCleanup) _apply;
  late final _Effect<T> node;
  // 0: holding the first apply, 1: the next apply is the first, 2: live.
  int _state = 0;
  bool _held = false;
  T? _value;

  T Function() compute(T Function() compute) => () {
    if (_state == 0) _held = false;
    return compute();
  };

  void call(T value, T? previous, OnCleanup onCleanup) {
    switch (_state) {
      case 0:
        _value = value;
        _held = true;
      case 1:
        _state = 2;
        _apply(value, null, onCleanup);
      default:
        _apply(value, previous, onCleanup);
    }
  }

  void release() {
    if (_state != 0) return;
    if (_computing > 0) {
      // Not inside a computation: the boundary that closes it flushes.
      afterFlush(this, release);
      return;
    }
    _state = 1;
    // A frame write woke it after the held compute: the drain recomputes
    // and makes the first apply, with the value the frame left.
    if (_deferred.contains(node)) {
      _held = false;
      _value = null;
    }
    if (!_held || node._disposed) return;
    final value = _value as T;
    _value = null;
    node._next = value;
    if (_flushing) {
      node._applyPrepared();
    } else {
      batch(() => _applyNow(node));
    }
  }
}

@pragma('vm:never-inline')
void _recoverRound(
  List<_Effect<Object?>> round,
  int index,
  int prepared, {
  required bool applying,
}) {
  final fault = round[index];
  final retry = <_Effect<Object?>>[];
  final seen = HashSet<_Effect<Object?>>.identity()..add(fault);

  void arm(_Effect<Object?> node, {bool recompute = false}) {
    if (node._disposed || !seen.add(node)) return;
    node._next = null;
    node._flags &= ~_watching;
    if (recompute) node._flags |= _dirty;
    retry.add(node);
  }

  if (applying) {
    for (var i = index + 1; i < prepared; i++) {
      arm(round[i], recompute: true);
    }
  } else {
    for (var i = 0; i < prepared; i++) {
      arm(round[i], recompute: true);
    }
    for (var i = index + 1; i < round.length; i++) {
      arm(round[i]);
    }
  }
  for (final node in _queued) {
    arm(node);
  }
  _queued = retry;
  fault._next = null;
  if (!fault._disposed) fault._flags |= _watching | _recursed;
}

void flush() {
  if (_boundary != 0 || _flushing || _computing != 0) return;
  if (_queued.isEmpty &&
      _watchHooks.isEmpty &&
      _afterFlush.isEmpty &&
      _errors.isEmpty) {
    assert(() {
      _lastWrites.clear();
      return true;
    }());
    _frameWrite = false;
    return;
  }
  _flushing = true;
  assert(_debugFlushZone(Zone.current));
  var rounds = 0;
  // After-flush work of the current round not yet run. A callback that
  // queues effects breaks the pass so the graph settles before the next one
  // runs (a reconcile assumes it has), but the rest of the pass is the same
  // round: a hundred independent landings in one batch are one round, only
  // a real feedback loop runs out of rounds.
  var carried = 0;
  var resumed = false;
  try {
    while (_queued.isNotEmpty ||
        _watchHooks.isNotEmpty ||
        _afterFlush.isNotEmpty) {
      // A release build must not hang the UI thread on a feedback loop
      // either: the bound costs one increment per round.
      // Uncounted only right after a pass ran carried work and broke: each
      // such pass shrinks what is carried, so effects alone still count.
      if (!resumed && ++rounds > 100) {
        _fail('RILL_INFINITE_LOOP', 'Last writes: ${_loopWrites()}.');
      }
      resumed = false;
      assert(() {
        _lastWrites.clear();
        return true;
      }());
      if (_queued.isNotEmpty) {
        final current = _queued;
        _queued = _round;
        _round = current;
        var prepared = 0;
        var index = 0;
        var applying = false;
        try {
          final length = current.length;
          for (; index < length; index++) {
            final node = current[index];
            if (node._prepare()) current[prepared++] = node;
          }
          applying = true;
          for (index = 0; index < prepared; index++) {
            current[index]._applyPrepared();
          }
        } on Object {
          _recoverRound(current, index, prepared, applying: applying);
          rethrow;
        } finally {
          current.clear();
        }
      }
      final hookCount = _watchHooks.length;
      for (var i = 0; i < hookCount; i++) {
        _invoke(_watchHooks.removeFirst());
      }
      if (_queued.isEmpty && _watchHooks.isEmpty && _afterFlush.isNotEmpty) {
        // Entries scheduled during the pass go to the back: the pass ends
        // before them, and a resumed pass runs only what it carried.
        var count = carried == 0 ? _afterFlush.length : carried;
        carried = 0;
        while (count > 0 && _afterFlush.isNotEmpty) {
          count--;
          final key = _afterFlush.keys.first;
          _invoke(_afterFlush.remove(key)!);
          if (_queued.isNotEmpty || _watchHooks.isNotEmpty) {
            carried = count;
            resumed = count > 0;
            break;
          }
        }
      }
    }
  } on Object catch (primary) {
    _flushing = false;
    assert(_debugFlushZone(null));
    if (_errors.isNotEmpty) {
      try {
        _reportErrors();
      } on Object catch (reported) {
        if (!_isFatal(primary) && _isFatal(reported)) rethrow;
      }
    }
    rethrow;
  } finally {
    _flushing = false;
    _frameWrite = false;
    assert(_debugFlushZone(null));
    _scheduleDeferred();
  }
  if (_errors.isNotEmpty) _reportErrors();
}

void _reportErrors() {
  final errors = List.of(_errors);
  _errors.clear();
  final handler = Rill.onError ?? Zone.current.handleUncaughtError;
  Object? reportingError;
  StackTrace? reportingStack;
  for (final failure in errors) {
    try {
      handler(failure.error, failure.stack);
    } on Object catch (error, stack) {
      final previous = reportingError;
      if (previous == null || (_isFatal(error) && !_isFatal(previous))) {
        reportingError = error;
        reportingStack = stack;
      }
    }
  }
  if (reportingError != null) {
    Error.throwWithStackTrace(reportingError, reportingStack!);
  }
}

Iterable<String> _writePaths(ReactiveNode node, int since) sync* {
  final name = _label(node);
  var found = false;
  for (var link = node._deps; link != null; link = link.nextDep) {
    if (link.dep._version <= since) continue;
    for (final path in _writePaths(link.dep, since)) {
      found = true;
      yield '$path → $name';
    }
  }
  if (!found) yield '$name @${node._version}';
}

/// Prepare a clock reached through an adapter before returning its cached output.
void prepareBindingInput(Readable<Object?> source) {
  switch (source) {
    case Signal<Object?> signal:
      signal._hooks?.beforeRead?.call();
    case Computed<Object?> computed when computed._hasSampledInput:
      _prepareHotBindingSources(computed);
    default:
      break;
  }
}

/// Bring paused clock inputs current before a hot computed returns its cache.
void _prepareHotBindingSources(Computed<Object?> root) {
  final seen = <ReactiveNode>{root};
  final pending = [root];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    for (var link = node._deps; link != null; link = link.nextDep) {
      final dep = link.dep;
      if (!dep._maySample || !seen.add(dep)) continue;
      switch (dep) {
        case Signal<Object?> signal:
          signal._hooks?.beforeRead?.call();
        case Computed<Object?> computed:
          pending.add(computed);
      }
    }
  }
}

typedef _EquivalentLink = (_ValueLink, int);

List<_EquivalentLink>? _prepareEquivalent<T>(
  ReactiveNode node,
  T current,
  Object? next,
  Equals<T>? equals,
) {
  if (_comparingSubscribers == 0) return null;
  List<_EquivalentLink>? matches;
  for (var link = node._subs; link != null; link = link.nextSub) {
    if (link is! _ValueLink ||
        !link.hasConsumedOutput ||
        identical(link.consumedOutput, current)) {
      continue;
    }
    final baseline = link.consumedOutput as T;
    if (equals == null ? _equal(baseline, next) : equals(baseline, next as T)) {
      (matches ??= []).add((link, link.cycle));
    }
  }
  return matches;
}

void _stampEquivalent(List<_EquivalentLink>? matches, int revision) {
  if (matches == null) return;
  for (final (link, cycle) in matches) {
    if (link.cycle == cycle) link.equivalentRevision = revision;
  }
}

void _markSampledInput(Computed<Object?> root) {
  final pending = [root];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (node._hasSampledInput) continue;
    node._hasSampledInput = true;
    for (var link = node._subs; link != null; link = link.nextSub) {
      if (link.sub case Computed<Object?> computed) pending.add(computed);
    }
  }
}
