part of '../rill_flutter.dart';

/// Calls with the same arguments return one source while any handle to it
/// lives, so `Pulse.every(period)` may be written wherever it is read, even
/// inside a `computed` or in two fields before either is read: there is one
/// timer per distinct period, not one per call.
abstract final class Pulse {
  static Readable<DateTime> every(Duration period) {
    if (period <= Duration.zero) throw ArgumentError.value(period, 'period');
    return _shared((
      'every',
      period,
    ), () => _PulseSource(period, () => clock.now())).readable;
  }

  static Readable<DateTime> get minute => every(const Duration(minutes: 1));

  /// Position in [period], 0 → 1, sampled every [frame]. A lower frame rate
  /// is fewer frames for every reader: sources with the same [frame] share
  /// sample instants, so loops drawn together cost one frame per sample.
  static Readable<double> phase(
    Duration period, {
    Duration frame = const Duration(milliseconds: 16),
  }) {
    if (period <= Duration.zero) throw ArgumentError.value(period, 'period');
    if (frame <= Duration.zero) throw ArgumentError.value(frame, 'frame');
    final us = period.inMicroseconds;
    return _shared(
      ('phase', period, frame),
      () => _PulseSource(
        frame,
        () => (clock.now().microsecondsSinceEpoch % us) / us,
        decorative: true,
      ),
    ).readable;
  }
}

/// Sources by their arguments, held weakly: a handle keeps its source, the
/// table keeps none, and an entry leaves when its source is collected. A
/// source is shared from creation, not from its first reader, so handles
/// taken before anything observes them are one source.
final _sharedPulses = <Object, WeakReference<_PulseSource<Object?>>>{};
final _collectedPulses = Finalizer<Object>((key) {
  if (_sharedPulses[key]?.target == null) _sharedPulses.remove(key);
});

_PulseSource<T> _shared<T>(Object key, _PulseSource<T> Function() create) {
  final existing = _sharedPulses[key]?.target;
  if (existing is _PulseSource<T>) return existing;
  final source = create();
  _sharedPulses[key] = WeakReference(source);
  _collectedPulses.attach(source, key);
  return source;
}

final _pulses = <_PulseSource<Object?>>{};
final _pulseLifecycle = _PulseLifecycle();
final _pulseRefreshKey = Object();

void _graphChanged() => afterFlush(_pulseRefreshKey, _refreshPulses);

/// Pausing and resuming follow readers that build, paint or change
/// visibility, so a catch-up sample is a frame write (R3b).
void _refreshPulses() => _frameWrite(() {
  for (final source in _pulses.toList()) {
    source.refresh();
  }
});

/// The binding [_pulseLifecycle] is registered on, while pulses are
/// watched and a binding exists.
WidgetsBinding? _lifecycleBinding;

/// Registers the lifecycle observer once a binding exists. A pulse watched
/// before the binding was initialized found none to register on; Flutter
/// announces no initialization, so every pulse event (watch, refresh, read
/// calibration, tick) asks again. True when it just
/// registered: visibility was decided without a lifecycle until now.
bool _bindLifecycle() {
  if (_lifecycleBinding != null || _pulses.isEmpty) return false;
  final binding = _binding();
  if (binding == null) return false;
  _lifecycleBinding = binding..addObserver(_pulseLifecycle);
  return true;
}

class _PulseLifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _refreshPulses();
}

class _PulseSource<T> {
  _PulseSource(this.interval, this.sample, {this.decorative = false}) {
    if (interval <= Duration.zero)
      throw ArgumentError.value(interval, 'period');
  }

  final Duration interval;
  final T Function() sample;
  final bool decorative;
  _BindingTimer? _timer;
  bool _calibratedOnRead = false;
  late final Signal<T> _state = bindingSignal(
    sample(),
    sample: sample,
    beforeRead: _calibrateForReader,
    watched: _watch,
    unwatched: _unwatch,
  );

  Readable<T> get readable => _state;

  void _sample() => writeBindingSignal(_state, sample());

  void _watch() {
    if (_pulses.isEmpty) bindingGraphChanged = _graphChanged;
    _pulses.add(this);
    refresh(calibrate: false);
  }

  void _unwatch() {
    _stop();
    _pulses.remove(this);
    if (_pulses.isEmpty) {
      bindingGraphChanged = null;
      _lifecycleBinding?.removeObserver(_pulseLifecycle);
      _lifecycleBinding = null;
    }
  }

  bool get _appVisible => switch (_binding()?.lifecycleState) {
    null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
    _ => false,
  };

