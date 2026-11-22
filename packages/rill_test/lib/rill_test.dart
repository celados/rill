library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/debug.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

part 'src/why.dart';

extension RillTester on WidgetTester {
  /// Mounts [app] the way `runApp` does, then pumps the warm-up frame.
  ///
  /// `pumpWidget` builds inside a frame callback. `runApp` builds its first
  /// tree synchronously, outside any frame, while the scheduler phase is
  /// still idle — the first `initState` of every widget in the app runs
  /// there. Code that sniffs the phase behaves differently between the two,
  /// and `binding.attachRootWidget` alone does not help: a test binding
  /// already has a root, so attaching only marks it dirty and the build
  /// waits for the next pump's frame. This helper builds that dirty root at
  /// once, in idle phase, with rill's frame guards installed, and then pumps
  /// one frame, whose post-frame callbacks run as the warm-up frame's would.
  /// Component libraries test their root-mounted widgets with it.
  Future<void> mountApp(Widget app) async {
    final owner = binding.buildOwner!;
    debugInstallRillGuards(owner);
    binding.attachRootWidget(binding.wrapWithDefaultView(app));
    owner.buildScope(binding.rootElement!);
    await pump();
  }

  /// The rebuilds of the reactive Elements found by [finder] during [during],
  /// each with its causal chain. Pumps a frame after [during].
  Future<List<RillWhy>> whyRebuilt(
    Finder finder, {
    required FutureOr<void> Function() during,
  }) async {
    final elements = Set<Element>.identity()..addAll(finder.evaluate());
    final records = await recordWhy(() async {
      await during();
      await pump();
    });
    return [
      for (final record in records)
        if (record.kind == 'observer' && elements.contains(record.target))
          record,
    ];
  }

  Future<void> expectRebuilds({
    required Set<Type> only,
    required FutureOr<void> Function() during,
  }) async {
    final actual = <Type>{};
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      actual.add(element.widget.runtimeType);
    };
    try {
      await during();
      await pump();
      expect(
        binding.hasScheduledFrame,
        isFalse,
        reason: 'Rebuilds are still pending after the observation frame.',
      );
      expect(actual, only);
    } finally {
      debugOnRebuildDirtyWidget = previous;
    }
  }

  /// Advances fake time and checks that no frames are scheduled or produced
  /// and no rill-managed timers, pulses, Slot tasks or queries (in flight,
  /// subscribed to a stream, or holding a retention timer) are active.
  ///
  /// For timers created outside rill, check `FakeAsync.pendingTimers` from
  /// package:fake_async in the fake-time zone that created those timers.
  Future<void> expectIdle({
    Duration across = const Duration(seconds: 5),
  }) async {
    if (across < Duration.zero) throw ArgumentError.value(across, 'across');
    final frames = _frameCounts[binding] ??= _FrameCount(binding);
    final initial = frames.count;
    final activity = bindingActivity;
    void check() {
      expect(binding.hasScheduledFrame, isFalse, reason: 'A frame is pending.');
      expect(frames.count, initial, reason: 'An idle tree produced a frame.');
      expect(
        binding.transientCallbackCount,
        0,
        reason: 'A frame callback is pending.',
      );
      expect(
        bindingActivity,
        activity,
        reason: 'A rill task, timer or query started.',
      );
      expect(activeTaskCount, 0, reason: 'A rill task is active.');
      expect(activePulseCount, 0, reason: 'A rill pulse is running.');
      expect(activeBindingTimerCount, 0, reason: 'A rill timer is active.');
      expect(activeQueryCount, 0, reason: 'A rill query is in flight.');
      expect(
        activeQueryStreamCount,
        0,
        reason: 'A rill stream query is subscribed.',
      );
      expect(
        activeQueryTimerCount,
        0,
        reason: 'A rill query retention timer is pending.',
      );
    }

    check();
    final us = across.inMicroseconds;
    for (var step = 0; step < 5; step++) {
      await pump(Duration(microseconds: us * (step + 1) ~/ 5 - us * step ~/ 5));
      check();
    }
  }
}

final _frameCounts = Expando<_FrameCount>();

class _FrameCount {
  _FrameCount(TestWidgetsFlutterBinding binding) {
    binding.addPersistentFrameCallback((_) => count++);
  }
  int count = 0;
}

Set<Readable<Object?>> wakes(
  List<Readable<Object?>> watched, {
  required void Function() during,
}) {
  if (bindingBoundaryOpen) {
    throw StateError(
      'RILL_OPEN_REFRESH_BOUNDARY: Put batch inside wakes(during:).',
    );
  }
  final actual = Set<Readable<Object?>>.identity();
  final observers = <_WakeObserver>[];
  try {
    for (final source in Set<Readable<Object?>>.identity()..addAll(watched)) {
      final observer = _WakeObserver(source, () => actual.add(source));
      observers.add(observer);
      observer.read();
    }
    during();
    return actual;
  } finally {
    for (final observer in observers) {
      observer.dispose();
    }
  }
}

final class _WakeObserver extends Subscriber {
  _WakeObserver(this.source, this.wake) : super(compareConsumedValues: true);
  final Readable<Object?> source;
  final void Function() wake;

  void read() => track(() {
    try {
      source.value;
    } on Object {
      // The dependency is still registered when a reactive read fails.
    }
  });

  @override
  void notify() => afterFlush(this, () {
    if (disposed || !changed()) return;
    wake();
    read();
  });
}

final class ManualAsync<T> {
  final _calls = <Completer<T>>[];

  int get pending => _calls.length;

  Future<T> call() {
    final completion = Completer<T>();
    _calls.add(completion);
    return completion.future;
  }

  void complete(T value) => completeAt(0, value);

  void fail(Object error) => failAt(0, error);

  /// Completes the call at the zero-based index among pending calls.
  void completeAt(int index, T value) => _take(index).complete(value);

  /// Fails the call at the zero-based index among pending calls.
  void failAt(int index, Object error) => _take(index).completeError(error);

  Completer<T> _take(int index) {
    if (_calls.isEmpty) throw StateError('No pending call.');
    return _calls.removeAt(index);
  }
}
