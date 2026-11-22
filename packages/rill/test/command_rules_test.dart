// Command layer: one minimal counterexample per rule, and design and review
// probes turned into regressions.
import 'dart:async';

import 'package:rill/debug.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:test/test.dart';

Matcher stale(StaleReason reason) =>
    isA<Stale<Object?>>().having((value) => value.reason, 'reason', reason);

Matcher failsWith(String code) => throwsA(
  isA<StateError>().having((e) => e.message, 'message', startsWith(code)),
);

Matcher failedWith(String code) => isA<Failed<Object?>>().having(
  (failed) => '${failed.error}',
  'error',
  contains(code),
);

Future<void> drain() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(RillDebug.clear);
  tearDown(() => diagnosticHook = null);
  stagingEventsLateCommitsAndRefusals();
  heldHandlesOfCancelledTasks();

  group('default install', () {
    test('parallel_newer_answer_lands_when_older_arrives_first', () async {
      final field = signal('init');
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot(onBusy: OnBusy.parallel);
      final older = Completer<void>(), newer = Completer<void>();
      late bool olderOk, newerOk;
      final first = slot.run((t) async {
        await older.future;
        olderOk = t.publish((p) => p.set(field, 'older'));
      });
      final second = slot.run((t) async {
        await newer.future;
        newerOk = t.publish((p) => p.set(field, 'newer'));
      });
      older.complete();
      await first;
      newer.complete();
      await second;
      expect((olderOk, newerOk, field.peek()), (true, true, 'newer'));
    });
  });

  group('Unchanged', () {
    test('unchanged_signal_rejects_aba', () {
      final a = signal(1);
      final asked = Unchanged(a);
      a.value = 0;
      a.value = 1;
      expect(asked.holds, isFalse);
    });

    test('unchanged_ignores_equal_writes', () {
      final a = signal(1);
      final asked = Unchanged(a);
      a.value = 1;
      transact((p) => p.set(a, 1));
      expect(asked.holds, isTrue);
    });

    test('unchanged_cold_computed_is_value_based', () {
      final a = signal(1);
      final positive = computed(() => a.value > 0);
      final asked = Unchanged(positive);
      a.value = 0;
      a.value = 1;
      expect(asked.holds, isTrue, reason: 'nobody pulled the round trip');
      a.value = 0;
      expect(asked.holds, isFalse);
    });

    test('unchanged_hot_computed_rejects_a_pulled_round_trip', () {
      final a = signal(1);
      final positive = computed(() => a.value > 0);
      addTearDown(effect(() => positive.value, (_, _, _) {}));
      final asked = Unchanged(positive);
      a.value = 0;
      a.value = 1;
      expect(asked.holds, isFalse);
    });

    test('unchanged_hot_computed_misses_a_batched_round_trip', () {
      final a = signal(1);
      final positive = computed(() => a.value > 0);
      addTearDown(effect(() => positive.value, (_, _, _) {}));
      final asked = Unchanged(positive), exact = Unchanged(a);
      batch(() {
        a.value = 0;
        a.value = 1;
      });
      expect(asked.holds, isTrue, reason: 'a Computed is judged when pulled');
      expect(exact.holds, isFalse, reason: 'a Signal counts every install');
    });

    test('unchanged_hot_computed_misses_a_frame_deferred_round_trip', () {
      final a = bindingSignal<int>(1, sample: () => 1);
      final positive = computed(() => a.value > 0);
      addTearDown(effect(() => positive.value, (_, _, _) {}));
      final asked = Unchanged(positive);
      final pending = <void Function()>[];
      frameBindingWrite(pending.add, () => writeBindingSignal(a, 0));
      frameBindingWrite(pending.add, () => writeBindingSignal(a, 1));
      for (final fn in pending) {
        fn();
      }
      expect(asked.holds, isTrue);
    });

    test('unchanged_samples_an_unwatched_binding_signal', () {
      var backing = 1;
      final bridge = bindingSignal<int>(backing, sample: () => backing);
      final asked = Unchanged(bridge);
      expect(asked.holds, isTrue);
      backing = 2;
      expect(asked.holds, isFalse, reason: 'holds samples like a read');
    });

    test('unchanged_calibrates_a_paused_clock_under_a_hot_computed', () {
      // A paused clock (Pulse) only catches up in beforeRead: a hot computed
      // returns its cache unless the pull calibrates it first.
      var now = 1;
      late final Signal<int> clock;
      clock = bindingSignal<int>(
        now,
        sample: () => now,
        beforeRead: () => writeBindingSignal(clock, now),
      );
      final minute = computed(() => clock.value ~/ 60);
      addTearDown(effect(() => minute.value, (_, _, _) {}));
      final asked = Unchanged(minute);
      now = 120;
      expect(asked.holds, isFalse);
    });

    test('unchanged_on_query_state', () async {
      var calls = 0;
      final q = computedAsync<String>((_) async {
        calls++;
        return 'same';
      });
      addTearDown(effect(() => q.value, (_, _, _) {}));
      await q.settled();
      final asked = Unchanged(q);
      q.invalidate();
      await q.settled();
      expect(calls, 2);
      expect(
        asked.holds,
        isFalse,
        reason: 'a refresh passes through refreshing',
      );
    });

    test('unchanged_on_throwing_computed', () {
      final a = signal(1);
      final c = computed<int>(() {
        a.value;
        throw const FormatException('same');
      });
      final asked = Unchanged(c);
      a.value = 2;
      expect(asked.holds, isFalse);
    });

    test('unchanged_on_constant_always_holds', () {
      final fixed = Readable.constant(3);
      final asked = Unchanged(fixed);
      signal(0).value = 1;
      expect(asked.holds, isTrue);
    });

    test('holds_does_not_recompute_an_unchanged_computed', () {
      final a = signal(1);
      var runs = 0;
      final chain = computed(() {
        runs++;
        return a.value + 1;
      });
      final top = computed(() => chain.value * 2);
      final asked = Unchanged(top);
      final before = runs;
      for (var i = 0; i < 3; i++) {
        expect(asked.holds, isTrue);
      }
      expect(runs, before);
    });
  });

  group('conditions are values', () {
    test('unchanged_taken_before_request_guards_another_task', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final poll = owner.slot(onBusy: OnBusy.skip), ends = owner.slot();
      final sweep = signal(0), status = signal(''), shown = signal(0);
      final reply = Completer<void>();
      late Future<Outcome<bool>> end;
      final polled = poll.run((t) async {
        final asked = Unchanged(sweep);
        await reply.future;
        final telemetry = t.publish((p) => p.set(status, 'ok'));
        final sweepPart = t.publish((p) {
          p.require(asked);
          p.set(sweep, 2);
        });
        end = ends.run((e) async {
          if (!asked.holds) return false;
          return e.publish((p) {
            p.require(asked);
            p.set(shown, 1);
          });
        });
        return (telemetry, sweepPart);
      });
      sweep.value = 7; // a sweep started while the poll was in flight
      reply.complete();
      expect((await polled as Done).value, (true, false));
      expect((await end as Done).value, isFalse);
      expect((status.peek(), sweep.peek(), shown.peek()), ('ok', 7, 0));
    });

    test('alive_is_lifecycle_only', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final source = signal(0), target = signal(0);
      final outcome = await owner.slot().run((t) async {
        final asked = Unchanged(source);
        source.value = 1;
        return (
          t.alive,
          asked.holds,
          t.publish((p) {
            p.require(asked);
            p.set(target, 1);
          }),
        );
      });
      expect((outcome as Done).value, (true, false, false));
    });

    test('unchanged_retaken_after_own_write_guards_rollback', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final save = owner.slot();
      final done = signal(false);
      Future<void> toggle(Completer<void> rpc) async {
        final next = !done.peek();
        done.value = next;
        final mine = Unchanged(done);
        await save.run((t) async {
          try {
            await rpc.future;
          } on Object {
            t.publish((p) {
              p.require(mine);
              p.set(done, !next);
            });
          }
        });
      }

      final failing = Completer<void>();
      final first = toggle(failing);
      expect(done.peek(), isTrue);
      failing.completeError(StateError('offline'));
      await first;
      expect(done.peek(), isFalse, reason: 'rolled back');

      final second = Completer<void>();
      final run = toggle(second);
      done.value = false; // the user changed it again meanwhile
      done.value = true;
      second.completeError(StateError('offline'));
      await run;
      expect(done.peek(), isTrue, reason: 'the newer user value is kept');
    });
  });

  group('transact', () {
    test('transact_staging_throws_installs_nothing_with_original_stack', () {
      final a = signal(0), b = signal(0);
      final failure = const FormatException('bad');
      late StackTrace thrown;
      Object? caught;
      StackTrace? stack;
      try {
        transact((p) {
          p.set(a, 1);
          try {
            throw failure;
          } on FormatException catch (_, s) {
            thrown = s;
            rethrow;
          }
        });
      } on Object catch (e, s) {
        (caught, stack) = (e, s);
      }
      expect(caught, same(failure));
      expect('$stack', '$thrown');
      expect((a.peek(), b.peek()), (0, 0));
    });

    test('transact_and_publish_are_interchangeable', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final a = signal(0), b = signal(0);
      bool accept(bool Function(void Function(Tx)) commit, int value) =>
          commit((p) {
            p.set(a, value);
            p.set(b, value * 2);
          });
      expect(accept(transact, 1), isTrue);
      expect((a.peek(), b.peek()), (1, 2));
      final outcome = await owner.slot().run((t) async => accept(t.publish, 3));
      expect((outcome as Done).value, isTrue);
      expect((a.peek(), b.peek()), (3, 6));
    });

    test('staging_rejects_bare_writes_and_nested_commits', () async {
      final x = signal(0);
      expect(
        () => transact((p) => x.value = 1),
        failsWith('RILL_WRITE_IN_COMPUTATION'),
      );
      expect(
        () => transact((p) => transact((q) => q.set(x, 1))),
        failsWith('RILL_WRITE_IN_COMPUTATION'),
      );
      final owner = Scope();
      addTearDown(owner.dispose);
      final outcome = await owner.slot().run(
        (t) async => transact((p) => t.publish((q) => q.set(x, 1))),
      );
      expect(outcome, failedWith('RILL_WRITE_IN_COMPUTATION'));
      expect(x.peek(), 0);
    });

    test('staging_rejects_invalidate_before_any_launch', () async {
      var fetches = 0;
      final q = computedAsync<int>((_) async => ++fetches);
      addTearDown(effect(() => q.value, (_, _, _) {}));
      await q.settled();
      final owner = Scope();
      addTearDown(owner.dispose);
      final outcome = await owner.slot().run((t) async {
        t.publish((p) {
          q.invalidate();
          throw const FormatException('stage failed later');
        });
      });
      expect(outcome, failedWith('RILL_WRITE_IN_COMPUTATION'));
      await drain();
      expect(fetches, 1, reason: 'nothing was launched');
    });

    test('staging_rejects_starting_a_task', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final other = owner.slot();
      final revision = nodeRevision(other.busy);
      final outcome = await owner.slot().run((t) async {
        await drain();
        t.publish((p) => other.run((_) async => 1));
      });
      expect(outcome, failedWith('RILL_WRITE_IN_COMPUTATION'));
      expect(nodeRevision(other.busy), revision);
    });

    test('transact_in_a_computation_throws', () {
      final x = signal(0);
      final c = computed(() => transact((p) => p.set(x, 1)));
      expect(c.peek, failsWith('RILL_WRITE_IN_COMPUTATION'));
      final errors = <Object>[];
      Rill.onError = (error, _) => errors.add(error);
      addTearDown(() => Rill.onError = null);
      final stop = effect(() => transact((p) => p.set(x, 2)), (_, _, _) {});
      addTearDown(stop);
      expect('$errors', contains('RILL_WRITE_IN_COMPUTATION'));
      expect(x.peek(), 0);
    });

    test('read_during_staging_is_commit_time', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot(onBusy: OnBusy.parallel);
      final labels = signal(const <String, String>{});
      final first = Completer<void>(), second = Completer<void>();
      Future<Outcome<bool>> ask(
        Completer<void> reply,
        Map<String, String> got,
      ) => slot.run((t) async {
        await reply.future;
        return t.publish((p) => p.set(labels, {...labels.peek(), ...got}));
      });
      final a = ask(first, {'a': '1'}), b = ask(second, {'b': '2'});
      second.complete();
      await b;
      first.complete();
      await a;
      expect(labels.peek(), {'a': '1', 'b': '2'});
    });
  });

  group('savepoints', () {
    test('part_exception_rolls_back_and_rethrows_original_stack', () {
      final kept = signal(0), dropped = signal(0);
      final failure = const FormatException('bad');
      late StackTrace thrown;
      StackTrace? caught;
      final committed = transact((p) {
        try {
          p.part(() {
            p.set(dropped, 1);
            try {
              throw failure;
            } on FormatException catch (_, s) {
              thrown = s;
              rethrow;
            }
          });
        } on FormatException catch (e, s) {
          expect(e, same(failure));
          caught = s;
        }
        p.set(kept, 1);
      });
      expect(committed, isTrue);
      expect('$caught', '$thrown');
      expect((kept.peek(), dropped.peek()), (1, 0));
    });

    test('part_exception_uncaught_fails_the_whole_commit', () {
      final kept = signal(0);
      expect(
        () => transact((p) {
          p.set(kept, 1);
          p.part(() => throw const FormatException('bad'));
        }),
        throwsFormatException,
      );
      expect(kept.peek(), 0);
    });

    test('part_unmet_returns_false', () {
      final source = signal(0), a = signal(0), b = signal(0);
      final asked = Unchanged(source);
      source.value = 1;
      late bool kept;
      final committed = transact((p) {
        kept = p.part(() {
          p.require(asked);
          p.set(a, 1);
        });
        p.set(b, 1);
      });
      expect((committed, kept, a.peek(), b.peek()), (true, false, 0, 1));
    });

    test('catch_all_in_stage_cannot_swallow_require', () {
      final source = signal(0), target = signal(0);
      final asked = Unchanged(source);
      source.value = 1;
      final committed = transact((p) {
        try {
          p.require(asked);
          p.set(target, 1);
        } on Object {
          // Nothing to swallow: require does not throw.
        }
      });
      expect((committed, target.peek()), (false, 0));
    });

    test('part_broken_after_returning_true_fails_the_commit', () {
      var backing = 1;
      final bridge = bindingSignal<int>(backing, sample: () => backing);
      final asked = Unchanged(bridge);
      final a = signal(0), b = signal(0);
      late bool kept;
      final committed = transact((p) {
        kept = p.part(() {
          p.require(asked);
          p.set(a, 1);
        });
        backing = 2; // what the part's condition reads changes afterwards
        p.set(b, 1);
      });
      expect(kept, isTrue);
      expect(committed, isFalse, reason: 'a kept part is never dropped');
      expect((a.peek(), b.peek()), (0, 0));
    });
  });

  group('outcomes and handles', () {
    test('stale_reasons_are_superseded_and_owner_disposed_only', () {
      expect(StaleReason.values, [
        StaleReason.superseded,
        StaleReason.ownerDisposed,
      ]);
    });

    test('skip_returns_skipped', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot(onBusy: OnBusy.skip);
      final gate = Completer<int>();
      var runs = 0;
      final first = slot.run((_) => gate.future);
      final skipped = await slot.run((_) async => ++runs);
      expect(skipped, isA<Skipped<int>>());
      expect(runs, 0);
      gate.complete(1);
      expect(await first, isA<Done<int>>());
    });

    test('skipped_rechecks_the_owner_at_delivery', () async {
      final owner = Scope();
      final slot = owner.slot(onBusy: OnBusy.skip);
      final gate = Completer<int>();
      final first = slot.run((_) => gate.future);
      final skipped = slot.run((_) async => 2);
      owner.dispose();
      expect(await skipped, stale(StaleReason.ownerDisposed));
      expect(await first, stale(StaleReason.ownerDisposed));
      gate.complete(1);
    });

    test('nested_run_in_same_owner_tree_cancels_with_owner', () async {
      final session = Scope();
      final steps = session.child();
      final outer = session.slot(), inner = steps.slot();
      final gate = Completer<int>();
      late Future<Outcome<int>> nested;
      final flow = outer.run((t) {
        nested = inner.run((_) => gate.future);
        return gate.future;
      });
      session.dispose();
      expect(await flow, stale(StaleReason.ownerDisposed));
      expect(await nested, stale(StaleReason.ownerDisposed));
      gate.complete(1);
    });

    test('publish_after_body_finished_reports_closed', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      late Task escaped;
      final outcome = await owner.slot().run((t) async {
        escaped = t;
      });
      expect(outcome, isA<Done<void>>());
      expect(escaped.alive, isFalse);
      expect(
        () => escaped.publish((p) {}),
        failsWith('RILL_CLOSED_PUBLICATION'),
      );
    });

    test('superseded_task_publishes_false_without_closed_diagnostic', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot();
      final rpc = Completer<void>();
      final x = signal(0);
      final log = <String>[];
      final first = slot.run((t) async {
        await rpc.future;
        log.add('publish=${t.publish((p) => p.set(x, 1))}');
      });
      final second = slot.run((t) async => 2);
      expect(await first, stale(StaleReason.superseded));
      log.add('delivered');
      rpc.complete();
      await drain();
      expect(log, ['delivered', 'publish=false']);
      expect(x.peek(), 0);
      await second;
    });

    test('a body that throws after supersession stays Stale', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot();
      final rpc = Completer<void>();
      final first = slot.run((t) async {
        await rpc.future;
        throw StateError('late');
      });
      unawaited(slot.run((_) async {}));
      expect(await first, stale(StaleReason.superseded));
      rpc.complete();
      await drain();
    });
  });

  group('delivery decides', () {
    test('owner_disposed_before_caller_resumes_delivers_stale', () async {
      final owner = Scope();
      final slot = owner.slot(onBusy: OnBusy.parallel);
      final done = Completer<void>();
      final future = slot.run((t) async {
        await done.future;
        return 42;
      });
      done.complete();
      Future<void>.microtask(owner.dispose);
      expect(await future, stale(StaleReason.ownerDisposed));
    });

    test('caller_resumes_in_delivery_microtask', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot();
      final gate = Completer<void>();
      final log = <String>[];
      Future<Outcome<int>> wrapper() async {
        final outcome = await slot.run((t) async {
          await gate.future;
          // Runs after the body ends but before delivery; it queues the
          // dispose behind the delivery microtask.
          scheduleMicrotask(
            () => scheduleMicrotask(() {
              log.add('dispose');
              owner.dispose();
            }),
          );
          return 1;
        });
        log.add('wrapper ${outcome.runtimeType} alive=${!owner.disposed}');
        return outcome;
      }

      final outer = wrapper().then((outcome) {
        log.add('outer ${outcome.runtimeType} alive=${!owner.disposed}');
      });
      gate.complete();
      await outer;
      await drain();
      expect(log, [
        'wrapper Done<int> alive=true',
        'outer Done<int> alive=true',
        'dispose',
      ]);
    });

    test('superseded_caller_not_resumed_inside_new_run', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot();
      final log = <String>[];
      final first = slot
          .run((_) => Completer<int>().future)
          .then((outcome) => log.add('resumed ${outcome.runtimeType}'));
      final second = slot.run((_) async => 2);
      log.add('after run');
      await first;
      expect(log, ['after run', 'resumed Stale<int>']);
      await second;
    });

    test('delivery_never_inside_a_batch', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final gate = Completer<int>.sync();
      bool? open;
      final future = owner
          .slot()
          .run((_) => gate.future)
          .then((_) => open = bindingBoundaryOpen);
      batch(() => gate.complete(1));
      await future;
      expect(open, isFalse);
    });

    test('queued_body_never_starts_inside_another_batch', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final queue = owner.slot(onBusy: OnBusy.queue);
      final gate = Completer<int>.sync();
      var inBatch = false;
      bool? secondInBatch;
      final first = queue.run((_) => gate.future);
      final second = queue.run((_) async {
        secondInBatch = inBatch;
        return 2;
      });
      batch(() {
        inBatch = true;
        gate.complete(1);
        inBatch = false;
      });
      expect(secondInBatch, isNull, reason: 'bookkeeping waits a microtask');
      expect(queue.busy.peek(), isTrue);
      await Future.wait([first, second]);
      expect(secondInBatch, isFalse);
      expect(queue.busy.peek(), isFalse);
    });

    test('task_finishing_inside_a_batch_defers_bookkeeping', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final queue = owner.slot(onBusy: OnBusy.queue);
      var inBatch = false;
      bool? secondInBatch;
      late Future<Outcome<int>> first, second;
      batch(() {
        inBatch = true;
        final gate = Completer<int>.sync();
        first = queue.run((_) => gate.future);
        second = queue.run((_) async {
          secondInBatch = inBatch;
          return 2;
        });
        gate.complete(1);
        inBatch = false;
      });
      await Future.wait([first, second]);
      expect(secondInBatch, isFalse);
    });

    test('queued_next_body_starts_before_previous_caller_resumes', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final queue = owner.slot(onBusy: OnBusy.queue);
      final log = <String>[];
      final first = queue.run((_) async => 1).then((_) => log.add('resumed'));
      final second = queue.run((_) async {
        log.add('second starts');
        return 2;
      });
      await Future.wait([first, second]);
      expect(log, ['second starts', 'resumed']);
    });

    test('joined_callers_share_one_verdict', () async {
      final owner = Scope();
      final slot = owner.slot();
      final gate = Completer<int>();
      final log = <String>[];
      final a = slot.run((_) => gate.future, key: 'k');
      final b = slot.run((_) => gate.future, key: 'k');
      expect(b, same(a));
      final first = a.then((outcome) {
        log.add('first ${outcome.runtimeType}');
        owner.dispose();
      });
      final second = b.then((outcome) {
        log.add('second ${outcome.runtimeType} disposed=${owner.disposed}');
      });
      gate.complete(1);
      await Future.wait([first, second]);
      expect(log, ['first Done<int>', 'second Done<int> disposed=true']);
    });

    test('finished_body_superseded_before_delivery_is_done', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot();
      final gate = Completer<void>();
      final x = signal(0);
      late bool published;
      late Future<Outcome<int>> later;
      final first = slot.run((t) async {
        await gate.future;
        published = t.publish((p) => p.set(x, 1));
        scheduleMicrotask(() => later = slot.run((_) async => 2));
        return 1;
      });
      gate.complete();
      final outcome = await first;
      expect(published, isTrue);
      expect((outcome as Done).value, 1);
      expect(await later, isA<Done<int>>());
    });
  });

  group('diagnostics', () {
    test('why_reports_refusing_condition', () async {
      final owner = Scope(name: 'store');
      addTearDown(owner.dispose);
      final slot = owner.slot(name: 'sweep');
      final round = signal(0, name: 'round');
      final asked = Unchanged(round);
      round.value = 1;
      expect(transact((p) => p.require(asked)), isFalse);
      final gate = Completer<void>();
      final first = slot.run((t) async {
        await gate.future;
        return t.publish((p) {});
      });
      unawaited(slot.run((_) async => false));
      gate.complete();
      await first;
      await drain();
      final refusals = RillDebug.refusals();
      expect(refusals.map((r) => r.condition), ['unchanged', 'task']);
      expect(refusals.first.source!.name, 'round');
      expect(refusals.first.task, isNull);
      expect(refusals.last.task!.label, 'sweep.task');
      expect(refusals.last.reason, 'superseded');
      expect(RillDebug.refusals('round'), hasLength(1));
      final json = RillDebug.whyJson();
      expect((json['refusals'] as List).length, 2);
      expect('${refusals.first}', contains('Unchanged(round)'));
    });
  });

  group('recipe', () {
    /// The Turn recipe from the command layer's design, kept as a test so the example
    /// stays true: later-asked wins across slots, atomically with the content.
    test('turn_recipe_lets_the_later_ask_win', () async {
      final turn = _Turn();
      final owner = Scope();
      addTearDown(owner.dispose);
      final shown = signal('');
      final older = Completer<void>(), newer = Completer<void>();
      Future<Outcome<bool>> refresh(
        Slot slot,
        Completer<void> reply,
        String v,
      ) {
        final ticket = turn.take();
        return slot.run((t) async {
          await reply.future;
          return t.publish((p) => turn.stage(p, ticket, () => p.set(shown, v)));
        });
      }

      final a = refresh(owner.slot(), older, 'older');
      final b = refresh(owner.slot(), newer, 'newer');
      newer.complete();
      await b;
      older.complete();
      await a;
      expect(shown.peek(), 'newer');
    });
  });
}

