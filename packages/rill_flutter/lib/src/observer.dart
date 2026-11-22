part of '../rill_flutter.dart';

const _untrackedCode = 'RILL_UNTRACKED_READ';
_Observer? _readingObserver;
final _knownOwners = <WeakReference<BuildOwner>>[];

void _installGuards([BuildOwner? owner]) {
  assert(() {
    _knownOwners.removeWhere((entry) => entry.target == null);
    if (owner != null &&
        !_knownOwners.any((entry) => identical(entry.target, owner))) {
      _knownOwners.add(WeakReference(owner));
    }
    bindingReadGuard = _guardRead;
    bindingWriteGuard = _guardWrite;
    _installDebugSections();
    return true;
  }());
}

/// The binding, if one exists. A plain `test()` that drives a controller
/// through `toListenable` / `toReadable` has none, and so runs no frame:
/// every frame question (guards, frame-bound invalidation, post-frame
/// effects, app lifecycle) answers "no frame" without one.
WidgetsBinding? _binding() {
  if (kDebugMode && BindingBase.debugBindingType() == null) return null;
  try {
    return WidgetsBinding.instance;
  } on Error {
    // Release builds do not track the binding type; the getter fails.
    return null;
  }
}

/// G1: the frame phase the framework is in, if any. The read and the write
/// guard share it.
String? _framePhase() {
  if (_binding()?.buildOwner?.debugBuilding == true ||
      _knownOwners.any((entry) => entry.target?.debugBuilding == true)) {
    return 'build';
  }
  if (RenderObject.debugActiveLayout != null) return 'layout';
  if (RenderObject.debugActivePaint != null) return 'paint';
  return null;
}

/// G2: a `.value` read with no reader during build, layout or paint. The
/// core calls it only outside any tracking and outside explicit snapshots
/// (`peek()`, `untracked`, an effect's apply, a Slot body's first part).
void _guardRead(String? name) {
  final phase = _framePhase();
  if (phase == null) return;
  final site = StackTrace.current
      .toString()
      .split('\n')
      .firstWhere(
        (line) =>
            line.startsWith('#') &&
            !line.contains('package:rill/src/') &&
            !line.contains('package:rill_flutter/src/') &&
            !line.contains(' (dart:'),
        orElse: () => '<unknown>',
      )
      .replaceFirst(RegExp(r'^#\d+\s+'), '');
  throw FlutterError(
    '$_untrackedCode: ${name ?? "<unnamed>"} was read during $phase with no '
    'reader tracking it, at $site.\n'
    'To update when it changes, read it inside a Reactive (or ReactiveWidget, '
    'ReactiveLayoutBuilder) or a ReactivePainter mounted with ReactivePaint. '
    'For a snapshot, use peek(). For a plain Dart helper called from a '
    'lifecycle method (initState, didUpdateWidget, deactivate), wrap the call '
    'in untracked(() => ...).',
  );
}

void _guardWrite(String? name) {
  // A WidgetInput's sync is the owner's frame write.
  if (_framePhase() != null && _syncing == null) {
    throw FlutterError(
      'RILL_WRITE_DURING_FRAME: Cannot write ${name ?? "<unnamed>"} during '
      'build, layout or paint. Write from an event or a post-frame callback.',
    );
  }
}

/// The Element a reader asks for visibility.
abstract interface class _VisibilityHost {
  /// Null while the host is not active: its reader counts as not visible.
  Element? get visibilityElement;
}

final class _Observer extends Subscriber {
  _Observer(
    this.invalidate, {
    this.reader,
    this.host,
    this.frameBound = false,
    super.visibilityTarget,
  }) : super(compareConsumedValues: true);

  final VoidCallback invalidate;
  final Object? reader;

  /// Where visibility is asked. Null: native listeners, always visible.
  final _VisibilityHost? host;
  final bool frameBound;

  @override
  Object? get debugReader => reader;

  @override
  String? get debugLabel => switch (reader) {
    final Element element => element.toStringShort(),
    final Object reader => describeIdentity(reader),
    null => null,
  };
  Object? _deferred;

  /// The host's TickerMode notifier, listened to from the first visibility
  /// query on: the wake-up channel, not a cached answer.
  ValueListenable<TickerModeData>? _tickerMode;

  /// Whether a decorative source asked for motion, which registered a
  /// MediaQuery dependency on the host.
  bool motionQueried = false;

  /// Visibility as a time source sees it now. Queried while a source
  /// reconciles; nothing is cached.
  bool visibleFor({required bool decorative}) {
    final host = this.host;
    if (host == null) return true;
    final element = host.visibilityElement;
    if (element == null || disposed) return false;
    final tickerMode = _tickerMode ??= _listenTickerMode(element);
    if (!tickerMode.value.enabled) return false;
    if (!decorative) return true;
    motionQueried = true;
    return !(MediaQuery.maybeDisableAnimationsOf(element) ?? false);
  }

  ValueListenable<TickerModeData> _listenTickerMode(Element element) =>
      TickerMode.getValuesNotifier(element)..addListener(hostChanged);

  /// The host's visibility may have changed: reconcile the time sources,
  /// then honour this observer's update now instead of after the frame.
  /// The wake-up comes from the host's own ancestors (TickerMode,
  /// MediaQuery) updating, so marking the host is in order.
  void hostChanged() {
    if (disposed) return;
    _refreshPulses();
    final deferred = _deferred;
    if (deferred == null) return;
    _deferred = null;
    invalidate();
  }

  @override
  void dispose() {
    // A host that moves (GlobalKey) drops its observer; the next one listens
    // to the TickerMode where the host lands.
    _tickerMode?.removeListener(hostChanged);
    _tickerMode = null;
    super.dispose();
  }

  @override
  void notify() {
    if (visibilityTarget == null) {
      afterFlush(this, _validate);
    } else {
      beforeBindingObservers(_validate);
    }
  }

  void _validate() {
    if (disposed ||
        !changed(
          onChange: reader == null || diagnosticHook == null ? null : _why,
        ))
      return;
    // A WidgetInput sync updates readers below its owner in this frame;
    // the rest keep the frame-bound path.
    final syncing = _syncing;
    if (syncing != null && syncing._admits(this)) {
      _deferred = null;
      invalidate();
      return;
    }
    final binding = frameBound ? _binding() : null;
    if (binding != null &&
        binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_deferred != null) return;
      final mark = _deferred = Object();
      binding.addPostFrameCallback((_) {
        if (!identical(_deferred, mark)) return;
        _deferred = null;
        if (!disposed) invalidate();
      }, debugLabel: 'rill.invalidate');
    } else {
      invalidate();
    }
  }

  void _why(String path) {
    diagnosticHook?.call('RILL_REBUILD', '$path → $reader');
  }

  R read<R>(R Function() fn) {
    _installGuards();
    _deferred = null;
    return track(() {
      final previousObserver = _readingObserver;
      _readingObserver = this;
      try {
        return fn();
      } finally {
        _readingObserver = previousObserver;
      }
    });
  }
}
