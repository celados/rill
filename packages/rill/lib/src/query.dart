part of 'runtime.dart';

// Async derivations. A query is plain graph
// nodes: a question Computed whose refresh only compares input versions, a
// retry counter, a landing record, and the state derived from the three —
// the AsyncComputed itself. Reads pull; work starts and stops only in the
// reconcile at the end of a refresh, from whether the state is observed.

/// The state of an async derivation: an ordinary value, so tests, mocks and
/// widget libraries can build one directly.
sealed class AsyncState<T> {
  const AsyncState();

  /// The value of [AsyncData], or the previous value of an [AsyncError] that
  /// has one; otherwise null.
  T? get valueOrNull;

  /// The value of [AsyncData]. An [AsyncError] rethrows its error with its
  /// original stack; [AsyncLoading] throws `RILL_NO_VALUE`.
  ///
  /// An assertion that a value is here, for a leaf under a gate that only
  /// builds it on [AsyncData] and unmounts it synchronously otherwise. A
  /// transition between gate and leaf (AnimatedSwitcher, route transitions,
  /// Hero), an effect or watch in the leaf, or a gate that keeps the page on
  /// a failed refresh all break that premise: pass the value down instead.
  T get requireValue;

  /// Transforms the value (and the previous value of an [AsyncError]),
  /// keeping `refreshing`, `stale` and `hasPrevious`.
  AsyncState<R> map<R>(R Function(T value) f);
}

/// No value yet for this question.
final class AsyncLoading<T> extends AsyncState<T> {
  const AsyncLoading();

  @override
  T? get valueOrNull => null;

  @override
  T get requireValue => _fail(
    'RILL_NO_VALUE',
    'requireValue read AsyncLoading<$T>. Switch on the state, or only build '
        'this reader under a gate that has a value.',
  );

  @override
  AsyncState<R> map<R>(R Function(T value) f) => AsyncLoading<R>();

  @override
  bool operator ==(Object other) => other is AsyncLoading<Object?>;

  @override
  int get hashCode => (AsyncLoading).hashCode;

  @override
  String toString() => 'AsyncLoading<$T>()';
}

/// A value. [refreshing]: this question still owes an answer (being fetched
/// while observed, or fetched once observed). [stale]: the value belongs to
/// the previous question.
final class AsyncData<T> extends AsyncState<T> {
  const AsyncData(this.value, {this.refreshing = false, this.stale = false});

  final T value;
  final bool refreshing;
  final bool stale;

  @override
  T? get valueOrNull => value;

  @override
  T get requireValue => value;

  @override
  AsyncState<R> map<R>(R Function(T value) f) =>
      AsyncData<R>(f(value), refreshing: refreshing, stale: stale);

  @override
  bool operator ==(Object other) =>
      other is AsyncData<Object?> &&
      other.refreshing == refreshing &&
      other.stale == stale &&
      other.value == value;

  @override
  int get hashCode => Object.hash(AsyncData, value, refreshing, stale);

  @override
  String toString() =>
      'AsyncData<$T>($value${refreshing ? ', refreshing' : ''}'
      '${stale ? ', stale' : ''})';
}

/// A failure is an answer, not an exception. [hasPrevious]: the same
/// question failed on a refresh and [previous] is its last good value (which
/// may itself be null for a nullable `T`).
final class AsyncError<T> extends AsyncState<T> {
  const AsyncError(this.error, this.stack)
    : hasPrevious = false,
      previous = null;

  const AsyncError.withPrevious(this.error, this.stack, T this.previous)
    : hasPrevious = true;

  final Object error;
  final StackTrace stack;
  final bool hasPrevious;
  final T? previous;

  @override
  T? get valueOrNull => hasPrevious ? previous : null;

  @override
  T get requireValue => Error.throwWithStackTrace(error, stack);

  @override
  AsyncState<R> map<R>(R Function(T value) f) => hasPrevious
      ? AsyncError<R>.withPrevious(error, stack, f(previous as T))
      : AsyncError<R>(error, stack);

  @override
  bool operator ==(Object other) =>
      other is AsyncError<Object?> &&
      identical(other.error, error) &&
      identical(other.stack, stack) &&
      other.hasPrevious == hasPrevious &&
      other.previous == previous;

  @override
  int get hashCode => Object.hash(
    AsyncError,
    identityHashCode(error),
    identityHashCode(stack),
    hasPrevious,
    previous,
  );

  @override
  String toString() =>
      'AsyncError<$T>($error${hasPrevious ? ', previous: $previous' : ''})';
}

/// Merges states by position: any error → the first error, with a previous
/// value only when every source has a value; otherwise any loading →
/// loading; otherwise data, refreshing / stale if any source is.
AsyncState<R> _combine<R>(
  List<AsyncState<Object?>> states,
  R Function(List<Object?> values) build,
) {
  AsyncError<Object?>? error;
  var loading = false, refreshing = false, stale = false, complete = true;
  final values = List<Object?>.filled(states.length, null);
  for (var i = 0; i < states.length; i++) {
    switch (states[i]) {
      case AsyncLoading():
        loading = true;
        complete = false;
      case AsyncData(:final value, refreshing: final r, stale: final s):
        values[i] = value;
        refreshing |= r;
        stale |= s;
      case final AsyncError<Object?> failure:
        error ??= failure;
        if (failure.hasPrevious) {
          values[i] = failure.previous;
        } else {
          complete = false;
        }
    }
  }
  if (error != null) {
    return complete
        ? AsyncError<R>.withPrevious(error.error, error.stack, build(values))
        : AsyncError<R>(error.error, error.stack);
  }
  if (loading) return AsyncLoading<R>();
  return AsyncData<R>(build(values), refreshing: refreshing, stale: stale);
}

extension AsyncStateAll2<A, B> on (AsyncState<A>, AsyncState<B>) {
  AsyncState<(A, B)> get all =>
      _combine([$1, $2], (v) => (v[0] as A, v[1] as B));
}

extension AsyncStateAll3<A, B, C>
    on (AsyncState<A>, AsyncState<B>, AsyncState<C>) {
  AsyncState<(A, B, C)> get all =>
      _combine([$1, $2, $3], (v) => (v[0] as A, v[1] as B, v[2] as C));
}

