import 'dart:math';

typedef RatioSummary = ({double median, double q1, double q3});

enum BudgetStatus { pass, uncertain, fail }

double _quantile(List<double> sorted, double percentile) {
  final index = (sorted.length - 1) * percentile;
  final lower = index.floor();
  return sorted[lower] +
      (sorted[index.ceil()] - sorted[lower]) * (index - lower);
}

RatioSummary summarize(Iterable<double> samples) {
  final sorted = samples.toList()..sort();
  return (
    median: _quantile(sorted, 0.5),
    q1: _quantile(sorted, 0.25),
    q3: _quantile(sorted, 0.75),
  );
}

/// Combine like-numbered rounds across a family's cases. Each input is already
/// a ratio from two consecutive processes for the same case.
List<double> familyRounds(List<List<double>> cases) => [
  for (var round = 0; round < cases.first.length; round++)
    exp(
      cases.fold(0.0, (sum, samples) => sum + log(samples[round])) /
          cases.length,
    ),
];

double relativeIqr(RatioSummary ratios) =>
    (ratios.q3 - ratios.q1) / ratios.median;

BudgetStatus judge(RatioSummary ratios, double budget) {
  if (ratios.q3 > ratios.q1 + ratios.median * 0.10) {
    return BudgetStatus.uncertain;
  }
  if (ratios.median > budget) return BudgetStatus.fail;
  return BudgetStatus.pass;
}
