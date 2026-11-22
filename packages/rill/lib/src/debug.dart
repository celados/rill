part of 'runtime.dart';

// Diagnostics live here so the graph code only carries assert-guarded hooks.
// Every entry point below is reached from an assert, so release builds neither
// record nor register anything, and the compiler drops the bodies.

// ── Names and creation sites ─────────────────────────────────────────────────

/// A source position: the first stack frame outside rill's own libraries.
final class RillSite {
  const RillSite._(this.uri, this.line, this.column);

  /// The frame's library URI, such as `package:app/store.dart`.
  final String uri;
  final int line;
  final int? column;

  /// [uri], relative to the working directory when it is a file under it.
  String get file {
    final base = Uri.base.toString();
    return uri.startsWith(base) ? uri.substring(base.length) : uri;
  }

  Map<String, Object?> toJson() => {
    'uri': uri,
    'file': file,
    'line': line,
    if (column != null) 'column': column,
  };

  @override
  String toString() => '$file:$line';
}

const _ownLibraries = [
  'package:rill/',
  'package:rill_flutter/',
  'package:rill_test/',
];
final _vmFrame = RegExp(r'\(([a-zA-Z][\w+.-]*:[^\s()]*?):(\d+)(?::(\d+))?\)$');
final _webFrame = RegExp(r'^(\S+) (\d+)(?::(\d+))?\s');

RillSite? _frameSite(String line) {
  final frame = line.trimRight();
  if (_vmFrame.firstMatch(frame) case final match?) {
    return RillSite._(
      match[1]!,
      int.parse(match[2]!),
      match[3] == null ? null : int.parse(match[3]!),
    );
  }
  if (_webFrame.firstMatch(frame) case final match?) {
    var uri = match[1]!;
    if (uri.startsWith('packages/')) {
      uri = 'package:${uri.substring('packages/'.length)}';
    }
    return RillSite._(
      uri,
      int.parse(match[2]!),
      match[3] == null ? null : int.parse(match[3]!),
    );
  }
  return null;
}

/// The first frame outside rill and the SDK. Flutter's own frames are used
/// only when nothing else is on the stack, such as a framework callback.
RillSite? _firstForeignSite(StackTrace trace) {
  RillSite? framework;
  for (final line in trace.toString().split('\n')) {
    final site = _frameSite(line);
    if (site == null) continue;
    final uri = site.uri;
    if (uri.startsWith('dart:') ||
        uri.startsWith('org-dartlang-') ||
        _ownLibraries.any(uri.startsWith)) {
      continue;
    }
    if (uri.startsWith('package:flutter/') ||
        uri.startsWith('package:flutter_test/')) {
      framework ??= site;
      continue;
    }
    return site;
  }
  return framework;
}

final _creationTraces = Expando<StackTrace>('rill.creation');
final _sites = Expando<Object>('rill.site');
final _noSite = Object();
final _ids = Expando<int>('rill.id');
int _nextId = 0;

// Internal nodes that belong to a public object, such as the busy signal of a
// Slot or the question node of an AsyncComputed, and the part they play.
final _owners = Expando<Object>('rill.owner');

/// The Scope an effect was registered with. Kept apart from [_owners],
/// which renames what it owns after the owner (`scope.busy`).
final _effectOwners = Expando<Scope>('rill.effectOwner');

bool _debugEffectOwner(_Effect<Object?> node, Scope? owner) {
  if (owner != null) _effectOwners[node] = owner;
  return true;
}

final _ownedParts = Expando<String>('rill.owner.part');
final _taskSlots = Expando<Slot>('rill.task.slot');

int _idOf(Object node) => _ids[node] ??= ++_nextId;

StackTrace? _traceOf(Object node) => _creationTraces[node];

RillSite? _siteOf(Object node) {
  final cached = _sites[node];
  if (cached != null)
    return identical(cached, _noSite) ? null : cached as RillSite;
  final trace = _traceOf(node);
  final site = trace == null ? null : _firstForeignSite(trace);
  if (trace != null) _sites[node] = site ?? _noSite;
  return site;
}

String _kindOf(Object node) => switch (node) {
  Signal() => 'signal',
  AsyncComputed() => 'asyncComputed',
  _QueryQuestion() => 'queryQuestion',
  Computed() => 'computed',
  _Constant() => 'constant',
  _Effect() => 'effect',
  Subscriber() => 'observer',
  Scope() => 'scope',
  Slot() => 'slot',
  Task() => 'task',
  Events() => 'events',
  _ => node.runtimeType.toString(),
};

