import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef Mutation = (String name, String file, String original, String altered);

const runtime = 'runtime.dart';
const graph = 'graph.dart';

const mutations = <Mutation>[
  (
    'signal equality early return',
    runtime,
    'if (equals == null ? _equal(_value, next) : equals(_value, next)) return;',
    'if (false) return;',
  ),
  (
    'revision on every install',
    runtime,
    '_value = next;\n    _writes = _revision = ++_clock;',
    '_value = next;\n    _writes = ++_clock;',
  ),
  ('quiet ABA pulldown', runtime, 'if (!_changed) return false;', ''),
  (
    'pending flag pull',
    graph,
    'return (flags & _pending) != 0 &&',
    'return (flags & _pending) == 0 &&',
  ),
  (
    'cold dependency version',
    graph,
    'if (link.version == dep._version) {',
    'if (link.version == link.version) {',
  ),
  (
    'cold first subscriber attaches upstream',
    runtime,
    'void _watched() => _setLive(this, true);',
    'void _watched() {}',
  ),
  (
    'cold last subscriber detaches upstream',
    runtime,
    'void _unwatched() => _setLive(this, false);',
    'void _unwatched() {}',
  ),
  (
    'cleanup precedes apply',
    runtime,
    '      _runCleanups();\n      if (_disposed) return;',
    '      if (_disposed) return;',
  ),
  (
    'debug feedback round limit',
    runtime,
    'if (!resumed && ++rounds > 100) {',
    'if (!resumed && ++rounds > 101) {',
  ),

  (
    'write guard independent of active subscriber',
    runtime,
    'if (_computing != 0 || _staging != 0) {',
    'if (_activeSub != null || _staging != 0) {',
  ),
  (
    'computed equality prunes the graph',
    runtime,
    '_revision == 0 ||\n          !(',
    '_revision >= 0 ||\n          !(',
  ),
  (
    'defer the next observer when a callback queues work',
    runtime,
    '            carried = count;\n            resumed = count > 0;\n            break;\n',
    '            carried = count;\n            resumed = count > 0;\n',
  ),
  (
    'recover the interrupted effect round',
    runtime,
    '          _recoverRound(current, index, prepared, applying: applying);\n',
    '',
  ),
  (
    'a fatal refresh requires retry',
    runtime,
    '      _requireRefresh();\n      // Let the next source write',
    '      // Let the next source write',
  ),
  (
    'preserve a fatal from the flush body',
    runtime,
    'if (!_isFatal(primary) && _isFatal(reported)) rethrow;',
    'rethrow;',
  ),
  (
    'prefer a fatal from the error handler',
    runtime,
    'if (previous == null || (_isFatal(error) && !_isFatal(previous))) {',
    'if (previous == null) {',
  ),
  (
    'isolate ordinary subscriber notification errors',
    runtime,
    '      notify();\n    } on Object catch (error, stack) {\n'
        '      if (_isFatal(error)) rethrow;',
    '      notify();\n    } on Object catch (error, stack) {\n'
        '      rethrow;',
  ),
  (
    'dispose deep Scope trees iteratively',
    runtime,
    '          child._beginDispose();\n          stack.add(child);',
    '          child.dispose();',
  ),
  (
    'owner disposal revokes publication and cancels',
    'command.dart',
    '_cancelAll(StaleReason.ownerDisposed);',
    '_cancelAll(StaleReason.superseded);',
  ),
  (
    'supersede revokes previous flight',
    'command.dart',
    '_cancelAll(StaleReason.superseded);\n      }',
    '\n      }',
  ),
  (
    'skip prevents admission while busy',
    'command.dart',
    'if (_policy == OnBusy.skip && _tasks.isNotEmpty)',
    'if (_policy == OnBusy.skip && _tasks.isEmpty)',
  ),
  (
    'queue starts in admission order',
    'command.dart',
    '_serial = _waiting.removeFirst();',
    '_serial = _waiting.removeLast();',
  ),
  (
    'same key reuses the future',
    'command.dart',
    'run.key == key &&',
    'false &&',
  ),
  (
    'final check after all staging',
    'command.dart',
    '  if (task != null && !task.alive) {\n'
        '    assert(_debugRefused(task, task));\n'
        '    return false;\n'
        '  }\n'
        '  if (failure != null) failure.raise();',
    '  if (failure != null) failure.raise();',
  ),
  (
    'delivery checks the owner',
    'command.dart',
    '(task._owner._alive ? null : StaleReason.ownerDisposed);',
    'null;',
  ),
  (
    'delivery runs in its own microtask',
    'command.dart',
    '    zone.scheduleMicrotask(() {\n      final reason =',
    '    zone.run(() {\n      final reason =',
  ),
  (
    'a throwing part rolls back',
    'command.dart',
    '    try {\n      stage();\n    } finally {\n      _frame = parent;\n    }',
    '    try {\n      stage();\n    } on Object {\n      parent.entries.add(layer);\n'
        '      rethrow;\n    } finally {\n      _frame = parent;\n    }',
  ),
  (
    'require in a part belongs to the part',
    'command.dart',
    '(_frame.conditions ??= []).add(condition);',
    '(_root.conditions ??= []).add(condition);',
  ),
  (
    'a kept part is checked again with the commit',
    'command.dart',
    '          if (entry.collect(writes, events) case final refusal?) {\n'
        '            return refusal;\n'
        '          }',
    '          entry.collect(writes, events);',
  ),
  (
    'staging is checked like a computation',
    runtime,
    'if (_computing != 0 || _staging != 0) {',
    'if (_computing != 0) {',
  ),
  (
    'end bookkeeping waits for the boundary',
    'command.dart',
    '    if (_boundary != 0 || _flushing || _computing != 0) {\n'
        '      run.zone.scheduleMicrotask(() => _settle(run));',
    '    if (false) {\n      run.zone.scheduleMicrotask(() => _settle(run));',
  ),
  (
    'Skipped is delivered with the owner check',
    'command.dart',
    '_owner._alive ? outcome : Stale<R>._(StaleReason.ownerDisposed),',
    'outcome,',
  ),
  (
    // Also covers the read set's sampling, which Unchanged took over.
    'Unchanged samples a binding signal',
    'command.dart',
    '  _sampleInput(source);\n  return source._revision;',
    '  if (source is Computed<Object?>) _sampleInput(source);\n'
        '  return source._revision;',
  ),
  (
    'Unchanged calibrates a hot computed',
    'command.dart',
    '  _sampleInput(source);\n  return source._revision;',
    '  if (source is Computed<Object?>) {\n'
        '    source._ensureFresh();\n'
        '  } else {\n'
        '    _sampleInput(source);\n'
        '  }\n'
        '  return source._revision;',
  ),
  (
    'transact checks the write guard',
    'command.dart',
    'bool _commit(Task? task, void Function(Tx) stage) {\n'
        '  assert(_checkWrite(null, bare: false));\n',
    'bool _commit(Task? task, void Function(Tx) stage) {\n',
  ),
  (
    'only an ended body reports a closed publication',
    'command.dart',
    '    if (_ended) {\n      assert(',
    '    if (!alive) {\n      assert(',
  ),
  (
    'emit checks staging',
    'command.dart',
    r"    assert(_checkStaging('emit on ${_describe(this)}'));"
        '\n',
    '',
  ),
  (
    'transact in a lapsed task is late',
    'debug.dart',
    '  if (task == null || !task._lapsed) return true;\n  for (final target in targets) {',
    '  if (true) return true;\n  for (final target in targets) {',
  ),
  (
    'a flushed reaction is not the task',
    'debug.dart',
    '  final task = _writerTask();\n  if (task == null || !task._lapsed) return true;',
    '  final task = Zone.current[_taskZone];\n'
        '  if (task is! Task || !task._lapsed) return true;',
  ),
  (
    'refusals match their slot',
    'debug.dart',
    'for (final node in [refusal.task, refusal.slot, refusal.source]) {',
    'for (final node in [refusal.task, refusal.source]) {',
  ),
  (
    'capacity trims refusals',
    'debug.dart',
    '    _trim(_runs, value);\n    _trim(_refusals, value);',
    '    _trim(_runs, value);',
  ),
  (
    'limit truncates refusals',
    'debug.dart',
    'for (final refusal in newest(RillDebug.refusals(target)))',
    'for (final refusal in RillDebug.refusals(target))',
  ),
  (
    // wire.dart sits in lib/, outside lib/src: `--file ../wire.dart`.
    'the ledger turns a JSON object into Map<Object?, Object?>',
    '../wire.dart',
    '  Map<String, dynamic>() => Map<String, dynamic>.unmodifiable(\n'
        '    wire.map((key, value) => MapEntry(key, _snapshot(value))),\n'
        '  ),\n',
    '',
  ),
  (
    'query yields to a pending dependency update',
    'query.dart',
    '      if (query._generation != generation || query._retry != retry) {',
    '      if (false) {',
  ),
  (
    'a failed new question does not revive the previous answer',
    'query.dart',
    'previous.generation == query._generation;',
    'true;',
  ),
  (
    'validate concrete signal before installation',
    'command.dart',
    'final candidate = target._validateCandidate(value);',
    'final candidate = value;',
  ),
  (
    'validate concrete event before installation',
    'command.dart',
    '_frame.entries.add(target._prepareEvent(event));',
    '_frame.entries.add(() => target._dispatch(event));',
  ),
  (
    'rethrow the original query stack',
    'query.dart',
    'T get requireValue => Error.throwWithStackTrace(error, stack);',
    'T get requireValue => throw error;',
  ),
  (
    'deferred first apply runs at creation',
    runtime,
    '  int _state = 0;',
    '  int _state = 2;',
  ),
  (
    'release applies a withheld value',
    runtime,
    '    if (!_held || node._disposed) return;',
    '    if (node._disposed) return;',
  ),
  (
    'failed compute keeps the held value',
    runtime,
    '    if (_state == 0) _held = false;\n',
    '',
  ),
  (
    'first apply sees the held previous',
    runtime,
    '        _apply(value, null, onCleanup);',
    '        _apply(value, previous, onCleanup);',
  ),
  (
    'constant links into its readers',
    runtime,
    '  T get value => _value;\n\n  @override\n  T peek() => _value;',
    '  T get value {\n    final sub = _activeSub;\n    if (sub != null) _link(this, sub);\n'
        '    return _value;\n  }\n\n  @override\n  T peek() => _value;',
  ),
  (
    'frame writes defer no effect',
    runtime,
    '(_frameWrite ? _deferred : _queued).add(this);',
    '_queued.add(this);',
  ),
  (
    'an idle flush keeps the frame mark',
    runtime,
    '    }());\n    _frameWrite = false;\n    return;',
    '    }());\n    return;',
  ),
  (
    'a full flush keeps the frame mark',
    runtime,
    '    _flushing = false;\n    _frameWrite = false;',
    '    _flushing = false;',
  ),
  (
    'a frame write that installs nothing still marks',
    runtime,
    'if (_clock == clock) _frameWrite = marked;',
    '',
  ),
  (
    'release applies a held value a frame write made stale',
    runtime,
    'if (_deferred.contains(node)) {',
    'if (false) {',
  ),
  (
    'binding inputs sample on a cold pull',
    'query.dart',
    '      if (hooks != null) signal._runHooks(hooks);\n',
    '',
  ),
  (
    'a wait edge marks the sampled input',
    'query.dart',
    '  if (dep._maySample && !sub._hasSampledInput) _markSampledInput(sub);\n'
        '  if (sub._live) _attach(link);\n',
    '  if (sub._live) _attach(link);\n',
  ),

  (
    'a retained query samples the clock',
    'query.dart',
    '    if (_retain > Duration.zero) _hasSampledInput = true;\n',
    '',
  ),
  (
    'expiry is derived in the pull',
    'query.dart',
    'landed.retry == retry && !_expired) {',
    'landed.retry == retry) {',
  ),
  (
    'a refreshing answer is pending',
    'query.dart',
    'AsyncData(:final value, stale: false, refreshing: false) => _Key(',
    'AsyncData(:final value, stale: false) => _Key(',
  ),
  (
    'a failed refresh resolves a new wait as an error',
    'query.dart',
    'AsyncError(:final error, :final stack) => _Key(',
    'AsyncError(:final error, :final stack, hasPrevious: false) => _Key(',
  ),
  (
    'the comparator only records a resolution',
    'query.dart',
    '        resolved = true;\n',
    '        resolved = true;\n'
        '        if (completer case final c? when key.kind == _Key.answer) {\n'
        '          if (!c.isCompleted) c.complete(key.value);\n'
        '        }\n',
  ),
  (
    'equal upstream answers keep the downstream',
    'query.dart',
    '!held.released && !source._sameAnswer(held.value, key.value);',
    '!held.released;',
  ),
  (
    'retry reaches a failed upstream',
    'query.dart',
    '          link.source.invalidate();\n',
    '',
  ),
  (
    'retry leaves a retrying upstream alone',
    'query.dart',
    'link.source.peek() is AsyncError',
    'true',
  ),
  (
    'a cooling microtask yields to a new observer',
    'query.dart',
    'if (token == _coolToken && !_observed && _lease == null) {',
    'if (!_observed && _lease == null) {',
  ),
  (
    'only work in flight keeps a timer',
    'query.dart',
    '      if (_working) _startTimer();\n',
    '',
  ),
  (
    'a retained answer records when it went cold',
    'query.dart',
    '      _unwatchedAt ??= clock.now();\n',
    '',
  ),
  (
    'a held error is invalidated while cold',
    'query.dart',
    '      _retry._write(retry + 1);\n',
    '',
  ),
  (
    'a lease does not skip held-error invalidation',
    'query.dart',
    '    final landed = _landed._value;\n'
        '    if (!_working && landed == null && _timer == null) return;',
    '    if (_lease != null) return;\n'
        '    final landed = _landed._value;\n'
        '    if (!_working && landed == null && _timer == null) return;',
  ),
  (
    'a cold landing ends the retention timer',
    'query.dart',
    '    // closing) leaves no work for the retention timer to end.\n'
        '    if (!_observed) _cancelTimer();\n',
    '    // closing) leaves no work for the retention timer to end.\n',
  ),
  (
    'an ended round leaves its waits uncompleted',
    'query.dart',
    'if (current == null || current._closed || current._endQueued) return;',
    'if (current == null || current._endQueued) return;',
  ),

  (
    'a cold stream close ends the retention timer',
    'query.dart',
    '    if (!_observed) _cancelTimer();\n',
    '',
  ),
  (
    'a cold sampled node refreshes on any freshness check',
    runtime,
    '      if (_hasSampledInput) {\n        // A sampled input',
    '      if (false) {\n        // A sampled input',
  ),
  (
    'a reused edge carries the sampled mark',
    graph,
    '    if (dep._maySample) _markReused(dep, sub);\n',
    '',
  ),
  (
    'a reused wait edge carries the sampled mark',
    'query.dart',
    '    if (dep._maySample && !sub._hasSampledInput) _markSampledInput(sub);\n'
        '    return nextDep;',
    '    return nextDep;',
  ),
  (
    'AsyncState equality ignores the type argument',
    'query.dart',
    'other is AsyncData<Object?> &&',
    'other is AsyncData<T> &&',
  ),
  (
    'a superseded attempt is cancelled',
    'query.dart',
    '      if (!query._cancelled.isCompleted) query._cancelled.complete();\n',
    '',
  ),
  (
    'a disposed Scope accepts registrations',
    runtime,
    '    _checkOpen();\n    final entry = _ScopeCleanup(target);',
    '    final entry = _ScopeCleanup(target);',
  ),
  (
    'a throwing apply drops what it registered',
    runtime,
    '      _errors.add(_Failure(error, stack));\n'
        '    } finally {\n'
        '      assert(--_diagnosticUntrackedDepth',
    '      _errors.add(_Failure(error, stack));\n'
        '      _cleanup = null;\n'
        '    } finally {\n'
        '      assert(--_diagnosticUntrackedDepth',
  ),
  (
    'onCleanup after stop is dropped',
    runtime,
    '    if (_disposed) {\n      batch(() => _invoke(cleanup));\n      return;\n    }',
    '    if (_disposed) return;',
  ),
  (
    'an apply is not an explicit snapshot',
    runtime,
    '    assert(++_diagnosticUntrackedDepth > 0);\n'
        '    try {\n'
        '      _apply(value, old, _onCleanup);\n'
        '    } on Object catch (error, stack) {\n'
        '      if (error is StackOverflowError || error is OutOfMemoryError) rethrow;\n'
        '      _errors.add(_Failure(error, stack));\n'
        '    } finally {\n'
        '      assert(--_diagnosticUntrackedDepth >= 0);\n',
    '    try {\n'
        '      _apply(value, old, _onCleanup);\n'
        '    } on Object catch (error, stack) {\n'
        '      if (error is StackOverflowError || error is OutOfMemoryError) rethrow;\n'
        '      _errors.add(_Failure(error, stack));\n'
        '    } finally {\n',
  ),
  (
    'the Slot body is tracked by its starter',
    'command.dart',
    '      () => untracked(\n'
        '        () => _debugZones\n'
        '            ? runZoned(() => body(task), zoneValues: {_taskZone: task})\n'
        '            : body(task),\n'
        '      ),',
    '      () => _debugZones\n'
        '          ? runZoned(() => body(task), zoneValues: {_taskZone: task})\n'
        '          : body(task),',
  ),
  (
    'a throwing comparator escapes the landing',
    'query.dart',
    '        ok = false;\n        error = e;\n        stack = s;\n',
    '        rethrow;\n',
  ),
  (
    // The step goes on after the comparator: the step guard refuses it.
    'a reentrant comparator installs the superseded answer',
    'query.dart',
    '            if (compares) return _afterUserCode();\n',
    '            if (compares) _afterUserCode();\n',
  ),

  (
    'a wait-edge comparator throw escapes the pull',
    'query.dart',
    '            failure ??= _Failure(e, s);\n',
    '            rethrow;\n',
  ),
  (
    'a wait-edge comparator failure is not the answer',
    'query.dart',
    '      if (_question._compareGeneration == generation) {',
    '      if (false) {',
  ),

  (
    'each wait wraps the shared future',
    'query.dart',
    '    return completer.future as Future<S>;\n  }',
    '    return completer.future.then((value) => value as S);\n  }',
  ),
  (
    'the next stream opens after a reentrant cancel',
    'query.dart',
    '        if (!query._closed && _cancelAttempt()) return;\n',
    '        if (!query._closed) _cancelAttempt();\n',
  ),

  (
    'an error event is not an answer',
    'query.dart',
    '          _answered = true;\n          _deliver(event);\n',
    '          if (event.ok) _answered = true;\n          _deliver(event);\n',
  ),

  (
    'a failed edge comparison is forgotten',
    'query.dart',
    '            link.compareFailed = true;\n',
    '',
  ),

  (
    'a failed stream factory leaves its round open',
    'query.dart',
    '      query._deliver(_Answer(false, null, error, stack), end: true);\n',
    '      query._deliver(_Answer(false, null, error, stack));\n',
  ),

  (
    'a cycle failure is cached as validated',
    runtime,
    '    if (error is _CycleError) {\n'
        '      // L1: never cached as validated, hot or cold; the next pull asks again.\n'
        '      _flags |= _mustRefresh;\n'
        '      _validated = -1;\n'
        '    } else if (_subs == null) {',
    '    if (_subs == null) {',
  ),
  (
    'carried after-flush work counts as a round',
    runtime,
    '            resumed = count > 0;\n',
    '            resumed = false;\n',
  ),

  (
    'a leased round nobody asks for keeps its producer',
    'query.dart',
    '        if (!query._closed && _cancelAttempt()) return;\n',
    '        if (!query._closed && _lease == null && _cancelAttempt()) return;\n',
  ),

  (
    'a cold read that finds a new question keeps the round',
    'query.dart',
    '        if (!query._closed && _cancelAttempt()) return;\n',
    '        if (!query._closed && observed && _cancelAttempt()) return;\n',
  ),
  (
    'every step of a reconcile yields to the flush',
    'query.dart',
    '      if (!_afterFlush.containsKey(this) || ++steps == 100) return;\n',
    '      return;\n',
  ),
  (
    'a pass that broke for effects is never counted',
    runtime,
    '            resumed = count > 0;\n',
    '            resumed = true;\n',
  ),
  (
    'a queued end does not hold the next wait',
    'query.dart',
    'if (current == null || current._closed || current._endQueued) return;',
    'if (current == null || current._closed) return;',
  ),
  (
    'one step completes every wait',
    'query.dart',
    '        return _completeWait(completer, link.consumed);\n',
    '        _completeWait(completer, link.consumed);\n',
  ),
  (
    'an unobserved round listens to its stream',
    'query.dart',
    'if (observed || produced is Future<Object?>) {',
    'if (true) {',
  ),
  (
    'the factory step listens at once',
    'query.dart',
    '    query._produced = result;\n',
    '    _subscribe(query, result!);\n',
  ),
  (
    'a stream event is delivered inside the code that sent it',
    'query.dart',
    '      scheduleMicrotask(_drain);\n    }\n    inbox.add(event);\n',
    '    }\n    inbox.add(event);\n    if (inbox.length == 1) _drain();\n',
  ),
  (
    'deliveries that keep queuing deliveries are never counted',
    'query.dart',
    '      _chain = _delivering < 0 ? 0 : _delivering + 1;\n',
    '      _chain = 0;\n',
  ),
  (
    'a wait after the first await only waits',
    'query.dart',
    '    if (owner == null || !_tracking) _failLateWait(source);\n'
        '    return owner._wait(this, source);\n',
    '    if (owner == null) return Completer<S>().future;\n'
        '    if (!_tracking) return source.settled().then((s) => s.requireValue);\n'
        '    return owner._wait(this, source);\n',
  ),
  (
    'the step guard lets a transition run after user code',
    'query.dart',
    '  if (query != null && _debugUserCodeRan) {\n',
    '  if (query != null && false) {\n',
  ),

  (
    'an unobserved reconcile samples its question',
    'query.dart',
    '      generation = _question._value ?? -1;\n',
    '      generation = _question.peek();\n'
        '      if (_moved(writes, observed)) return;\n',
  ),
  (
    'a cached tracked wait completes at once',
    'query.dart',
    '        link.resolved = true;\n        _schedule();\n',
    '        if (key.kind == _Key.answer) completer.complete(key.value);\n',
  ),
  (
    'a reconcile that moved the graph is not asked again',
    'query.dart',
    '      if (_moved(writes, observed)) {\n        _schedule();\n',
    '      if (_moved(writes, observed)) {\n',
  ),
];