extension AsyncStateAll4<A, B, C, D>
    on (AsyncState<A>, AsyncState<B>, AsyncState<C>, AsyncState<D>) {
  AsyncState<(A, B, C, D)> get all => _combine([
    $1,
    $2,
    $3,
    $4,
  ], (v) => (v[0] as A, v[1] as B, v[2] as C, v[3] as D));
}

extension AsyncStateAll5<A, B, C, D, E>
    on
        (
          AsyncState<A>,
          AsyncState<B>,
          AsyncState<C>,
          AsyncState<D>,
          AsyncState<E>,
        ) {
  AsyncState<(A, B, C, D, E)> get all => _combine([
    $1,
    $2,
    $3,
    $4,
    $5,
  ], (v) => (v[0] as A, v[1] as B, v[2] as C, v[3] as D, v[4] as E));
}

extension AsyncStateAll6<A, B, C, D, E, F>
    on
        (
          AsyncState<A>,
          AsyncState<B>,
          AsyncState<C>,
          AsyncState<D>,
          AsyncState<E>,
          AsyncState<F>,
        ) {
  AsyncState<(A, B, C, D, E, F)> get all => _combine([
    $1,
    $2,
    $3,
    $4,
    $5,
    $6,
  ], (v) => (v[0] as A, v[1] as B, v[2] as C, v[3] as D, v[4] as E, v[5] as F));
}

extension AsyncStateIterableAll<T> on Iterable<AsyncState<T>> {
  /// The merged state of every element, in order; empty is `AsyncData([])`.
  AsyncState<List<T>> get all =>
      _combine(toList(), (v) => List<T>.unmodifiable(v.cast<T>()));
}

// ── Diagnostics and counters ─────────────────────────────────────────────────

final _queryZone = Object();
int _diagnosticUntrackedDepth = 0;

int _activeQueryCount = 0;
int _activeQueryStreamCount = 0;
int _activeQueryTimerCount = 0;

/// Future queries with an attempt in flight.
int get activeQueryCount => _activeQueryCount;

/// Stream queries holding a subscription.
int get activeQueryStreamCount => _activeQueryStreamCount;

/// Retention timers of unobserved queries with work in flight.
int get activeQueryTimerCount => _activeQueryTimerCount;

bool _checkQueryRead(ReactiveNode node) {
  if (_activeSub == null && _diagnosticUntrackedDepth == 0) {
    final guard = bindingReadGuard;
    if (guard != null) guard(_describe(node));
    final query = Zone.current[_queryZone];
    if (query is Query && !query._tracking) {
      _warn(
        'RILL_READ_AFTER_AWAIT',
        node,
        'was read after an await in computedAsync, or inside the async* body '
            'of computedStream, and is not tracked. Read it before the first '
            'await (computedStream: in the synchronous fn before returning '
            'the stream), or use peek() for a snapshot.',
      );
    }
    if (node is AsyncComputed<Object?>) node._debugColdRead();
  }
  return true;
}

// ── Query internals ──────────────────────────────────────────────────────────

/// The argument of a query function: one attempt at one question.
///
/// Everything that reaches the query from outside — the
/// Future's answer, a stream event or its end — is only recorded on the
/// attempt and asks for a reconcile. The reconcile alone installs answers,
/// delivers waits, ends rounds and starts work. A stream is an asynchronous
/// source whatever its controller: its events reach the attempt through the
/// attempt's own FIFO, a microtask after they were sent.
final class Query {
  Query._(this._owner, this._generation, this._retry);

  /// Cleared when the attempt is cancelled. The attempt is what a pending
  /// Future or stream callback holds, so a producer that never completes
  /// keeps nothing of a cooled query alive.
  AsyncComputed<Object?>? _owner;
  final int _generation;
  final int _retry;
  final _cancelled = Completer<void>();
  bool _tracking = true;
  bool _answered = false;
  bool _inFlight = false;

  /// The round ended: landed (Future), its stream closed or failed to
  /// start, or cancelled. Its waits are never delivered.
  bool _closed = false;

  /// What the query function returned, until a later step subscribes to it:
  /// the step that ran the function ends there.
  Object? _produced;

  /// Requests the reconcile has not handled: the latest answer, and whether
  /// the producer ended the round.
  _Answer? _pending;
  bool _ending = false;

  /// Stream events not yet delivered, oldest first; null is the end. Once
  /// the producer has ended the round ([_endQueued]) no wait is delivered,
  /// even before the end itself is.
  List<_Answer?>? _inbox;
  bool _endQueued = false;

  /// How many deliveries in a row led to the queued events: queued while
  /// another attempt's events were being delivered, one more than that
  /// delivery; queued from outside (a socket, a timer, a frame), zero.
  int _chain = 0;

  /// Completes when this attempt is superseded or the query cools.
  Future<void> get cancelled => _cancelled.future;

  /// Waits for [source]'s answer: its terminal state, a value or its error,
  /// and makes [source] an input of this query: the query asks again when
  /// [source] changes question or its answer changes by its `equals`.
  ///
  /// Only before the first await (in computedStream: before returning the
  /// stream). Called later it throws `RILL_READ_AFTER_AWAIT`; a one-off
  /// answer is `source.settled()`.
  Future<S> wait<S>(AsyncComputed<S> source) {
    final owner = _owner;
    if (owner == null || !_tracking) _failLateWait(source);
    return owner._wait(this, source);
  }

  /// The single way an answer reaches the query: recorded on the attempt,
  /// only while it has not been cancelled, for the reconcile to take.
  void _deliver(_Answer? answer, {bool end = false}) {
    final owner = _owner;
    if (owner == null) return;
    if (answer != null) _pending = answer;
    if (end) _ending = true;
    owner._request();
  }

  // The callbacks are made here, not in the query's methods: a closure there
  // shares its context with the others, which hold the query itself.
  void _await(Future<Object?> result) => result.then(
    (value) => _deliver(_Answer(true, value, null, null), end: true),
    onError: (Object e, StackTrace s) =>
        _deliver(_Answer(false, null, e, s), end: true),
  );

  StreamSubscription<Object?> _listen(Stream<Object?> stream) => stream.listen(
    (value) => _post(_Answer(true, value, null, null)),
    // An error event is an answer: a stream that fails and closes keeps its
    // error, not RILL_EMPTY_QUERY. The subscription stays:
    // later data still answers.
    onError: (Object e, StackTrace s) => _post(_Answer(false, null, e, s)),
    onDone: () {
      _endQueued = true;
      _post(null);
    },
  );

