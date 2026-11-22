// Adapted from alien-signals src/system.ts at 8734d38.
// Copyright (c) 2024-present Johnson Chu. MIT License, see ../../LICENSE.
part of 'runtime.dart';

const _mutable = 1;
const _watching = 2;
const _recursedCheck = 4;
const _recursed = 8;
const _dirty = 16;
const _pending = 32;
// A lost edge or aborted evaluation cannot be checked by cached versions.
const _mustRefresh = 64;

final class _Link {
  _Link(this.dep, this.sub, this.prevDep, this.nextDep)
    : version = dep._version,
      cycle = sub._trackingCycle;

  final ReactiveNode dep;
  final _Tracking sub;
  _Link? prevDep;
  _Link? nextDep;
  _Link? prevSub;
  _Link? nextSub;
  int version;
  int cycle;
  bool attached = false;

  /// Whether the dependency's latest change produced the output this reader
  /// consumed (only [_ValueLink]s record it).
  bool get matchesOutput => false;
}

/// The link of a [Subscriber] that compares consumed values. Only bindings
/// create them, so ordinary links stay small: on large graphs the extra
/// fields cost more than the comparison.
final class _ValueLink extends _Link {
  _ValueLink(super.dep, super.sub, super.prevDep, super.nextDep) {
    captureOutput();
  }

  bool hasConsumedOutput = false;
  Object? consumedOutput;
  int equivalentRevision = -1;

  @override
  bool get matchesOutput =>
      equivalentRevision ==
      (dep is Signal<Object?>
          ? (dep as Signal<Object?>)._revision
          : dep._version);

  void captureOutput() {
    final input = dep;
    hasConsumedOutput = input is! Computed<Object?> || input._failure == null;
    consumedOutput = input._output;
    equivalentRevision = -1;
  }
}

// Out of line: _link is inlined into every tracked read, and recursive cold
// reads nest those frames.
@pragma('vm:never-inline')
void _recapture(_Link link) {
  if (link is _ValueLink) link.captureOutput();
}

/// Live subscribers that compare consumed values. While none exist, no
/// [_ValueLink] exists either, and writes skip the equivalence pass.
int _comparingSubscribers = 0;

@pragma('vm:prefer-inline')
void _link(ReactiveNode dep, _Tracking sub) {
  if (sub._disposed) return;
  final prevDep = sub._depsTail;
  if (prevDep != null && identical(prevDep.dep, dep)) return;
  final nextDep = prevDep == null ? sub._deps : prevDep.nextDep;
  if (nextDep != null && identical(nextDep.dep, dep)) {
    nextDep.version = dep._version;
    nextDep.cycle = sub._trackingCycle;
    if (_comparingSubscribers != 0) _recapture(nextDep);
    sub._depsTail = nextDep;
    // The input may have started sampling since this edge was made, while
    // the reader was cold and so not on its subscriber list.
    if (dep._maySample) _markReused(dep, sub);
    return;
  }
  _insertLink(dep, sub, prevDep, nextDep);
}

@pragma('vm:never-inline')
void _markReused(ReactiveNode dep, _Tracking sub) {
  if (sub is Computed<Object?> && !sub._hasSampledInput) {
    _markSampledInput(sub);
  }
}

@pragma('vm:never-inline')
void _insertLink(
  ReactiveNode dep,
  _Tracking sub,
  _Link? prevDep,
  _Link? nextDep,
) {
  final prevSub = dep._subsTail;
  if (prevSub != null &&
      prevSub.cycle == sub._trackingCycle &&
      identical(prevSub.sub, sub)) {
    return;
  }
  final link =
      _comparingSubscribers != 0 &&
          sub is Subscriber &&
          sub._compareConsumedValues
      ? _ValueLink(dep, sub, prevDep, nextDep)
      : _Link(dep, sub, prevDep, nextDep);
  sub._depsTail = link;
  nextDep?.prevDep = link;
  if (prevDep == null) {
    sub._deps = link;
  } else {
    prevDep.nextDep = link;
  }
  if (sub is Computed<Object?> && dep._maySample && !sub._hasSampledInput) {
    _markSampledInput(sub);
  }
  if (sub._live) _attach(link);
  bindingGraphChanged?.call();
}

_Link? _unlink(_Link link) {
  final sub = link.sub;
  final next = link.nextDep;
  final previous = link.prevDep;
  if (next == null) {
    sub._depsTail = previous;
  } else {
    next.prevDep = previous;
  }
  if (previous == null) {
    sub._deps = next;
  } else {
    previous.nextDep = next;
  }
  if (link.attached && _detachReverse(link)) link.dep._unwatched();
  bindingGraphChanged?.call();
  return next;
}

@pragma('vm:prefer-inline')
bool _attachReverse(_Link link) {
  final dep = link.dep;
  final previous = dep._subsTail;
  link.attached = true;
  link.prevSub = previous;
  dep._subsTail = link;
  if (previous == null) {
    dep._subs = link;
    return true;
  }
  previous.nextSub = link;
  return false;
}