void _copyDirectory(Directory source, Directory target) {
  target.createSync(recursive: true);
  for (final entry in source.listSync()) {
    final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
    final destination = '${target.path}/$name';
    if (entry is Directory) {
      _copyDirectory(entry, Directory(destination));
    } else if (entry is File) {
      entry.copySync(destination);
    }
  }
}

/// Core mutants only a process test sees, by the test's plain name: a held
/// reference shows only under forced GC (once an ended round
/// also refuses late waits, the in-process test no longer tells).
const processMutations = <(Mutation, String)>[
  (
    (
      'a cancelled attempt keeps its query',
      'query.dart',
      '      query._owner = null;\n',
      '',
    ),
    'cooled_query_is_not_held_by_a_pending_future',
  ),
  (
    (
      // A synchronous loop: only a process test's kill timer sees it.
      'validation revisits a node still in its cycle',
      graph,
      '      if (returned) {\n        returned = false;\n      } else if',
      '      if (returned) {\n        returned = false;\n      }\n      if',
    ),
    'cycles_rounds_and_installs_in_debug',
  ),
  (
    (
      // A table that holds every computed that gained a live input until a
      // later transition (the scheduler's _relinked): only forced GC tells.
      'a computed that gains an input is held',
      graph,
      '  if (sub._live) _attach(link);\n',
      '  if (sub._live) {\n'
          '    _attach(link);\n'
          '    Timer(const Duration(days: 1), () => sub);\n'
          '  }\n',
    ),
    'no_scheduler_rounds_feedback_or_relink_table_in_debug',
  ),
  (
    (
      // The landing signal keeps the cooled answer as its committed value
      // until a read that never comes: only forced GC tells.
      'a cooled query keeps its answer',
      'query.dart',
      '    _landed._refresh();\n',
      '',
    ),
    'cooled_query_releases_its_answer_in_debug',
  ),
  (
    (
      // The body's pending Future still reaches the run, its body and the
      // page model behind it: only forced GC tells.
      'a cancelled run stays on its Future',
      'command.dart',
      '    _body = null;\n    _settle?.cut();\n',
      '',
    ),
    'disposed_scope_releases_a_task_on_a_pending_future_in_debug',
  ),
  (
    (
      // A cut link that still holds its task reaches the disposed Scope
      // through the task's owner: only forced GC tells, and only on the
      // Scope and the Task themselves (the page model is not on the path).
      'a cut link holds its task',
      'command.dart',
      '    _cutTask = WeakReference(run.task);\n'
          '    _run = null;\n'
          '    _ended = null;\n',
      '    _cutTask = WeakReference(run.task);\n'
          '    _run = null;\n'
          '    _ended = () => run.task;\n',
    ),
    'pending_future_holds_no_disposed_scope_or_task_in_debug',
  ),
];