  /// Queues a stream event. Never delivered inside the code that sent it,
  /// so no synchronous controller reaches a reconcile mid-step or orders
  /// queries by itself.
  void _post(_Answer? event) {
    if (_owner == null) return;
    var inbox = _inbox;
    if (inbox == null) {
      inbox = _inbox = [];
      _chain = _delivering < 0 ? 0 : _delivering + 1;
      scheduleMicrotask(_drain);
    }
    inbox.add(event);
  }

  /// Delivers the queued events in order, each as its own request; once
  /// the attempt is cancelled the rest are dropped. Events queued while
  /// these are delivered wait for the next microtask.
  ///
  /// Deliveries that keep queuing deliveries (a comparator, onListen or an
  /// effect that sends a synchronous controller a value each time) never
  /// return to the event loop: past [_deliveryLimit] in a row the events are
  /// dropped and the loop is reported, as a flush reports one (v0.4.0 counted
  /// such a loop in flush rounds while it delivered synchronously).
  void _drain() {
    final events = _inbox!;
    _inbox = null;
    final owner = _owner;
    if (owner == null) return;
    if (_chain >= _deliveryLimit) {
      _fail(
        'RILL_INFINITE_LOOP',
        'stream events of ${_describe(owner)} fed queries $_deliveryLimit '
            'times in a row without returning to the event loop.',
      );
    }
    final outer = _delivering;
    _delivering = _chain;
    try {
      for (var i = 0; i < events.length && _owner != null; i++) {
        final event = events[i];
        if (event == null) {
          _deliver(null, end: true);
        } else {
          _answered = true;
          _deliver(event);
        }
      }
    } finally {
      _delivering = outer;
    }
  }
}

/// The chain of the stream deliveries running now, -1 outside any.
int _delivering = -1;
const _deliveryLimit = 100000;

/// An answer as it arrived, before the reconcile installs it. [prepared] is
/// the landing record once the comparator has run: the step that ran it
/// ends there, and the next one installs it.
final class _Answer {
  _Answer(this.ok, this.value, this.error, this.stack);

  final bool ok;
  final Object? value;
  final Object? error;
  final StackTrace? stack;
  Object? prepared;
}

Never _failLateWait(ReactiveNode source) => _fail(
  'RILL_READ_AFTER_AWAIT',
  '${_describe(source)} was waited on after the first await of a query, or '
      'inside the async* body of computedStream: q.wait only works before '
      'the first await, where it makes the source an input. For a one-off '
      'answer, await source.settled().',
);

/// The query whose reconcile step is running (debug builds). Steps never
/// nest.
AsyncComputed<Object?>? _transitioning;

/// The running step already called user code (debug builds). A step ends
/// at its first call into user code — sampling the question is the one
/// exception, a judgement that stands only if nothing moved — so every
/// transition asserts it has not.
bool _debugUserCodeRan = false;

bool _debugInTransition(AsyncComputed<Object?>? query) {
  if (query != null && !identical(_transitioning, query)) {
    throw StateError(
      'rill internal: a transition of ${_describe(query)} ran outside its '
      'reconcile.',
    );
  }
  return true;
}

/// A transition of [query]: inside its step, before any user code.
bool _debugStep(AsyncComputed<Object?>? query) {
  _debugInTransition(query);
  if (query != null && _debugUserCodeRan) {
    throw StateError(
      'rill internal: a step of ${_describe(query)} went on after user code.',
    );
  }
  return true;
}

/// Runs a transition of [query] after user code in a step of its own: the
/// step guard must refuse it (the guard's own test; debug builds only).
void debugViolateQueryStep(AsyncComputed<Object?> query) {
  assert(() {
    _transitioning = query;
    _debugUserCodeRan = true;
    try {
      query._record(query._landed._value);
    } finally {
      _transitioning = null;
      _debugUserCodeRan = false;
    }
    return true;
  }());
}

/// The answer key a downstream consumes: pending, an answer,
/// or a failure, of one upstream question generation.
final class _Key {
  const _Key(
    this.generation,
    this.kind,
    this.value,
    this.error,
    this.stack, {
    this.released = false,
  });

  static const pending = 0, answer = 1, failure = 2;

  final int generation;
  final int kind;
  final Object? value;
  final Object? error;
  final StackTrace? stack;

  /// The value or error was released when the downstream dropped its
  /// answer; the generation and kind still tell a new question or a recovery.
  final bool released;

  _Key release() => _Key(generation, kind, null, null, null, released: true);

  static bool same(_Key a, _Key b) =>
      a.generation == b.generation &&
      a.kind == b.kind &&
      identical(a.value, b.value) &&
      identical(a.error, b.error) &&
      identical(a.stack, b.stack);
}

/// The last thing an attempt delivered, plus the last good answer of the
/// same question (a failure of a new question holds none).
final class _Landing<T> {
  _Landing(
    this.generation,
    this.retry,
    this.ok,
    this.value,
    this.error,
    this.stack,
    this.hasGood,
    this.good,
  );

  final int generation;
  final int retry;
  final bool ok;
  final T? value;
  final Object? error;
  final StackTrace? stack;
  final bool hasGood;
  final T? good;
}

/// The question node. Its value is the question generation. Its refresh
/// pulls each input as a read would, without linking, and compares versions;
/// it never runs the query function. Only a launch tracks into it.
final class _QueryQuestion extends Computed<int> {
  _QueryQuestion(AsyncComputed<Object?> query)
    : _query = query,
      super._(
        () {
          query._schedule();
          return 1;
        },
        null,
        null,
      );

  final AsyncComputed<Object?> _query;

  /// Set while a launch tracks into this node (debug run records).
  bool _launching = false;

  /// An upstream comparator threw on a wait edge:
  /// the change could not be judged, so it is a new question whose answer
  /// is this failure. The launch of that generation lands it instead of
  /// running the query; the next upstream change compares again.
  _Failure? _compareFailure;
  int _compareGeneration = -1;