String? _nameOf(Object node) => switch (node) {
  Readable(:final name) => name,
  _Effect(:final _name) => _name,
  Scope(:final _name) => _name,
  Slot(:final _busy) => _busy.name,
  Events(:final name) => name,
  _ => null,
};

/// A short label: the name, otherwise `kind@file:line`.
String _label(Object node) {
  final owner = node is Task ? _taskSlots[node] : _owners[node];
  if (owner != null) {
    final part =
        _ownedParts[node] ??
        switch (node) {
          Task() => 'task',
          _ => 'busy',
        };
    return '${_label(owner)}.$part';
  }
  if (node case Subscriber(:final debugReader?)) {
    return node.debugLabel ?? '$debugReader';
  }
  final name = _nameOf(node);
  if (name != null) return name;
  final site = _siteOf(node);
  final kind = _kindOf(node);
  return site == null ? '<unnamed $kind>' : '$kind@$site';
}

/// The label with the kind and creation site, for error messages.
String _describe(Object node) {
  if (node case _QueryQuestion(:final _query)) return _describe(_query);
  final label = _label(node);
  final site = node is Subscriber && node.debugReader != null
      ? null
      : _siteOf(node);
  if (site == null || label.endsWith('@$site')) return label;
  return '$label (${_kindOf(node)} at $site)';
}

String _computationLabel() {
  final sub = _activeSub;
  return sub == null ? 'a computation' : _describe(sub);
}

final class _WeakRegistry<T extends Object> {
  final _entries = <WeakReference<T>>[];
  int _compactAt = 256;

  void add(T value) {
    _entries.add(WeakReference(value));
    if (_entries.length < _compactAt) return;
    _entries.removeWhere((entry) => entry.target == null);
    _compactAt = _entries.length * 2 < 256 ? 256 : _entries.length * 2;
  }

  Iterable<T> get live sync* {
    for (final entry in _entries) {
      final target = entry.target;
      if (target != null) yield target;
    }
  }

  void clear() => _entries.clear();
}

final _nodes = _WeakRegistry<ReactiveNode>();
final _scopes = _WeakRegistry<Scope>();
final _slots = _WeakRegistry<Slot>();

bool _debugCreated(Object node) {
  final trace = StackTrace.current;
  switch (node) {
    case ReactiveNode():
      _creationTraces[node] = trace;
      _nodes.add(node);
    case Scope():
      _creationTraces[node] = trace;
      _scopes.add(node);
    case Slot():
      _creationTraces[node] = trace;
      _slots.add(node);
    case Events():
      _creationTraces[node] = trace;
  }
  _installExtensions();
  return true;
}

bool _debugOwn(Object node, Object owner, [String? part]) {
  _owners[node] = owner;
  if (part != null) _ownedParts[node] = part;
  return true;
}

bool _debugTask(Task task, Slot slot) {
  _creationTraces[task] = StackTrace.current;
  _taskSlots[task] = slot;
  return true;
}

// ── Warnings without a hook ──────────────────────────────────────────────────

final _printedWarnings = <String>{};

/// Reports a debug warning. A [diagnosticHook] receives the code and label;
/// otherwise the warning prints once per code and site in the current zone.
/// [atCreation] keys the warning on the node's creation site instead of the
/// caller, for warnings raised while rill evaluates the node.
bool _warn(
  String code,
  Object node,
  String message, {
  bool atCreation = false,
  StackTrace? trace,
}) {
  final hook = diagnosticHook;
  if (hook != null) {
    final label = _label(node);
    // A hook raised during an evaluation must not abort it.
    if (atCreation) {
      _invoke(() => hook(code, label));
    } else {
      hook(code, label);
    }
    return true;
  }
  final site = atCreation
      ? _siteOf(node)
      : _firstForeignSite(trace ?? StackTrace.current);
  if (!_printedWarnings.add('$code ${site ?? _label(node)}')) return true;
  final at = site == null || atCreation ? '' : ' at $site';
  Zone.current.print(
    '$code$at: ${_describe(node)} $message '
    '(rill docs/diagnostics/$code.md)',
  );
  return true;
}

// ── Causal records ───────────────────────────────────────────────────────────