const flutterMutations = <(Mutation, String)>[
  (
    (
      'every notify marks the Flutter reader dirty',
      'observer.dart',
      'afterFlush(this, _validate);',
      'invalidate();',
    ),
    'budget_test.dart',
  ),
  (
    (
      'reattach retains old paint',
      'paint.dart',
      'if (_hasPainted) notifyListeners();',
      '',
    ),
    'budget_test.dart',
  ),
  (
    (
      'clock ignores reader visibility',
      'time.dart',
      'node is! _Observer || node.visibleFor(decorative: decorative)',
      'true',
    ),
    'lifecycle_test.dart',
  ),
  (
    (
      'every persistent notification queues a post-frame mark',
      'observer.dart',
      'if (_deferred != null) return;',
      '',
    ),
    'budget_test.dart',
  ),
  (
    (
      'untracked reads are silent',
      'observer.dart',
      'bindingReadGuard = _guardRead;',
      'bindingReadGuard = null;',
    ),
    'diagnostics_test.dart',
  ),
  (
    (
      'sample retired cold inputs before running the current branch',
      'runtime.dart',
      '      // Re-evaluate the branch before sampling any managed input.',
      '      for (var link = _deps; link != null; link = link.nextDep) {\n'
          '        final input = link.dep;\n'
          '        if (input is Computed<Object?> && input._maySample) input.value;\n'
          '      }',
    ),
    'async_test.dart',
  ),
  (
    (
      'ignore writes made while the subscriber is tracking',
      'runtime.dart',
      '_flags & _recursed != 0 &&',
      'false &&',
    ),
    'bridges_test.dart',
  ),
  (
    (
      'skip listener cleanup after dispatch',
      'adapters.dart',
      '} finally {\n          _releaseIfIdle();\n        }',
      '} finally {}',
    ),
    'bridges_test.dart',
  ),
  (
    (
      'linger samples before registering the recovery dependency',
      'time.dart',
      'final current = _state.value;',
      'if (_state.peek() == null) source.peek();\n    final current = _state.value;',
    ),
    'async_test.dart',
  ),
  (
    (
      'watch applies first inside the build',
      'lifecycle.dart',
      'schedule: _afterFrame,\n      owner: scope,',
      'schedule: (release) => release(),\n      owner: scope,',
    ),
    'reactive_state_test.dart',
  ),
  (
    (
      'deferred apply requests no frame',
      'lifecycle.dart',
      "debugLabel: 'rill.effect')\n    ..ensureVisualUpdate();",
      "debugLabel: 'rill.effect');",
    ),
    'reactive_state_test.dart',
  ),
  (
    (
      'State keeps its scope after dispose',
      'lifecycle.dart',
      '    _lifetime?.dispose();\n',
      '',
    ),
    'reactive_state_test.dart',
  ),
  (
    (
      'bridge writes are ordinary',
      'adapters.dart',
      '_frameWrite(() => writeBindingSignal(state, listenable.value));',
      'writeBindingSignal(state, listenable.value);',
    ),
    'frame_writes_test.dart',
  ),
  (
    (
      'activate leaves the reader unbuilt',
      'widgets.dart',
      '    // has any of its own.\n    markNeedsBuild();',
      '    // has any of its own.',
    ),
    'ownership_test.dart',
  ),
  (
    (
      'the host wake-up leaves its update for after the frame',
      'observer.dart',
      '    if (deferred == null) return;\n    _deferred = null;\n    invalidate();',
      '    if (deferred == null) return;',
    ),
    'ownership_test.dart',
  ),
  (
    (
      'a painter host does not reconcile on a dependency change',
      'paint.dart',
      '    _background?.repaint.hostChanged();',
      '',
    ),
    'ownership_test.dart',
  ),
  (
    (
      'visibility ignores TickerMode',
      'observer.dart',
      '    if (!tickerMode.value.enabled) return false;\n',
      '',
    ),
    'ownership_test.dart',
  ),
  (
    (
      'decorative sources ignore reduced motion',
      'observer.dart',
      '    return !(MediaQuery.maybeDisableAnimationsOf(element) ?? false);',
      '    return true;',
    ),
    'ownership_test.dart',
  ),
  (
    (
      'the host reconciles inside notifyClients',
      'widgets.dart',
      '    super.didChangeDependencies();\n    _dependenciesChanged = true;',
      '    super.didChangeDependencies();\n'
          '    final observer = _observer;\n'
          '    if (observer != null && observer.motionQueried) '
          'observer.hostChanged();',
    ),
    'ownership_test.dart',
  ),
  (
    (
      'a painter host leaves its BuildOwner unguarded',
      'paint.dart',
      '    // A ReactivePaint may be the only reader on an independent BuildOwner.\n'
          '    _installGuards(context.owner);',
      '',
    ),
    'ownership_test.dart',
  ),
  (
    (
      'painters without semantics rebuild semantics',
      'paint.dart',
      '    if (painter.semanticsBuilder == null &&\n'
          '        oldDelegate.painter.semanticsBuilder == null) {\n'
          '      return false;\n'
          '    }\n',
      '',
    ),
    'ownership_test.dart',
  ),
  (
    (
      'an untracked frame read is let through',
      'observer.dart',
      '  final phase = _framePhase();\n  if (phase == null) return;',
      '  final phase = _framePhase();\n  return;',
    ),
    'diagnostics_test.dart',
  ),
  (
    (
      'a cleanup founds a second State scope',
      'lifecycle.dart',
      '    _ending = true;\n    _lifetime?.dispose();\n',
      '    final lifetime = _lifetime;\n    _lifetime = null;\n    lifetime?.dispose();\n',
    ),
    'binding_probes_test.dart',
  ),
  (
    (
      'pulse handles share only once observed',
      'time.dart',
      '  _sharedPulses[key] = WeakReference(source);\n',
      '',
    ),
    'binding_probes_test.dart',
  ),
  (
    (
      'frame questions need a binding',
      'observer.dart',
      '  if (kDebugMode && BindingBase.debugBindingType() == null) return null;\n',
      '  return WidgetsBinding.instance;\n',
    ),
    'binding_free_test.dart',
  ),
  (
    (
      'a pulse never registers its lifecycle observer',
      'time.dart',
      '  _lifecycleBinding = binding..addObserver(_pulseLifecycle);\n  return true;\n',
      '  return false;\n',
    ),
    'pulse_binding_late_test.dart',
  ),
  (
    (
      'a sync defers the readers below its owner',
      'observer.dart',
      'if (syncing != null && syncing._admits(this)) {',
      'if (false) {',
    ),
    'widget_input_test.dart',
  ),
  (
    (
      'the subtree check ignores Element ancestry',
      'input.dart',
      '    found = identical(parent, ancestor);',
      '    found = false;',
    ),
    'widget_input_test.dart',
  ),
  (
    (
      'the write guard does not exempt a sync',
      'observer.dart',
      'if (_framePhase() != null && _syncing == null) {',
      'if (_framePhase() != null) {',
    ),
    'widget_input_test.dart',
  ),
  (
    (
      'sync is an ordinary write',
      'input.dart',
      '_frameWrite(() => _node.value = value);',
      '_node.value = value;',
    ),
    'widget_input_test.dart',
  ),
  (
    (
      'escaped readers are not reported',
      'input.dart',
      'if (dependents.contains(observer)) (_escaped ??= []).add(observer);',
      '',
    ),
    'widget_input_test.dart',
  ),
  (
    (
      'every outside reader woken during a sync is escaped',
      'input.dart',
      'if (dependents.contains(observer)) (_escaped ??= []).add(observer);',
      '(_escaped ??= []).add(observer);',
    ),
    'widget_input_test.dart',
  ),
  (
    (
      'sync is legal outside the owner window',
      'input.dart',
      '} else if (!owner._inputWindow || _framePhase() != \'build\') {',
      '} else if (_framePhase() != \'build\') {',
    ),
    'widget_input_test.dart',
  ),
  (
    (
      'the owner window never closes',
      'lifecycle.dart',
      '      (_) => _inputWindow = false,',
      '      (_) {},',
    ),
    'widget_input_test.dart',
  ),
  (
    (
      'sync is legal in the owner build',
      'input.dart',
      '} else if (element.debugDoingBuild) {',
      '} else if (false) {',
    ),
    'widget_input_test.dart',
  ),
  (
    (
      'sync after the owner is disposed is legal',
      'input.dart',
      '    if (element == null || element.debugIsDefunct) {\n      where = \'after its owner was disposed\';\n    } else if',
      '    if (element == null || element.debugIsDefunct) {\n      where = null;\n    } else if',
    ),
    'widget_input_test.dart',
  ),
  (
    (
      'a sync inside a batch is let through',
      'input.dart',
      '    } else if (bindingBoundaryOpen) {',
      '    } else if (false) {',
    ),
    'widget_input_test.dart',
  ),
  (
    (
      'a sync in the owner dispose is not after disposal',
      'input.dart',
      'if (element == null || element.debugIsDefunct) {',
      'if (element == null) {',
    ),
    'widget_input_test.dart',
  ),
  (
    (
      'the composite host leaves its BuildOwner unguarded on activate',
      'composite.dart',
      '    super.activate();\n    _installGuards(owner);\n',
      '    super.activate();\n',
    ),
    'composite_test.dart',
  ),
  (
    (
      'a composite reader has no host',
      'composite.dart',
      '      host: _host,',
      '      host: null,',
    ),
    'composite_test.dart',
  ),
  (
    (
      'the composite host does not reconcile in performRebuild',
      'composite.dart',
      '    _reconcile();\n    super.performRebuild();',
      '    super.performRebuild();',
    ),
    'composite_test.dart',
  ),
  (
    (
      'the composite host does not reconcile when its parent rebuilds it',
      'composite.dart',
      '    super.update(newWidget);\n    _reconcile();',
      '    super.update(newWidget);',
    ),
    'composite_test.dart',
  ),
  (
    (
      're-attach waits for the next notification',
      'composite.dart',
      '      frameBound: true,\n    );\n    _sync();',
      '      frameBound: true,\n    );',
    ),
    'composite_test.dart',
  ),
  (
    (
      'transform origin: alignment is ignored',
      'composite.dart',
      '    if (alignment != null) pivot += alignment.alongSize(size);\n',
      '',
    ),
    'composite_test.dart',
  ),
  (
    (
      'transform origin: origin is ignored',
      'composite.dart',
      '    var pivot = origin ?? Offset.zero;',
      '    var pivot = Offset.zero;',
    ),
    'composite_test.dart',
  ),
  (
    (
      'transform origin: the alignment ignores the text direction',
      'composite.dart',
      '_alignment?.resolve(_textDirection);',
      '_alignment?.resolve(TextDirection.ltr);',
    ),
    'composite_test.dart',
  ),
  (
    (
      'transform origin: the layer uses the raw matrix',
      'composite.dart',
      '    layer.transform = _effective;',
      '    layer.transform = _matrix;',
    ),
    'composite_test.dart',
  ),
  (
    (
      'transform origin: hit tests use the raw matrix',
      'composite.dart',
      '      transform: _effective,\n      position: position,',
      '      transform: _matrix,\n      position: position,',
    ),
    'composite_test.dart',
  ),
  (
    (
      'transform origin: applyPaintTransform uses the raw matrix',
      'composite.dart',
      '    transform.multiply(_effective);',
      '    transform.multiply(_matrix);',
    ),
    'composite_test.dart',
  ),
  (
    (
      'transform origin: a placement change does not update the layer',
      'composite.dart',
      '  void _placementChanged() {\n    markNeedsCompositedLayerUpdate();',
      '  void _placementChanged() {',
    ),
    'composite_test.dart',
  ),
  (
    (
      'transform origin: updateRenderObject drops the alignment',
      'composite.dart',
      '      ..alignment = alignment\n',
      '',
    ),
    'composite_test.dart',
  ),
  (
    (
      'transform origin: updateRenderObject drops the text direction',
      'composite.dart',
      '      ..textDirection = Directionality.maybeOf(context)\n      ..transformHitTests',
      '      ..transformHitTests',
    ),
    'composite_test.dart',
  ),
];