  @override
  bool _refresh() {
    var changed = _revision == 0;
    final initial = _revision == 0;
    List<_DebugInput>? inputs;
    assert(() {
      inputs = [];
      return true;
    }());
    final previous = _activeSub;
    _activeSub = null;
    ++_computing;
    _flags = _mutable | _recursedCheck;
    _Failure? failure;
    try {
      for (var link = _deps; link != null; link = link.nextDep) {
        final dep = link.dep;
        _sampleInput(dep);
        final version = dep._version;
        final from = link.version;
        if (from == version) continue;
        var differs = true;
        if (link is _WaitLink) {
          // The version is committed only once the change is judged: a
          // comparator that throws leaves no edge claiming it consumed a
          // version it never compared.
          try {
            differs = link.consider((dep as Computed<_Key>)._value!);
          } on Object catch (e, s) {
            if (_isFatal(e)) rethrow;
            failure ??= _Failure(e, s);
            link.compareFailed = true;
          }
        }
        link.version = version;
        if (differs) {
          changed = true;
          inputs?.add(_DebugInput(dep, from, version));
        }
      }
    } finally {
      --_computing;
      _activeSub = previous;
      _flags &= ~_recursedCheck;
    }
    if (_subs == null) _validated = _writes;
    if (changed) {
      _value = (_value ?? 0) + 1;
      _version = ++_clock;
      _compareFailure = failure;
      _compareGeneration = failure == null ? -1 : _value!;
      assert(_debugQuestionChanged(this, initial ? const [] : inputs!));
      _query._schedule();
    }
    return changed;
  }
}

/// Brings [dep] current the way reading its value would, without a link:
/// binding signals run their read hooks; a cold computed with a sampled
/// input re-evaluates. The one sampling protocol for every reader that
/// compares revisions instead of subscribing: a query's question and
/// [Unchanged].
void _sampleInput(ReactiveNode dep) {
  switch (dep) {
    case Signal<Object?> signal:
      final hooks = signal._hooks;
      if (hooks != null) signal._runHooks(hooks);
      if ((signal._flags & _dirty) != 0 && signal._refresh()) {
        _shallowPropagate(signal._subs);
      }
    case Computed<Object?> computed:
      // _ensureFresh re-evaluates a cold node with a sampled input (and
      // fails a node being evaluated as a cycle); a hot one first brings
      // its paused clock sources current.
      computed._ensureFresh();
      if (computed._subs != null && computed._hasSampledInput) {
        _prepareHotBindingSources(computed);
        computed._ensureFresh();
      }
    default:
      break;
  }
}

/// The edge `q.wait` adds from a downstream question to an upstream answer
/// node. It records the answer key the downstream consumed and compares it
/// with the upstream's current key.
final class _WaitLink extends _Link {
  _WaitLink(
    super.dep,
    super.sub,
    super.prevDep,
    super.nextDep,
    this.source,
    this.consumed,
    this.attempt,
  );

  final AsyncComputed<Object?> source;
  _Key consumed;

  /// The attempt whose wait this edge completes.
  Query? attempt;

  /// Typed by the upstream (`Completer<T>`), so every wait of one attempt
  /// on one source returns this completer's future itself.
  Completer<Object?>? completer;

  /// The consumed key moved from pending to an answer or failure; the
  /// downstream's reconcile completes the wait (never this pull).
  bool resolved = false;

  /// The upstream comparator threw judging this edge: the consumed key is
  /// not what the downstream's answer stands on, so the next judged change
  /// asks again even when equal to it.
  bool compareFailed = false;

  /// Whether the upstream key is a change of the downstream question.
  bool consider(_Key key) {
    final held = consumed;
    if (held.kind == _Key.pending) {
      if (key.kind != _Key.pending) {
        consumed = key;
        resolved = true;
        (sub as _QueryQuestion)._query._schedule();
      }
      return false;
    }
    if (key.generation != held.generation) {
      compareFailed = false;
      return true;
    }
    if (key.kind != _Key.answer) return false;
    final differs =
        held.kind == _Key.failure ||
        !held.released && !source._sameAnswer(held.value, key.value);
    if (compareFailed) {
      compareFailed = false;
      return true;
    }
    return differs;
  }
}

_WaitLink _linkWait(
  Computed<_Key> dep,
  _QueryQuestion sub,
  AsyncComputed<Object?> source,
  _Key key,
  Query attempt,
) {
  // The same attempt already waits on this source: share its edge.
  for (var link = sub._deps; link != null; link = link.nextDep) {
    if (link is _WaitLink &&
        identical(link.dep, dep) &&
        identical(link.attempt, attempt)) {
      return link;
    }
  }
  final prevDep = sub._depsTail;
  var nextDep = prevDep == null ? sub._deps : prevDep.nextDep;
  if (nextDep is _WaitLink && identical(nextDep.dep, dep)) {
    nextDep
      ..version = dep._version
      ..cycle = sub._trackingCycle
      ..consumed = key
      ..attempt = attempt
      ..completer = null
      ..resolved = false
      ..compareFailed = false;
    sub._depsTail = nextDep;
    if (dep._maySample && !sub._hasSampledInput) _markSampledInput(sub);
    return nextDep;
  }
  if (nextDep != null && identical(nextDep.dep, dep)) {
    nextDep = _unlink(nextDep);
  }
  final link = _WaitLink(dep, sub, prevDep, nextDep, source, key, attempt);
  sub._depsTail = link;
  nextDep?.prevDep = link;
  if (prevDep == null) {
    sub._deps = link;
  } else {
    prevDep.nextDep = link;
  }
  if (dep._maySample && !sub._hasSampledInput) _markSampledInput(sub);
  if (sub._live) _attach(link);
  bindingGraphChanged?.call();
  return link;
}

/// Whether [target] is reachable from [from] along dependency edges.
bool _reaches(ReactiveNode from, ReactiveNode target) {
  final seen = HashSet<ReactiveNode>.identity()..add(from);
  final pending = <ReactiveNode>[from];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    for (var link = node._deps; link != null; link = link.nextDep) {
      final dep = link.dep;
      if (identical(dep, target)) return true;
      if (dep._deps != null && seen.add(dep)) pending.add(dep);
    }
  }
  return false;
}

// ── AsyncComputed ────────────────────────────────────────────────────────────