void _attach(_Link link) {
  if (_attachReverse(link)) link.dep._watched();
}

bool _detachReverse(_Link link) {
  final dep = link.dep;
  final next = link.nextSub;
  final previous = link.prevSub;
  if (next == null) {
    dep._subsTail = previous;
  } else {
    next.prevSub = previous;
  }
  if (previous == null) {
    dep._subs = next;
  } else {
    previous.nextSub = next;
  }
  link.attached = false;
  link.prevSub = null;
  link.nextSub = null;
  return dep._subs == null;
}

// Walk the first/last-subscriber transitions without recursing down a chain.
void _setLive(Computed<Object?> root, bool live) {
  List<_Link>? branches;
  var link = root._deps;
  if (!live) _cool(root);
  while (link != null) {
    final dep = link.dep;
    final next = link.nextDep;
    final transition = live
        ? !link.attached && _attachReverse(link)
        : link.attached && _detachReverse(link);
    if (transition) {
      if (dep is Computed<Object?>) {
        if (!live) _cool(dep);
        final upstream = dep._deps;
        if (upstream != null) {
          if (next != null) (branches ??= []).add(next);
          link = upstream;
          continue;
        }
      } else if (live) {
        dep._watched();
      } else {
        dep._unwatched();
      }
    }
    link =
        next ??
        (branches != null && branches.isNotEmpty
            ? branches.removeLast()
            : null);
  }
}

void _cool(Computed<Object?> node) {
  node._validated = -1;
  node._flags &= ~(_dirty | _pending | _recursed);
}

final class _Frame {
  _Frame(this.link, this.previous);
  final _Link link;
  final _Frame? previous;
}

@pragma('vm:align-loops')
void _propagate(_Link first, bool innerWrite) {
  var link = first;
  var next = link.nextSub;
  _Frame? stack;
  top:
  while (true) {
    final sub = link.sub;
    var flags = sub._flags;
    if ((flags & (_recursedCheck | _recursed | _dirty | _pending)) == 0) {
      sub._flags = flags | _pending | (innerWrite ? _recursed : 0);
    } else if ((flags & (_recursedCheck | _recursed)) == 0) {
      flags = 0;
    } else if ((flags & _recursedCheck) == 0) {
      sub._flags = (flags & ~_recursed) | _pending;
    } else if ((flags & (_dirty | _pending)) == 0 && _isValidLink(link, sub)) {
      sub._flags = flags | _recursed | _pending;
      flags &= _mutable;
    } else {
      flags = 0;
    }

    if ((flags & _watching) != 0) sub._notify();

    if ((flags & _mutable) != 0) {
      final downstream = sub._subs;
      if (downstream != null) {
        link = downstream;
        final sibling = downstream.nextSub;
        if (sibling != null) {
          if (next != null) stack = _Frame(next, stack);
          next = sibling;
        }
        continue;
      }
    }
    if (next != null) {
      link = next;
      next = link.nextSub;
      continue;
    }
    if (stack != null) {
      link = stack.link;
      stack = stack.previous;
      next = link.nextSub;
      continue top;
    }
    return;
  }
}

@pragma('vm:prefer-inline')
bool _needsUpdate(_Tracking sub) {
  final flags = sub._flags;
  if ((flags & _dirty) != 0) return true;
  final deps = sub._deps;
  return (flags & _pending) != 0 && deps != null && _checkDirty(deps, sub);
}

@pragma('vm:align-loops')
bool _checkDirty(_Link first, _Tracking target) {
  var link = first;
  var sub = target;
  _Frame? stack;
  var dirty = false;

  top:
  while (true) {
    final dep = link.dep;
    final flags = dep._flags;
    if ((sub._flags & _dirty) != 0) {
      dirty = true;
    } else if ((flags & (_mutable | _dirty | _recursedCheck)) ==
        (_mutable | _dirty)) {
      if (dep._refresh()) {
        final subs = dep._subs;
        if (subs?.nextSub != null) _shallowPropagate(subs);
        dirty = true;
      }
    } else if ((flags & (_mutable | _pending | _recursedCheck)) ==
        (_mutable | _pending)) {
      final deps = dep._deps;
      if (deps != null) {
        stack = _Frame(link, stack);
        link = deps;
        sub = dep as _Tracking;
        continue;
      }
    } else if ((flags & _recursedCheck) != 0) {
      // A pull from inside a computation can reach that computation through
      // the old graph. Returning a cache hit here would install a cycle.
      _failCycle(dep);
    }

    if (!dirty) {
      final next = link.nextDep;
      if (next != null) {
        link = next;
        continue;
      }
    }

    while (stack != null) {
      link = stack.link;
      stack = stack.previous;
      if (dirty) {
        if (sub._refresh()) {
          final subs = sub._subs;
          if (subs?.nextSub != null) _shallowPropagate(subs);
          sub = link.sub;
          continue;
        }
        dirty = false;
      } else {
        sub._flags &= ~_pending;
      }
      sub = link.sub;
      final next = link.nextDep;
      if (next != null) {
        link = next;
        continue top;
      }
    }
    return dirty && !sub._disposed;
  }
}