  /// Asked of each consumer while reconciling: the
  /// reader's host answers now; nothing is cached on the reader.
  bool _visible(ReactiveNode node) =>
      node is! _Observer || node.visibleFor(decorative: decorative);

  void _calibrateForReader() {
    if (_bindLifecycle()) afterFlush(_pulseRefreshKey, _refreshPulses);
    final reader = _readingObserver;
    if (_timer != null ||
        _calibratedOnRead ||
        reader == null ||
        !_appVisible ||
        !_visible(reader)) {
      return;
    }
    _calibratedOnRead = true;
    _frameWrite(_sample);
    afterFlush(_pulseRefreshKey, _refreshPulses);
  }

  void refresh({bool calibrate = true}) {
    // The other sources were decided without the lifecycle too.
    if (_bindLifecycle()) afterFlush(_pulseRefreshKey, _refreshPulses);
    final run = _appVisible && hasVisibleConsumer(_state, _visible);
    final calibrated = _calibratedOnRead;
    _calibratedOnRead = false;
    if (!run) {
      _stop();
    } else if (_timer == null) {
      activePulseCount++;
      _schedule();
      if (calibrate && !calibrated) _sample();
    }
  }

  void _stop() {
    final timer = _timer;
    if (timer == null) return;
    timer.cancel();
    _timer = null;
    activePulseCount--;
  }

  void _schedule() {
    final now = clock.now().microsecondsSinceEpoch;
    final us = interval.inMicroseconds;
    _timer = _BindingTimer(Duration(microseconds: us - now % us), () {
      if (_bindLifecycle()) {
        // Decide again with the lifecycle: a paused app stops here.
        _refreshPulses();
        if (_timer == null) return;
      }
      _schedule();
      _sample();
    });
  }
}

Readable<T?> linger<T>(Readable<T?> source, Duration duration) {
  if (duration < Duration.zero) throw ArgumentError.value(duration, 'duration');
  return _Linger(source, duration).readable;
}

typedef _LingerValue<T> = ({T? value, Object? error, StackTrace? stack});

/// Belongs to no owner: its observer and timer exist only while
/// something reads it, and it goes with the last reference.
class _Linger<T> {
  _Linger(this.source, this.duration);

  final Readable<T?> source;
  final Duration duration;
  _BindingTimer? _timer;
  _Observer? _observer;
  T? _lastValue;
  late final Signal<_LingerValue<T>?> _state = bindingSignal(
    null,
    sample: () => null,
    beforeRead: _prepareRead,
    watched: _watch,
    unwatched: _unwatch,
  );

  late final Readable<T?> readable = computed(() {
    final current = _state.value;
    if (current == null) return source.value;
    final error = current.error;
    if (error != null) Error.throwWithStackTrace(error, current.stack!);
    return current.value;
  });

  _LingerValue<T> _readSource() => _observer!.track(() {
    try {
      return (value: source.value, error: null, stack: null);
    } on Object catch (error, stack) {
      return (value: null, error: error, stack: stack);
    }
  });

  void _prepareRead() {
    final observer = _observer;
    if (observer == null || _readingObserver == null) return;
    _frameWrite(() {
      prepareBindingInput(source);
      if (observer.changed()) _update();
    });
  }

  void _watch() {
    _observer = _Observer(_update, visibilityTarget: _state);
    _lastValue = _readSource().value;
  }

  void _update() {
    final next = _readSource();
    final value = next.value;
    if (next.error != null || value != null || duration == Duration.zero) {
      _cancelTimer();
      _lastValue = value;
      writeBindingSignal(_state, next);
    } else if (_timer == null && _lastValue != null) {
      // Store the retained value so the output switches off its initial
      // direct read of the source.
      writeBindingSignal(_state, (value: _lastValue, error: null, stack: null));
      _timer = _BindingTimer(duration, () {
        _timer = null;
        _lastValue = null;
        writeBindingSignal(_state, (value: null, error: null, stack: null));
      });
    } else if (_timer == null) {
      writeBindingSignal(_state, next);
    }
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _unwatch() {
    _cancelTimer();
    _observer?.dispose();
    _observer = null;
    _lastValue = null;
    writeBindingSignal(_state, null);
  }
}

class _BindingTimer {
  _BindingTimer(Duration duration, VoidCallback callback) {
    activeBindingTimerCount++;
    bindingActivity++;
    _timer = Timer(duration, () {
      activeBindingTimerCount--;
      callback();
    });
  }

  late final Timer _timer;

  void cancel() {
    if (_timer.isActive) activeBindingTimerCount--;
    _timer.cancel();
  }
}
