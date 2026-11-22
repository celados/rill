import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:rill/rill.dart';
import 'package:test/test.dart';

enum Op {
  start,
  finish,
  fail,
  cancel,
  replace,
  condition,
  publish,
  aba,
  badPart,
  reenter,
  zonePublish,
  transact,
  deliver,
}

// `guarded`: the commit requires the row's condition, when it has one.
typedef Step = ({
  Op op,
  int id,
  int slot,
  int key,
  int field,
  int value,
  bool guarded,
});

List<Step> generate(int seed) {
  final rng = Random(seed);
  const choices = [
    Op.start,
    Op.start,
    Op.start,
    Op.start,
    Op.start,
    Op.finish,
    Op.finish,
    Op.fail,
    Op.cancel,
    Op.replace,
    Op.replace,
    Op.condition,
    Op.condition,
    Op.publish,
    Op.publish,
    Op.publish,
    Op.aba,
    Op.aba,
    Op.badPart,
    Op.reenter,
    Op.zonePublish,
    Op.zonePublish,
    Op.transact,
    Op.deliver,
  ];
  final recent = <int>[];
  return List.generate(1000, (index) {
    final op = index == 0 ? Op.start : choices[rng.nextInt(choices.length)];
    if (op == Op.start) {
      recent.add(index);
      if (recent.length > 10) recent.removeAt(0);
    }
    return (
      op: op,
      id: op == Op.start ? index : recent[rng.nextInt(recent.length)],
      slot: rng.nextInt(4),
      key: rng.nextInt(4),
      field: rng.nextInt(2),
      value: rng.nextInt(5),
      guarded: rng.nextInt(2) == 0,
    );
  });
}

final class _Row {
  _Row(this.slot, this.key);
  final int slot;
  final int key;
  bool started = false;
  bool ended = false;
  (int, int)? condition;
  String? outcome;
  bool get alive => started && outcome == null;
}

// The model has no dependency graph, Futures, or execution-context state.
// Default install (C3): a commit fails only on its task's life or on a
// required condition (C3b); delivery decides the outcome (C8a).
final class _Model {
  bool open = true;
  int clock = 0;
  final values = [0, 0];
  final revisions = [0, 0];
  final events = <int>[];
  final rows = <int, _Row>{};
  final aliases = <int, int>{};
  final live = List.generate(4, (_) => <int>[]);

  void _write(int field, int value) {
    if (values[field] == value) return;
    values[field] = value;
    revisions[field] = ++clock;
  }

  void _cancel() {
    open = false;
    for (final ids in live) {
      for (final id in ids) {
        rows[id]!.outcome = 'ownerDisposed';
      }
      ids.clear();
    }
  }

  bool holds((int, int)? condition) =>
      condition == null || revisions[condition.$1] == condition.$2;

  void _end(int id, _Row row, String outcome) {
    row.ended = true;
    if (!row.alive) return;
    row.outcome = outcome;
    final ids = live[row.slot]..remove(id);
    if (row.slot == 2 && ids.isNotEmpty) rows[ids.first]!.started = true;
  }

