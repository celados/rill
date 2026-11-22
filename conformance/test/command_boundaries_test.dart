import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:rill/internal.dart' show activeQueryCount;
import 'package:rill/rill.dart';
import 'package:rill/wire.dart';
import 'package:test/test.dart';

enum _Boundary {
  typedSet,
  typedEmit,
  savepoint,
  condition,
  join,
  streamCancel,
  cleanup,
}

typedef _Step = ({_Boundary op, int value, bool alternate});
typedef _Snapshot = ({List<int> values, List<int> events, String result});

List<_Step> _generate(int seed, int length) {
  final random = Random(seed);
  return List.generate(
    length,
    (index) => (
      op: _Boundary.values[index % _Boundary.values.length],
      value: random.nextInt(99) + 1,
      alternate: random.nextBool(),
    ),
  );
}

// Each boundary starts with a fresh model. The fields record all observable
// effects of the generated schedule, including rejected publication results.
_Snapshot _model(_Step step) => switch (step.op) {
  _Boundary.typedSet ||
  _Boundary.typedEmit => (values: [0, 0], events: [], result: 'type error'),
  _Boundary.savepoint => (
    values: [step.alternate ? step.value + 1 : step.value, step.value],
    events: [],
    result: 'true:${!step.alternate}',
  ),
  // Default install (C3): only the passed condition (C3b) refuses.
  _Boundary.condition => (
    values: step.value.isEven && step.alternate ? [0, 1] : [step.value, 0],
    events: [],
    result: '${!(step.value.isEven && step.alternate)}',
  ),
  _Boundary.join => (
    values: [step.value + 1, 0],
    events: [1],
    result: 'true:true',
  ),
  _Boundary.streamCancel => (
    values: [2, 0],
    events: [0, 1],
    result: 'AsyncData<int>',
  ),
  _Boundary.cleanup => (
    values: [step.alternate ? 1 : 2, 0],
    events: [],
    result: 'AsyncLoading<int>',
  ),
};