/// An async derivation. It is a `Readable<AsyncState<T>>`: reading it
/// returns the current state and never starts work. It works while observed
/// (a reader, an effect, a hot computed, a pending `settled()` / `refresh()`,
/// or an observed downstream that waits on it) and cools when not.
final class AsyncComputed<T> extends Computed<AsyncState<T>> {
  AsyncComputed._(
    AsyncState<T> Function() derive,
    String? name,
    this._load,
    this._stream,
    Equals<T>? equals,
    this._retain,
    Scope? keepAlive,
  ) : _answerEquals = equals,
      super._(derive, name, _sameState) {
    _question = _QueryQuestion(this);
    _retry = Signal<int>._(0, null, null, null, null);
    _landed = Signal<_Landing<T>?>._(null, null, null, _schedule, _schedule);
    // A retained answer expires with time: reads sample the clock.
    if (_retain > Duration.zero) _hasSampledInput = true;
    keepAlive?.onDispose(_releaseLease);
    _lease = keepAlive;
    assert(
      _debugOwn(_question, this, 'question') &&
          _debugOwn(_retry, this, 'retry') &&
          _debugOwn(_landed, this, 'landed'),
    );
  }

  final Object Function(Query) _load;
  final bool _stream;
  final Equals<T>? _answerEquals;
  final Duration _retain;
  Scope? _lease;
  late final _QueryQuestion _question;
  late final Signal<int> _retry;
  late final Signal<_Landing<T>?> _landed;
  Computed<_Key>? _answer;

  Query? _current;
  int _launchedGeneration = -1;
  int _launchedRetry = -1;
  StreamSubscription<Object?>? _subscription;
  Timer? _timer;
  int _coolToken = 0;
  DateTime? _unwatchedAt;
  bool _launchedOnce = false;

  /// Cooling requests from a microtask or the retention timer, taken by the
  /// next unobserved reconcile.
  bool _dropRequested = false;
  bool _expireRequested = false;
  bool _coldReadChecked = false;

  bool get _observed => _subs != null;
  bool get _working =>
      (_current?._inFlight ?? false) ||
      _subscription != null ||
      _current?._produced != null;

  static bool _sameState(Object? a, Object? b) => switch ((a, b)) {
    (AsyncLoading(), AsyncLoading()) => true,
    (AsyncData x, AsyncData y) =>
      identical(x.value, y.value) &&
          x.refreshing == y.refreshing &&
          x.stale == y.stale,
    (AsyncError x, AsyncError y) =>
      identical(x.error, y.error) &&
          identical(x.stack, y.stack) &&
          x.hasPrevious == y.hasPrevious &&
          identical(x.previous, y.previous),
    _ => false,
  };

  bool _sameAnswer(Object? a, Object? b) {
    final equals = _answerEquals;
    return equals == null ? _equal(a, b) : equals(a as T, b as T);
  }

  bool get _expired {
    final since = _unwatchedAt;
    return since != null &&
        _lease == null &&
        clock.now().difference(since) >= _retain;
  }

  // Reads all three inputs on every evaluation.
  AsyncState<T> _derive() {
    final generation = _question.value;
    final retry = _retry.value;
    final landed = _landed.value;
    if (landed == null) return AsyncLoading<T>();
    if (landed.generation == generation && landed.retry == retry && !_expired) {
      if (landed.ok) return AsyncData<T>(landed.value as T);
      return landed.hasGood
          ? AsyncError<T>.withPrevious(
              landed.error!,
              landed.stack!,
              landed.good as T,
            )
          : AsyncError<T>(landed.error!, landed.stack!);
    }
    // A landing only holds a good answer of its own question.
    if (landed.hasGood) {
      return AsyncData<T>(
        landed.good as T,
        refreshing: true,
        stale: landed.generation != generation,
      );
    }
    return AsyncLoading<T>();
  }

  Computed<_Key> get _answerNode => _answer ??= _createAnswer();

  Computed<_Key> _createAnswer() {
    final node = Computed<_Key>._(
      () => _keyOf(_question.value, value),
      null,
      _Key.same,
    );
    assert(_debugOwn(node, this, 'answer'));
    return node;
  }

  static _Key _keyOf(int generation, AsyncState<Object?> state) =>
      switch (state) {
        AsyncData(:final value, stale: false, refreshing: false) => _Key(
          generation,
          _Key.answer,
          value,
          null,
          null,
        ),
        AsyncError(:final error, :final stack) => _Key(
          generation,
          _Key.failure,
          null,
          error,
          stack,
        ),
        _ => _Key(generation, _Key.pending, null, null, null),
      };

  /// Asks for a reconcile on the flush's after-flush channel.
  void _schedule() => afterFlush(this, _reconcile);

  /// Asks for a reconcile from outside the graph (a producer, a timer):
  /// flushes now when nothing is open, else when it closes.
  void _request() {
    _schedule();
    if (_boundary != 0 || _flushing) return;
    if (_computing == 0) {
      flush();
    } else {
      scheduleMicrotask(flush);
    }
  }

  /// The step called user code: it ends here, and the next step judges
  /// afresh.
  void _afterUserCode() {
    _schedule();
    assert(() {
      _debugUserCodeRan = true;
      return true;
    }());
  }

  // The only place that installs an answer,
  // delivers a wait, ends or cancels a round and starts work. It runs from
  // the flush's after-flush channel, which never nests and runs only once
  // effects and hooks are drained, so it starts on a settled graph. It runs
  // in steps. A step judges from the current attempt, question and
  // observation and takes at most one action; an action that calls user
  // code (onCancel, the comparator, the query function, listen, a wait's
  // completion) is its last, and asks for the next step. Steps follow one
  // another here while the graph stays settled; once it moved — a write, a
  // hook or effect queued, observation changed — the flush settles it and
  // the next step runs from there. Nothing judged before user code is used
  // after it.
  void _reconcile() {
    for (var steps = 0; ;) {
      _afterFlush.remove(this);
      final writes = _writes;
      final observed = _observed;
      assert(() {
        if (_transitioning != null) {
          throw StateError('rill internal: reconciles nested.');
        }
        if (_queued.isNotEmpty || _watchHooks.isNotEmpty) {
          throw StateError('rill internal: a reconcile on an unsettled graph.');
        }
        _transitioning = this;
        _debugUserCodeRan = false;
        return true;
      }());
      try {
        _step(writes, observed);
      } finally {
        assert(() {
          _transitioning = null;
          _debugUserCodeRan = false;
          return true;
        }());
      }
      if (_moved(writes, observed)) {
        _schedule();
        return;
      }
      // A step a hundred in a row yields to the flush: a round.
      if (!_afterFlush.containsKey(this) || ++steps == 100) return;
    }
  }