  Object? step(Step s) {
    if (s.op == Op.start) {
      final ids = live[s.slot];
      for (final id in ids) {
        if (rows[id]!.key == s.key) {
          aliases[s.id] = id;
          return null;
        }
      }
      aliases[s.id] = s.id;
      final row = rows[s.id] = _Row(s.slot, s.key);
      if (!open || (s.slot == 1 && ids.isNotEmpty)) {
        row.outcome = open ? 'skipped' : 'ownerDisposed';
        return null;
      }
      if (s.slot == 0) {
        for (final id in ids) {
          rows[id]!.outcome = 'superseded';
        }
        ids.clear();
      }
      if (s.slot != 2 || ids.isEmpty) row.started = true;
      ids.add(s.id);
      return null;
    }
    if (s.op == Op.cancel || s.op == Op.replace) {
      _cancel();
      open = s.op == Op.replace;
      return null;
    }
    if (s.op == Op.aba) {
      final value = values[s.field];
      _write(s.field, value + 1);
      _write(s.field, value);
      return null;
    }
    final id = aliases[s.id];
    final row = rows[id];
    if (s.op == Op.transact) {
      if (s.guarded && !holds(row?.condition)) return false;
      _write(s.field, s.value);
      events.add(s.value);
      return true;
    }
    if (row == null || !row.started || row.ended) {
      // A body that ended can no longer publish (S5).
      return row != null && row.ended && _publishes(s.op) ? 'closed' : null;
    }
    if (s.op == Op.finish || s.op == Op.fail) {
      _end(id!, row, s.op == Op.finish ? 'done:${s.value}' : 'failed');
      return null;
    }
    if (s.op == Op.deliver) {
      // The body ends, then the owner is disposed before delivery.
      _end(id!, row, 'done:${s.value}');
      if (row.outcome == 'done:${s.value}') row.outcome = 'ownerDisposed';
      _cancel();
      return null;
    }
    if (s.op == Op.condition) {
      row.condition = (s.field, revisions[s.field]);
      return null;
    }
    if (!row.alive) return false;
    if (s.op == Op.reenter) {
      _cancel(); // staging disposes the owner, whatever the condition
      return false;
    }
    if (s.guarded && !holds(row.condition)) return false;
    final target = s.op == Op.badPart ? 1 - s.field : s.field;
    _write(target, s.value);
    events.add(s.value);
    return true;
  }

  static bool _publishes(Op op) =>
      op == Op.publish ||
      op == Op.zonePublish ||
      op == Op.badPart ||
      op == Op.reenter;
}

String _describe(Outcome<Object?> outcome) => switch (outcome) {
  Done(:final value) => 'done:$value',
  Stale(:final reason) => reason.name,
  Failed() => 'failed',
  Skipped() => 'skipped',
};

final class _Actual {
  Scope scope = Scope();
  late List<Slot> slots = _slots();
  final cells = [signal(0), signal(0)];
  final _notices = Events<int>();
  final eventsSeen = <int>[];
  final handles = <int, Task>{};
  final conditions = <int, Unchanged>{};
  final answers = <int, Completer<int>>{};
  final futures = Map<Future<Outcome<int>>, int>.identity();
  final aliases = <int, int>{};
  final outcomes = <int, String>{};

  List<Slot> _slots() =>
      OnBusy.values.map((policy) => scope.slot(onBusy: policy)).toList();

  void _stage(Tx p, Step s, Unchanged? condition) {
    if (s.guarded && condition != null) p.require(condition);
    var field = s.field;
    if (s.op == Op.badPart) {
      try {
        p.part(() {
          p.set(cells[field], s.value);
          p.emit(_notices, -1);
          throw const FormatException('decode');
        });
      } on FormatException {
        // Only the part is dropped.
      }
      field = 1 - field;
    }
    p.set(cells[field], s.value);
    if (s.op == Op.reenter) scope.dispose();
    p.emit(_notices, s.value);
  }