/// A hung run is killed (SIGKILL) after its kind's limit. Stream events
/// reach queries in microtasks, so a mutant that turns work into a
/// feedback loop through them starves the event loop: no test timeout can
/// fire. A run that is killed counts as killed (a hang). Whether a mutant
/// hangs depends on which test the runner schedules first, so any of them
/// may hit the limit on some run: it is the tail of every shard.

/// Runs a command to completion, killing it past [limit]. The output is
/// whatever arrived: a killed run may leave a grandchild holding the pipes,
/// so the streams are not awaited for long after the exit.
Future<ProcessResult> _run(
  String executable,
  List<String> args,
  Directory directory, {
  Duration? limit,
}) async {
  final process = await Process.start(
    executable,
    args,
    workingDirectory: directory.path,
  );
  final out = StringBuffer(), err = StringBuffer();
  final outDone = process.stdout.transform(utf8.decoder).forEach(out.write);
  final errDone = process.stderr.transform(utf8.decoder).forEach(err.write);
  final timer = limit == null
      ? null
      : Timer(limit, () => process.kill(ProcessSignal.sigkill));
  final code = await process.exitCode;
  timer?.cancel();
  await Future.wait([outDone, errDone])
      .timeout(const Duration(seconds: 10), onTimeout: () => const []);
  return ProcessResult(process.pid, code, '$out', '$err');
}