void _shallowPropagate(_Link? link) {
  while (link != null) {
    final sub = link.sub;
    final flags = sub._flags;
    if ((flags & (_pending | _dirty)) == _pending) {
      sub._flags = flags | _dirty;
      if ((flags & (_watching | _recursedCheck)) == _watching) sub._notify();
    }
    link = link.nextSub;
  }
}

bool _isValidLink(_Link candidate, _Tracking sub) {
  var link = sub._depsTail;
  while (link != null) {
    if (identical(link, candidate)) return true;
    link = link.prevDep;
  }
  return false;
}

// The write clock makes unchanged cold reads O(1). Refresh each dependency
// before comparing its output version. Finish a node before revisiting its
// parent, so a shared diamond is validated only once per write generation.
void _validateCold(Computed<Object?> root) {
  var node = root;
  var link = node._deps;
  _Frame? stack;
  // Back from validating link.dep: compare its version, do not visit it
  // again (a node still in a cycle keeps _mustRefresh).
  var returned = false;
  while (true) {
    if (!returned && (node._flags & _mustRefresh) != 0) {
      node._refresh();
    } else if (link != null) {
      final dep = link.dep;
      if (returned) {
        returned = false;
      } else if (dep is Computed<Object?> &&
          dep._subs == null &&
          (dep._validated != _writes || (dep._flags & _mustRefresh) != 0) &&
          (dep._flags & _recursedCheck) == 0) {
        stack = _Frame(link, stack);
        node = dep;
        link = dep._deps;
        continue;
      } else if (dep is Computed<Object?>) {
        dep._ensureFresh();
      } else if ((dep._flags & _dirty) != 0 && dep._refresh()) {
        _shallowPropagate(dep._subs);
      }
      if (link.version == dep._version) {
        link = link.nextDep;
        continue;
      }
      node._refresh();
    }
    node._validated = _writes;
    if (stack == null) return;
    link = stack.link;
    stack = stack.previous;
    node = link.sub as Computed<Object?>;
    returned = true;
  }
}

/// Validate both directions from explicit roots. Retaining disposed roots lets
/// tests check that teardown removed every edge without a global node registry.
void checkGraph(Iterable<ReactiveNode> roots) {
  final pending = [...roots];
  final visited = HashSet<ReactiveNode>.identity();
  final forward = HashSet<_Link>.identity();
  final reverse = HashSet<_Link>.identity();
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (!visited.add(node)) continue;
    if (node._disposed && (node._deps != null || node._subs != null)) {
      throw StateError('Disposed node has edges');
    }
    if (node is Computed<Object?> && node._disposed) {
      // Derived nodes belong to no owner and cannot be disposed.
      throw StateError('Computed is disposed');
    }
    _Link? previous;
    for (var link = node._deps; link != null; link = link.nextDep) {
      if (!forward.add(link) ||
          !identical(link.sub, node) ||
          !identical(link.prevDep, previous) ||
          link.attached != link.sub._live) {
        throw StateError('Invalid dependency edge');
      }
      if (link is _WaitLink &&
          (node is! _QueryQuestion ||
              !identical(link.dep, link.source._answer))) {
        throw StateError('Invalid wait edge');
      }
      pending.add(link.dep);
      previous = link;
    }
    if (!identical(node._depsTail, previous)) {
      throw StateError('Invalid dependency tail');
    }
    if (node is AsyncComputed<Object?>) {
      // The query's own nodes are live exactly while it is observed.
      if (node._question._live != (node._subs != null)) {
        throw StateError('Query question liveness differs from its state');
      }
      pending.add(node._question);
      final answer = node._answer;
      if (answer != null) pending.add(answer);
      // Between reconciles the attempt is owned by this
      // query.
      final current = node._current;
      if (current != null && !identical(current._owner, node)) {
        throw StateError('Query attempt is not owned by its query');
      }
    }
    if (node is _QueryQuestion) {
      for (var link = node._subs; link != null; link = link.nextSub) {
        final sub = link.sub;
        if (!identical(sub, node._query) &&
            !identical(sub, node._query._answer)) {
          throw StateError('Query question read outside its query');
        }
      }
    }
    previous = null;
    for (var link = node._subs; link != null; link = link.nextSub) {
      if (!reverse.add(link) ||
          !link.attached ||
          !identical(link.dep, node) ||
          !identical(link.prevSub, previous)) {
        throw StateError('Invalid subscriber edge');
      }
      pending.add(link.sub);
      previous = link;
    }
    if (!identical(node._subsTail, previous)) {
      throw StateError('Invalid subscriber tail');
    }
  }
  if (_transitioning != null) {
    throw StateError('Query reconcile in progress');
  }
  if (forward.where((link) => link.attached).length != reverse.length ||
      !reverse.every(forward.contains)) {
    throw StateError('Unpaired dependency edge');
  }
}