final class _Turn {
  final _shown = signal(0);
  int _asked = 0;
  int take() => ++_asked;
  bool stage(Tx tx, int ticket, void Function() body) {
    final snap = Unchanged(_shown);
    if (ticket <= _shown.peek()) return false;
    return tx.part(() {
      tx.require(snap);
      tx.set(_shown, ticket);
      body();
    });
  }
}

// Staging events, late commits and refusal records.
void stagingEventsLateCommitsAndRefusals() {
  group('staging events, late commits and refusal records', () {
    test('emit_during_staging_throws', () {
      final notices = Events<String>(name: 'notices');
      final seen = <String>[];
      addTearDown(notices.listen(seen.add));
      expect(
        () => transact((tx) {
          notices.emit('leaked');
          throw const FormatException('stage failed');
        }),
        failsWith('RILL_WRITE_IN_COMPUTATION'),
      );
      expect(seen, isEmpty);
      // Staged with the commit, it goes out once the commit installs.
      transact((tx) => tx.emit(notices, 'staged'));
      expect(seen, ['staged']);
    });

    test('transact_in_a_lapsed_task_reports_late_write', () async {
      final warnings = <String>[];
      diagnosticHook = (code, label) => warnings.add('$code:$label');
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot();
      final x = signal(0, name: 'x'), y = signal(0, name: 'y');
      final z = signal(0, name: 'z');
      // A reaction the late commit flushes writes through transact in the
      // same zone: the write is the reaction's, not the task's.
      addTearDown(
        effect(() => y.value, (value, _, _) {
          transact((tx) => tx.set(z, value));
        }),
      );
      final gate = Completer<void>();
      final first = slot.run((t) async {
        await gate.future;
        x.value = 1;
        transact((tx) => tx.set(y, 1));
      });
      unawaited(slot.run((_) async {}));
      gate.complete();
      await first;
      await drain();
      expect(warnings, ['RILL_LATE_WRITE:x', 'RILL_LATE_WRITE:y']);
      expect((y.peek(), z.peek()), (1, 1));
    });

    test('transact_in_a_live_task_is_not_late', () async {
      final warnings = <String>[];
      diagnosticHook = (code, label) => warnings.add('$code:$label');
      final owner = Scope();
      addTearDown(owner.dispose);
      final y = signal(0, name: 'y');
      await owner.slot().run((t) async {
        await drain();
        transact((tx) => tx.set(y, 1));
      });
      expect(warnings, isEmpty);
      expect(y.peek(), 1);
    });

    Future<Slot> refuseIn(Scope owner, String name) async {
      final slot = owner.slot(name: name);
      final gate = Completer<void>();
      final first = slot.run((t) async {
        await gate.future;
        t.publish((tx) {});
      });
      unawaited(slot.run((_) async {}));
      gate.complete();
      await first;
      await drain();
      return slot;
    }

    test('refusals_filter_by_slot_and_slot_name', () async {
      final owner = Scope(name: 'store');
      addTearDown(owner.dispose);
      final sweep = await refuseIn(owner, 'sweep');
      final other = await refuseIn(owner, 'other');
      expect(RillDebug.refusals(), hasLength(2));
      expect(RillDebug.refusals(sweep).single.task!.label, 'sweep.task');
      expect(RillDebug.refusals('sweep').single.task!.label, 'sweep.task');
      expect(RillDebug.refusals(other).single.task!.label, 'other.task');
      expect(RillDebug.refusals('sweep.task'), hasLength(1));
    });

    test('capacity_and_limit_trim_refusals', () {
      final capacity = RillDebug.capacity;
      addTearDown(() => RillDebug.capacity = capacity);
      final s = signal(0, name: 's');
      final asked = Unchanged(s);
      s.value = 1;
      for (var i = 0; i < 3; i++) {
        expect(transact((tx) => tx.require(asked)), isFalse);
      }
      expect(RillDebug.refusals(), hasLength(3));
      final all = RillDebug.whyJson()['refusals'] as List;
      final limited = RillDebug.whyJson(limit: 1)['refusals'] as List;
      expect(limited, [all.last]);
      RillDebug.capacity = 1;
      expect(RillDebug.refusals().single.seq, (all.last as Map)['seq']);
    });
  });
}

