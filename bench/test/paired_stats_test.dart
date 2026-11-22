import 'package:rill_bench/paired_stats.dart';
import 'package:test/test.dart';

void main() {
  test('summarizes ratios rather than dividing independent medians', () {
    final alien = [1, 2, 3, 4, 5, 6, 7];
    final rill = [1, 2, 9, 4, 5, 18, 21];
    final summary = summarize([
      for (var index = 0; index < alien.length; index++)
        rill[index] / alien[index],
    ]);
    expect(summary, (median: 1.0, q1: 1.0, q3: 3.0));
  });

  test('uses linearly interpolated quartiles', () {
    expect(summarize([7, 2, 6, 4, 5, 1, 3]), (median: 4.0, q1: 2.5, q3: 5.5));
  });

  test('combines cases within a round before summarizing the family', () {
    final rounds = familyRounds([
      [1, 4, 9],
      [9, 1, 1],
    ]);
    expect(rounds, orderedEquals([closeTo(3, 1e-10), 2, closeTo(3, 1e-10)]));
    expect(summarize(rounds).median, closeTo(3, 1e-10));
  });

  test('wide IQR makes both fast and slow medians uncertain', () {
    expect(
      judge((median: 0.85, q1: 0.68, q3: 0.96), 1.10),
      BudgetStatus.uncertain,
    );
    expect(
      judge((median: 1.489, q1: 1.332, q3: 1.60), 1.35),
      BudgetStatus.uncertain,
    );
  });

  test('only the median decides within the IQR limit', () {
    expect(judge((median: 1.10, q1: 1.09, q3: 1.11), 1.10), BudgetStatus.pass);
    expect(judge((median: 1.301, q1: 1.29, q3: 1.31), 1.30), BudgetStatus.fail);
  });

  test('the IQR limit is relative and excludes the exact 10% boundary', () {
    expect(judge((median: 2, q1: 1.9, q3: 2.1), 1.9), BudgetStatus.fail);
    expect(judge((median: 2, q1: 1.9, q3: 2.101), 1.9), BudgetStatus.uncertain);
    expect(relativeIqr((median: 2, q1: 1.9, q3: 2.1)), closeTo(0.1, 1e-12));
  });
}