/// Recent writes and derived changes, keyed by the global revision stamp.
/// Every installed write and every changed computed draws a unique stamp from
/// the same clock, so the stamp a reader consumed identifies its cause.
final _changes = <int, _DebugChange>{};
const _changeCapacity = 4096;
final _runs = ListQueue<_DebugRun>();
int _runCapacity = 128;
int _runSeq = 0;
final _runCounts = Expando<int>('rill.runs');
final _lastRun = Expando<_DebugRun>('rill.lastRun');
final _snapshots = Expando<_DebugSnapshot>('rill.snapshot');
final _applying = <_DebugRun?>[];
final _lastWrites = <ReactiveNode, _DebugChange>{};

final class _DebugInput {
  _DebugInput(this.node, this.from, this.to);
  final ReactiveNode node;
  final int? from;
  final int to;
}

final class _DebugChange {
  _DebugChange.write(this.node, this.stamp, this.trace, this.origin, this.by)
    : inputs = const [],
      failed = false;
  _DebugChange.derived(this.node, this.stamp, this.inputs, this.failed)
    : trace = null,
      origin = null,
      by = null;

  final ReactiveNode node;
  final int stamp;
  final StackTrace? trace;
  final String? origin;
  final _DebugRun? by;
  final List<_DebugInput> inputs;
  final bool failed;
  bool get write => trace != null;
}

final class _DebugRun {
  _DebugRun(this.node, this.kind, this.run, this.inputs, this.initial)
    : seq = ++_runSeq,
      time = DateTime.now();

  final int seq;
  final ReactiveNode node;
  final String kind;
  final int run;
  final List<_DebugInput> inputs;
  final bool initial;
  final DateTime time;
}

final class _DebugSnapshot {
  _DebugSnapshot(this.version, this.versions);
  final int version;
  final Map<ReactiveNode, int> versions;
}

void _recordChange(_DebugChange change) {
  _changes[change.stamp] = change;
  if (_changes.length > _changeCapacity) _changes.remove(_changes.keys.first);
}

void _recordRun(_DebugRun run) {
  _runs.add(run);
  _trim(_runs, _runCapacity);
}

/// A [transact] in the zone of a task that lost its right to publish: its
/// writes are as late as bare ones. The writer is found the way
/// [_debugWrote] attributes an install, so a reaction that a commit flushes
/// in that zone is not taken for the task.
bool _debugLateCommit(Iterable<Signal<Object?>> targets) {
  final task = _writerTask();
  if (task == null || !task._lapsed) return true;
  for (final target in targets) {
    _warn(
      'RILL_LATE_WRITE',
      target,
      'was committed by transact after its task became stale. The commit is '
          'installed without publication rights; stage it with task.publish.',
    );
  }
  return true;
}

bool _debugWrote(
  Signal<Object?> node, {
  Task? publisher,
  bool committed = false,
}) {
  final String? origin;
  final _DebugRun? by;
  final task = _writerTask();
  final owner = _owners[node];
  if (publisher != null) {
    origin = 'publish by ${_label(publisher)}';
  } else if (owner is AsyncComputed<Object?>) {
    origin = _ownedParts[node] == 'retry'
        ? 'retry of ${_label(owner)}'
        : 'settle of ${_label(owner)}';
  } else if (owner is Slot) {
    origin = 'bookkeeping of ${_label(owner)}';
  } else if (task != null) {
    origin = '${committed ? 'transact' : 'bare write'} in ${_label(task)}';
  } else {
    origin = null;
  }
  by = _applying.isEmpty ? null : _applying.last;
  final change = _DebugChange.write(
    node,
    node._revision,
    StackTrace.current,
    by == null ? origin : (origin ?? 'apply of ${_label(by.node)}'),
    by,
  );
  _recordChange(change);
  _lastWrites[node] = change;
  return true;
}

String _loopWrites() {
  if (_lastWrites.isEmpty) return '<none>';
  return _lastWrites.values
      .map((change) {
        final site = _firstForeignSite(change.trace!);
        final at = site == null ? '' : ' at $site';
        return '${_describe(change.node)}$at';
      })
      .join(', ');
}

// A launch tracks into the question node: a run of the query, not a
// derivation. The question's first evaluation runs no user code.
bool _isRun(_Tracking sub) =>
    sub is _Effect<Object?> || (sub is _QueryQuestion && sub._launching);

// The input versions a query's last launch tracked. Its question's pulls
// advance the edges before the next launch, so the cause of a re-ask is
// measured against the previous launch, not against the edges.
final _launchVersions = Expando<Map<ReactiveNode, int>>('rill.launch');

Map<ReactiveNode, int> _edgeVersions(_Tracking sub) {
  final versions = Map<ReactiveNode, int>.identity();
  for (var link = sub._deps; link != null; link = link.nextDep) {
    versions[link.dep] = link.version;
  }
  return versions;
}

