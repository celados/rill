import 'dart:async';

import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill/wire.dart';
import 'package:test/test.dart';

Matcher stale(StaleReason reason) =>
    isA<Stale<Object?>>().having((value) => value.reason, 'reason', reason);

void main() {
  tearDown(() {
    Rill.onError = null;
    diagnosticHook = null;
  });

  test('revalidates after staging disposes its owner', () async {
    final owner = Scope();
    final slot = owner.slot();
    final target = signal(0);
    late bool publication;
    final wire = Wire(0, (json) {
      owner.dispose();
      return json as int;
    });
    final old = slot.run((t) async {
      publication = t.publish((p) {
        p.set(target, 9);
        wire.stage(p, 3);
      });
      return 1;
    });
    expect(await old, stale(StaleReason.ownerDisposed));
    expect(publication, isFalse);
    expect((target.peek(), wire.readable.peek()), (0, 0));
  });

  test('a throwing part restores the prior same-key wire candidate', () {
    var decodes = 0;
    final wire = Wire(0, (json) {
      decodes++;
      return json as int;
    });
    final committed = transact((p) {
      wire.stage(p, 1);
      expect(
        () => p.part(() {
          wire.stage(p, 2);
          wire.stage(p, 3);
          throw const FormatException('bad part');
        }),
        throwsFormatException,
      );
    });
    expect(committed, isTrue);
    expect(wire.readable.peek(), 1);
    transact((p) => wire.stage(p, 1));
    expect(decodes, 3);
    transact((p) => wire.stage(p, 3));
    expect(wire.readable.peek(), 3);
    expect(decodes, 4);
  });

  test(
    'comparator failure cannot install an earlier field or ledger',
    () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      var decodes = 0;
      final wire = Wire(0, (json) {
        decodes++;
        return json as int;
      });
      final failure = StateError('compare');
      final stack = StackTrace.fromString('comparison stack');
      final second = signal(
        0,
        equals: (_, _) => Error.throwWithStackTrace(failure, stack),
      );
      final revisions = (nodeRevision(wire.readable), nodeRevision(second));
      var notifications = 0;
      final stop = effect(() => (wire.readable.value, second.value), (_, _, _) {
        notifications++;
      });
      addTearDown(stop);
      final outcome = await owner.slot().run(
        (t) async => t.publish((p) {
          wire.stage(p, 8);
          p.set(second, 5);
        }),
      );
      expect(
        outcome,
        isA<Failed<bool>>()
            .having((failure) => failure.error, 'error', same(failure))
            .having((failure) => failure.stack.toString(), 'stack', '$stack'),
      );
      expect((wire.readable.peek(), second.peek()), (0, 0));
      expect((nodeRevision(wire.readable), nodeRevision(second)), revisions);
      expect(notifications, 1);
      transact((p) => wire.stage(p, 8));
      expect(decodes, 2);
    },
  );

  test(
    'observer failure is reported after seeing the fully installed state',
    () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final left = signal(0);
      final right = signal(0);
      final failure = StateError('observer');
      final seen = <Object>[];
      Rill.onError = (error, _) => seen.add(error);
      final stop = effect(() => left.value, (value, _, _) {
        if (value != 0) {
          seen.add((left.peek(), right.peek()));
          throw failure;
        }
      });
      addTearDown(stop);
      final outcome = await owner.slot().run(
        (t) async => t.publish((p) {
          p.set(left, 1);
          p.set(right, 2);
        }),
      );
      expect((outcome as Done).value, isTrue);
      expect(seen, [(1, 2), same(failure)]);
    },
  );

  test('disposal revokes publication before sibling cleanup', () async {
    final root = Scope();
    final child = root.child();
    final slot = child.slot();
    final pending = Completer<int>();
    late Task handle;
    late bool publication;
    final value = signal(0);
    final outcome = slot.run((t) {
      handle = t;
      return pending.future;
    });
    root.child().onDispose(() {
      publication = handle.publish((p) => p.set(value, 1));
      expect(slot.busy.peek(), false);
    });
    root.dispose();
    expect(publication, isFalse);
    expect(await outcome, stale(StaleReason.ownerDisposed));
    await handle.cancelled;
    pending.completeError(StateError('late'));
    expect(value.peek(), 0);
  });

  test('publish_without_conditions_never_conflicts', () async {
    final owner = Scope();
    addTearDown(owner.dispose);
    final slot = owner.slot();
    final cell = signal(0);
    final pending = Completer<void>();
    final first = slot.run((t) async {
      await pending.future;
      return t.publish((p) => p.set(cell, 5));
    });
    batch(() {
      cell.value = 1;
      cell.value = 0;
    });
    owner.slot().run((other) async => other.publish((p) => p.set(cell, 3)));
    pending.complete();
    expect((await first as Done).value, isTrue);
    expect(cell.peek(), 5);
  });

  test(
    'require_at_root_returns_false_and_installs_nothing (computed)',
    () async {
      final scope = Scope();
      addTearDown(scope.dispose);
      final source = signal(1);
      final derived = computed(() => source.value * 2);
      final output = signal(0);
      final notices = Events<int>();
      final heard = <int>[];
      addTearDown(notices.listen(heard.add));
      final gate = Completer<void>();
      final future = scope.slot().run((t) async {
        final asked = Unchanged(derived);
        await gate.future;
        return t.publish((p) {
          p.require(asked);
          p.set(output, 9);
          p.emit(notices, 1);
        });
      });
      source.value = 2;
      gate.complete();
      expect((await future as Done).value, isFalse);
      expect(output.peek(), 0);
      expect(heard, isEmpty);
    },
  );

  test('require_in_part_drops_only_that_part, events included', () async {
    final owner = Scope();
    addTearDown(owner.dispose);
    final optional = signal(0);
    final required = signal(0);
    final notices = Events<int>();
    final received = <int>[];
    addTearDown(notices.listen(received.add));
    final asked = Unchanged(optional);
    optional.value = 2;
    late bool kept;
    final result = await owner.slot().run(
      (t) async => t.publish((p) {
        kept = p.part(() {
          p.require(asked);
          p.set(optional, 1);
          p.emit(notices, 11);
        });
        p.set(required, 3);
        p.emit(notices, 12);
      }),
    );
    expect((result as Done).value, isTrue);
    expect(kept, isFalse);
    expect((optional.peek(), required.peek(), received.single), (2, 3, 12));
  });

  test('staging handle closes after return', () async {
    final owner = Scope();
    addTearDown(owner.dispose);
    late Tx handle;
    final target = signal(0);
    final result = await owner.slot().run(
      (t) async => t.publish((p) {
        handle = p;
      }),
    );
    expect((result as Done).value, isTrue);
    expect(
      () => handle.set(target, 9),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          startsWith('RILL_CLOSED_PUBLICATION'),
        ),
      ),
    );
  });

  test(
    'supersede, skip and keyed merge preserve task and Future identity',
    () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot();
      final skip = owner.slot(onBusy: OnBusy.skip);
      final pending = Completer<int>();
      late Task handle;
      final a = slot.run((t) {
        handle = t;
        return pending.future;
      }, key: 'a');
      expect(slot.run((_) async => -1, key: 'a'), same(a));
      final b = slot.run((_) async => 2, key: 'b');
      expect(await a, stale(StaleReason.superseded));
      await handle.cancelled;
      expect((await b as Done).value, 2);
      final c = skip.run((_) => pending.future, key: 'c');
      expect(skip.run((_) async => -1, key: 'c'), same(c));
      expect(await skip.run((_) async => -1), isA<Skipped<int>>());
      pending.completeError(StateError('old exception'));
      expect(await c, isA<Failed<int>>());
    },
  );

  test(
    'queue begins in FIFO order; a keyed call joins the queued run',
    () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot(onBusy: OnBusy.queue);
      final gate = Completer<void>();
      final target = signal(0);
      final started = <int>[];
      final first = slot.run((_) async {
        started.add(1);
        await gate.future;
        return 1;
      });
      final second = slot.run((t) async {
        started.add(2);
        expect(t.publish((p) => p.set(target, 2)), isTrue);
        return 'two';
      }, key: 2);
      final third = slot.run((_) async {
        started.add(3);
        return true;
      });
      expect(slot.run((_) async => 'unexpected', key: 2), same(second));
      expect(started, [1]);
      target.value = 9;
      gate.complete();
      expect((await first as Done).value, 1);
      expect((await second as Done).value, 'two');
      expect((await third as Done).value, true);
      expect(started, [1, 2, 3]);
      expect((target.peek(), slot.busy.peek()), (2, false));
    },
  );

  test(
    'parallel busy stays true through overlaps and releases on owner close',
    () async {
      final owner = Scope();
      final slot = owner.slot(onBusy: OnBusy.parallel);
      final a = Completer<int>();
      final b = Completer<int>();
      final first = slot.run((_) => a.future);
      final second = slot.run((_) => b.future);
      a.complete(1);
      expect(await first, isA<Done<int>>());
      expect(slot.busy.peek(), true);
      owner.dispose();
      expect(await second, stale(StaleReason.ownerDisposed));
      expect(slot.busy.peek(), false);
      b.complete(2);
    },
  );

  test('disposed_scope_rejects_child_effect_slot_ondispose', () {
    final root = Scope(name: 'root');
    final child = root.child(name: 'child');
    root.dispose();
    final disposed = throwsA(
      isA<StateError>().having(
        (e) => e.message,
        'message',
        startsWith('RILL_DISPOSED'),
      ),
    );
    for (final scope in [root, child]) {
      expect(scope.disposed, isTrue);
      expect(() => scope.child(), disposed);
      expect(() => scope.effect(() => 0, (_, _, _) {}), disposed);
      expect(() => scope.slot(), disposed);
      expect(() => scope.onDispose(() {}), disposed);
    }
  });

  test(
    'an effect that reacts to a publish writes as itself, not as the task',
    () async {
      // A session swap: an effect reading what a task published
      // supersedes that task in the same commit and writes. The effect runs
      // inside the publishing task's zone; its write is still its own.
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot();
      final issues = signal(0, name: 'issues');
      final session = signal(0, name: 'session');
      final log = <(String, String?)>[];
      diagnosticHook = (code, name) => log.add((code, name));
      addTearDown(() => diagnosticHook = null);
      late Task first;
      final stop = owner.effect(() => issues.value, (value, _, _) {
        if (value != 1) return;
        unawaited(slot.run((_) async {}));
        expect(first.alive, isFalse);
        session.value = 1;
      });
      addTearDown(stop);
      final run = slot.run((task) async {
        first = task;
        await Future<void>.delayed(Duration.zero);
        expect(task.publish((p) => p.set(issues, 1)), isTrue);
        // The task's own bare write after it went stale still diagnoses.
        session.value = 2;
      });
      await run;
      expect(log, [('RILL_LATE_WRITE', 'session')]);
      expect(session.value, 2);
    },
  );

  test(
    'late bare writes diagnose, but do not gain or require publication rights',
    () async {
      final owner = Scope();
      final target = signal(0, name: 'late');
      final gate = Completer<void>();
      final log = <(String, String?)>[];
      diagnosticHook = (code, name) => log.add((code, name));
      final other = Scope();
      addTearDown(other.dispose);
      late final Task live;
      final held = Completer<void>();
      final otherResult = other.slot().run((task) {
        live = task;
        return held.future;
      });
      final task = owner.slot().run((_) async {
        await gate.future;
        expect(live.publish((p) => p.set(target, 2)), isTrue);
        target.value = 3;
      });
      owner.dispose();
      await task;
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(log, [('RILL_LATE_WRITE', 'late')]);
      expect(target.peek(), 3);
      held.complete();
      expect(await otherResult, isA<Done<void>>());
    },
  );

  test('names a field repeatedly written by publication', () async {
    final owner = Scope();
    addTearDown(owner.dispose);
    final seed = signal(false);
    final target = signal(0, name: 'published feedback');
    final gate = Completer<void>();
    late final Task live;
    final pending = owner.slot().run((task) {
      live = task;
      return gate.future;
    });
    final stop = effect(() => seed.value ? target.value : null, (value, _, _) {
      if (value != null) live.publish((p) => p.set(target, value + 1));
    });
    try {
      expect(
        () => seed.value = true,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('RILL_INFINITE_LOOP'),
              contains('published feedback'),
            ),
          ),
        ),
      );
    } finally {
      stop();
    }
    gate.complete();
    expect(await pending, isA<Done<void>>());
  });

  test('Events are synchronous, ordered and can repeat the same value', () {
    final notice = Events<int>();
    final log = <int>[];
    final stop = notice.listen(log.add);
    addTearDown(notice.listen((n) => log.add(n + 10)));
    notice.emit(1);
    notice.emit(1);
    stop();
    notice.emit(1);
    expect(log, [1, 11, 1, 11, 11]);
  });

  group('Events hold', () {
    test('without hold, an event nobody hears is gone', () {
      final notice = Events<int>();
      notice.emit(1);
      final log = <int>[];
      addTearDown(notice.listen(log.add));
      notice.emit(2);
      expect(log, [2]);
    });

    test('held events go to the first listener, in order, once', () {
      final notice = Events<int>(hold: true);
      notice
        ..emit(1)
        ..emit(1)
        ..emit(2);
      final first = <int>[];
      final second = <int>[];
      addTearDown(notice.listen(first.add));
      expect(first, [1, 1, 2]);
      addTearDown(notice.listen(second.add));
      notice.emit(3);
      expect(first, [1, 1, 2, 3]);
      expect(second, [3]);
    });

    test('a published event is held like an emitted one', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final notice = Events<int>(hold: true);
      await owner.slot().run((t) async => t.publish((p) => p.emit(notice, 7)));
      final log = <int>[];
      addTearDown(notice.listen(log.add));
      expect(log, [7]);
    });

    test('events held again once every listener has left', () {
      final notice = Events<int>(hold: true);
      final log = <int>[];
      final stop = notice.listen(log.add);
      notice.emit(1);
      stop();
      notice.emit(2);
      expect(log, [1]);
      addTearDown(notice.listen(log.add));
      expect(log, [1, 2]);
    });

    test('an event emitted while held ones drain queues behind them', () {
      final notice = Events<int>(hold: true);
      notice
        ..emit(1)
        ..emit(2);
      final log = <int>[];
      addTearDown(
        notice.listen((n) {
          log.add(n);
          if (n == 1) notice.emit(3);
        }),
      );
      expect(log, [1, 2, 3]);
    });

    test('held events are delivered before listen returns', () {
      // So a listener cannot stop itself during the hand-over: it sees all of
      // them. Bindings that must not call back synchronously defer on their side.
      final notice = Events<int>(hold: true)..emit(1);
      final log = <int>[];
      final stop = notice.listen(log.add);
      expect(log, [1]);
      stop();
    });

    test('beyond the limit the oldest is dropped, with a warning', () {
      final warnings = <(String, String?)>[];
      diagnosticHook = (code, name) => warnings.add((code, name));
      final notice = Events<int>(name: 'notices', hold: true, holdLimit: 3);
      for (var i = 0; i < 5; i++) {
        notice.emit(i);
      }
      final log = <int>[];
      addTearDown(notice.listen(log.add));
      expect(log, [2, 3, 4]);
      expect(warnings, [
        ('RILL_DROPPED_EVENT', 'notices'),
        ('RILL_DROPPED_EVENT', 'notices'),
      ]);
    });

    test('the default limit is 16', () {
      final notice = Events<int>(hold: true);
      for (var i = 0; i < 20; i++) {
        notice.emit(i);
      }
      final log = <int>[];
      addTearDown(notice.listen(log.add));
      expect(log, [for (var i = 4; i < 20; i++) i]);
    });

    test('a limit below one is refused', () {
      expect(() => Events<int>(hold: true, holdLimit: 0), throwsArgumentError);
    });

    // The limit is for while nobody listens, and what was held
    // belongs to the first listener alone.
    test(
      'events emitted during the hand-over are not held: no limit, no warning',
      () {
        final warnings = <String>[];
        diagnosticHook = (code, _) => warnings.add(code);
        final notice = Events<int>(hold: true, holdLimit: 2)
          ..emit(1)
          ..emit(2);
        final log = <int>[];
        addTearDown(
          notice.listen((n) {
            log.add(n);
            if (n == 1) {
              notice
                ..emit(3)
                ..emit(4);
            }
          }),
        );
        expect(log, [1, 2, 3, 4]);
        expect(warnings, isEmpty);
      },
    );

    test(
      'a listener added during the hand-over hears later events, not held ones',
      () {
        final notice = Events<int>(hold: true)
          ..emit(1)
          ..emit(2);
        final first = <int>[], second = <int>[];
        void Function()? stopSecond;
        final stop = notice.listen((n) {
          first.add(n);
          if (n == 1) {
            stopSecond = notice.listen(second.add);
            notice.emit(3);
          }
        });
        addTearDown(() {
          stop();
          stopSecond?.call();
        });
        expect(first, [1, 2, 3]);
        expect(second, [3]);
        notice.emit(4);
        expect(first, [1, 2, 3, 4]);
        expect(second, [3, 4]);
      },
    );
  });

  group('Events order', () {
    test('every listener hears events in the order they were emitted', () {
      final notice = Events<int>();
      final a = <int>[], b = <int>[];
      addTearDown(
        notice.listen((n) {
          a.add(n);
          if (n == 1) notice.emit(2);
        }),
      );
      addTearDown(notice.listen(b.add));
      notice.emit(1);
      expect(a, [1, 2]);
      expect(b, [1, 2]);
    });

    test('a throwing listener stops neither the others nor later events', () {
      final errors = <Object>[];
      Rill.onError = (error, _) => errors.add(error);
      final notice = Events<int>(hold: true)
        ..emit(1)
        ..emit(2);
      final log = <int>[];
      addTearDown(
        notice.listen((n) {
          log.add(n);
          if (n == 1) throw StateError('one');
        }),
      );
      expect(log, [1, 2]);
      final other = <int>[];
      addTearDown(notice.listen(other.add));
      notice.emit(3);
      expect(log, [1, 2, 3]);
      expect(other, [3]);
      expect(errors, [isA<StateError>()]);
    });
  });

  test('unchanged_samples_a_cold_bridge', () async {
    var native = 1;
    final bridge = bindingSignal<int>(native, sample: () => native);
    final out = signal(0);
    final owner = Scope();
    addTearDown(owner.dispose);
    final barrier = Completer<void>();
    final task = owner.slot().run((t) async {
      final snapshot = bridge.peek();
      final asked = Unchanged(bridge);
      await barrier.future;
      return t.publish(
        (p) => p
          ..require(asked)
          ..set(out, snapshot),
      );
    });
    native = 2;
    barrier.complete();
    final result = await task as Done<bool>;
    expect((result.value, out.peek()), (false, 0));
  });

  test('unchanged_takes_the_sampled_value_as_baseline', () async {
    var native = 1;
    final bridge = bindingSignal<int>(0, sample: () => native);
    final out = signal(0);
    final owner = Scope();
    addTearDown(owner.dispose);
    final task = owner.slot().run((t) async {
      // The bridge is stale (0) until sampled; Unchanged samples it before
      // taking the baseline, so the bridge's own catch-up is no change.
      final asked = Unchanged(bridge);
      await null;
      return t.publish(
        (p) => p
          ..require(asked)
          ..set(out, 1),
      );
    });
    final result = await task as Done<bool>;
    expect((result.value, out.peek()), (true, 1));
  });
}