  bool _moved(int writes, bool observed) =>
      _writes != writes ||
      _watchHooks.isNotEmpty ||
      _queued.isNotEmpty ||
      _observed != observed;

  void _step(int writes, bool observed) {
    final int generation;
    if (observed) {
      _coolToken++;
      _dropRequested = _expireRequested = false;
      _cancelTimer();
      final since = _unwatchedAt;
      _unwatchedAt = null;
      if (since != null && clock.now().difference(since) >= _retain) {
        // The pull already derived refreshing: true; this write is equal.
        _retry._write(_retry._value + 1);
        return;
      }
      // The judgement. Sampling the question runs user code (an upstream
      // comparator on a wait edge, a bridge's read hook, a cold computed),
      // which may remove the last reader or write an input: it stands only
      // if nothing moved.
      generation = _question.peek();
      if (_moved(writes, observed)) return;
    } else {
      // Nobody observes: whether the question changed is nobody's business,
      // and sampling it may write (a clock read cold samples and advances),
      // so cooling would never get its turn. The
      // question last judged stands — a cold read samples it — and an
      // answer installed for it reads stale once a reader samples again.
      generation = _question._value ?? -1;
    }
    final retry = _retry._value;
    final query = _current;
    if (query != null) {
      if (query._generation != generation || query._retry != retry) {
        // Nobody asks that question any more: the round ends now with its
        // producer, lease or not — a lease keeps the answer, not the
        // resources of a round nobody wants.
        if (!query._closed && _cancelAttempt()) return;
      } else {
        if (query._ending && !query._closed) _endRound(query);
        final answer = query._pending;
        if (answer != null) {
          // The comparator is user code: the step that ran
          // it ends, the next installs. A newer answer that arrives
          // meanwhile replaces this one and is compared in turn.
          if (answer.prepared == null) {
            final compares = _compares(answer);
            answer.prepared = _prepare(query, answer);
            if (compares) return _afterUserCode();
          }
          query._pending = null;
          return _install(answer.prepared! as _Landing<T>);
        }
        final produced = query._produced;
        if (produced != null) {
          // A Future runs already: its answer is taken even while cold. A
          // stream is listened to only while observed: the query function
          // may have removed the last reader.
          if (observed || produced is Future<Object?>) {
            return _subscribe(query, produced);
          }
          _cancelAttempt();
        }
      }
    }
    if (observed) {
      if (generation != _launchedGeneration || retry != _launchedRetry) {
        _launch(generation, retry);
      } else {
        _completeWaits();
      }
      return;
    }
    _coolDown(generation, retry);
  }

  /// The unobserved half of a reconcile: cooling requests, held-error invalidation, retention.
  void _coolDown(int generation, int retry) {
    if (_dropRequested || _expireRequested) {
      final drop = _dropRequested;
      _dropRequested = _expireRequested = false;
      if (_lease != null) return;
      if (_cancelAttempt()) {
        // onCancel ran: the drop waits for the next step.
        _dropRequested = drop;
        return;
      }
      if (drop) _drop();
      return;
    }
    final landed = _landed._value;
    if (!_working && landed == null && _timer == null) return;
    if (landed != null &&
        !landed.ok &&
        landed.generation == generation &&
        landed.retry == retry) {
      // A held error is invalidated, also under a lease.
      _retry._write(retry + 1);
      return;
    }
    if (_lease != null) return;
    if (_retain == Duration.zero) {
      final token = ++_coolToken;
      scheduleMicrotask(() {
        if (token == _coolToken && !_observed && _lease == null) {
          _dropRequested = true;
          _request();
        }
      });
    } else {
      if (_working) _startTimer();
      _unwatchedAt ??= clock.now();
    }
  }

  /// Ends the current round on its producer's request: a Future landed, a
  /// stream closed or failed to start.
  void _endRound(Query query) {
    assert(_debugStep(this));
    _endAttempt(query);
    if (_subscription != null) {
      _subscription = null;
      _activeQueryStreamCount--;
    }
    // A round that ends while cold (a Future landing, a stream
    // closing) leaves no work for the retention timer to end.
    if (!_observed) _cancelTimer();
    if (_stream && !query._answered && query._pending == null) {
      query._pending = _Answer(
        false,
        null,
        StateError(
          'RILL_EMPTY_QUERY: Stream of ${_describe(this)} closed without '
          'an answer.',
        ),
        StackTrace.current,
      );
    }
    query._closed = true;
  }

  void _install(_Landing<T> next) {
    if (!_observed && !_stream && _retain > Duration.zero && _lease == null) {
      // An attempt that ends while cold is fresh from now (its round
      // end above already ended the retention timer).
      _unwatchedAt = clock.now();
    }
    _record(next);
    // Downstreams waiting on this answer resolve in their reconcile.
    for (var link = _answer?._subs; link != null; link = link.nextSub) {
      final sub = link.sub;
      if (sub is _QueryQuestion) sub._query._schedule();
    }
  }

  /// Whether preparing [answer] runs the comparator.
  bool _compares(_Answer answer) =>
      answer.ok && (_landed._value?.hasGood ?? false);

  /// The landing record of [answer]. A comparator that throws makes the
  /// answer a failure with the comparator's own stack.
  _Landing<T> _prepare(Query query, _Answer answer) {
    assert(_debugStep(this));
    var ok = answer.ok;
    var error = answer.error;
    var stack = answer.stack;
    final previous = _landed._value;
    var reuse = false;
    if (ok && previous != null && previous.hasGood) {
      try {
        reuse = _sameAnswer(previous.good, answer.value);
      } on Object catch (e, s) {
        if (_isFatal(e)) rethrow;
        ok = false;
        error = e;
        stack = s;
      }
    }
    if (ok) {
      final good = reuse ? previous!.good as T : answer.value as T;
      return _Landing<T>(
        query._generation,
        query._retry,
        true,
        good,
        null,
        null,
        true,
        good,
      );
    }
    // Only a failure of the same question keeps the good answer: a new
    // question that fails forgets the old one, so no later question can
    // revive it.
    final keepGood =
        previous != null &&
        previous.hasGood &&
        previous.generation == query._generation;
    return _Landing<T>(
      query._generation,
      query._retry,
      false,
      null,
      error,
      stack,
      keepGood,
      keepGood ? previous.good : null,
    );
  }