bool _debugBegin(_Tracking sub) {
  if (sub is _QueryQuestion && !sub._launching) return true;
  if (sub is! Computed<Object?> && sub is! _Effect<Object?>) return true;
  final versions = sub is _QueryQuestion
      ? (_launchVersions[sub] ?? Map<ReactiveNode, int>.identity())
      : _edgeVersions(sub);
  _snapshots[sub] = _DebugSnapshot(
    _isRun(sub) ? (_runCounts[sub] ?? 0) : sub._version,
    versions,
  );
  return true;
}

List<_DebugInput> _changedInputs(_Tracking sub, Map<ReactiveNode, int> before) {
  final inputs = <_DebugInput>[];
  final tail = sub._depsTail;
  if (tail == null) return inputs;
  for (var link = sub._deps; link != null; link = link.nextDep) {
    final from = before[link.dep];
    if (from != link.version) {
      inputs.add(_DebugInput(link.dep, from, link.version));
    }
    if (identical(link, tail)) break;
  }
  return inputs;
}

bool _debugEnd(_Tracking sub) {
  final snapshot = _snapshots[sub];
  if (snapshot == null) return true;
  _snapshots[sub] = null;
  switch (sub) {
    case Computed<Object?>() when !_isRun(sub):
      if (sub._version == snapshot.version) return true;
      final initial = snapshot.version == 0;
      _recordChange(
        _DebugChange.derived(
          sub,
          sub._version,
          initial ? const [] : _changedInputs(sub, snapshot.versions),
          sub._failure != null,
        ),
      );
    case _Effect<Object?>() || _QueryQuestion():
      final run = _runCounts[sub] = snapshot.version + 1;
      final initial = run == 1;
      final inputs = initial
          ? <_DebugInput>[]
          : _changedInputs(sub, snapshot.versions);
      final record = _DebugRun(
        sub,
        sub is _Effect<Object?> ? 'effect' : 'query',
        run,
        inputs,
        initial,
      );
      _lastRun[sub] = record;
      _recordRun(record);
      if (sub is _QueryQuestion) _launchVersions[sub] = _edgeVersions(sub);
  }
  return true;
}

/// Records an observer that confirmed a change at a refresh boundary.
bool _debugWake(Subscriber sub, bool changed) {
  if (!changed || sub.debugReader == null) return true;
  final inputs = <_DebugInput>[];
  for (var link = sub._deps; link != null; link = link.nextDep) {
    if (link.dep._version != link.version && !link.matchesOutput) {
      inputs.add(_DebugInput(link.dep, link.version, link.dep._version));
    }
  }
  final run = _runCounts[sub] = (_runCounts[sub] ?? 0) + 1;
  _recordRun(_DebugRun(sub, 'observer', run, inputs, false));
  return true;
}

bool _debugApplyStart(_Effect<Object?> node) {
  _applying.add(_lastRun[node]);
  return true;
}

bool _debugApplyEnd() {
  if (_applying.isNotEmpty) _applying.removeLast();
  return true;
}

// ── Resolution into public records ───────────────────────────────────────────

/// Identity of a node in diagnostic output.
final class RillNodeInfo {
  RillNodeInfo._(Object node)
    : id = _idOf(node),
      kind = _kindOf(node),
      name = _nameOf(node),
      label = _label(node),
      location = node is Subscriber && node.debugReader != null
          ? null
          : _siteOf(node);

  final int id;
  final String kind;
  final String? name;
  final String label;
  final RillSite? location;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'name': name,
    'label': label,
    'location': location?.toString(),
  };

  @override
  String toString() {
    final head = label.startsWith('$kind@') ? label : '$kind $label';
    return location == null || label.endsWith('@$location')
        ? head
        : '$head ($location)';
  }
}

/// One step of a causal chain: an input that changed, and why it changed.
final class RillCause {
  RillCause._(
    this.node,
    this.revision,
    this.change, {
    this.previous,
    this.site,
    this.origin,
    this.trigger,
    this.causes = const [],
  });

  final RillNodeInfo node;

  /// The revision stamp the reader consumed.
  final int revision;

  /// The stamp the reader had consumed before, or null for a new input.
  final int? previous;

  /// `write`, `value`, `error`, `initial` or `unrecorded`.
  final String change;

  /// Where a write was made.
  final RillSite? site;

  /// The write path, such as `publish by sweep.task` or `apply of effect@…`.
  final String? origin;

  /// The effect run whose apply made this write.
  final RillWhy? trigger;