  Future<Object?> step(Step s) async {
    Object? result;
    switch (s.op) {
      case Op.start:
        final future = slots[s.slot].run((task) {
          handles[s.id] = task;
          // Synchronous answers: a finish ends the body inside the step, so
          // a deliver can dispose the owner before the delivery microtask.
          final answer = answers[s.id] = Completer<int>.sync();
          return answer.future;
        }, key: s.key);
        aliases[s.id] = futures.putIfAbsent(future, () {
          unawaited(
            future.then((outcome) => outcomes[s.id] = _describe(outcome)),
          );
          return s.id;
        });
      case Op.cancel:
      case Op.replace:
        scope.dispose();
        if (s.op == Op.replace) {
          scope = Scope();
          slots = _slots();
        }
      case Op.finish:
      case Op.fail:
      case Op.deliver:
        final answer = answers[aliases[s.id]];
        if (answer != null && !answer.isCompleted) {
          if (s.op == Op.fail) {
            answer.completeError(StateError('failed'));
          } else {
            answer.complete(s.value);
          }
          if (s.op == Op.deliver) scope.dispose();
        }
      case Op.aba:
        batch(() {
          final value = cells[s.field].peek();
          cells[s.field].value = value + 1;
          cells[s.field].value = value;
        });
      case Op.condition:
        final id = aliases[s.id];
        if (answers[id]?.isCompleted == false) {
          conditions[id!] = Unchanged(cells[s.field]);
        }
      case Op.transact:
        result = transact((p) {
          if (s.guarded) {
            if (conditions[aliases[s.id]] case final condition?) {
              p.require(condition);
            }
          }
          p.set(cells[s.field], s.value);
          p.emit(_notices, s.value);
        });
      case Op.publish:
      case Op.zonePublish:
      case Op.badPart:
      case Op.reenter:
        final id = aliases[s.id];
        final task = handles[id];
        if (task == null) return null;
        try {
          result = runZoned(
            () => task.publish((p) => _stage(p, s, conditions[id])),
            zoneValues: {#unrelatedOwner: Object()},
          );
        } on StateError catch (error) {
          if (!'$error'.contains('RILL_CLOSED_PUBLICATION')) rethrow;
          result = 'closed';
        }
    }
    for (var i = 0; i < 3; i++) {
      await Future<void>.value();
    }
    return result;
  }

  Future<void> run(Future<void> Function() fn) async {
    final stop = _notices.listen(eventsSeen.add);
    try {
      await fn();
    } finally {
      stop();
      scope.dispose();
    }
  }
}

Future<({int index, String error})?> replay(List<Step> sequence) async {
  final model = _Model();
  final actual = _Actual();
  ({int index, String error})? failure;
  await actual.run(() async {
    for (final (index, step) in sequence.indexed) {
      try {
        expect(
          await actual.step(step),
          model.step(step),
          reason: 'publication',
        );
        expect(
          actual.cells.map((cell) => cell.peek()),
          model.values,
          reason: 'values',
        );
        expect(actual.eventsSeen, model.events, reason: 'events');
        expect(actual.handles.map((id, task) => MapEntry(id, task.alive)), {
          for (final entry in model.rows.entries)
            if (entry.value.started) entry.key: entry.value.alive,
        }, reason: 'active tasks');
        expect(actual.aliases, model.aliases, reason: 'identity');
        expect(actual.outcomes, {
          for (final entry in model.rows.entries)
            if (entry.value.outcome case final result?) entry.key: result,
        }, reason: 'outcomes');
        expect(
          actual.slots.map((slot) => slot.busy.peek()),
          model.live.map((ids) => ids.isNotEmpty),
          reason: 'active slots',
        );
      } on Object catch (error) {
        failure = (index: index, error: '$error');
        return;
      }
    }
  });
  return failure;
}

Future<List<Step>> minimize(List<Step> steps) async {
  var current = steps;
  var chunk = (current.length / 2).ceil();
  while (chunk > 0) {
    var start = 0;
    while (start < current.length) {
      final candidate = [
        ...current.take(start),
        ...current.skip(start + chunk),
      ];
      if (await replay(candidate) != null) {
        current = candidate;
      } else {
        start += chunk;
      }
    }
    chunk ~/= 2;
  }
  return current;
}

void main() {
  test('V4 command reference model across 100,000 operations', () async {
    for (var seed = 0; seed < 100; seed++) {
      final sequence = generate(seed);
      if (await replay(sequence) case final failure?) {
        final minimal = await minimize(
          sequence.take(failure.index + 1).toList(),
        );
        final file = File('../.out/command-failure.json');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(
          jsonEncode({
            'seed': seed,
            'steps': [
              for (final s in minimal)
                [s.op.name, s.id, s.slot, s.key, s.field, s.value, s.guarded],
            ],
          }),
        );
        fail(
          'Seed $seed, step ${failure.index}: ${failure.error}. Replay: ${file.path}',
        );
      }
    }
  });
}
