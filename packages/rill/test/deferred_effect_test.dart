// The deferred first apply behind rill_flutter's ReactiveState.watch:
// compute now, first apply on release, later ones at once.
// Also the core regression for Readable.constant and the frame-write
// deferral that rill_flutter drives with a post-frame scheduler.
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:test/test.dart';

void main() {
  late List<void Function()> releases;
  void schedule(void Function() release) => releases.add(release);
  void releaseAll() {
    for (final release in releases) {
      release();
    }
    releases.clear();
  }

  setUp(() {
    releases = [];
    Rill.onError = null;
  });

  test('compute tracks at once; the first apply waits for release', () {
    final source = signal(1);
    final log = <String>[];
    final stop = deferredEffect(
      () {
        log.add('compute ${source.value}');
        return source.value;
      },
      (v, previous, _) {
        log.add('apply $v $previous');
      },
      schedule: schedule,
    );
    expect(log, ['compute 1']);
    releaseAll();
    expect(log, ['compute 1', 'apply 1 null']);
    source.value = 2;
    expect(log.last, 'apply 2 1', reason: 'later applies are synchronous');
    stop();
  });

  test('recomputes before release only replace the held value', () {
    final source = signal(1);
    final applied = <(int, int?)>[];
    final stop = deferredEffect(() => source.value, (v, previous, _) {
      applied.add((v, previous));
    }, schedule: schedule);
    source.value = 2;
    source.value = 3;
    expect(applied, isEmpty);
    releaseAll();
    expect(applied, [(3, null)]);
    source.value = 4;
    expect(applied, [(3, null), (4, 3)]);
    stop();
  });

  test('a failing compute withholds the first apply until one succeeds', () {
    final source = signal(1);
    final errors = <Object>[];
    Rill.onError = (error, _) => errors.add(error);
    final applied = <(int, int?)>[];
    final stop = deferredEffect(
      () => source.value.isEven ? throw StateError('even') : source.value,
      (v, previous, _) {
        applied.add((v, previous));
      },
      schedule: schedule,
    );
    source.value = 2;
    releaseAll();
    expect(applied, isEmpty);
    expect(errors, hasLength(1));
    source.value = 3;
    expect(applied, [(3, null)]);
    stop();
  });

  test('stopping before release applies nothing; cleanup and errors flow', () {
    final source = signal(1);
    var applied = 0;
    deferredEffect(() => source.value, (_, _, _) {
      applied++;
    }, schedule: schedule)();
    releaseAll();
    expect(applied, 0);

    final log = <String>[];
    final errors = <Object>[];
    Rill.onError = (error, _) => errors.add(error);
    final stop = deferredEffect(() => source.value, (v, _, onCleanup) {
      log.add('apply $v');
      if (v == 2) throw StateError('apply');
      onCleanup(() => log.add('cleanup $v'));
    }, schedule: schedule);
    releaseAll();
    source.value = 2;
    expect(log, ['apply 1', 'cleanup 1', 'apply 2']);
    expect(errors.single, isA<StateError>());
    source.value = 3;
    stop();
    expect(log, ['apply 1', 'cleanup 1', 'apply 2', 'apply 3', 'cleanup 3']);
  });

  test('writes made by the first apply flush before release returns', () {
    final source = signal(1);
    final mirror = signal(0);
    final seen = <int>[];
    final watch = effect(() => mirror.value, (v, _, _) {
      seen.add(v);
    });
    final stop = deferredEffect(() => source.value, (v, _, _) {
      mirror.value = v * 10;
    }, schedule: schedule);
    releaseAll();
    expect(seen, [0, 10]);
    stop();
    watch();
  });

  test('an owner Scope owns it; nothing it creates is owned', () {
    final scope = Scope(name: 'owner');
    final source = signal(1);
    var applied = 0;
    Computed<int>? inner;
    deferredEffect(
      () {
        inner = computed(() => source.value);
        return inner!.value;
      },
      (_, _, _) {
        applied++;
      },
      schedule: schedule,
      owner: scope,
    );
    scope.dispose();
    releaseAll();
    expect(applied, 0);
    // A computed made in the compute belongs to no one and outlives it.
    expect(inner!.value, 1);
  });

  test('a disposed owner rejects it', () {
    final scope = Scope()..dispose();
    expect(
      () => deferredEffect(
        () => 0,
        (_, _, _) {},
        schedule: schedule,
        owner: scope,
      ),
      throwsStateError,
    );
  });

  test('a constant leaves no edge in its readers', () {
    final fixed = Readable.constant(1);
    final derived = computed(() => fixed.value + 1);
    final stop = effect(() => derived.value, (_, _, _) {});
    expect((derived.value, subscriberCount(fixed)), (2, 0));
    stop();
  });

  group('frame writes', () {
    late List<void Function()> drains;
    void frame(void Function() write) =>
        frameBindingWrite((drain) => drains.add(drain), write);
    void drainAll() {
      final pending = List.of(drains);
      drains.clear();
      for (final drain in pending) {
        drain();
      }
    }

    setUp(() => drains = []);

    test('effects it wakes wait for the drain; track exits do not drain', () {
      final source = signal(1);
      final log = <String>[];
      final stop = effect(() => source.value, (v, previous, onCleanup) {
        log.add('apply $v $previous');
        onCleanup(() => log.add('cleanup $v'));
      });
      final reader = _Reader();
      reader.track(() => frame(() => writeBindingSignal(source, 2)));
      expect(log, ['apply 1 null']);
      expect(drains, hasLength(1));
      reader.track(() => source.peek());
      final other = signal(0);
      other.value = 1;
      batch(() {});
      expect(log, ['apply 1 null']);
      drainAll();
      expect(log, ['apply 1 null', 'cleanup 1', 'apply 2 1']);
      stop();
      reader.dispose();
    });

    test('hit again by frame or ordinary writes, it applies once, latest', () {
      final source = signal(1);
      final log = <String>[];
      final stop = effect(() => source.value, (v, previous, _) {
        log.add('apply $v $previous');
      });
      frame(() => writeBindingSignal(source, 2));
      frame(() => writeBindingSignal(source, 3));
      source.value = 4;
      expect(log, ['apply 1 null']);
      expect(drains, hasLength(1));
      drainAll();
      expect(log, ['apply 1 null', 'apply 4 1']);
      stop();
    });

    test('stopped before the drain: cleanup runs, the apply does not', () {
      final source = signal(1);
      final log = <String>[];
      final stop = effect(() => source.value, (v, _, onCleanup) {
        log.add('apply $v');
        onCleanup(() => log.add('cleanup $v'));
      });
      frame(() => writeBindingSignal(source, 2));
      stop();
      drainAll();
      expect(log, ['apply 1', 'cleanup 1']);
    });

    test('ordinary writes outside it still flush synchronously', () {
      final source = signal(1);
      final applied = <int>[];
      final stop = effect(() => source.value, (v, _, _) {
        applied.add(v);
      });
      final unrelated = signal(0);
      // A frame write that settles with nothing to run.
      frame(() => writeBindingSignal(unrelated, 1));
      source.value = 2;
      // One that settles through a full flush.
      frame(() {
        writeBindingSignal(unrelated, 2);
        afterFlush(#settle, () {});
      });
      source.value = 3;
      // One that installs nothing marks nothing, even inside a boundary.
      batch(() {
        frame(() => writeBindingSignal(unrelated, 2));
        source.value = 4;
      });
      expect(applied, [1, 2, 3, 4]);
      expect(drains, isEmpty);
      stop();
    });

    test('a held first apply woken by it is made by the drain, latest', () {
      final source = signal(1);
      final log = <String>[];
      final stop = deferredEffect(() => source.value, (v, previous, _) {
        log.add('apply $v $previous');
      }, schedule: schedule);
      frame(() => writeBindingSignal(source, 2));
      releaseAll();
      expect(log, isEmpty);
      drainAll();
      expect(log, ['apply 2 null']);
      source.value = 3;
      expect(log, ['apply 2 null', 'apply 3 2']);
      stop();
    });
  });
}

final class _Reader extends Subscriber {
  @override
  void notify() {}
}