  /// The inputs that made a computed change.
  final List<RillCause> causes;

  Map<String, Object?> toJson() => {
    'node': node.toJson(),
    'revision': revision,
    'previous': previous,
    'change': change,
    if (site != null) 'site': site.toString(),
    if (origin != null) 'origin': origin,
    if (trigger != null) 'trigger': trigger!.toJson(),
    'causes': [for (final cause in causes) cause.toJson()],
  };

  void _format(StringBuffer out, String indent) {
    out
      ..write('\n$indent← ')
      ..write(node)
      ..write(switch (change) {
        'write' => ' written @$revision',
        'value' => ' changed @$revision',
        'error' => ' failed @$revision',
        'initial' => ' first evaluated @$revision',
        _ => ' @$revision (not recorded)',
      });
    if (site != null) out.write(' at $site');
    if (origin != null) out.write(' ($origin)');
    for (final cause in causes) {
      cause._format(out, '$indent  ');
    }
    final trigger = this.trigger;
    if (trigger != null) {
      out.write('\n$indent  ⤷ ${trigger._headline}');
      for (final cause in trigger.causes) {
        cause._format(out, '$indent    ');
      }
    }
  }
}

/// Why a reader ran: an effect rerun, an observer rebuild or a query re-ask.
final class RillWhy {
  RillWhy._(
    this.seq,
    this.kind,
    this.node,
    this.run,
    this.initial,
    this.causes,
    this.target,
    this.time,
  );

  /// Monotonic sequence number of this record.
  final int seq;

  /// `effect`, `observer` or `query`.
  final String kind;
  final RillNodeInfo node;

  /// The run number for this reader, starting at 1.
  final int run;

  /// True for the first run, which has no causing change.
  final bool initial;
  final List<RillCause> causes;

  /// The object to match against: the effect node, an observer's reader such
  /// as an Element, or the AsyncComputed of a query.
  final Object target;
  final DateTime time;

  String get _headline => switch (kind) {
    'observer' => '${node.label} rebuilt (#$run)',
    'query' => '$node re-asked (#$run)',
    _ => initial ? '$node ran (#$run, first run)' : '$node ran (#$run)',
  };

  Map<String, Object?> toJson() => {
    'seq': seq,
    'kind': kind,
    'node': node.toJson(),
    'run': run,
    'initial': initial,
    'time': time.toIso8601String(),
    'causes': [for (final cause in causes) cause.toJson()],
    'text': toString(),
  };

  @override
  String toString() {
    final out = StringBuffer(_headline);
    for (final cause in causes) {
      cause._format(out, '  ');
    }
    return out.toString();
  }
}

const _maxDepth = 24;

RillWhy _resolveRun(_DebugRun run, int depth) {
  final node = run.node;
  final target = switch (node) {
    _QueryQuestion(:final _query) => _query,
    Subscriber(:final debugReader?) => debugReader,
    _Effect() => node,
    _ => node,
  };
  return RillWhy._(
    run.seq,
    run.kind,
    RillNodeInfo._(node is _QueryQuestion ? node._query : node),
    run.run,
    run.initial,
    depth >= _maxDepth
        ? const []
        : [
            for (final input in run.inputs)
              _resolveCause(input.node, input.to, input.from, depth + 1),
          ],
    target,
    run.time,
  );
}

RillCause _resolveCause(ReactiveNode node, int stamp, int? from, int depth) {
  final info = RillNodeInfo._(node);
  final change = _changes[stamp];
  if (change == null || !identical(change.node, node)) {
    return RillCause._(info, stamp, 'unrecorded', previous: from);
  }
  if (change.write) {
    final by = change.by;
    return RillCause._(
      info,
      stamp,
      'write',
      previous: from,
      site: _firstForeignSite(change.trace!),
      origin: change.origin,
      trigger: by == null || depth >= _maxDepth
          ? null
          : _resolveRun(by, depth + 1),
    );
  }
  final initial = change.inputs.isEmpty && from == null;
  return RillCause._(
    info,
    stamp,
    change.failed ? 'error' : (initial ? 'initial' : 'value'),
    previous: from,
    causes: depth >= _maxDepth
        ? const []
        : [
            for (final input in change.inputs)
              _resolveCause(input.node, input.to, input.from, depth + 1),
          ],
  );
}