  /// Cancels work, forgets the answer and releases the upstream
  /// answers its wait edges consumed. The edges stay: they still tell when an
  /// upstream changes question, so this query's own downstreams see `stale`.
  void _drop() {
    final cancelled = _cancelAttempt();
    assert(!cancelled, 'a drop runs once nothing is subscribed');
    for (var link = _question._deps; link != null; link = link.nextDep) {
      if (link is _WaitLink) {
        link
          ..consumed = link.consumed.release()
          ..attempt = null
          ..completer = null
          ..resolved = false
          ..compareFailed = false;
      }
    }
    _record(null);
    // Nothing would read these until the next read, and each holds the
    // answer meanwhile: the landing signal's committed
    // value, the cached state and the answer key. Commit the write, as a read
    // would, and replace the caches with what they derive from no landing.
    _landed._refresh();
    if (_subs == null && _value is! AsyncLoading<T>) {
      _replaceCold(AsyncLoading<T>());
    }
    final answer = _answer;
    if (answer != null && answer._subs == null) {
      final key = answer._value;
      if (key != null && key.kind != _Key.pending) {
        answer._replaceCold(
          _Key(key.generation, _Key.pending, null, null, null),
        );
      }
    }
  }

  /// Installs the landing record, the query's own output.
  void _record(_Landing<T>? next) {
    assert(_debugStep(this));
    _landed._write(next);
  }

  void _releaseLease() {
    _lease = null;
    _schedule();
  }

  void _startTimer() {
    if (_timer != null) return;
    _activeQueryTimerCount++;
    _timer = Timer(_retain, () {
      _timer = null;
      _activeQueryTimerCount--;
      if (!_observed && _lease == null) {
        _expireRequested = true;
        _request();
      }
    });
  }

  void _cancelTimer() {
    final timer = _timer;
    if (timer == null) return;
    _timer = null;
    _activeQueryTimerCount--;
    timer.cancel();
  }

  void _endAttempt(Query query) {
    if (!query._inFlight) return;
    query._inFlight = false;
    _activeQueryCount--;
  }

  /// Cancels the current attempt. Returns whether it cancelled a stream
  /// subscription: onCancel is user code, and the step ends.
  bool _cancelAttempt() {
    assert(_debugStep(this));
    final query = _current;
    _current = null;
    _launchedGeneration = _launchedRetry = -1;
    if (query != null) {
      query._closed = true;
      query._owner = null;
      query._pending = null;
      final produced = query._produced;
      query._produced = null;
      if (produced is Future<Object?>) produced.ignore();
      _endAttempt(query);
      if (!query._cancelled.isCompleted) query._cancelled.complete();
    }
    _cancelTimer();
    final subscription = _subscription;
    if (subscription == null) return false;
    _subscription = null;
    _activeQueryStreamCount--;
    _cancelStream(subscription);
    _afterUserCode();
    return true;
  }

  /// Runs the query function. Its result waits on the attempt for the next
  /// step to subscribe to: the function is user code, and the step ends.
  void _launch(int generation, int retry) {
    assert(_debugStep(this));
    final cancelled = _cancelAttempt();
    assert(!cancelled, 'a round is cancelled before its question relaunches');
    _launchedGeneration = generation;
    _launchedRetry = retry;
    _launchedOnce = true;
    // Seen by expectIdle even when the work ends between two pumps.
    bindingActivity++;
    final query = _current = Query._(this, generation, retry);
    if (!_stream) {
      query._inFlight = true;
      _activeQueryCount++;
    }
    final failure = _question._compareFailure;
    if (failure != null) {
      _question._compareFailure = null;
      if (_question._compareGeneration == generation) {
        // The question's edges stay as they are: nothing re-tracks them.
        query._tracking = false;
        query._deliver(
          _Answer(false, null, failure.error, failure.stack),
          end: true,
        );
        return;
      }
    }
    final question = _question.._launching = true;
    final previous = _begin(question, _mutable);
    Object? result;
    Object? error;
    StackTrace? stack;
    try {
      result = _debugZones
          ? runZoned(() => _load(query), zoneValues: {_queryZone: query})
          : _load(query);
    } on Object catch (e, s) {
      if (_isFatal(e)) rethrow;
      error = e;
      stack = s;
    } finally {
      _end(question, previous);
      question._launching = false;
      query._tracking = false;
    }
    _afterUserCode();
    // What follows only records the function's result on the attempt.
    if (_reaches(question, question)) {
      // A wait mixed with a synchronous read (or a read of this query)
      // closed a cycle. Drop the edges that lead back; the other inputs
      // stay, so an input change or invalidate() asks again.
      for (var link = question._deps; link != null;) {
        final dep = link.dep;
        link = identical(dep, question) || _reaches(dep, question)
            ? _unlink(link)
            : link.nextDep;
      }
      if (result is Future<Object?>) result.ignore();
      query._deliver(
        _Answer(
          false,
          null,
          _CycleError('RILL_CYCLE: Cycle detected in ${_describe(this)}.'),
          StackTrace.current,
        ),
        end: true,
      );
      return;
    }
    if (error != null) {
      // A factory that throws never produced a stream: the round ends with
      // its failure.
      query._deliver(_Answer(false, null, error, stack), end: true);
      return;
    }
    query._produced = result;
  }

  /// Takes the answer of the Future the query function returned, or
  /// listens to its stream (onListen is user code: the step ends).
  void _subscribe(Query query, Object produced) {
    assert(_debugStep(this));
    query._produced = null;
    if (produced is Future<Object?>) {
      // A Future's `then` is user code too when it is not the SDK's.
      query._await(produced);
    } else {
      try {
        void listen() {
          _subscription = query._listen(produced as Stream<Object?>);
        }

        _debugZones
            ? runZoned(listen, zoneValues: {_queryZone: query})
            : listen();
        if (_subscription != null) _activeQueryStreamCount++;
      } on Object catch (e, s) {
        if (_isFatal(e)) rethrow;
        query._deliver(_Answer(false, null, e, s), end: true);
      }
    }
    _afterUserCode();
  }