/// The part a forced GC cannot show: a link cut by
/// cancellation keeps no Task (test/process: the Scope and the Task are
/// collected), yet a handle someone still holds learns when the late Future
/// settles that the body ended.
void heldHandlesOfCancelledTasks() {
  group('held handles of cancelled tasks', () {
    test(
      'held_handle_of_a_cancelled_task_closes_when_its_future_settles',
      () async {
        final owner = Scope();
        final sdkReady = Completer<int>();
        late Task held;
        final outcome = owner.slot().run((t) {
          held = t;
          return sdkReady.future;
        });
        owner.dispose();
        expect(await outcome, stale(StaleReason.ownerDisposed));
        // Invalidated but not ended: refused without the closed diagnostic.
        expect(held.publish((_) {}), isFalse);
        sdkReady.complete(1);
        await drain();
        expect(
          () => held.publish((_) {}),
          failsWith('RILL_CLOSED_PUBLICATION'),
        );
      },
    );

    test(
      'held_handle_of_a_cancelled_task_closes_when_its_future_fails',
      () async {
        final owner = Scope();
        final rpc = Completer<int>();
        late Task held;
        final slot = owner.slot();
        final first = slot.run((t) {
          held = t;
          return rpc.future;
        });
        addTearDown(owner.dispose);
        unawaited(slot.run((_) async => 0));
        expect(await first, stale(StaleReason.superseded));
        rpc.completeError(StateError('late'));
        await drain();
        expect(
          () => held.publish((_) {}),
          failsWith('RILL_CLOSED_PUBLICATION'),
        );
      },
    );
  });
}
