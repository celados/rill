import 'package:rill_conformance/fuzz.dart';
import 'package:test/test.dart';

void main() {
  test('rill and alien_signals match the same oracle across 100,000 steps', () {
    for (var seed = 0; seed < 100; seed++) {
      final steps = generate(seed, 1000);
      for (final adapter in ['alien_signals', 'rill']) {
        final mismatch = runSequence(adapter, steps);
        if (mismatch != null) {
          fail(explainFailure(adapter, seed, steps, mismatch));
        }
      }
    }
  });

  test(
    'shrinking removes allocations and their dependent operations together',
    () {
      final steps = [
        const Step(Op.signal, 0, [10]),
        const Step(Op.computed, 1, [0, 0, 0, 1]),
        const Step(Op.effect, 2, [1]),
        const Step(Op.dispose, 2),
        const Step(Op.signal, 3, [2]),
        const Step(Op.read, 3),
        const Step(Op.write, 3, [9]),
      ];
      final result = minimize(
        steps,
        (candidate) =>
            candidate.any((step) => step.op == Op.read && step.id == 3),
      );
      expect(result, [steps[4], steps[5]]);
    },
  );
}