bool _matches(_DebugRun run, Object? target) {
  if (target == null) return true;
  final node = run.node;
  if (identical(node, target)) return true;
  if (node case _QueryQuestion(:final _query) when identical(_query, target)) {
    return true;
  }
  if (node case Subscriber(:final debugReader?)
      when identical(debugReader, target)) {
    return true;
  }
  if (node is _Effect<Object?> && target is Function && target == node._stop) {
    return true;
  }
  final named = node is _QueryQuestion ? node._query : node;
  if (target is int) return _ids[named] == target;
  if (target is String) {
    return _nameOf(named) == target || _label(named) == target;
  }
  return false;
}

/// Records a question generation change with the inputs that caused it: the
/// question refreshes outside _begin/_end.
bool _debugQuestionChanged(_QueryQuestion question, List<_DebugInput> inputs) {
  _recordChange(
    _DebugChange.derived(question, question._version, inputs, false),
  );
  return true;
}

/// The diagnostic description of a node: its name, kind and creation site in
/// debug builds, its name or `<unnamed kind>` in release builds.
String debugDescribe(Object node) => _describe(node);

// ── Snapshots and VM service extensions ──────────────────────────────────────

final _activeSections = <String, Object? Function()>{};

/// Adds a named section to `ext.rill.active`, such as the pulses of a binding.
void debugActiveSection(String name, Object? Function() snapshot) {
  assert(() {
    _activeSections[name] = snapshot;
    return true;
  }());
}

Map<String, Object?> _nodeJson(ReactiveNode node) {
  final deps = <int>[];
  for (var link = node._deps; link != null; link = link.nextDep) {
    deps.add(_idOf(link.dep));
  }
  final subs = <int>[];
  for (var link = node._subs; link != null; link = link.nextSub) {
    subs.add(_idOf(link.sub));
  }
  final flags = node._flags;
  return {
    ...RillNodeInfo._(node).toJson(),
    'version': node._version,
    if (node is Readable<Object?>) 'revision': node._revision,
    'dirty': flags & _dirty != 0,
    'pending': flags & _pending != 0,
    'disposed': node._disposed,
    if (node case Computed<Object?>(:final _failure))
      'failed': _failure != null,
    if (node case Signal<Object?>(:final _value))
      'valueType': '${_value.runtimeType}',
    if (node case Computed<Object?>(:final _value))
      'valueType': '${_value.runtimeType}',
    if (node case _Constant<Object?>(:final _value))
      'valueType': '${_value.runtimeType}',
    if (node case final AsyncComputed<Object?> query) ...{
      'state': query._value.runtimeType.toString().split('<').first,
      'questionNode': _idOf(query._question),
      'generation': query._question._value,
      'retry': query._retry._value,
      'observed': query._observed,
      'inFlight': query._current?._inFlight ?? false,
      'streaming': query._subscription != null,
      'retainMs': query._retain.inMilliseconds,
      'leased': query._lease != null,
      'waits': [
        for (
          var link = query._question._deps;
          link != null;
          link = link.nextDep
        )
          if (link is _WaitLink)
            {
              'source': _idOf(link.source),
              'consumed': link.consumed.released
                  ? 'released'
                  : const ['pending', 'answer', 'failure'][link.consumed.kind],
            },
      ],
    },
    if (_effectOwners[node] case final owner?) 'owner': _idOf(owner),
    if (node is _Effect<Object?> || node is Subscriber)
      'runs': _runCounts[node] ?? 0,
    if (_owners[node] case final owner?) 'ownedBy': _idOf(owner),
    'deps': deps,
    'subs': subs,
  };
}

Map<String, Object?> _graph({int limit = 2000}) {
  final nodes = <Map<String, Object?>>[];
  var total = 0;
  for (final node in _nodes.live) {
    total++;
    if (nodes.length < limit) nodes.add(_nodeJson(node));
  }
  return {
    'type': 'RillGraph',
    'enabled': RillDebug.enabled,
    'revisionClock': _clock,
    'count': total,
    'truncated': total > nodes.length,
    'nodes': nodes,
  };
}

Map<String, Object?> _scopeJson(Scope scope) {
  final effects = <int>[];
  var callbacks = 0;
  for (final entry in scope._cleanups) {
    switch (entry.target) {
      case _Effect<Object?> effect:
        effects.add(_idOf(effect));
      default:
        callbacks++;
    }
  }
  return {
    ...RillNodeInfo._(scope).toJson(),
    'slots': [for (final slot in scope._slots ?? const <Slot>[]) _idOf(slot)],
    'effects': effects,
    'callbacks': callbacks,
    'children': [for (final child in scope._children) _scopeJson(child)],
  };
}

