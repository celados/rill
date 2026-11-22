import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:rill/debug.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:test/test.dart';

// Async derivations: one case per rule, and design and review probes turned
// into regressions.

Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String show(AsyncState<Object?> state) => switch (state) {
  AsyncLoading() => 'loading',
  AsyncData(:final value, :final refreshing, :final stale) =>
    'data($value${refreshing ? ',refreshing' : ''}${stale ? ',stale' : ''})',
  AsyncError(:final error, :final hasPrevious, :final previous) =>
    'error($error${hasPrevious ? ',prev=$previous' : ''})',
};

/// A plain observer standing in for a Reactive element.
final class Reader extends Subscriber {
  Reader([this.onChange]);
  final void Function(Reader)? onChange;
  int reads = 0;

  @override
  void notify() => afterFlush(this, () {
    if (!disposed && changed()) onChange?.call(this);
  });

  R read<R>(R Function() fn) {
    reads++;
    return track(fn);
  }
}

/// Observes [query] the way a Reactive would; returns the states it built.
(List<String>, void Function()) observe(AsyncComputed<Object?> query) {
  final log = <String>[];
  final reader = Reader((r) => log.add(show(r.read(() => query.value))));
  log.add(show(reader.read(() => query.value)));
  return (log, reader.dispose);
}