  /// Completes one wait whose answer arrived, only for the attempt the
  /// reconcile still wants, only while observed (a lease keeps the work,
  /// the continuation waits for an observer). Completing it is user code
  /// (a Future's `then`): the next wait is the next step's.
  void _completeWaits() {
    final current = _current;
    // Only a round still open delivers; a round that ended (landed,
    // closed, cancelled) or whose producer has ended it leaves its waits
    // behind, never completed.
    if (current == null || current._closed || current._endQueued) return;
    for (var link = _question._deps; link != null; link = link.nextDep) {
      if (link is _WaitLink &&
          link.resolved &&
          identical(link.attempt, current)) {
        link.resolved = false;
        final completer = link.completer;
        if (completer == null || completer.isCompleted) continue;
        return _completeWait(completer, link.consumed);
      }
    }
  }

  void _completeWait(Completer<Object?> completer, _Key key) {
    assert(_debugStep(this));
    if (key.kind == _Key.answer) {
      completer.complete(key.value);
    } else {
      completer.completeError(key.error!, key.stack);
    }
    _afterUserCode();
  }

  Future<S> _wait<S>(Query query, AsyncComputed<S> source) {
    final question = _question;
    if (!identical(_activeSub, question)) _failLateWait(source);
    _checkWaitCycle(source);
    final answer = source._answerNode;
    final key = untracked(() => answer.value);
    final link = _linkWait(answer, question, source, key, query);
    var completer = link.completer;
    if (completer == null) {
      completer = link.completer = source._newCompleter();
      if (key.kind != _Key.pending) {
        // A terminal answer already here is delivered like one that arrives
        // later: by the reconcile, to the round it still wants, while
        // observed.
        link.resolved = true;
        _schedule();
      }
    }
    return completer.future as Future<S>;
  }

  /// Refuses a wait that closes a cycle, before pulling the upstream.
  void _checkWaitCycle(AsyncComputed<Object?> source) {
    if (identical(source, this) || _reaches(source, _question)) {
      _failCycle(this);
    }
  }

  Completer<T> _newCompleter() => Completer<T>();

  /// The current answer expires: the retry number advances. Observed, the
  /// query asks the same question again (keeping the value, `refreshing`);
  /// unobserved, it keeps the value marked `refreshing` and asks once
  /// observed. Never starts work by itself and adds no observer. Retrying a
  /// query first retries the upstreams whose failure it consumed and that
  /// still fail.
  void invalidate() {
    assert(_checkWrite(_retry, bare: false));
    batch(() {
      for (var link = _question._deps; link != null; link = link.nextDep) {
        if (link is _WaitLink &&
            link.consumed.kind == _Key.failure &&
            link.source.peek() is AsyncError) {
          link.source.invalidate();
        }
      }
      _retry._write(_retry._value + 1);
      _schedule();
    });
  }

  /// [invalidate], then waits for the terminal state. The query is observed
  /// while this waits.
  Future<AsyncState<T>> refresh() {
    invalidate();
    return settled();
  }

  /// The terminal state of the current question: data that is neither
  /// stale nor refreshing, or an error. The query is observed while this
  /// waits, so a cold query starts.
  Future<AsyncState<T>> settled() {
    final completer = Completer<AsyncState<T>>();
    _Settle<T>(this, completer).check();
    return completer.future;
  }

  void _debugColdRead() {
    if (_coldReadChecked) return;
    _coldReadChecked = true;
    // The reader's frames are gone by the microtask.
    final trace = StackTrace.current;
    scheduleMicrotask(() {
      if (_observed || _launchedOnce) return;
      _warn(
        'RILL_COLD_QUERY_READ',
        this,
        'was read outside any observer and has never started: a query only '
            'works while observed. Observe it (Reactive, effect, watch) or '
            'await settled().',
        trace: trace,
      );
    });
  }

  void _cancelStream(StreamSubscription<Object?> subscription) {
    Future<void>.sync(subscription.cancel)
        .catchError((Object error, StackTrace stack) {
          (Rill.onError ?? Zone.current.handleUncaughtError)(error, stack);
        });
  }
}

/// The temporary observer of `settled()` / `refresh()`.
final class _Settle<T> extends Subscriber {
  _Settle(this.query, this.completer);

  final AsyncComputed<T> query;
  final Completer<AsyncState<T>> completer;

  void check() {
    if (disposed) return;
    final state = track(() => query.value);
    final terminal = switch (state) {
      AsyncData(stale: false, refreshing: false) || AsyncError() => true,
      _ => false,
    };
    if (terminal && !disposed) {
      dispose();
      completer.complete(state);
    }
  }

  @override
  void notify() => afterFlush(this, check);
}

AsyncComputed<T> _query<T>(
  Object Function(Query q) load,
  bool stream,
  String? name,
  Equals<T>? equals,
  Duration retain,
  Scope? keepAlive,
) {
  if (retain < Duration.zero) throw ArgumentError.value(retain, 'retain');
  // A disposed lease is a programming error, as for Scope.onDispose; check
  // before any node exists.
  keepAlive?._checkOpen();
  late final AsyncComputed<T> query;
  query = AsyncComputed<T>._(
    () => query._derive(),
    name,
    load,
    stream,
    equals,
    retain,
    keepAlive,
  );
  return query;
}

/// An async derivation from a Future. Inputs are tracked until the first
/// await. [equals] compares answers: an equal answer keeps the old value
/// reference and wakes nobody. [retain] is how long an unobserved answer
/// stays fresh (a logical TTL, not a memory timer: use the default zero to
/// release early) and how long unobserved work in flight is kept. While
/// [keepAlive] lives the query keeps its answer and work (a lease; it never
/// cancels an active observer).
AsyncComputed<T> computedAsync<T>(
  Future<T> Function(Query q) fn, {
  String? name,
  Equals<T>? equals,
  Duration retain = Duration.zero,
  Scope? keepAlive,
}) => _query(fn, false, name, equals, retain, keepAlive);

/// An async derivation from a Stream. [fn] must be synchronous (not async*):
/// inputs are tracked only until it returns the stream. See [computedAsync].
AsyncComputed<T> computedStream<T>(
  Stream<T> Function(Query q) fn, {
  String? name,
  Equals<T>? equals,
  Duration retain = Duration.zero,
  Scope? keepAlive,
}) => _query(fn, true, name, equals, retain, keepAlive);