// ── Refused commits ──────────────────────────────────────────────────────────

final _refusals = ListQueue<RillRefusal>();

/// Records which declared condition refused a commit: the task's right to
/// publish, or an [Unchanged] that no longer holds. A staged target written
/// while staging ran (only a write that bypasses the staging guard can do
/// that) is recorded as an `unchanged` on that target: the commit's own
/// condition that what it staged against did not move.
bool _debugRefused(Task? task, Object refusal) {
  final publisher = task ?? (refusal is Task ? refusal : null);
  final slot = publisher == null ? null : _taskSlots[publisher];
  final record = RillRefusal._(
    ++_runSeq,
    publisher == null ? null : RillNodeInfo._(publisher),
    slot == null ? null : RillNodeInfo._(slot),
    refusal is Task ? 'task' : 'unchanged',
    switch (refusal) {
      Task() => null,
      Unchanged(:final _source) => RillNodeInfo._(_source),
      _ => RillNodeInfo._(refusal),
    },
    refusal is Task
        ? refusal._reason?.name ??
              (refusal._ended
                  ? 'ended'
                  : refusal._owner._alive
                  ? null
                  : StaleReason.ownerDisposed.name)
        : null,
  );
  _refusals.add(record);
  _trim(_refusals, _runCapacity);
  return true;
}

void _trim(ListQueue<Object> records, int capacity) {
  while (records.length > capacity) {
    records.removeFirst();
  }
}

/// A commit ([transact] or [Task.publish]) that returned false, and the
/// declared condition that refused it. A refusal is a normal result, not an
/// error; this answers "why did this result not land".
final class RillRefusal {
  RillRefusal._(
    this.seq,
    this.task,
    this.slot,
    this.condition,
    this.source,
    this.reason,
  );

  /// Sequence number, drawn from the same counter as [RillWhy.seq].
  final int seq;

  /// The publishing task, or null for a [transact].
  final RillNodeInfo? task;

  /// The Slot that ran [task], or null for a [transact].
  final RillNodeInfo? slot;

  /// `task` (the task lost its right to publish) or `unchanged` (the
  /// [Unchanged] on [source] no longer holds).
  final String condition;

  /// The node the condition is about, for `unchanged`.
  final RillNodeInfo? source;

  /// For `task`: `superseded`, `ownerDisposed` or `ended`.
  final String? reason;

  Map<String, Object?> toJson() => {
    'seq': seq,
    'task': task?.toJson(),
    'slot': slot?.toJson(),
    'condition': condition,
    'source': source?.toJson(),
    'reason': reason,
  };

  @override
  String toString() {
    final who = task == null ? 'transact' : 'publish by ${task!.label}';
    return condition == 'task'
        ? '$who refused: the task is ${reason ?? 'not alive'}'
        : '$who refused: Unchanged(${source!.label}) no longer holds';
  }
}

bool _refusalMatches(RillRefusal refusal, Object? target) {
  if (target == null) return true;
  final id = switch (target) {
    int() => target,
    String() => null,
    _ => _idOf(target),
  };
  for (final node in [refusal.task, refusal.slot, refusal.source]) {
    if (node == null) continue;
    if (id != null
        ? node.id == id
        : (node.name == target || node.label == target)) {
      return true;
    }
  }
  return false;
}

Map<String, Object?> _active() {
  final effects = [
    for (final node in _nodes.live)
      if (node is _Effect<Object?> && !node._disposed)
        {
          ...RillNodeInfo._(node).toJson(),
          'runs': _runCounts[node] ?? 0,
          'deps': [
            for (var link = node._deps; link != null; link = link.nextDep)
              _idOf(link.dep),
          ],
          if (_effectOwners[node] case final owner?) 'owner': _idOf(owner),
        },
  ];
  final tasks = [
    for (final slot in _slots.live)
      for (final run in slot._tasks)
        {
          ...RillNodeInfo._(run.task).toJson(),
          'slot': RillNodeInfo._(slot).toJson(),
          'policy': slot._policy.name,
          'key': run.key?.toString(),
          'queued': slot._waiting.contains(run),
          'stale': run.task._reason?.name,
        },
  ];
  final scopes = [
    for (final scope in _scopes.live)
      if (!scope._disposed && scope._parent == null) _scopeJson(scope),
  ];
  return {
    'type': 'RillActive',
    'enabled': RillDebug.enabled,
    'counts': {
      'tasks': _activeTaskCount,
      'pulses': activePulseCount,
      'bindingTimers': activeBindingTimerCount,
      'effects': effects.length,
    },
    'effects': effects,
    'tasks': tasks,
    'scopes': scopes,
    for (final MapEntry(:key, :value) in _activeSections.entries) key: value(),
  };
}

