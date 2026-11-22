import 'dart:convert';
import 'dart:math';

import 'adapter.dart';

enum Op { signal, computed, effect, read, write, batch, dispose }

typedef Write = (int id, int value);

final class Step {
  const Step(this.op, this.id, [this.inputs = const []]);

  // A computed uses selector, even arm, odd arm, and bias.
  // A batch stores consecutive (signal ID, value) pairs.
  final Op op;
  final int id;
  final List<int> inputs;

  Iterable<Write> get writes sync* {
    for (var i = 0; i < inputs.length; i += 2) {
      yield (inputs[i], inputs[i + 1]);
    }
  }

  List<Object> toJson() => [op.name, id, ...inputs];

  static Step fromJson(List<dynamic> row) => Step(
    Op.values.byName(row.first as String),
    row[1] as int,
    row.skip(2).cast<int>().toList(),
  );
}

List<Step> generate(int seed, int length) {
  final random = Random(seed);
  final steps = <Step>[];
  final signals = <int>[];
  final nodes = <int>[];
  final activeEffects = <int>[];
  int pick(List<int> ids) => ids[random.nextInt(ids.length)];
  int value() => random.nextInt(65) - 32;

  for (var id = 0; id < length; id++) {
    final op = switch (random.nextInt(13)) {
      _ when signals.length < 2 => Op.signal,
      0 when signals.length < 8 => Op.signal,
      1 || 2 when nodes.length < 24 => Op.computed,
      3 || 4 when activeEffects.length < 8 => Op.effect,
      5 || 6 => Op.read,
      7 || 8 || 9 => Op.write,
      10 || 11 => Op.batch,
      _ when activeEffects.isNotEmpty => Op.dispose,
      _ => Op.read,
    };
    switch (op) {
      case Op.signal:
        signals.add(id);
        nodes.add(id);
        steps.add(Step(op, id, [value()]));
      case Op.computed:
        steps.add(
          Step(op, id, [pick(nodes), pick(nodes), pick(nodes), value()]),
        );
        nodes.add(id);
      case Op.effect:
        steps.add(Step(op, id, [pick(nodes)]));
        activeEffects.add(id);
      case Op.read:
        steps.add(Step(op, pick(nodes)));
      case Op.write:
        steps.add(Step(op, pick(signals), [value()]));
      case Op.batch:
        final pairs = <int>[];
        final count = random.nextInt(5);
        for (var i = 0; i < count; i++) {
          pairs.addAll([pick(signals), value()]);
        }
        steps.add(Step(op, id, pairs));
      case Op.dispose:
        final effect = pick(activeEffects);
        activeEffects.remove(effect);
        steps.add(Step(op, effect));
    }
  }
  return steps;
}

final class _Oracle {
  final signals = <int, int>{};
  final computed = <int, List<int>>{};

  Map<int, int> recompute() {
    final values = Map<int, int>.of(signals);
    for (final MapEntry(key: id, value: [selector, even, odd, bias])
        in computed.entries) {
      final branch = values[selector]!.isEven ? even : odd;
      values[id] = values[branch]! + bias;
    }
    return values;
  }
}

final class _Effect {
  _Effect(this.target);

  final int target;
  final readings = <int>[];
  late final Dispose stop;
  bool disposed = false;
}

typedef Divergence = ({int index, String kind, String detail});