Future<ProcessResult> _dart(
  Directory directory,
  List<String> args,
  Duration limit,
) => _run(Platform.resolvedExecutable, args, directory, limit: limit);

Future<ProcessResult> _flutter(Directory directory, List<String> args) =>
    _run('flutter', args, directory);

/// Whether the mutant was killed, and the line that says so: the run failed
/// (exit 1) and at least one test that actually ran failed. A compile or
/// load failure fails no test that has a line, so it counts as a survivor,
/// as does a clean run.
(bool, String) _killed(String name, Duration? limit, ProcessResult result) {
  final events = (result.stdout as String)
      .split('\n')
      .where((line) => line.startsWith('{'))
      .map((line) {
        try {
          return jsonDecode(line) as Map<String, dynamic>;
        } on FormatException {
          return const <String, dynamic>{}; // cut off by a kill
        }
      })
      .toList();
  // In the order tests finished: under --fail-fast the tests still running
  // when the first one fails are cancelled and reported after it.
  final tests = {
    for (final event in events)
      if (event['type'] == 'testStart' && event['test']['line'] != null)
        event['test']['id']: event['test']['name'],
  };
  final killers = [
    for (final event in events)
      if (event['type'] == 'testDone' &&
          event['result'] != 'success' &&
          tests.containsKey(event['testID']))
        tests[event['testID']],
  ];
  if (result.exitCode == 137 || result.exitCode == -9) {
    return (true, '$name: hung past ${limit?.inSeconds}s (killed)');
  }
  if (result.exitCode != 1 || killers.isEmpty) {
    return (false, 'SURVIVED $name (exit ${result.exitCode})');
  }
  return (true, '$name: ${killers.first}');
}

