import 'dart:async';

import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:test/test.dart';

import 'process/fixtures/query_reconcile.dart' as cases;

// There is no query scheduler: stream events reach a query through its own
// microtask FIFO, and a reconcile step ends at its first call into user
// code. The first three cases also run as process tests (debug and AOT).

/// A Future whose `then` is user code that runs synchronously when a
/// completer completes with it.
final class _ObservedFuture implements Future<int> {
  _ObservedFuture(this.onThen);

  final void Function() onThen;
  final Future<int> _inner = Future.value(1);

  @override
  Future<R> then<R>(FutureOr<R> Function(int) f, {Function? onError}) {
    onThen();
    return _inner.then(f, onError: onError);
  }

  @override
  Future<int> catchError(Function onError, {bool Function(Object)? test}) =>
      _inner.catchError(onError, test: test);

  @override
  Future<int> whenComplete(FutureOr<void> Function() action) =>
      _inner.whenComplete(action);

  @override
  Stream<int> asStream() => _inner.asStream();

  @override
  Future<int> timeout(Duration limit, {FutureOr<int> Function()? onTimeout}) =>
      _inner.timeout(limit, onTimeout: onTimeout);
}

Future<void> turns([int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  tearDown(() => Rill.onError = null);

  test('independent_queries_settled_in_one_batch_cost_no_round', () async {
    expect(await cases.settleFan(99), 'returned 99/99');
    expect(await cases.settleFan(180), 'returned 180/180');
  });

  test('feedback_through_a_new_query_each_run_runs_out_of_rounds', () {
    expect(cases.feedback(), 'RILL_INFINITE_LOOP within 100');
  });

  test('a_round_whose_producer_ended_delivers_no_second_wait', () async {
    // The first delivered wait's `then` closes the parent stream. The step
    // that delivered it ends there; the next step sees the round's end
    // queued and delivers nothing more.
    final trace = <String>[];
    final ca = StreamController<Object?>.broadcast(sync: true);
    final cb = StreamController<Object?>.broadcast(sync: true);
    final qa = computedStream<Object?>((_) => ca.stream);
    final qb = computedStream<Object?>((_) => cb.stream);
    final oa = effect(() => qa.value, (_, _, _) {});
    final ob = effect(() => qb.value, (_, _, _) {});
    final producer = StreamController<int>.broadcast(sync: true);
    ca.add(
      _ObservedFuture(() {
        trace.add('first.then');
        producer.close();
      }),
    );
    cb.add(_ObservedFuture(() => trace.add('second.then')));
    final down = computedStream<int>((q) {
      q.wait(qa).then((v) => trace.add('resume a=$v'));
      q.wait(qb).then((v) => trace.add('resume b=$v'));
      return producer.stream.transform(
        StreamTransformer<int, int>.fromHandlers(
          handleDone: (sink) {
            trace.add('onDone before');
            sink.close();
            trace.add('onDone returned');
          },
        ),
      );
    });
    final off = effect(() => down.value, (_, _, _) {});
    await turns();
    expect(trace, isNot(contains('second.then')));
    expect(trace, isNot(contains('resume b=1')));
    expect(trace.take(3), ['first.then', 'onDone before', 'onDone returned']);
    expect(
      '${down.peek()}',
      contains('RILL_EMPTY_QUERY'),
      reason: 'the round ended without an answer',
    );
    off();
    oa();
    ob();
    await ca.close();
    await cb.close();
  });

  test('a_factory_that_removes_the_last_reader_never_listens', () async {
    // The stream factory runs and the step ends; the next step finds the
    // query unobserved and drops the produced stream unlistened.
    final trigger = signal(false), view = Scope();
    late AsyncComputed<int> query;
    final trace = <String>[];
    query = computedStream<int>((_) {
      final reload = trigger.value;
      if (reload) {
        view.dispose();
        trace.add('factory disposed scope; readers=${subscriberCount(query)}');
      }
      return StreamController<int>.broadcast(
        sync: true,
        onListen: () => trace.add(
          'listen reload=$reload readers=${subscriberCount(query)}',
        ),
        onCancel: () => trace.add('cancel reload=$reload'),
      ).stream;
    }, retain: const Duration(milliseconds: 100));
    final streams = activeQueryStreamCount;
    final timers = activeQueryTimerCount;
    view.effect(() => query.value, (_, _, _) {});
    trigger.value = true;
    expect(trace, [
      'listen reload=false readers=1',
      'cancel reload=false',
      'factory disposed scope; readers=0',
    ]);
    expect(activeQueryStreamCount, streams);
    expect(activeQueryTimerCount, timers);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(trace, hasLength(3));
  });

  test('a_factory_that_sends_its_upstream_a_value_converges', () async {
    // The value the factory sends is an asynchronous stream event (no
    // cross-stream order in one batch): the round for 1 may start, and
    // the event replaces it. Eventually the query listens to 2 only.
    final streams = activeQueryStreamCount;
    final source = StreamController<int>.broadcast(sync: true);
    final up = computedStream<int>((_) => source.stream);
    final keep = effect(() => up.value, (_, _, _) {});
    source.add(1);
    await turns(1);
    final trace = <String>[], feeds = <StreamController<int>>[];
    var arm = false;
    final down = computedStream<int>((_) {
      final id = up.value.requireValue;
      trace.add('factory $id');
      if (arm) {
        arm = false;
        source.add(2);
      }
      final c = StreamController<int>.broadcast(
        sync: true,
        onListen: () => trace.add('listen $id'),
        onCancel: () => trace.add('cancel $id'),
      );
      feeds.add(c);
      return c.stream;
    });
    final off = effect(() => down.value, (_, _, _) {});
    feeds.last.add(100);
    await turns(1);
    trace.clear();
    arm = true;
    down.invalidate();
    await turns();
    feeds.last.add(200);
    await turns(1);
    expect(trace.last, 'listen 2');
    expect(trace.where((e) => e.startsWith('listen')).length, lessThan(3));
    expect(down.peek(), const AsyncData<int>(200));
    expect(activeQueryStreamCount - streams, 2);
    off();
    keep();
    for (final c in [...feeds, source]) {
      await c.close();
    }
  });

  test('stream_events_are_delivered_a_microtask_later', () async {
    // computedStream is an asynchronous source whatever its controller: a
    // synchronous controller's event is not seen inside the code that sent
    // it, in order once it arrives.
    final c = StreamController<int>.broadcast(sync: true);
    final q = computedStream<int>((_) => c.stream);
    final seen = <String>[];
    final stop = effect(() => q.value, (s, _, _) => seen.add('$s'));
    c
      ..add(1)
      ..addError(StateError('e'))
      ..add(2);
    expect(q.peek(), const AsyncLoading<int>());
    await Future<void>.delayed(Duration.zero);
    expect(seen, [
      'AsyncLoading<int>()',
      'AsyncData<int>(1)',
      'AsyncError<int>(Bad state: e, previous: 1)',
      'AsyncData<int>(2)',
    ]);
    stop();
    await c.close();
  });

  test('a_round_completing_many_waits_owes_no_round', () async {
    // One wait per step, the steps back to back while the graph stays
    // settled: a hundred and fifty answered waits are one round.
    final ups = [
      for (var i = 0; i < 150; i++) computedAsync<int>((_) async => i),
    ];
    final keep = [for (final u in ups) effect(() => u.value, (_, _, _) {})];
    await turns(2);
    final down = computedAsync<int>((q) async {
      final waits = [for (final u in ups) q.wait(u)];
      return (await Future.wait(waits)).fold<int>(0, (a, b) => a + b);
    });
    expect(await down.settled(), const AsyncData<int>(149 * 150 ~/ 2));
    for (final stop in keep) {
      stop();
    }
  });

  test('the_step_guard_refuses_a_transition_after_user_code', () {
    // Debug builds: a step ends at its first call into user code; the
    // guard is what makes that an invariant and not a convention.
    final q = computedAsync<int>((_) async => 1);
    expect(
      () => debugViolateQueryStep(q),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('went on after user code'),
        ),
      ),
    );
  });

  test('a_comparator_that_always_sends_a_newer_answer_is_reported', () async {
    // Each comparison sends the query's own synchronous controller a newer
    // value. Delivered in microtasks, the loop never returns to the event
    // loop; it is dropped and reported as v0.4.0 reported it in rounds,
    // instead of starving the app.
    final errors = <Object>[];
    var compares = 0;
    final c = StreamController<int>.broadcast(sync: true);
    final done = Completer<void>();
    late void Function() stop;
    runZonedGuarded(() {
      final q = computedStream<int>(
        (_) => c.stream,
        equals: (a, b) {
          if (++compares < 300000) c.add(compares + 1);
          return a == b;
        },
      );
      stop = effect(() => q.value, (_, _, _) {});
      c
        ..add(1)
        ..add(2);
      Timer.run(done.complete);
    }, (e, _) => errors.add(e));
    await done.future;
    expect(errors, hasLength(1));
    expect('${errors.single}', contains('RILL_INFINITE_LOOP'));
    expect(compares, lessThan(300000));
    stop();
    await c.close();
  });
}