Divergence? replay(ReactiveAdapter adapter, List<Step> steps) {
  final oracle = _Oracle();
  final signals = <int, Writable<int>>{};
  final reads = <int, int Function()>{};
  final effects = <int, _Effect>{};
  var previous = <int, int>{};

  for (final (index, step) in steps.indexed) {
    final Step(:op, :id, :inputs) = step;
    Divergence mismatch(String kind, String detail) =>
        (index: index, kind: kind, detail: detail);

    try {
      switch (op) {
        case Op.signal:
          final initial = inputs.single;
          oracle.signals[id] = initial;
          final signal = signals[id] = adapter.signal(initial);
          reads[id] = signal.read;
        case Op.computed:
          final [selector, even, odd, bias] = inputs;
          oracle.computed[id] = inputs;
          reads[id] = adapter.computed(() {
            final branch = reads[selector]!().isEven ? even : odd;
            return reads[branch]!() + bias;
          }).read;
        case Op.effect:
          final effect = effects[id] = _Effect(inputs.single);
          effect.stop = adapter.effect(() {
            effect.readings.add(reads[effect.target]!());
          });
        case Op.read:
          break;
        case Op.write:
          final next = inputs.single;
          oracle.signals[id] = next;
          signals[id]!.write(next);
        case Op.batch:
          adapter.batch(() {
            for (final (signal, next) in step.writes) {
              oracle.signals[signal] = next;
              signals[signal]!.write(next);
            }
          });
        case Op.dispose:
          final effect = effects[id]!;
          effect.stop();
          effect.disposed = true;
      }

      final expected = oracle.recompute();
      // Compare explicit pulls. Unobserved nodes stay cold until a generated read
      // or a subscriber needs them.
      if (op == Op.read) {
        final actual = adapter.untracked(reads[id]!);
        if (actual != expected[id]) {
          return mismatch(
            'read',
            'Node $id yielded $actual, expected ${expected[id]}',
          );
        }
      }
      for (final MapEntry(key: effectId, value: effect) in effects.entries) {
        final actual = effect.readings;
        final expectedValue = expected[effect.target]!;
        if (effect.disposed && actual.isNotEmpty) {
          return mismatch(
            'disposed effect',
            'Effect $effectId ran with $actual',
          );
        }
        if (actual.any((value) => value != expectedValue)) {
          return mismatch(
            'effect value',
            'Effect $effectId read $actual, expected $expectedValue',
          );
        }
        // A new effect runs once. On a visible change, a single-target effect
        // runs once after the write or batch. Equal-value emission is allowed
        // to vary with the adapter's scheduling and equality policy.
        final created = op == Op.effect && effectId == id;
        final changed = previous[effect.target] != expectedValue;
        if (!effect.disposed && (created || changed) && actual.length != 1) {
          return mismatch(
            'effect count',
            'Effect $effectId ran ${actual.length} times, expected 1',
          );
        }
        actual.clear();
      }
      if (adapter is RillAdapter) adapter.validate();
      previous = expected;
    } on Object catch (error) {
      return mismatch('exception ${error.runtimeType}', '$error');
    }
  }
  return null;
}

// A removed allocation can invalidate its readers and writers. Drop those
// dependent operations so delta debugging only executes well-formed sequences.
List<Step> _validSubsequence(Iterable<Step> steps) {
  final nodes = <int>{};
  final signals = <int>{};
  final effects = <int>{};
  final valid = <Step>[];
  for (final step in steps) {
    final Step(:op, :id, :inputs) = step;
    switch (op) {
      case Op.signal:
        nodes.add(id);
        signals.add(id);
      case Op.computed:
        if (!inputs.take(3).every(nodes.contains)) continue;
        nodes.add(id);
      case Op.effect:
        if (!nodes.contains(inputs.single)) continue;
        effects.add(id);
      case Op.read:
        if (!nodes.contains(id)) continue;
      case Op.write:
        if (!signals.contains(id)) continue;
      case Op.batch:
        valid.add(
          Step(op, id, [
            for (final (signal, value) in step.writes)
              if (signals.contains(signal)) ...[signal, value],
          ]),
        );
        continue;
      case Op.dispose:
        if (!effects.remove(id)) continue;
    }
    valid.add(step);
  }
  return valid;
}

List<Step> minimize(List<Step> steps, bool Function(List<Step>) stillFails) {
  var current = steps;
  var partitions = 2;
  while (current.length >= 2) {
    final chunk = (current.length / partitions).ceil();
    var reduced = false;
    for (var start = 0; start < current.length; start += chunk) {
      final candidate = _validSubsequence([
        ...current.take(start),
        ...current.skip(start + chunk),
      ]);
      if (stillFails(candidate)) {
        current = candidate;
        partitions = max(2, partitions - 1);
        reduced = true;
        break;
      }
    }
    if (reduced) continue;
    if (partitions >= current.length) break;
    partitions = min(current.length, partitions * 2);
  }
  return current;
}

Divergence? runSequence(String adapter, List<Step> steps) {
  final fw = adapter == 'rill'
      ? RillAdapter(inspect: true)
      : adapterFor(adapter);
  Divergence? mismatch;
  try {
    fw.run(() => mismatch = replay(fw, steps));
    return mismatch;
  } on Object catch (error) {
    return mismatch ??
        (
          index: steps.length - 1,
          kind: 'scope exception ${error.runtimeType}',
          detail: '$error',
        );
  }
}

String explainFailure(
  String adapter,
  int seed,
  List<Step> steps,
  Divergence failure,
) {
  final minimal = minimize(
    steps.sublist(0, failure.index + 1),
    (candidate) => runSequence(adapter, candidate)?.kind == failure.kind,
  );
  final reproduced = runSequence(adapter, minimal)!;
  final json = jsonEncode(minimal.map((step) => step.toJson()).toList());
  return '$adapter seed=$seed failed at step ${failure.index}: ${failure.detail}\n'
      'Reduced to ${minimal.length} operations: ${reproduced.detail}\n$json';
}