void _validateMutations(Directory package, Iterable<Mutation> mutations) {
  for (final (name, file, original, _) in mutations) {
    final contents = File('${package.path}/lib/src/$file').readAsStringSync();
    if (original.allMatches(contents).length != 1) {
      throw StateError('Mutation must match exactly once: $name');
    }
  }
}

const _usage = '''
Usage: dart run tool/mutate.dart [--only <substring>]... [--file <name>]...
                                 [--changed] [--shard <i>/<n>] [--jobs <n>]
                                 [--list]

Runs every selected mutant, then lists all survivors; exits 1 if any.
  --only <substring>  only mutants whose name contains it (repeatable)
  --file <name>       only mutants of this target file, e.g. query.dart
                      (repeatable)
  --changed           only mutants whose target file changed since the branch
                      left main (on main: since the last tag); tool/check.sh
                      --quick uses it, CI and releases run every mutant
  --shard <i>/<n>     only the i-th (1-based) of n shards of the selected
                      mutants, balanced by estimated cost; the n shards
                      together run each selected mutant exactly once
                      (repeatable with the same n: a bigger machine takes
                      several shards in one run)
  --jobs <n>          run n mutants at a time, each in its own temporary
                      workspace (default: cores / 3, at least 1)
  --list              print the mutants that would run, one per line, and
                      exit
''';