Map<String, Object?> _why({Object? target, int? limit}) {
  List<T> newest<T>(List<T> records) => limit == null || limit >= records.length
      ? records
      : records.sublist(records.length - limit);
  final shown = newest(RillDebug.why(target));
  return {
    'type': 'RillWhy',
    'enabled': RillDebug.enabled,
    'capacity': _runCapacity,
    'records': [for (final record in shown) record.toJson()],
    'refusals': [
      for (final refusal in newest(RillDebug.refusals(target)))
        refusal.toJson(),
    ],
  };
}

bool _extensionsInstalled = false;

void _installExtensions() {
  if (_extensionsInstalled) return;
  _extensionsInstalled = true;
  void register(
    String method,
    Map<String, Object?> Function(Map<String, String> params) body,
  ) {
    try {
      developer.registerExtension(method, (_, params) async {
        try {
          return developer.ServiceExtensionResponse.result(
            jsonEncode(body(params)),
          );
        } on Object catch (error, stack) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError,
            '$error\n$stack',
          );
        }
      });
    } on ArgumentError {
      // Another copy of the library already serves this isolate.
    }
  }

  Object? target(String? value) =>
      value == null ? null : (int.tryParse(value) ?? value);

  Zone.root.run(() {
    register(
      'ext.rill.graph',
      (params) => _graph(limit: int.tryParse(params['limit'] ?? '') ?? 2000),
    );
    register(
      'ext.rill.why',
      (params) => _why(
        target: target(params['target']),
        limit: int.tryParse(params['limit'] ?? ''),
      ),
    );
    register('ext.rill.active', (_) => _active());
  });
}

// ── Public entry point (package:rill/debug.dart) ─────────────────────────────

/// Debug-only introspection. Every method returns empty results in release
/// builds, where nothing is recorded.
abstract final class RillDebug {
  /// Whether asserts are enabled, so rill records names, sites and causes.
  static bool get enabled {
    var on = false;
    assert(on = true);
    return on;
  }

  /// How many reader runs `why` retains, and how many refused commits
  /// `refusals` retains.
  static int get capacity => _runCapacity;
  static set capacity(int value) {
    if (value < 1) throw ArgumentError.value(value, 'capacity');
    _runCapacity = value;
    _trim(_runs, value);
    _trim(_refusals, value);
  }

  /// The retained reader runs, oldest first. [target] narrows them to one
  /// reader: an effect disposer, a Flutter Element or painter, an
  /// AsyncComputed, a node id or a name.
  static List<RillWhy> why([Object? target]) => [
    for (final run in _runs)
      if (_matches(run, target)) _resolveRun(run, 0),
  ];

  /// The newest run of [target], if one is retained.
  static RillWhy? lastWhy(Object target) {
    for (final run in _runs.toList().reversed) {
      if (_matches(run, target)) return _resolveRun(run, 0);
    }
    return null;
  }

  /// The retained refused commits, oldest first (as many as [capacity]).
  /// [target] narrows them to a task, a Slot (or its name, such as
  /// `'sweep'`), a task label (`'sweep.task'`), a condition's source node, a
  /// node id or a name.
  static List<RillRefusal> refusals([Object? target]) => [
    for (final refusal in _refusals)
      if (_refusalMatches(refusal, target)) refusal,
  ];

  /// Sequence number of the newest retained run, or 0.
  static int get lastSeq => _runs.isEmpty ? 0 : _runs.last.seq;

  /// Forgets retained runs, changes and which warnings already printed.
  /// Names and sites are kept.
  static void clear() {
    _runs.clear();
    _refusals.clear();
    _changes.clear();
    _printedWarnings.clear();
  }

  /// Identity, name and creation site of a node, scope, slot or task.
  static RillNodeInfo? describe(Object node) =>
      enabled &&
          (node is ReactiveNode ||
              node is Scope ||
              node is Slot ||
              node is Task)
      ? RillNodeInfo._(node)
      : null;

  /// The payload of `ext.rill.graph`.
  static Map<String, Object?> graph({int limit = 2000}) => _graph(limit: limit);

  /// The payload of `ext.rill.active`.
  static Map<String, Object?> active() => _active();

  /// The payload of `ext.rill.why`.
  static Map<String, Object?> whyJson({Object? target, int? limit}) =>
      _why(target: target, limit: limit);
}