Future<_Snapshot> _run(_Step step) async {
  final owner = Scope();
  final x = signal(0), y = signal(0);
  final seen = <int>[];
  try {
    switch (step.op) {
      case _Boundary.typedSet:
      case _Boundary.typedEmit:
        final bus = Events<int>();
        final stop = bus.listen(seen.add);
        final errors = <Object>[];
        Outcome<bool>? result;
        try {
          await runZonedGuarded(() async {
            result = await owner.slot().run(
              (t) async => t.publish((p) {
                p.set(x, step.value);
                if (step.op == _Boundary.typedSet) {
                  p.set(y, step.value + 0.5);
                } else {
                  p.emit(bus, step.value + 0.5);
                  p.emit(bus, step.value);
                }
              }),
            );
            await Future<void>.delayed(Duration.zero);
          }, (error, _) => errors.add(error));
        } finally {
          stop();
        }
        final outcome = result;
        return (
          values: [x.peek(), y.peek()],
          events: seen,
          result:
              outcome is Failed<bool> &&
                  outcome.error is TypeError &&
                  errors.isEmpty
              ? 'type error'
              : '${outcome.runtimeType}, uncaught=${errors.length}',
        );
      case _Boundary.savepoint:
        final wire = Wire(0, (wire) => wire as int);
        final asked = Unchanged(x);
        if (step.alternate) x.value = step.value + 1;
        late bool kept;
        final committed = transact((p) {
          kept = p.part(() {
            p.require(asked);
            p.set(x, step.value);
            wire.stage(p, step.value);
          });
          // The part's ledger is staged, not installed: the root decodes too.
          wire.stage(p, step.value);
        });
        return (
          values: [x.peek(), wire.readable.peek()],
          events: seen,
          result: '$committed:$kept',
        );
      case _Boundary.condition:
        final first = owner.slot(), second = owner.slot();
        final run = await first.run((t) async {
          // A condition is a value: taken here, required by another task.
          final asked = step.alternate ? Unchanged(y) : null;
          if (step.value.isEven) (step.alternate ? y : x).value = 1;
          final result = await second.run<bool>(
            (other) async => other.publish((p) {
              if (asked != null) p.require(asked);
              p.set(x, step.value);
            }),
          );
          return switch (result) {
            Done(:final value) => '$value',
            Stale(:final reason) => reason.name,
            Failed() => 'failed',
            Skipped() => 'skipped',
          };
        });
        return (
          values: [x.peek(), y.peek()],
          events: seen,
          result: '${(run as Done).value}',
        );
      case _Boundary.join:
        final slot = owner.slot(), firstCaller = owner.slot();
        final resolve = Completer<void>();
        late Future<Outcome<bool>> first, duplicate;
        final admitted = firstCaller.run((_) async {
          first = slot.run((child) async {
            seen.add(1);
            await resolve.future;
            return child.publish((p) => p.set(x, step.value + 1));
          }, key: step.value);
          await first;
        });
        x.value = step.value;
        await owner.slot().run((_) async {
          if (step.alternate) {
            batch(() {
              y.value = 1;
              y.value = 0;
            });
          }
          // A join is not re-admitted: the joiner shares the first Future.
          duplicate = slot.run((_) async {
            seen.add(2);
            return true;
          }, key: step.value);
        });
        resolve.complete();
        await admitted;
        final result = await first;
        return (
          values: [x.peek(), y.peek()],
          events: seen,
          result:
              '${identical(first, duplicate)}:${(result as Done<bool>).value}',
        );
      case _Boundary.streamCancel:
        // Synchronous cancellation of a replaced stream may read the same
        // query; the last observer leaving cools it a microtask later.
        late AsyncComputed<int> query;
        final streams = <StreamController<int>>[];
        query = computedStream((_) {
          final id = streams.length;
          final stream = StreamController<int>(
            onCancel: () {
              seen.add(id);
              if (id == 0) {
                if (step.alternate) {
                  query.value;
                } else {
                  query.peek();
                }
              }
            },
          );
          streams.add(stream);
          return stream.stream;
        });
        final stop = owner.effect(() => query.value, (_, _, _) {});
        final initial = query.refresh();
        streams.last.add(step.value);
        final answer = await initial;
        stop();
        await _settle();
        final active = streams.where((s) => s.hasListener).length;
        if (active == 0) {
          for (final stream in streams) {
            await stream.close();
          }
        }
        return (
          values: [streams.length, active],
          events: seen,
          result: '${answer.runtimeType}',
        );
      case _Boundary.cleanup:
        // Scope cleanup may read or refresh a query its sibling observes;
        // a read starts nothing, and nothing keeps working after disposal.
        var starts = 0;
        final query = computedAsync((_) async => ++starts);
        final child = owner.child();
        child.effect(() => query.value, (_, _, _) {});
        owner.child().onDispose(() {
          if (step.alternate) {
            query.value;
          } else {
            unawaited(query.refresh());
          }
        });
        owner.dispose();
        await _settle();
        return (
          values: [starts, activeQueryCount],
          events: seen,
          result: '${query.peek().runtimeType}',
        );
    }
  } finally {
    owner.dispose();
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('V4 generated publication and lifecycle boundaries', () async {
    final errors = <Object>[];
    Rill.onError = (error, _) => errors.add(error);
    addTearDown(() => Rill.onError = null);
    for (var seed = 0; seed < 100; seed++) {
      for (final (index, step) in _generate(seed, 14).indexed) {
        final expected = _model(step);
        final actual = await _run(step);
        final reason = 'seed=$seed step=$index fixture=$step';
        try {
          expect(actual.result, expected.result, reason: reason);
          expect(actual.values, expected.values, reason: reason);
          expect(actual.events, expected.events, reason: reason);
          expect(errors, isEmpty, reason: reason);
        } on TestFailure {
          final file = File('../.out/command-boundary-failure.json');
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(
            jsonEncode({
              'seed': seed,
              'step': index,
              'operation': step.op.name,
              'value': step.value,
              'alternate': step.alternate,
            }),
          );
          rethrow;
        }
      }
    }
  });
}
