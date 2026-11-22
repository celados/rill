part of '../rill_flutter.dart';

const _escapedCode = 'RILL_WIDGET_INPUT_ESCAPED';

/// The sync in flight, if any: the write guard
/// lets its one write through, and observers validated meanwhile are routed
/// by where their host sits.
WidgetInput<Object?>? _syncing;

/// Widget configuration entering the graph. Create it with [ReactiveState.input]; hand [readable]
/// to controllers and readers; call [sync] from the owner's
/// `didUpdateWidget` / `didChangeDependencies`, after the `super` call.
///
/// Readers in the owner's subtree (the owner included, an `OverlayPortal`
/// child too) update in the same frame. Any other reader is an error in
/// debug (`RILL_WIDGET_INPUT_ESCAPED`) and one frame late in release.
/// Effects and `watch`es it wakes apply after the frame (R3b).
///
/// Configuration that changes together belongs in one input: an immutable
/// object or a record, with `equals` when it is rebuilt on every
/// configuration. Syncing several inputs inside a `batch` is an error in
/// debug (the flush would wait past the sync, and the readers below would
/// update a frame late); synced one after another, composite readers
/// (`ReactiveTransform`, `ReactiveOpacity`) see each step.
///
/// It is not a [Signal] and needs no disposal: it belongs to the graph like
/// a computed, and stays readable, at its last value, after the owner is
/// gone.
final class WidgetInput<T> {
  WidgetInput._(this._owner, this._node);

  final ReactiveState _owner;
  final Signal<T> _node;

  /// Debug: observers that depend on this input, collected on the first
  /// escaped candidate of a sync.
  Set<_Observer>? _dependents;

  /// Debug: readers outside the owner's subtree woken by the current sync.
  List<_Observer>? _escaped;

  Readable<T> get readable => _node;

  /// Takes the widget's new configuration. Equal values (by the `equals`
  /// given to [ReactiveState.input], `==` by default) propagate nothing.
  ///
  /// Only in the owner's `didUpdateWidget` / `didChangeDependencies`, after
  /// the `super` call, and not inside a `batch`; debug throws
  /// `RILL_WIDGET_INPUT_ESCAPED` anywhere else. A call in a `Builder` or
  /// `LayoutBuilder` callback inside the owner's build runs while the
  /// window is open and is not caught at runtime: the lint
  /// `rill_write_in_build` reports it.
  void sync(T value) {
    assert(_checkSync());
    final previous = _syncing;
    _syncing = this;
    try {
      _frameWrite(() => _node.value = value);
    } finally {
      _syncing = previous;
      _dependents = null;
    }
    assert(_reportEscaped());
  }

  /// Whether [observer], woken during this sync, reads from inside the
  /// owner's subtree; it then updates now. Debug: an outside reader that
  /// depends on this input is recorded as escaped.
  bool _admits(_Observer observer) {
    if (observer.visibilityTarget != null) return false;
    final host = observer.host;
    final element = host?.visibilityElement;
    if (host != null && element == null) return false;
    final owner = _owner.mounted ? _owner.context as Element : null;
    if (element != null && owner != null && _within(element, owner)) {
      return true;
    }
    assert(() {
      final dependents = _dependents ??= _collectDependents();
      if (dependents.contains(observer)) (_escaped ??= []).add(observer);
      return true;
    }());
    return false;
  }

  Set<_Observer> _collectDependents() {
    final found = <_Observer>{};
    hasVisibleConsumer(_node, (sub) {
      if (sub is _Observer) found.add(sub);
      return false;
    });
    return found;
  }

  bool _checkSync() {
    final owner = _owner;
    // State.dispose runs after its Element is unmounted (defunct) and
    // before the State leaves it: the owner still reads as mounted there.
    final element = owner.mounted ? owner.context as Element : null;
    final String? where;
    if (element == null || element.debugIsDefunct) {
      where = 'after its owner was disposed';
    } else if (!owner._inputWindow || _framePhase() != 'build') {
      where = 'outside its owner\'s didUpdateWidget / didChangeDependencies';
    } else if (element.debugDoingBuild) {
      where = 'in its owner\'s build';
    } else if (bindingBoundaryOpen) {
      // The flush would wait for the enclosing batch, past this sync: the
      // readers below the owner would update after the frame, and escaped
      // readers would go unreported.
      throw FlutterError(
        '$_escapedCode: ${_describeInput()} was synced inside a batch.\n'
        'A sync updates the readers below its owner in this frame only '
        'when it flushes by itself. Inputs that change together belong in '
        'one WidgetInput: combine them into an immutable object or a record, '
        'with `equals` if it is rebuilt on every configuration.',
      );
    } else {
      where = null;
    }
    if (where == null) return true;
    throw FlutterError(
      '$_escapedCode: ${_describeInput()} was synced $where.\n'
      'A WidgetInput takes widget configuration: call sync in the owner\'s '
      'didUpdateWidget or didChangeDependencies, after the super call. '
      'Write state that changes on events to a Signal instead.',
    );
  }

  bool _reportEscaped() {
    final escaped = _escaped;
    _escaped = null;
    if (escaped == null || escaped.isEmpty) return true;
    final readers = escaped
        .map((observer) => observer.debugLabel ?? 'a listener')
        .join(', ');
    // Reported, not thrown: the write and its propagation are done, and
    // throwing out of didUpdateWidget would leave the parent's children
    // half updated. The escaped readers update after the frame.
    final error = FlutterError(
      '$_escapedCode: ${_describeInput()} was read outside its owner\'s '
      'subtree, by $readers.\n'
      'Readers of a WidgetInput update in the frame it is synced only when '
      'they sit below its owner (${_owner.widget.runtimeType}); this one '
      'would show the old configuration for a frame. Read it in the owner\'s '
      'subtree, or give the outside reader its own source.',
    );
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: StackTrace.current,
        library: 'rill_flutter',
        context: ErrorDescription('while syncing a WidgetInput'),
      ),
    );
    return true;
  }

  String _describeInput() =>
      _node.name ?? '${_owner.widget.runtimeType}\'s WidgetInput<$T>';
}

/// Whether [element] is [ancestor] or below it in the Element tree.
bool _within(Element element, Element ancestor) {
  if (identical(element, ancestor)) return true;
  var found = false;
  element.visitAncestorElements((parent) {
    found = identical(parent, ancestor);
    return !found;
  });
  return found;
}