/// Mutant target names (`query.dart`, `../wire.dart`) of the library files
/// changed since the branch left main, or since the last tag on main,
/// including uncommitted edits.
List<String> _changedTargets() {
  String git(List<String> args) {
    final result = Process.runSync('git', args);
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')}: ${result.stderr}');
    }
    return (result.stdout as String).trim();
  }

  final head = git(['rev-parse', 'HEAD']);
  final main = git(['rev-parse', 'main']);
  final base = head == main
      ? git(['describe', '--tags', '--abbrev=0'])
      : git(['merge-base', 'HEAD', 'main']);
  final names = git(['diff', '--name-only', base]).split('\n');
  return [
    for (final name in names)
      if (name == 'packages/rill/lib/wire.dart')
        '../wire.dart'
      else if (RegExp(r'^packages/rill(_flutter)?/lib/.*\.dart$')
          .hasMatch(name))
        name.split('/').last,
  ];
}

typedef _Options = ({
  bool Function(Mutation) selected,
  (Set<int>, int)? shard,
  int jobs,
  bool list,
});

/// A mutant runs when it matches some `--only` (if any) and some `--file`
/// (if any), and falls in the `--shard`.
_Options _options(List<String> args) {
  final only = <String>[], files = <String>[];
  var changed = false, list = false;
  final shards = <int>{};
  int? shardCount;
  var jobs = Platform.numberOfProcessors ~/ 3;
  Never usage() {
    stderr.write(_usage);
    exit(64);
  }

  for (var i = 0; i < args.length; i++) {
    final flag = args[i];
    if (flag == '--help' || flag == '-h') {
      stdout.write(_usage);
      exit(0);
    }
    if (flag == '--changed') {
      files.addAll(_changedTargets());
      changed = true;
      continue;
    }
    if (flag == '--list') {
      list = true;
      continue;
    }
    if (i + 1 == args.length) usage();
    final value = args[++i];
    switch (flag) {
      case '--only':
        only.add(value);
      case '--file':
        files.add(value);
      case '--shard':
        final match = RegExp(r'^(\d+)/(\d+)$').firstMatch(value);
        if (match == null) usage();
        final (index, count) = (int.parse(match[1]!), int.parse(match[2]!));
        if (index < 1 || index > count) usage();
        if (shardCount != null && shardCount != count) usage();
        shardCount = count;
        shards.add(index);
      case '--jobs':
        jobs = int.tryParse(value) ?? usage();
        if (jobs < 1) usage();
      default:
        usage();
    }
  }
  if (changed && files.isEmpty) {
    stdout.writeln('No mutated library file changed; no mutant to run.');
    exit(0);
  }
  return (
    selected: (mutation) =>
        (only.isEmpty || only.any(mutation.$1.contains)) &&
        (files.isEmpty || files.contains(mutation.$2)),
    shard: shardCount == null ? null : (shards, shardCount),
    jobs: jobs < 1 ? 1 : jobs,
    list: list,
  );
}

enum _Kind {
  // Estimated seconds per run, measured on an M-series Mac (2026-11-21):
  // the whole core suite, one process test, one widget test file. The core
  // suite takes 5-6 s, so 60 s only cuts hangs; a process test spawns and
  // compiles VMs under its own limits of up to 60 s. Widget tests run under
  // fake time and have no limit.
  core(6, Duration(seconds: 60)),
  process(3, Duration(seconds: 180)),
  flutter(3, null);

  const _Kind(this.cost, this.limit);
  final int cost;
  final Duration? limit;
}

/// One mutant and the test that judges it: the core suite, a process test
/// by plain name, or a widget test file.
typedef _Task = ({_Kind kind, Mutation mutation, String? test});

/// The [indices] (1-based) of [count] shards of [tasks]: in declaration
/// order, each task goes to the shard with the least estimated cost so far
/// (the lowest shard on a tie). Deterministic for a given selection, and
/// every task lands in exactly one shard.
List<_Task> _shard(List<_Task> tasks, Set<int> indices, int count) {
  final load = List.filled(count, 0);
  return [
    for (final task in tasks)
      if (indices.contains(_assign(load, task.kind.cost) + 1)) task,
  ];
}

int _assign(List<int> load, int cost) {
  var least = 0;
  for (var i = 1; i < load.length; i++) {
    if (load[i] < load[least]) least = i;
  }
  load[least] += cost;
  return least;
}

/// A temporary pub workspace holding copies of the mutated packages; one
/// per job, so concurrent mutants never see each other's edits.
class _Workspace {
  _Workspace(this.root);

  final Directory root;
  Directory get core => Directory('${root.path}/packages/rill');
  Directory get binding => Directory('${root.path}/packages/rill_flutter');

  /// The package a mutant edits: Flutter mutants of the runtime edit core.
  Directory target(_Task task) =>
      task.kind == _Kind.flutter && task.mutation.$2 != runtime
      ? binding
      : core;