void main() {
  tearDown(() {
    Rill.onError = null;
    diagnosticHook = null;
  });

  group('AsyncState', () {
    test('public const constructors, hasPrevious and ==', () {
      const loading = AsyncLoading<int>();
      expect(loading, const AsyncLoading<int>());
      expect(
        const AsyncData(1, refreshing: true),
        const AsyncData(1, refreshing: true),
      );
      expect(const AsyncData(1) == const AsyncData(1, stale: true), isFalse);
      final error = StateError('e');
      final stack = StackTrace.current;
      expect(AsyncError<int>(error, stack), AsyncError<int>(error, stack));
      expect(
        AsyncError<int>(StateError('e'), stack) ==
            AsyncError<int>(error, stack),
        isFalse,
      );
      final none = AsyncError<int?>(error, stack);
      final nullPrevious = AsyncError<int?>.withPrevious(error, stack, null);
      expect((none.hasPrevious, nullPrevious.hasPrevious), (false, true));
      expect(none == nullPrevious, isFalse);
      expect(
        Readable.constant(const AsyncLoading<String>()).peek(),
        isA<AsyncLoading<String>>(),
      );
      final mock = signal<AsyncState<String>>(const AsyncData('mock'));
      expect(mock.value.valueOrNull, 'mock');
    });

    test('valueOrNull, requireValue and map follow hasPrevious', () {
      final error = StateError('net');
      final stack = StackTrace.fromString('original');
      expect(const AsyncLoading<int>().valueOrNull, isNull);
      expect(
        () => const AsyncLoading<int>().requireValue,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            startsWith('RILL_NO_VALUE'),
          ),
        ),
      );
      expect(const AsyncData(3).requireValue, 3);
      final failed = AsyncError<int>.withPrevious(error, stack, 4);
      expect(failed.valueOrNull, 4);
      try {
        failed.requireValue;
        fail('requireValue must rethrow');
      } on StateError catch (caught, caughtStack) {
        expect(caught, same(error));
        expect('$caughtStack', '$stack');
      }
      expect(
        failed.map((v) => v * 2),
        AsyncError<int>.withPrevious(error, stack, 8),
      );
      expect(
        (AsyncError<int>(
          error,
          stack,
        ).map((v) => '$v') as AsyncError<String>).hasPrevious,
        isFalse,
      );
      expect(
        const AsyncData(2, refreshing: true, stale: true).map((v) => v + 1),
        const AsyncData(3, refreshing: true, stale: true),
      );
      expect(const AsyncLoading<int>().map((v) => v), isA<AsyncLoading<int>>());
    });

    test('all merges by position', () {
      final e1 = StateError('1'), e2 = StateError('2');
      final s = StackTrace.current;
      expect(
        (const AsyncData(1), const AsyncData('a')).all,
        const AsyncData((1, 'a')),
      );
      expect(
        (
          const AsyncData(1, refreshing: true),
          const AsyncData(2, stale: true),
        ).all,
        const AsyncData((1, 2), refreshing: true, stale: true),
      );
      expect(
        (const AsyncData(1), const AsyncLoading<int>()).all,
        isA<AsyncLoading<(int, int)>>(),
      );
      final firstError =
          (AsyncError<int>(e1, s), AsyncError<int>(e2, s)).all
              as AsyncError<(int, int)>;
      expect((firstError.error, firstError.hasPrevious), (e1, false));
      final withPrevious =
          (
                AsyncError<int>.withPrevious(e1, s, 1),
                const AsyncData(2),
                const AsyncData(3),
              ).all
              as AsyncError<(int, int, int)>;
      expect(
        (withPrevious.hasPrevious, withPrevious.previous),
        (true, (1, 2, 3)),
      );
      expect(
        (const AsyncLoading<int>(), AsyncError<int>(e2, s)).all,
        isA<AsyncError<(int, int)>>(),
      );
      expect(
        (
          const AsyncData(1),
          const AsyncData(2),
          const AsyncData(3),
          const AsyncData(4),
          const AsyncData(5),
          const AsyncData(6),
        ).all.valueOrNull,
        (1, 2, 3, 4, 5, 6),
      );
      expect(<AsyncState<int>>[].all.valueOrNull, isEmpty);
      expect(
        [const AsyncData(1), const AsyncData(2, refreshing: true)].all,
        isA<AsyncData<List<int>>>()
            .having((s) => s.value, 'value', [1, 2])
            .having((s) => s.refreshing, 'refreshing', isTrue),
      );
    });
  });

  group('supersession', () {
    test(
      'an input change supersedes and cancels; old answers never land',
      () async {
        final id = signal(0);
        final flights = <(Query, Completer<int>)>[];
        final query = computedAsync((q) {
          id.value;
          final answer = Completer<int>();
          flights.add((q, answer));
          return answer.future;
        });
        final (log, dispose) = observe(query);
        addTearDown(dispose);
        id.value = 1;
        await flights[0].$1.cancelled;
        id.value = 2;
        await flights[1].$1.cancelled;
        flights[1].$2.completeError(StateError('stale'));
        flights[0].$2.complete(100);
        await settle();
        expect(query.peek(), isA<AsyncLoading<int>>());
        flights[2].$2.complete(20);
        await settle();
        expect(log, ['loading', 'data(20)']);
      },
    );

    test('a synchronous completion inside a write batch cannot land', () async {
      final source = signal(0);
      final answers = <Completer<int>>[];
      final query = computedAsync((_) {
        source.value;
        final answer = Completer<int>.sync();
        answers.add(answer);
        return answer.future;
      });
      final values = <int>[];
      addTearDown(
        effect(() => query.value, (state, _, _) {
          if (state is AsyncData<int>) values.add(state.value);
        }),
      );
      batch(() {
        source.value = 1;
        answers.first.complete(99);
      });
      await settle();
      expect(query.peek(), isA<AsyncLoading<int>>());
      expect(values, isEmpty);
      answers.last.complete(7);
      await settle();
      expect(values, [7]);
    });

    test('overlapping independent flights settle independently', () async {
      final a = Completer<int>(), b = Completer<int>();
      final left = computedAsync((_) => a.future);
      final right = computedAsync((_) => b.future);
      final l = left.settled(), r = right.settled();
      b.complete(8);
      expect(await r, const AsyncData(8));
      expect(left.peek(), isA<AsyncLoading<int>>());
      a.complete(7);
      expect(await l, const AsyncData(7));
    });

    test('a stream switches its dependencies and cancels the replaced subscription', () async {
      final source = signal(false);
      final left = signal(0), right = signal(0);
      final streams = <StreamController<int>>[];
      final cancellations = <int>[];
      final query = computedStream((q) {
        if (source.value) {
          right.value;
        } else {
          left.value;
        }
        final index = streams.length;
        final controller = StreamController<int>(
          onCancel: () => cancellations.add(index),
        );
        streams.add(controller);
        return controller.stream;
      });
      final (log, dispose) = observe(query);
      source.value = true;
      expect(cancellations, [0]);
      left.value = 9;
      expect(streams, hasLength(2));
      right.value = 1;
      expect(cancellations, [0, 1]);
      streams.last.add(8);
      await settle();
      expect(log.last, 'data(8)');
      dispose();
      await settle();
      expect(cancellations, [0, 1, 2]);
      expect(activeQueryStreamCount, 0);
      for (final stream in streams) {
        await stream.close();
      }
    });
  });

  group('state, new question and refresh', () {
    test('peek is a state, never throws; tracked reads see loading', () async {
      final pending = Completer<int>();
      final query = computedAsync((_) => pending.future);
      expect(query.peek(), isA<AsyncLoading<int>>());
      final fallback = computed(() => query.value.valueOrNull ?? -1);
      final values = <int>[];
      addTearDown(
        effect(() => fallback.value, (value, _, _) {
          values.add(value);
        }),
      );
      pending.complete(5);
      await settle();
      expect(values, [-1, 5]);
    });

    test(
      'a new question can show A while loading but B failing has no previous',
      () async {
        final id = signal('A');
        final starts = <String>[];
        final answers = <Completer<int>>[];
        final query = computedAsync((_) {
          starts.add(id.value);
          final next = Completer<int>();
          answers.add(next);
          return next.future;
        });
        final (log, dispose) = observe(query);
        addTearDown(dispose);
        answers[0].complete(7);
        await settle();
        id.value = 'B';
        expect(show(query.peek()), 'data(7,refreshing,stale)');
        final error = StateError('B');
        final stack = StackTrace.fromString('B failure');
        answers[1].completeError(error, stack);
        await settle();
        final failed = query.peek() as AsyncError<int>;
        expect(failed.hasPrevious, isFalse);
        expect(failed.error, same(error));
        expect('${failed.stack}', '$stack');
        final retry = query.refresh();
        expect(query.peek(), isA<AsyncLoading<int>>());
        answers[2].complete(7);
        expect(await retry, const AsyncData(7));
        expect(starts, ['A', 'B', 'B']);
        expect(log, [
          'loading',
          'data(7)',
          'data(7,refreshing,stale)',
          'error(Bad state: B)',
          'loading',
          'data(7)',
        ]);
      },
    );

    test('a same-question refresh keeps the value; a failed refresh keeps it as previous', () async {
      final answers = <Completer<int>>[];
      final query = computedAsync((_) {
        final next = Completer<int>();
        answers.add(next);
        return next.future;
      });
      final (_, dispose) = observe(query);
      addTearDown(dispose);
      answers.first.complete(9);
      await settle();
      final refresh = query.refresh();
      expect(show(query.peek()), 'data(9,refreshing)');
      answers.last.completeError(StateError('refresh'));
      final failure = await refresh as AsyncError<int>;
      expect((failure.hasPrevious, failure.previous), (true, 9));
      final recovery = query.refresh();
      answers.last.complete(9);
      expect(await recovery, const AsyncData(9));
    });

    test(
      'concurrent refresh waiters settle on the replacement landing',
      () async {
        final flights = <(Query, Completer<int>)>[];
        final query = computedAsync((q) {
          final answer = Completer<int>();
          flights.add((q, answer));
          return answer.future;
        });
        final first = query.refresh();
        final second = query.refresh();
        await flights.first.$1.cancelled;
        flights.first.$2.complete(1);
        flights.last.$2.complete(2);
        expect(await first, const AsyncData(2));
        expect(await second, const AsyncData(2));
      },
    );

    test('equals keeps the old value reference: an equal refresh wakes no value reader', () async {
      var n = 0;
      final query = computedAsync<List<int>>(
        (_) async => [1, 2, ++n > 0 ? 3 : 0],
        equals: Equality.deep,
      );
      final first = await query.refresh() as AsyncData<List<int>>;
      final values = computed(() => query.value.valueOrNull);
      var wakes = 0;
      addTearDown(
        effect(() => values.value, (_, _, _) {
          wakes++;
        }),
      );
      await settle();
      final again = await query.refresh() as AsyncData<List<int>>;
      expect(again.value, same(first.value));
      await settle();
      expect(n, 2);
      expect(wakes, 1);
    });

    test('AsyncError carries the original object and stack', () async {
      final failure = StateError('loader failed');
      final stack = StackTrace.fromString('original loader stack');
      final query = computedAsync<int>((_) => Future.error(failure, stack));
      final state = await query.settled() as AsyncError<int>;
      expect('${state.stack}', '$stack');
      try {
        state.requireValue;
        fail('requireValue rethrows');
      } on StateError catch (error, caughtStack) {
        expect(error, same(failure));
        expect('$caughtStack', '$stack');
      }
    });

    test(
      'streams: an error event does not end the stream; empty streams fail',
      () async {
        final controller = StreamController<int>();
        final query = computedStream((_) => controller.stream);
        final (log, dispose) = observe(query);
        controller.add(1);
        await settle();
        controller.addError(StateError('glitch'));
        await settle();
        controller.add(2);
        await settle();
        expect(log, [
          'loading',
          'data(1)',
          'error(Bad state: glitch,prev=1)',
          'data(2)',
        ]);
        dispose();
        await controller.close();
        final empty = computedStream<int>((_) => const Stream<int>.empty());
        expect(
          await empty.settled(),
          isA<AsyncError<int>>().having(
            (e) => '${e.error}',
            'error',
            contains('RILL_EMPTY_QUERY'),
          ),
        );
      },
    );

    test(
      'tracks the synchronous prefix and diagnoses post-await reads',
      () async {
        final key = signal(1, name: 'key');
        final lateSource = signal(2, name: 'late');
        final gate = Completer<void>();
        final events = <(String, String?)>[];
        diagnosticHook = (code, name) => events.add((code, name));
        var starts = 0;
        final query = computedAsync((_) async {
          starts++;
          final value = key.value;
          await gate.future;
          lateSource.peek();
          untracked(() => lateSource.value);
          return value + lateSource.value;
        });
        final (log, dispose) = observe(query);
        addTearDown(dispose);
        gate.complete();
        await settle();
        expect(log.last, 'data(3)');
        expect(events, [('RILL_READ_AFTER_AWAIT', 'late')]);
        lateSource.value = 4;
        expect(starts, 1);
        key.value = 8;
        await settle();
        expect(starts, 2);
        expect(log.last, 'data(12)');
      },
    );

    test('computedStream: the synchronous fn tracks; an async* body does not and is diagnosed', () async {
      final src = signal(1, name: 'src');
      final events = <(String, String?)>[];
      diagnosticHook = (code, name) => events.add((code, name));
      final sync = computedStream((_) => Stream.value(src.value));
      final star = computedStream<int>((_) async* {
        yield src.value;
      });
      final (syncLog, d1) = observe(sync);
      final (starLog, d2) = observe(star);
      await settle();
      src.value = 2;
      await settle();
      expect(syncLog.last, 'data(2)');
      expect(starLog.last, 'data(1)');
      expect(events, contains(('RILL_READ_AFTER_AWAIT', 'src')));
      d1();
      d2();
    });

    test('q.wait chains streams: the sync fn registers the wait', () async {
      final token = computedAsync((_) async => 't1');
      final room = signal('r1');
      final messages = computedStream((q) {
        final r = room.value;
        final t = q.wait(token);
        return Stream.fromFuture(t).asyncExpand((t) => Stream.value('$r/$t'));
      });
      final (log, dispose) = observe(messages);
      await settle();
      room.value = 'r2';
      await settle();
      expect(log, [
        'loading',
        'data(r1/t1)',
        'data(r1/t1,refreshing,stale)',
        'data(r2/t1)',
      ]);
      dispose();
    });
  });

  group('question, reconcile and derived state', () {
    test('cold_peek_runs_no_user_code; cold_peek_launches_nothing', () async {
      var runs = 0;
      final query = computedAsync((q) {
        runs++;
        return Future.value(1);
      });
      expect(query.peek(), isA<AsyncLoading<int>>());
      await settle();
      expect(runs, 0);
      expect(await query.settled(), const AsyncData(1));
      expect(runs, 1);
    });

    test('first_frame_is_loading_and_siblings_agree', () async {
      final answer = Completer<int>();
      var launches = 0;
      final query = computedAsync((_) {
        launches++;
        return answer.future;
      });
      final (a, da) = observe(query);
      final (b, db) = observe(query);
      expect((a.first, b.first), ('loading', 'loading'));
      expect(launches, 1);
      answer.complete(7);
      await settle();
      expect((a.last, b.last), ('data(7)', 'data(7)'));
      da();
      db();
    });

    test('hot_branch_switch_into_cold_chain_launches', () async {
      final flag = signal(false);
      var launches = 0;
      final query = computedAsync((_) {
        launches++;
        return Future.value(3);
      });
      final mid = computed(() => show(query.value));
      final top = computed(() => flag.value ? mid.value : 'off');
      final seen = <String>[];
      final stop = effect(() => top.value, (v, _, _) {
        seen.add(v);
      });
      expect(launches, 0);
      flag.value = true;
      expect(seen, ['off', 'loading']);
      expect(launches, 1);
      await settle();
      expect(seen.last, 'data(3)');
      stop();
    });

    test(
      'effect_stopped_before_flush_launches_nothing (stop() inside compute)',
      () async {
        var launches = 0;
        final query = computedAsync((_) {
          launches++;
          return Future.value(4);
        });
        final flag = signal(false);
        late void Function() stop;
        stop = effect(() {
          if (flag.value) {
            query.value;
            stop();
          }
          return 0;
        }, (_, _, _) {});
        flag.value = true;
        await settle();
        expect(launches, 0);
        // An effect stopped after it observed did launch once.
        final late = effect(() => query.value, (_, _, _) {});
        late();
        expect(launches, 1);
      },
    );

    test('input_change_while_cold_is_stale_on_first_frame', () async {
      final id = signal(1);
      final query = computedAsync(
        (_) => Future.value(id.value * 10),
        retain: const Duration(seconds: 30),
      );
      final chain = computed(() => show(query.value));
      final first = Reader();
      first.read(() => chain.value);
      await settle();
      expect(first.read(() => chain.value), 'data(10)');
      first.dispose();
      await settle();
      id.value = 2;
      expect(show(query.peek()), 'data(10,refreshing,stale)');
      final second = Reader();
      expect(second.read(() => chain.value), 'data(10,refreshing,stale)');
      await settle();
      expect(second.read(() => chain.value), 'data(20)');
      second.dispose();
    });

    test('cold_invalidated_query_reports_refreshing_without_request', () async {
      var launches = 0;
      final query = computedAsync(
        (_) async => ++launches,
        retain: const Duration(minutes: 1),
      );
      expect(await query.settled(), const AsyncData(1));
      await settle();
      query.invalidate();
      expect(show(query.peek()), 'data(1,refreshing)');
      await settle();
      expect(launches, 1);
      expect(await query.settled(), const AsyncData(2));
    });

    test('query_launch_in_build_joins_nothing', () async {
      Scope? seen;
      final query = computedAsync((_) async {
        seen = Scope();
        return 1;
      });
      final reader = Reader();
      reader.read(() => query.value);
      expect(seen, isNotNull);
      // There is no ambient owner for it to join: a Scope is a root.
      expect(seen!.disposed, isFalse);
      reader.dispose();
      seen!.dispose();
    });

    test(
      'a cold read outside observers is diagnosed once; peek is exempt',
      () async {
        final events = <(String, String?)>[];
        diagnosticHook = (code, name) => events.add((code, name));
        final peeked = computedAsync((_) async => 1, name: 'peeked');
        final read = computedAsync((_) async => 1, name: 'read');
        final settledOne = computedAsync((_) async => 1, name: 'settled');
        peeked.peek();
        read.value;
        read.value;
        await settledOne.settled();
        settledOne.value;
        await settle();
        expect(events, [('RILL_COLD_QUERY_READ', 'read')]);
      },
    );
  });

  group('cooling', () {
    test('unobserved_query_ignores_input_writes', () async {
      final s = signal(0);
      var launches = 0;
      final query = computedAsync((_) {
        launches++;
        return Future.value(s.value);
      });
      final (_, dispose) = observe(query);
      await settle();
      dispose();
      await settle();
      final before = launches;
      s.value = 1;
      s.value = 2;
      s.value = 3;
      await settle();
      expect(launches, before);
      checkGraph([s, query]);
      expect(subscriberCount(s), 0);
    });

    test('cold_computed_reobserved_after_unfinished_load_restarts', () async {
      var launches = 0;
      final query = computedAsync((_) {
        launches++;
        return Completer<int>().future;
      });
      final chain = computed(() => show(query.value));
      final first = Reader();
      expect(first.read(() => chain.value), 'loading');
      expect(launches, 1);
      first.dispose();
      await settle();
      expect(activeQueryCount, 0);
      final second = Reader();
      expect(second.read(() => chain.value), 'loading');
      expect(launches, 2);
      second.dispose();
      await settle();
    });

    test('stream_unsubscribes_a_microtask_after_last_observer', () async {
      var listening = 0;
      final controller = StreamController<int>.broadcast(
        onListen: () => listening++,
        onCancel: () => listening--,
      );
      final query = computedStream((_) => controller.stream);
      final (_, dispose) = observe(query);
      expect(listening, 1);
      dispose();
      expect(
        listening,
        1,
        reason: 'the same synchronous section may re-observe',
      );
      await settle();
      expect(listening, 0);
      expect(query.peek(), isA<AsyncLoading<int>>());
    });

    test('globalkey_reparent_keeps_query: re-observed in the same section, nothing restarts', () async {
      var launches = 0;
      final query = computedAsync((_) {
        launches++;
        return Future.value(1);
      });
      final (_, d1) = observe(query);
      await settle();
      d1();
      final (log, d2) = observe(query);
      await settle();
      expect(launches, 1);
      expect(log, ['data(1)']);
      d2();
    });

    test('in_flight_with_retain_keeps_one_timer; timer_expiry_cancels_and_keeps_good_answer', () {
      fakeAsync((async) {
        var n = 0;
        final answers = <Completer<int>>[];
        final query = computedAsync((q) {
          n++;
          if (n == 1) return Future.value(1);
          final answer = Completer<int>();
          answers.add(answer);
          return answer.future;
        }, retain: const Duration(seconds: 5));
        final (_, d1) = observe(query);
        async.flushMicrotasks();
        query.invalidate();
        async.flushMicrotasks();
        expect(activeQueryCount, 1);
        d1();
        async.flushMicrotasks();
        expect(activeQueryTimerCount, 1);
        expect(async.pendingTimers, hasLength(1));
        async.elapse(const Duration(seconds: 4));
        expect(activeQueryCount, 1);
        async.elapse(const Duration(seconds: 1));
        expect((activeQueryCount, activeQueryTimerCount), (0, 0));
        expect(show(query.peek()), 'data(1,refreshing)');
        answers.single.complete(2);
        async.flushMicrotasks();
        expect(show(query.peek()), 'data(1,refreshing)');
        final (log, d2) = observe(query);
        async.flushMicrotasks();
        expect(
          answers,
          hasLength(2),
          reason: 'the cancelled attempt is asked again',
        );
        answers.last.complete(3);
        async.flushMicrotasks();
        expect(log, ['data(1,refreshing)', 'data(3)']);
        d2();
        async.flushMicrotasks();
      });
    });

    test('retained_answer_within_ttl_no_request; expired_retained_answer_revalidates_swr', () {
      fakeAsync((async) {
        var n = 0;
        final query = computedAsync(
          (_) => Future.value(++n),
          retain: const Duration(seconds: 5),
        );
        final (_, d1) = observe(query);
        async.flushMicrotasks();
        d1();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(seconds: 4));
        final (within, d2) = observe(query);
        async.flushMicrotasks();
        expect(within, ['data(1)']);
        expect(n, 1);
        d2();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        expect(show(query.peek()), 'data(1,refreshing)');
        final (log, d3) = observe(query);
        async.flushMicrotasks();
        expect(log, ['data(1,refreshing)', 'data(2)']);
        d3();
      });
    });

    test('cooled_error_retries_on_return', () async {
      var fail = true;
      final query = computedAsync(
        (_) => fail ? Future<int>.error('net') : Future.value(1),
        retain: const Duration(seconds: 30),
      );
      final (log1, d1) = observe(query);
      await settle();
      expect(log1.last, 'error(net)');
      d1();
      await settle();
      fail = false;
      expect(query.peek(), isA<AsyncLoading<int>>());
      final (log2, d2) = observe(query);
      await settle();
      expect(log2, ['loading', 'data(1)']);
      d2();
    });

    test('keepalive_scope_skips_cooling; keepalive_scope_disposed_with_observer_does_not_cancel', () async {
      final lease = Scope();
      final controller = StreamController<int>();
      final query = computedStream((_) => controller.stream, keepAlive: lease);
      final (_, d1) = observe(query);
      controller.add(1);
      await settle();
      d1();
      await settle();
      expect(activeQueryStreamCount, 1);
      expect(query.peek(), const AsyncData(1));
      final (log, d2) = observe(query);
      lease.dispose();
      await settle();
      expect(activeQueryStreamCount, 1);
      controller.add(2);
      await settle();
      expect(log, ['data(1)', 'data(2)']);
      d2();
      await settle();
      expect(activeQueryStreamCount, 0);
      await controller.close();
      expect(
        () => computedAsync((_) async => 1, keepAlive: lease),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('RILL_DISPOSED'),
          ),
        ),
      );
    });

    test('keepalive_still_retries_cooled_error', () async {
      final lease = Scope();
      addTearDown(lease.dispose);
      var n = 0;
      final query = computedAsync<int>(
        (_) => ++n == 1 ? Future.error('net') : Future.value(n),
        keepAlive: lease,
      );
      final (_, d1) = observe(query);
      await settle();
      d1();
      await settle();
      expect(query.peek(), isA<AsyncLoading<int>>());
      final (log, d2) = observe(query);
      await settle();
      expect(log, ['loading', 'data(2)']);
      d2();
    });

    test('pulse_input_stops_through_wait_chain', () async {
      final pulse = signal(0);
      final upstream = computedAsync((_) => Future.value(pulse.value));
      final downstream = computedAsync((q) async => await q.wait(upstream) + 1);
      final reader = Reader();
      reader.read(() => downstream.value);
      await settle();
      expect(
        hasVisibleConsumer(pulse, (sub) => identical(sub, reader)),
        isTrue,
      );
      reader.dispose();
      await settle();
      expect(
        hasVisibleConsumer(pulse, (sub) => identical(sub, reader)),
        isFalse,
      );
      expect(subscriberCount(pulse), 0);
    });
  });

  group('waiting', () {
    test('diamond_wait_never_pairs_new_input_with_old_answer', () async {
      final s = signal(1);
      final a = computedAsync((_) => Future.value(s.value * 100), name: 'a');
      final pairs = <String>[];
      final down = computedAsync((q) async {
        final sv = s.value;
        final av = await q.wait(a);
        pairs.add('$sv/$av');
        return '$sv/$av';
      }, name: 'down');
      final (log, dispose) = observe(down);
      await settle();
      s.value = 2;
      await settle();
      expect(pairs, ['1/100', '2/200']);
      expect(log.last, 'data(2/200)');
      dispose();
    });

    test('two_upstreams_land_downstream_runs_once', () async {
      final ca = Completer<int>(), cb = Completer<int>();
      final a = computedAsync((_) => ca.future);
      final b = computedAsync((_) => cb.future);
      var runs = 0;
      final down = computedAsync((q) async {
        runs++;
        final (x, y) = await (q.wait(a), q.wait(b)).wait;
        return x + y;
      });
      final (log, dispose) = observe(down);
      ca.complete(1);
      await settle();
      cb.complete(2);
      await settle();
      expect(runs, 1);
      expect(log, ['loading', 'data(3)']);
      dispose();
    });

    test('upstream_equal_refresh_no_rerun', () async {
      final a = computedAsync((_) => Future.value(5));
      var runs = 0;
      final down = computedAsync((q) async {
        runs++;
        return await q.wait(a) + 1;
      });
      final (log, dispose) = observe(down);
      await settle();
      a.invalidate();
      await settle();
      expect(runs, 1);
      expect(log, ['loading', 'data(6)']);
      dispose();
    });

    test(
      'stream_upstream_resubscribes_when_only_downstream_observes',
      () async {
        final tokens = StreamController<String>.broadcast();
        var listens = 0;
        final session = computedStream((_) {
          listens++;
          final out = StreamController<String>();
          out.add('tok1');
          final sub = tokens.stream.listen(out.add);
          out.onCancel = sub.cancel;
          return out.stream;
        });
        var profiles = 0;
        final profile = computedAsync((q) async {
          profiles++;
          return 'prof(${await q.wait(session)})';
        }, retain: const Duration(seconds: 30));
        final (log1, d1) = observe(profile);
        await settle();
        expect(log1.last, 'data(prof(tok1))');
        d1();
        await settle();
        expect(listens, 1);
        final (log2, d2) = observe(profile);
        await settle();
        expect(listens, 2, reason: 'upstream re-asked once');
        expect(
          profiles,
          1,
          reason: 'an equal token keeps the downstream answer',
        );
        expect(log2, ['data(prof(tok1))']);
        tokens.add('tok2');
        await settle();
        expect(profiles, 2);
        expect(log2.last, 'data(prof(tok2))');
        d2();
        await settle();
        await tokens.close();
      },
    );

    test('relanded_different_answer_after_discard_reruns_downstream', () async {
      var v = 1;
      final u = computedAsync((_) => Future.value(v));
      var runs = 0;
      final d = computedAsync((q) async {
        runs++;
        return await q.wait(u) * 10;
      }, retain: const Duration(seconds: 30));
      final (_, d1) = observe(d);
      await settle();
      d1();
      await settle();
      v = 2;
      expect(await u.settled(), const AsyncData(2));
      final (log, d2) = observe(d);
      await settle();
      expect(runs, 2);
      expect(log.last, 'data(20)');
      d2();
    });

    test('upstream_error_recovery_recovers_downstream', () async {
      var fail = true;
      final u = computedAsync<int>(
        (_) => fail ? Future.error('net') : Future.value(1),
      );
      final d = computedAsync((q) async => await q.wait(u) + 1);
      final (log, dispose) = observe(d);
      await settle();
      expect(log.last, 'error(net)');
      fail = false;
      u.invalidate();
      await settle();
      expect(log.last, 'data(2)');
      dispose();
    });

    test('upstream_new_question_makes_downstream_stale_at_once', () async {
      final id = signal(1);
      final u = computedAsync((_) => Future.value(id.value));
      final d = computedAsync((q) async => await q.wait(u) * 10);
      final (log, dispose) = observe(d);
      await settle();
      id.value = 2;
      expect(show(d.peek()), 'data(10,refreshing,stale)');
      await settle();
      expect(log, [
        'loading',
        'data(10)',
        'data(10,refreshing,stale)',
        'data(20)',
      ]);
      dispose();
    });

    test('upstream_refetch_failure_keeps_downstream', () async {
      var n = 0;
      final u = computedAsync<int>(
        (_) => ++n == 1 ? Future.value(1) : Future.error('refetch'),
      );
      var runs = 0;
      final d = computedAsync((q) async {
        runs++;
        return await q.wait(u) + 1;
      });
      final (log, dispose) = observe(d);
      await settle();
      u.invalidate();
      await settle();
      expect(show(u.peek()), 'error(refetch,prev=1)');
      expect(runs, 1);
      expect(log, ['loading', 'data(2)']);
      dispose();
    });

    test('retry_downstream_retries_failed_upstream', () async {
      var fail = true, us = 0;
      final u = computedAsync<int>((_) {
        us++;
        return fail ? Future.error('net') : Future.value(1);
      });
      final d = computedAsync((q) async => await q.wait(u) + 1);
      final (log, dispose) = observe(d);
      await settle();
      expect(log.last, 'error(net)');
      fail = false;
      d.invalidate();
      await settle();
      expect(us, 2);
      expect(log.last, 'data(2)');
      dispose();
    });

    test('abandoned_wait_neither_leaks_nor_throws', () async {
      final errors = <Object>[];
      late final AsyncComputed<int> b;
      // Futures complete in the zone that created them: build everything
      // inside the guarded zone.
      await runZonedGuarded(() async {
        final fast = Completer<int>(), slow = Completer<int>();
        final a = computedAsync((_) => fast.future);
        b = computedAsync((_) => slow.future);
        final d = computedAsync((q) => Future.any([q.wait(a), q.wait(b)]));
        final (log, dispose) = observe(d);
        fast.complete(1);
        await settle();
        expect(log.last, 'data(1)');
        dispose();
        await settle();
        slow.completeError('late');
        await settle();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
      expect((activeQueryCount, subscriberCount(b)), (0, 0));
    });

    test('repeated_wait_shares_future', () async {
      final u = computedAsync((_) async => 3);
      final d = computedAsync((q) async {
        final one = q.wait(u);
        final two = q.wait(u);
        return await one + await two;
      });
      expect(await d.settled(), const AsyncData(6));
    });

    test('a wait after an await throws and observes nothing', () async {
      // Q4: q.wait only before the first await; later it throws in debug
      // and release alike, and the query fails with it. A one-off answer is
      // source.settled().
      final id = signal(1);
      final u = computedAsync((_) async => id.value, name: 'u');
      var runs = 0;
      final d = computedAsync((q) async {
        runs++;
        await null;
        return await q.wait(u);
      });
      final (log, dispose) = observe(d);
      await settle();
      expect(log.last, contains('RILL_READ_AFTER_AWAIT'));
      expect(log.last, contains('settled()'));
      expect(subscriberCount(u), 0);
      id.value = 2;
      await settle();
      expect(runs, 1);
      dispose();
    });
  });

  group('wait cycles, expiry, supersession and retries', () {
    test('mutual_wait_cycle_fails_with_cycle', () async {
      late final AsyncComputed<int> a, b;
      a = computedAsync((q) async => await q.wait(b) + 1, name: 'a');
      b = computedAsync((q) async => await q.wait(a) + 1, name: 'b');
      final (log, dispose) = observe(a);
      await settle();
      expect(log.last, contains('RILL_CYCLE'));
      expect(show(b.peek()), contains('RILL_CYCLE'));
      dispose();
      await settle();
      expect((subscriberCount(a), subscriberCount(b)), (0, 0));
      checkGraph([a, b]);
      a.invalidate();
      await settle();
    });

    test('self_wait_fails_with_cycle', () async {
      late final AsyncComputed<int> self;
      self = computedAsync((q) async => await q.wait(self) + 1, name: 'self');
      expect(show(await self.settled()), contains('RILL_CYCLE'));
    });

    test('wait_plus_sync_read_cycle_fails_with_cycle', () async {
      late final AsyncComputed<int> a, b;
      a = computedAsync((q) async => await q.wait(b) + 1, name: 'a');
      b = computedAsync((q) async => (a.value.valueOrNull ?? 0) + 1, name: 'b');
      final (log, dispose) = observe(a);
      await settle();
      expect(log.last, contains('RILL_CYCLE'));
      dispose();
      await settle();
      checkGraph([a, b]);
      expect((subscriberCount(a), subscriberCount(b)), (0, 0));
      // A query reading itself.
      late final AsyncComputed<int> me;
      me = computedAsync((_) async => (me.value.valueOrNull ?? 0) + 1);
      expect(show(await me.settled()), contains('RILL_CYCLE'));
    });

    test('cold_binding_input_change_is_stale', () async {
      var external = 1;
      final bridge = bindingSignal<int>(external, sample: () => external);
      final query = computedAsync(
        (_) async => bridge.value * 10,
        retain: const Duration(seconds: 30),
      );
      final (log1, d1) = observe(query);
      await settle();
      expect(log1.last, 'data(10)');
      d1();
      await settle();
      external = 2;
      expect(show(query.peek()), 'data(10,refreshing,stale)');
      final (log2, d2) = observe(query);
      await settle();
      expect(log2, ['data(10,refreshing,stale)', 'data(20)']);
      d2();
    });

    test('cold_binding_input_change_through_wait_is_stale', () async {
      var external = 1;
      final bridge = bindingSignal<int>(external, sample: () => external);
      final upstream = computedAsync((_) async => bridge.value * 10);
      final downstream = computedAsync(
        (q) async => await q.wait(upstream) + 1,
        retain: const Duration(seconds: 30),
      );
      final (log1, d1) = observe(downstream);
      await settle();
      expect(log1.last, 'data(11)');
      d1();
      await settle();
      external = 2;
      expect(show(downstream.peek()), 'data(11,refreshing,stale)');
      final (log2, d2) = observe(downstream);
      await settle();
      expect(log2.last, 'data(21)');
      d2();
    });

    test('wait_on_a_sampled_upstream_marks_the_reader', () async {
      // The upstream already samples before the wait edge exists, so only the
      // edge itself can mark the downstream; no retain hides it.
      var external = 1;
      final bridge = bindingSignal<int>(external, sample: () => external);
      final upstream = computedAsync((_) async => bridge.value * 10);
      final (_, u1) = observe(upstream);
      await settle();
      final lease = Scope();
      addTearDown(lease.dispose);
      final downstream = computedAsync(
        (q) async => await q.wait(upstream) + 1,
        keepAlive: lease,
      );
      final (log1, d1) = observe(downstream);
      await settle();
      expect(log1.last, 'data(11)');
      d1();
      u1();
      await settle();
      // A clean cold read first: with no write since, only the sampled-input
      // mark makes the next read look at the bridge again.
      expect(show(downstream.peek()), 'data(11)');
      external = 2;
      expect(show(downstream.peek()), 'data(11,refreshing,stale)');
      final (log2, d2) = observe(downstream);
      await settle();
      expect(log2.last, 'data(21)');
      d2();
    });

    test('stale_cooling_microtask_yields_to_a_later_observer', () async {
      // Leave, return and leave again: the first leave's microtask runs before
      // an observer that arrives in between, so only the last leave may drop.
      var runs = 0;
      final query = computedAsync((_) async => ++runs);
      final (_, d1) = observe(query);
      await settle();
      d1();
      final (_, d2) = observe(query);
      late void Function() d3;
      List<String>? log3;
      scheduleMicrotask(() {
        final (log, dispose) = observe(query);
        log3 = log;
        d3 = dispose;
      });
      d2();
      await settle();
      expect(runs, 1);
      expect(log3, ['data(1)']);
      d3();
    });

    test('dropped_query_releases_consumed_answers', () async {
      final upstream = computedAsync((_) async => List.filled(4, 0));
      final downstream = computedAsync(
        (q) async => (await q.wait(upstream)).length,
        name: 'holder',
      );
      Map<Object?, Object?> node() =>
          (RillDebug.graph()['nodes']! as List<Object?>)
              .cast<Map<Object?, Object?>>()
              .firstWhere((n) => n['label'] == 'holder');
      Object? consumed() =>
          ((node()['waits']! as List).single as Map)['consumed'];
      final (_, dispose) = observe(downstream);
      await settle();
      expect(consumed(), 'answer');
      dispose();
      await settle();
      expect(consumed(), 'released');
      expect(downstream.peek(), isA<AsyncLoading<int>>());
    });

    test('unchanged_on_query_detects_a_change', () async {
      final id = signal(1);
      final query = computedAsync((_) async => id.value);
      final (_, dispose) = observe(query);
      addTearDown(dispose);
      await settle();
      final slot = Scope().slot();
      final target = signal(0);
      final gate = Completer<void>();
      bool? published;
      final outcome = slot.run((t) async {
        final asked = Unchanged(query);
        await gate.future;
        published = t.publish((p) {
          p.require(asked);
          p.set(target, 1);
        });
      });
      id.value = 2;
      await settle();
      gate.complete();
      await outcome;
      expect(published, isFalse, reason: 'the query changed under the task');
      expect(target.value, 0);
      prepareBindingInput(query);
    });

    test('settled_on_expired_query_waits_for_revalidation', () {
      fakeAsync((async) {
        var n = 0;
        final second = Completer<int>();
        final query = computedAsync(
          (_) => ++n == 1 ? Future.value(1) : second.future,
          retain: const Duration(seconds: 5),
        );
        AsyncState<int>? first, again;
        query.settled().then((s) => first = s);
        async.flushMicrotasks();
        expect(first, const AsyncData(1));
        async.elapse(const Duration(seconds: 10));
        query.settled().then((s) => again = s);
        async.flushMicrotasks();
        expect(again, isNull);
        expect(n, 2);
        second.complete(2);
        async.flushMicrotasks();
        expect(again, const AsyncData(2));
        expect((activeQueryCount, activeQueryTimerCount), (0, 0));
      });
    });

    test('expired_query_siblings_agree', () {
      fakeAsync((async) {
        var n = 0;
        final query = computedAsync(
          (_) => Future.value(++n),
          retain: const Duration(seconds: 5),
        );
        final (_, d1) = observe(query);
        async.flushMicrotasks();
        d1();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        final r1 = Reader(), r2 = Reader();
        final s1 = show(r1.read(() => query.value));
        final s2 = show(r2.read(() => query.value));
        expect((s1, s2), ('data(1,refreshing)', 'data(1,refreshing)'));
        var applies = 0;
        final stop = effect(() => query.value, (_, _, _) {
          applies++;
        });
        expect(applies, 1);
        async.flushMicrotasks();
        expect(show(query.peek()), 'data(2)');
        expect(applies, 2);
        stop();
        r1.dispose();
        r2.dispose();
      });
    });

    test('wait_on_refreshing_upstream_waits_for_new_answer', () async {
      var n = 0;
      final second = Completer<int>();
      final u = computedAsync(
        (_) => ++n == 1 ? Future.value(10) : second.future,
      );
      final (_, du) = observe(u);
      await settle();
      u.invalidate();
      expect(show(u.peek()), 'data(10,refreshing)');
      final tokens = <int>[];
      final d = computedAsync((q) async {
        final token = await q.wait(u);
        tokens.add(token);
        return token * 2;
      });
      final (log, dd) = observe(d);
      await settle();
      expect(tokens, isEmpty);
      second.complete(20);
      await settle();
      expect(tokens, [20]);
      expect(log, ['loading', 'data(40)']);
      du();
      dd();
    });

    test('wait_on_failed_refresh_resolves_error', () async {
      var n = 0;
      final u = computedAsync<int>(
        (_) => ++n == 1 ? Future.value(1) : Future.error('refetch'),
      );
      final (_, du) = observe(u);
      await settle();
      await u.refresh();
      expect(show(u.peek()), 'error(refetch,prev=1)');
      final d = computedAsync((q) async => await q.wait(u) + 1);
      expect(show(await d.settled()), 'error(refetch)');
      du();
    });

    test('superseded_attempt_wait_never_completes', () async {
      final s = signal(1);
      final cu = Completer<int>();
      final u = computedAsync(
        (_) => cu.future,
        retain: const Duration(seconds: 30),
      );
      final calls = <String>[];
      final down = computedAsync((q) async {
        final fu = q.wait(u);
        final sv = s.value;
        final av = await fu;
        calls.add('rpc($sv, $av)');
        return '$sv/$av';
      }, retain: const Duration(seconds: 30));
      final (_, du) = observe(u);
      final (_, dd1) = observe(down);
      await settle();
      dd1();
      await settle();
      cu.complete(100);
      await settle();
      s.value = 2;
      final (log, dd2) = observe(down);
      await settle();
      expect(calls, ['rpc(2, 100)']);
      expect(log.last, 'data(2/100)');
      du();
      dd2();
      await settle();
    });

    test('cold_peek_does_not_resume_paused_wait', () async {
      final cu = Completer<int>();
      final u = computedAsync(
        (_) => cu.future,
        retain: const Duration(seconds: 30),
      );
      var resumed = 0;
      final d = computedAsync((q) async {
        final v = await q.wait(u);
        resumed++;
        return v + 1;
      }, retain: const Duration(seconds: 30));
      final (_, du) = observe(u);
      final (_, dd) = observe(d);
      await settle();
      dd();
      await settle();
      cu.complete(10);
      await settle();
      d.peek();
      await settle();
      expect(resumed, 0);
      final (log, dd2) = observe(d);
      await settle();
      expect((resumed, log.last), (1, 'data(11)'));
      du();
      dd2();
    });

    test('cold_landed_error_retries_on_return', () {
      fakeAsync((async) {
        final first = Completer<int>();
        var attempts = 0;
        final query = computedAsync(
          (_) => ++attempts == 1 ? first.future : Future.value(99),
          retain: const Duration(seconds: 30),
        );
        final (_, d1) = observe(query);
        async.flushMicrotasks();
        d1();
        async.flushMicrotasks();
        expect(activeQueryTimerCount, 1);
        first.completeError('net');
        async.flushMicrotasks();
        expect(
          activeQueryTimerCount,
          0,
          reason: 'the attempt ended while cold',
        );
        expect(async.pendingTimers, isEmpty);
        final (log, d2) = observe(query);
        async.flushMicrotasks();
        expect(log, ['loading', 'data(99)']);
        d2();
      });
    });

    test('retry_does_not_reinvalidate_retrying_upstream', () async {
      var count = 0;
      final second = Completer<int>();
      final u = computedAsync<int>((_) {
        count++;
        if (count == 1) return Future.error('net');
        return second.future;
      });
      final d = computedAsync((q) async => await q.wait(u) + 1);
      final (log, dispose) = observe(d);
      await settle();
      u.invalidate();
      await settle();
      expect(count, 2);
      d.invalidate();
      await settle();
      expect(count, 2);
      second.complete(1);
      await settle();
      expect(log.last, 'data(2)');
      dispose();
    });

    test('throwing_listen_lands_error', () async {
      final query = computedStream<int>((_) => _ThrowingStream());
      expect(show(await query.settled()), contains('listen'));
      expect(activeQueryStreamCount, 0);
    });
  });

  group('answers, retention and diagnostics', () {
    test('new_question_failure_forgets_the_old_answer', () async {
      final id = signal('A');
      final answers = <Completer<int>>[];
      final query = computedAsync((_) {
        id.value;
        final c = Completer<int>();
        answers.add(c);
        return c.future;
      });
      final (log, dispose) = observe(query);
      addTearDown(dispose);
      answers[0].complete(7);
      await settle();
      expect(log.last, 'data(7)');
      id.value = 'B';
      expect(show(query.peek()), 'data(7,refreshing,stale)');
      answers[1].completeError('B');
      await settle();
      expect(log.last, 'error(B)');
      // Neither a retry of B nor a new question C brings A back.
      query.invalidate();
      expect(show(query.peek()), 'loading');
      id.value = 'C';
      expect(show(query.peek()), 'loading');
      answers[3].complete(9);
      await settle();
      expect(log.last, 'data(9)');
      // A same-question failure still keeps the value as previous.
      query.invalidate();
      answers[4].completeError('again');
      await settle();
      expect(log.last, 'error(again,prev=9)');
    });

    test('abandoned_wait_under_an_observed_downstream_stays_silent', () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final fast = Completer<int>(), slow = Completer<int>();
        final a = computedAsync((_) => fast.future);
        final b = computedAsync((_) => slow.future);
        final d = computedAsync((q) async {
          final fa = q.wait(a), fb = q.wait(b);
          final av = await fa;
          if (av == 0) return 0;
          return av + await fb;
        });
        final (log, dispose) = observe(d);
        fast.complete(0);
        await settle();
        expect(log.last, 'data(0)');
        // d stays observed while the wait it never awaited fails.
        slow.completeError(StateError('late'));
        await settle();
        expect(log.last, 'data(0)');
        dispose();
        await settle();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
    });

    test('failed_first_wait_leaves_the_second_silent', () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final first = Completer<int>(), second = Completer<int>();
        final a = computedAsync((_) => first.future);
        final b = computedAsync((_) => second.future);
        final d = computedAsync((q) async {
          final fa = q.wait(a), fb = q.wait(b);
          return await fa + await fb;
        });
        final (log, dispose) = observe(d);
        first.completeError('first');
        await settle();
        expect(log.last, 'error(first)');
        second.completeError('second');
        await settle();
        dispose();
        await settle();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
    });

    for (final answered in [true, false]) {
      test('cold_stream_close_ends_the_retention_timer '
          '(${answered ? 'answered' : 'empty'})', () {
        fakeAsync((async) {
          final controller = StreamController<int>();
          final query = computedStream(
            (_) => controller.stream,
            retain: const Duration(seconds: 5),
          );
          final (_, dispose) = observe(query);
          if (answered) controller.add(1);
          async.flushMicrotasks();
          dispose();
          async.flushMicrotasks();
          expect(activeQueryTimerCount, 1);
          controller.close();
          async.flushMicrotasks();
          expect(activeQueryStreamCount, 0);
          expect(activeQueryTimerCount, 0);
          expect(async.pendingTimers, isEmpty);
        });
      });
    }

    test('unchanged_sees_cold_expiry', () {
      fakeAsync((async) {
        var n = 0;
        final query = computedAsync(
          (_) async => ++n,
          retain: const Duration(seconds: 5),
        );
        query.settled();
        async.flushMicrotasks();
        expect(show(query.peek()), 'data(1)');
        final target = signal(0);
        final gate = Completer<void>();
        bool? published;
        Scope().slot().run((t) async {
          final asked = Unchanged(query);
          await gate.future;
          published = t.publish((p) {
            p.require(asked);
            p.set(target, 1);
          });
        });
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        gate.complete();
        async.flushMicrotasks();
        expect(published, isFalse, reason: 'the cold answer expired');
      });
    });

    test('unchanged_sees_cold_binding_input_change', () async {
      var external = 1;
      final bridge = bindingSignal<int>(external, sample: () => external);
      final lease = Scope();
      addTearDown(lease.dispose);
      final query = computedAsync(
        (_) async => bridge.value * 10,
        keepAlive: lease,
      );
      await query.settled();
      await settle();
      final target = signal(0);
      final gate = Completer<void>();
      bool? published;
      final outcome = Scope().slot().run((t) async {
        final asked = Unchanged(query);
        await gate.future;
        published = t.publish((p) {
          p.require(asked);
          p.set(target, 1);
        });
      });
      external = 2;
      gate.complete();
      await outcome;
      expect(published, isFalse, reason: 'the cold query became stale');
    });

    test('reused_edge_carries_the_sampled_mark', () async {
      var external = 1;
      final bridge = bindingSignal<int>(external, sample: () => external);
      final lease = Scope();
      addTearDown(lease.dispose);
      final query = computedAsync(
        (_) async => bridge.value * 10,
        keepAlive: lease,
      );
      final view = computed(() => show(query.value));
      // view links to query before query has ever sampled anything.
      expect(view.peek(), 'loading');
      expect(await query.settled(), const AsyncData(10));
      expect(view.peek(), 'data(10)');
      external = 2;
      expect(view.peek(), 'data(10,refreshing,stale)');
    });

    test('reused_wait_edge_carries_the_sampled_mark', () async {
      final useBridge = signal(false);
      var external = 10;
      final bridge = bindingSignal<int>(external, sample: () => external);
      final lease = Scope();
      addTearDown(lease.dispose);
      final u = computedAsync(
        (_) async => useBridge.value ? bridge.value : 10,
        keepAlive: lease,
      );
      final d = computedAsync(
        (q) async => await q.wait(u) + 1,
        keepAlive: lease,
      );
      final (_, first) = observe(d);
      await settle();
      expect(show(d.peek()), 'data(11)');
      first();
      await settle();
      // u starts sampling while d is cold.
      final (_, upstream) = observe(u);
      useBridge.value = true;
      await settle();
      upstream();
      await settle();
      d.invalidate();
      final (_, second) = observe(d);
      await settle();
      expect(show(d.peek()), 'data(11)');
      second();
      await settle();
      // A cold read validates d's question now: only the sampled mark makes
      // the next read look at the bridge again (an unobserved reconcile no
      // longer samples).
      expect(show(d.peek()), 'data(11)');
      external = 20;
      expect(show(d.peek()), 'data(11,refreshing,stale)');
    });

    test(
      'why_finds_queries_by_name_and_id; question and retry are recorded',
      () async {
        addTearDown(RillDebug.clear);
        final key = signal(1, name: 'key');
        final user = computedAsync((_) async => key.value, name: 'user');
        final stop = effect(() => user.value, (_, _, _) {}, name: 'render');
        addTearDown(stop);
        await settle();
        expect(RillDebug.why('user'), isNotEmpty);
        expect(RillDebug.why(RillDebug.describe(user)!.id), isNotEmpty);
        key.value = 2;
        final stale = RillDebug.lastWhy(stop)!.toString();
        expect(stale, isNot(contains('not recorded')));
        expect(stale, contains('signal key'));
        await settle();
        user.invalidate();
        expect(
          RillDebug.lastWhy(stop)!.toString(),
          contains('(retry of user)'),
        );
      },
    );

    test('cold_query_read_warning_names_the_reader', () async {
      final printed = <String>[];
      await runZoned(
        () async {
          final cold = computedAsync((_) async => 1, name: 'coldQ');
          cold.value;
          await settle();
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );
      expect(printed, [
        startsWith('RILL_COLD_QUERY_READ at test/query_test.dart:'),
      ]);
    });

    test('async_state_equality_is_symmetric', () {
      const a = AsyncLoading<num>(), b = AsyncLoading<int>();
      const d1 = AsyncData<num>(1), d2 = AsyncData<int>(1);
      final error = StateError('x');
      final e1 = AsyncError<num>(error, StackTrace.empty);
      final e2 = AsyncError<int>(error, StackTrace.empty);
      expect((a == b, b == a), (true, true));
      expect((d1 == d2, d2 == d1), (true, true));
      expect((e1 == e2, e2 == e1), (true, true));
    });

    test('check_graph_walks_into_the_answer_node', () async {
      final u = computedAsync((_) async => 1);
      final d = computedAsync((q) async => await q.wait(u) + 1);
      final (_, dispose) = observe(d);
      await settle();
      checkGraph([u]);
      dispose();
      await settle();
      checkGraph([u]);
    });
  });

  // Cases run under a zone so a stray error fails.
  group('comparators, waits and stream ends', () {
    Future<List<Object>> guarded(Future<void> Function() body) async {
      final errors = <Object>[];
      await runZonedGuarded(body, (error, _) => errors.add(error));
      return errors;
    }

    test('cycle_formed_after_success_lands_once_and_recovers', () async {
      final flag = signal(false);
      late final AsyncComputed<int> q;
      final view = computed<int>(
        () => flag.value ? (q.value.valueOrNull ?? 0) : 0,
      );
      var loads = 0;
      q = computedAsync<int>((_) async {
        // Under the defect every landing relaunches: stop reading the view
        // after a few so the failure is a count, not a starved event loop.
        if (++loads > 5) return -1;
        return view.value;
      });
      final (log, dispose) = observe(q);
      await settle();
      expect(log.last, 'data(0)');
      flag.value = true;
      await settle();
      expect(loads, 2);
      expect(log.last, startsWith('error(Bad state: RILL_CYCLE'));
      flag.value = false;
      await settle();
      expect((loads, log.last), (3, 'data(0)'));
      dispose();
    });

    test('comparator_throw_lands_as_error_with_its_stack', () async {
      final errors = await guarded(() async {
        final boom = StateError('comparator');
        var loads = 0;
        final q = computedAsync<int>(
          (_) async => ++loads,
          equals: (_, _) => throw boom,
        );
        final (_, dispose) = observe(q);
        await settle();
        final state = await q.refresh().timeout(const Duration(seconds: 2));
        expect(
          state,
          isA<AsyncError<int>>()
              .having((e) => e.error, 'error', same(boom))
              .having((e) => e.previous, 'previous', 1)
              .having((e) => '${e.stack}', 'stack', contains('query_test')),
        );
        expect(activeQueryCount, 0);
        dispose();
      });
      expect(errors, isEmpty);
    });

    test(
      'comparator_reentrant_invalidate_installs_no_superseded_answer',
      () async {
        final requests = <Completer<int>>[];
        late AsyncComputed<int> q;
        var reentered = false;
        q = computedAsync<int>(
          (_) => (requests..add(Completer<int>())).last.future,
          equals: (a, b) {
            if (!reentered) {
              reentered = true;
              q.invalidate();
            }
            return a == b;
          },
        );
        final (log, dispose) = observe(q);
        requests[0].complete(1);
        await settle();
        q.invalidate();
        requests[1].complete(2);
        await settle();
        expect(requests, hasLength(3));
        expect(log, ['loading', 'data(1)', 'data(1,refreshing)']);
        requests[2].complete(3);
        await settle();
        expect(log.last, 'data(3)');
        dispose();
      },
    );

    test('late_self_wait_throws_and_cools', () async {
      late AsyncComputed<int> self;
      var cancelled = false;
      self = computedAsync<int>((q) async {
        q.cancelled.then((_) => cancelled = true);
        await null;
        return q.wait(self);
      });
      final (log, dispose) = observe(self);
      await settle();
      expect(log.last, startsWith('error(Bad state: RILL_READ_AFTER_AWAIT'));
      dispose();
      await settle();
      expect(
        (activeQueryCount, subscriberCount(self), cancelled),
        (0, 0, true),
      );
    });

    test('repeated_wait_returns_one_future_and_reports_one_error', () async {
      Future<int>? one, two;
      Future<num>? widened;
      final errors = await guarded(() async {
        final failing = computedAsync<int>(
          (_) => Future.error(StateError('failed')),
        );
        final d = computedAsync<int>((q) async {
          one = q.wait(failing);
          two = q.wait(failing);
          widened = q.wait<num>(failing);
          return await one! + await two!;
        });
        final (log, dispose) = observe(d);
        await settle();
        expect(log.last, 'error(Bad state: failed)');
        dispose();
      });
      expect(identical(one, two), isTrue);
      expect(identical(one, widened), isTrue);
      expect(errors, isEmpty);
    });

    test('stream_cancel_that_drops_last_reader_opens_no_stream', () async {
      final input = signal(0), view = Scope(), session = Scope();
      final opened = <int>[], closed = <int>[];
      final q = computedStream<int>((_) {
        final id = input.value;
        return StreamController<int>(
          onListen: () => opened.add(id),
          onCancel: () {
            closed.add(id);
            if (id == 0) view.dispose();
          },
        ).stream;
      }, keepAlive: session);
      view.effect(() => q.value, (_, _, _) {});
      expect(opened, [0]);
      input.value = 1;
      await settle();
      expect(opened, [0]);
      expect(closed, [0]);
      expect(activeQueryStreamCount, 0);
      session.dispose();
      await settle();
    });

    test(
      'cancelled_attempt_holds_no_query_and_its_wait_observes_nothing',
      () async {
        final u = computedAsync<int>((_) async => 1);
        Query? attempt;
        final never = Completer<int>();
        final d = computedAsync<int>((q) {
          attempt = q;
          return never.future;
        });
        final (_, dispose) = observe(d);
        await settle();
        dispose();
        await settle();
        expect(
          () => attempt!.wait(u),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              startsWith('RILL_READ_AFTER_AWAIT'),
            ),
          ),
        );
        await settle();
        expect((subscriberCount(u), activeQueryCount), (0, 0));
      },
    );

    test('stream_error_then_done_keeps_the_error', () async {
      final q = computedStream<int>(
        (_) => Stream.error(StateError('backend denied')),
      );
      final (log, dispose) = observe(q);
      await settle();
      expect(log.last, 'error(Bad state: backend denied)');
      expect(log.where((s) => s.contains('RILL_EMPTY_QUERY')), isEmpty);
      dispose();
    });

    test('empty_stream_is_still_rill_empty_query', () async {
      final q = computedStream<int>((_) => const Stream.empty());
      final (log, dispose) = observe(q);
      await settle();
      expect(log.last, contains('RILL_EMPTY_QUERY'));
      dispose();
    });
  });

  group('cycle recovery and wait-edge comparator failures', () {
    Future<List<Object>> guarded(Future<void> Function() body) async {
      final errors = <Object>[];
      await runZonedGuarded(body, (error, _) => errors.add(error));
      return errors;
    }

    String read(Readable<int> node) {
      try {
        return '${node.value}';
      } on Object catch (e) {
        return '$e'.contains('RILL_CYCLE') ? 'cycle' : '$e';
      }
    }

    test('independent_landing_recovers_a_computed_cycle_once_untied', () async {
      // L1: b has an input and recovers when it lands; a
      // closed the cycle with no edge to b, so nothing pushes it (L2 is
      // given up): its effect keeps the error until a is read cold, after
      // which it is fresh. The landing wakes no cycle and nothing relaunches.
      var loads = 0;
      final finish = Completer<bool>();
      final input = computedAsync<bool>((_) {
        loads++;
        return finish.future;
      });
      late Computed<int> a, b;
      a = computed(() => b.value);
      b = computed(() => input.value.valueOrNull == true ? 7 : a.value);
      final seen = <String>[];
      final stopB = effect(() => read(b), (v, _, _) => seen.add('b=$v'));
      var stopA = effect(() => read(a), (v, _, _) => seen.add('a=$v'));
      expect((read(a), read(b)), ('cycle', 'cycle'));
      finish.complete(true);
      await settle();
      expect(seen, ['b=cycle', 'a=cycle', 'b=7']);
      expect((read(a), read(b)), ('cycle', '7'), reason: 'hot: no L2');
      stopA();
      expect(read(a), '7', reason: 'cold read: L1');
      stopA = effect(() => read(a), (v, _, _) => seen.add('a=$v'));
      expect(seen.last, 'a=7', reason: 'remount: L1');
      expect(loads, 1);
      checkGraph([a, b, input]);
      stopA();
      stopB();
    });

    test('wait_edge_comparator_throw_is_a_recoverable_error_cold', () async {
      final errors = await guarded(() async {
        final lease = Scope();
        final c = StreamController<int>.broadcast(sync: true);
        final boom = StateError('incompatible versions');
        final source = computedStream<int>(
          (_) => c.stream,
          equals: (old, now) {
            if (old == 1 && now == 3) throw boom;
            return old == now;
          },
        );
        final upReader = effect(() => source.value, (_, _, _) {});
        final down = computedAsync<int>(
          (q) => q.wait(source),
          keepAlive: lease,
        );
        final stop = effect(() => down.value, (_, _, _) {});
        c.add(1);
        await settle();
        stop();
        await settle();
        c.add(2);
        c.add(3);
        await settle();
        // Never the stale success: the change is judged, as a failure.
        expect(
          down.peek(),
          isNot(
            isA<AsyncData<int>>().having(
              (d) => d.refreshing || d.stale,
              'refreshing or stale',
              false,
            ),
          ),
        );
        expect(
          await down.settled().timeout(const Duration(seconds: 2)),
          isA<AsyncError<int>>().having((e) => e.error, 'error', same(boom)),
        );
        // The next upstream change compares again and recovers.
        c.add(4);
        expect(
          await down.settled().timeout(const Duration(seconds: 2)),
          const AsyncData<int>(4),
        );
        lease.dispose();
        upReader();
        await c.close();
      });
      expect(errors, isEmpty);
    });

    test(
      'wait_edge_comparator_throw_is_a_recoverable_error_observed',
      () async {
        final errors = await guarded(() async {
          var loads = 0, comparisons = 0;
          final up = computedAsync<int>(
            (_) async => ++loads,
            equals: (a, b) {
              if (++comparisons == 2) throw StateError('2nd compare');
              return a == b;
            },
          );
          final down = computedAsync<int>((q) => q.wait(up));
          final (log, dispose) = observe(down);
          await settle();
          expect(log.last, 'data(1)');
          up.invalidate();
          await settle();
          expect(log.last, 'error(Bad state: 2nd compare)');
          up.invalidate();
          await settle();
          expect(log.last, 'data(3)');
          dispose();
        });
        expect(errors, isEmpty);
      },
    );
  });
  // The reconcile is the only transition; a failed cycle retries only on a
  // change from outside it.
  group('independent cycles, edge recovery and round ends', () {
    Future<List<Object>> guarded(Future<void> Function() body) async {
      final errors = <Object>[];
      await runZonedGuarded(body, (error, _) => errors.add(error));
      return errors;
    }

    String read(Readable<int> node) {
      try {
        return '${node.value}';
      } on Object catch (e) {
        return '$e'.contains('RILL_CYCLE') ? 'cycle' : '$e';
      }
    }

    test('two_independent_cycles_do_not_wake_each_other', () async {
      final enabled = signal(false);
      final launches = [0, 0];
      final stops = <void Function()>[];
      final queries = <AsyncComputed<int>>[];
      for (var i = 0; i < 2; i++) {
        late AsyncComputed<int> query;
        final view = computed(
          () => enabled.value ? query.value.valueOrNull ?? 0 : 0,
        );
        query = computedAsync((_) async {
          // A runaway would starve the timer below: stop it here.
          if (++launches[i] > 50) return 0;
          return view.value;
        });
        queries.add(query);
        stops.add(effect(() => query.value, (_, _, _) {}));
      }
      await settle();
      expect(launches, [1, 1]);
      enabled.value = true;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(launches, [2, 2]);
      for (final q in queries) {
        expect(show(q.peek()), contains('RILL_CYCLE'));
      }
      // Each recovers from the outside.
      enabled.value = false;
      await settle();
      expect(launches, [3, 3]);
      expect(queries.map((q) => show(q.peek())), ['data(0)', 'data(0)']);
      for (final stop in stops) {
        stop();
      }
    });

    test('independent_stream_event_recovers_a_diamond_once_untied', () async {
      {
        var derivedLoads = 0;
        final events = StreamController<bool>.broadcast(sync: true);
        late Computed<int> a, b;
        final fallback = Completer<int>();
        final derived = computedAsync<int>((_) async {
          derivedLoads++;
          try {
            return a.value;
          } on Object {
            return fallback.future;
          }
        });
        final input = computedStream<bool>((_) => events.stream);
        a = computed(() => b.value);
        b = computed(() => input.value.valueOrNull == true ? 7 : a.value);
        final d = computed(() => a.value + b.value);
        final stops = [
          effect(() => read(b), (_, _, _) {}),
          effect(() => read(a), (_, _, _) {}),
          effect(() => read(d), (_, _, _) {}),
        ];
        await settle();
        expect((read(a), read(b), read(d)), ('cycle', 'cycle', 'cycle'));
        checkGraph([a, b, d, input, derived]);
        final loadsBefore = derivedLoads;
        events.add(true);
        await settle();
        // b has the input and recovers; a and d (through a) closed the cycle
        // without an edge back: hot, they keep the error (no L2) and wake
        // nothing; read cold they recover.
        expect((read(a), read(b), read(d)), ('cycle', '7', 'cycle'));
        expect(derivedLoads, loadsBefore);
        stops[1]();
        stops[2]();
        expect((read(a), read(b), read(d)), ('7', '7', '14'));
        stops[0]();
        await events.close();
        checkGraph([a, b, d, input, derived]);
      }
    });

    test(
      'wait_edge_recovers_to_the_value_before_its_comparator_threw',
      () async {
        final errors = await guarded(() async {
          final lease = Scope();
          final c = StreamController<int>.broadcast(sync: true);
          final source = computedStream<int>(
            (_) => c.stream,
            equals: (a, b) {
              if (a == 1 && b == 3) throw StateError('cannot compare 1/3');
              return a == b;
            },
          );
          final watchSource = effect(() => source.value, (_, _, _) {});
          final down = computedAsync<int>(
            (q) => q.wait(source),
            keepAlive: lease,
          );
          final stop = effect(() => down.value, (_, _, _) {});
          c.add(1);
          await settle();
          stop();
          await settle();
          c.add(2);
          c.add(3);
          await settle();
          final again = effect(() => down.value, (_, _, _) {});
          expect(
            await down.settled().timeout(const Duration(seconds: 2)),
            isA<AsyncError<int>>(),
          );
          c.add(1);
          await settle();
          expect(
            await down.settled().timeout(const Duration(seconds: 2)),
            const AsyncData<int>(1),
          );
          again();
          lease.dispose();
          watchSource();
          await c.close();
        });
        expect(errors, isEmpty);
      },
    );

    test('self_wait_of_an_ended_round_throws_not_a_cycle', () async {
      late Query handle;
      final up = computedAsync<int>((q) async {
        handle = q;
        return 7;
      });
      final stop = effect(() => up.value, (_, _, _) {});
      expect(await up.settled(), const AsyncData(7));
      // A wait after the round is a late wait: it throws, it is no cycle.
      expect(
        () => handle.wait(up),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            startsWith('RILL_READ_AFTER_AWAIT'),
          ),
        ),
      );
      stop();
    });

    test('stream_factory_throw_ends_the_round', () async {
      late Query handle;
      final gate = Completer<int>();
      final up = computedAsync<int>((_) => gate.future);
      final waited = <int>[];
      final stream = computedStream<int>((q) {
        handle = q;
        // A wait registered before the throw belongs to the round that the
        // throw ends: it is never delivered.
        q.wait(up).then(waited.add).ignore();
        throw StateError('factory failed');
      });
      final (log, dispose) = observe(stream);
      await settle();
      expect(show(stream.peek()), 'error(Bad state: factory failed)');
      expect(log, contains('error(Bad state: factory failed)'));
      expect(() => handle.wait(up), throwsStateError);
      gate.complete(7);
      await settle();
      expect(waited, isEmpty);
      checkGraph([stream, up]);
      dispose();
    });

    test('stream_error_event_keeps_the_round_open_for_later_data', () async {
      final c = StreamController<int>.broadcast(sync: true);
      final stream = computedStream<int>((_) => c.stream);
      final (log, dispose) = observe(stream);
      c.addError(StateError('blip'));
      await settle();
      expect(log.last, 'error(Bad state: blip)');
      c.add(5);
      await settle();
      expect(log.last, 'data(5)');
      dispose();
      await c.close();
    });

    test('a_wait_under_a_lease_resumes_once_observed_again', () async {
      {
        final lease = Scope(), gate = Completer<int>(), tail = <int>[];
        final up = computedAsync<int>((_) => gate.future);
        final observeUp = effect(() => up.value, (_, _, _) {});
        final down = computedAsync<int>((q) async {
          final v = await q.wait(up);
          tail.add(v);
          return v;
        }, keepAlive: lease);
        final stop = effect(() => down.value, (_, _, _) {});
        await settle();
        stop();
        await settle();
        gate.complete(7);
        await settle();
        // R7: the continuation waits until the downstream is observed.
        expect(tail, isEmpty);
        expect(show(down.peek()), 'loading');
        expect(await down.settled(), const AsyncData(7));
        expect(tail, [7]);
        observeUp();
        lease.dispose();
      }
    });
  });
}

final class _ThrowingStream extends Stream<int> {
  @override
  StreamSubscription<int> listen(
    void Function(int event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => throw StateError('listen');
}