  static Future<_Workspace> create() async {
    final workspace = _Workspace(
      Directory.systemTemp.createTempSync('rill-mutation-'),
    );
    final work = workspace.root;
    for (final member in [
      '',
      'conformance/',
      'bench/',
      'packages/rill/',
      'packages/rill_flutter/',
      'packages/rill_test/',
      'packages/rill_lint/',
      'examples/feed_store/',
    ]) {
      Directory('${work.path}/$member').createSync(recursive: true);
      File('${member}pubspec.yaml')
          .copySync('${work.path}/${member}pubspec.yaml');
    }
    File('pubspec.lock').copySync('${work.path}/pubspec.lock');
    for (final member in ['rill', 'rill_flutter']) {
      for (final dir in ['lib', 'test']) {
        _copyDirectory(
          Directory('packages/$member/$dir'),
          Directory('${work.path}/packages/$member/$dir'),
        );
      }
    }
    final setup = await _flutter(work, [
      'pub',
      'get',
      '--offline',
      '--enforce-lockfile',
    ]);
    if (setup.exitCode != 0) throw StateError('${setup.stdout}${setup.stderr}');
    return workspace;
  }

  Future<ProcessResult> coreTests() => _dart(core, [
    'test',
    '--reporter',
    'json',
    // `dart test` runs one suite per core it sees. In a container that is
    // the host's count, not the CPU the job is guaranteed, so CI caps it to
    // keep the 5 s timeout below from firing on a busy shared host.
    if (Platform.environment['RILL_TEST_CONCURRENCY'] case final n?)
      '--concurrency=$n',
    '--exclude-tags',
    'process',
    // A mutant that hangs a wait would otherwise sit out the default 30 s
    // per test; the whole suite runs in seconds, so 5 s only cuts hangs.
    '--timeout',
    '5s',
    // One failing test kills the mutant: a mutant that hangs every query
    // test would otherwise wait out 5 s per test in turn.
    '--fail-fast',
  ], _Kind.core.limit!);

  Future<ProcessResult> widgetTests([String? file]) => _flutter(binding, [
    'test',
    '--no-pub',
    '--reporter',
    'json',
    '--concurrency=1',
    if (file != null) 'test/$file',
  ]);

  Future<ProcessResult> run(_Task task) => switch (task.kind) {
    _Kind.core => coreTests(),
    _Kind.process => _dart(core, [
      'test',
      '--reporter',
      'json',
      '--plain-name',
      task.test!,
      'test/process/query_process_test.dart',
    ], _Kind.process.limit!),
    _Kind.flutter => widgetTests(task.test),
  };

  /// Applies the mutant, runs its test, and restores the source.
  Future<(bool, String)> mutate(_Task task) async {
    final (name, file, original, altered) = task.mutation;
    final source = File('${target(task).path}/lib/src/$file');
    final contents = source.readAsStringSync();
    source.writeAsStringSync(contents.replaceFirst(original, altered));
    try {
      return _killed(name, task.kind.limit, await run(task));
    } finally {
      source.writeAsStringSync(contents);
    }
  }
}

Future<void> main(List<String> args) async {
  final options = _options(args);
  // Every mutant is validated against the checkout, selected or not: a
  // stale one fails at once.
  final checkout = _Workspace(Directory('.'));
  _validateMutations(checkout.core, mutations);
  _validateMutations(checkout.core, [for (final (m, _) in processMutations) m]);
  for (final (mutation, test) in flutterMutations) {
    final task = (kind: _Kind.flutter, mutation: mutation, test: test);
    _validateMutations(checkout.target(task), [mutation]);
  }
  final selected = <_Task>[
    for (final mutation in mutations)
      if (options.selected(mutation))
        (kind: _Kind.core, mutation: mutation, test: null),
    for (final (mutation, test) in processMutations)
      if (options.selected(mutation))
        (kind: _Kind.process, mutation: mutation, test: test),
    for (final (mutation, test) in flutterMutations)
      if (options.selected(mutation))
        (kind: _Kind.flutter, mutation: mutation, test: test),
  ];
  if (selected.isEmpty) {
    stderr.writeln('No mutant matches the filters.');
    exit(64);
  }
  final tasks = switch (options.shard) {
    null => selected,
    (final indices, final count) => _shard(selected, indices, count),
  };
  if (options.list) {
    for (final task in tasks) {
      stdout.writeln('${task.kind.name}\t${task.mutation.$1}');
    }
    return;
  }
  if (options.shard case (final indices, final count)) {
    stdout.writeln(
      'Shard ${(indices.toList()..sort()).join(',')}/$count: '
      '${tasks.length} of ${selected.length} mutants.',
    );
    if (tasks.isEmpty) return;
  }
  final jobs = options.jobs < tasks.length ? options.jobs : tasks.length;
  final survivors = <String>{};
  final watch = Stopwatch()..start();
  // Mutants are compiled outside the checkout.
  final workspaces = await Future.wait([
    for (var i = 0; i < jobs; i++) _Workspace.create(),
  ]);
  try {
    final baselines = [
      if (tasks.any((task) => task.kind == _Kind.core))
        (_Workspace w) => w.coreTests(),
      if (tasks.any((task) => task.kind == _Kind.flutter))
        (_Workspace w) => w.widgetTests(),
    ];
    var b = 0;
    for (final baseline in await Future.wait([
      for (final run in baselines) run(workspaces[b++ % jobs]),
    ])) {
      if (baseline.exitCode != 0) {
        throw StateError(
          'Baseline test run failed\n${baseline.stdout}${baseline.stderr}',
        );
      }
    }
    stdout.writeln(
      'Running ${tasks.length} mutants, $jobs at a time '
      '(${Platform.numberOfProcessors} cores).',
    );
    final queue = tasks.iterator;
    Future<void> worker(_Workspace workspace) async {
      while (queue.moveNext()) {
        final task = queue.current;
        final (killed, line) = await workspace.mutate(task);
        stdout.writeln(line);
        if (!killed) survivors.add(task.mutation.$1);
      }
    }

    await Future.wait(workspaces.map(worker));
  } finally {
    for (final workspace in workspaces) {
      workspace.root.deleteSync(recursive: true);
    }
  }
  for (final (label, kinds) in [
    ('core', {_Kind.core, _Kind.process}),
    ('Flutter', {_Kind.flutter}),
  ]) {
    final ran = [
      for (final t in tasks)
        if (kinds.contains(t.kind)) t,
    ];
    if (ran.isEmpty) continue;
    final dead = ran.where((t) => !survivors.contains(t.mutation.$1)).length;
    stdout.writeln('$dead/${ran.length} $label mutants killed');
  }
  stdout.writeln('Took ${watch.elapsed.inSeconds}s with $jobs jobs.');
  if (survivors.isNotEmpty) {
    stdout.writeln('${survivors.length}/${tasks.length} mutants survived:');
    // In declaration order, however the jobs interleaved.
    for (final task in tasks) {
      if (survivors.contains(task.mutation.$1)) {
        stdout.writeln('  ${task.mutation.$1}');
      }
    }
    exit(1);
  }
}
