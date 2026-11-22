import 'dart:convert';
import 'dart:io';

import 'package:rill_bench/paired_stats.dart';
import 'package:rill_conformance/adapter.dart';

const cases = [
  'kairo-avoidable',
  'kairo-broad',
  'kairo-deep',
  'kairo-diamond',
  'kairo-mux',
  'kairo-repeated',
  'kairo-triangle',
  'kairo-unstable',
  'cellx-10',
  'cellx-20',
  'cellx-30',
  'cellx-1000',
  'cellx-2500',
  'cellx-5000',
  'mol',
  'dynamic-simple',
  'dynamic-component',
  'dynamic-large',
  'dynamic-wide-dense',
  'dynamic-deep',
  'cold-50',
  'cold-500',
  'cold-1000',
  'cold-2500',
  'cold-5000',
  'cold-limit',
  'warm-300000',
];

typedef Sample = Map<String, dynamic>;
typedef CaseResult = ({
  Map<String, Sample> engines,
  List<double> ratios,
  List<List<Sample>> pairs,
});

const _alien = 'alien_signals';
const _rill = 'rill';
const _reference = 'signals_core';
const _rounds = 7;
const _windowMs = 1000;

/// Every benchmark process, rill and the references alike, runs with a fixed
/// new generation: initial and maximum semi-space are equal, so the VM's
/// growth heuristic cannot move the cold cases by a size class when a node
/// changes size (docs/bench.md, measurement basis).
const _vmOptions = '--new_gen_semi_initial_size=32,--new_gen_semi_max_size=32';

/// The split-effect overhead has a separate CellX budget.
double _budget(String family) => family == 'cellx' ? 1.35 : 1.10;

String _ratio(double value) => '${value.toStringAsFixed(3)}×';

String _interval(RatioSummary value) =>
    '${_ratio(value.q1)}–${_ratio(value.q3)}';

num? _time(Sample sample) => sample['median_ns'] as num?;

String _cell(Sample sample) {
  final depth = sample['depth'];
  if (depth != null) return '$depth layers';
  if (sample['teardown'] == 'stack overflow') {
    return 'pass (teardown overflow)';
  }
  final time = _time(sample);
  return time == null
      ? sample['status'] as String
      : (time / 1000).toStringAsFixed(3);
}

Map<String, RatioSummary> _families(Map<String, CaseResult> results) {
  final families = <String, List<List<double>>>{};
  for (final entry in results.entries) {
    if (entry.value.ratios.isEmpty) continue;
    final family = entry.key.split('-').first;
    families.putIfAbsent(family, () => []).add(entry.value.ratios);
  }
  return families.map(
    (family, samples) => MapEntry(family, summarize(familyRounds(samples))),
  );
}

String _report(
  Map<String, CaseResult> results,
  Map<String, RatioSummary> families,
  String environment,
  String loadAverage,
  List<String> failures,
) {
  final output = StringBuffer('''
---
type: Reference
title: rill AOT benchmarks
description: Paired native Dart benchmark measurements for rill and alien_signals.
timestamp: 2026-11-18
---

# AOT benchmarks

$environment. Start load average (1m / 5m / 15m) $loadAverage.

Each timed case runs $_rounds paired rounds. A round starts one AOT process
per engine, each with 100 ms warmup and one at-least-${_windowMs} ms window.
The two processes run back to back and their order alternates between rounds.
Every process runs with a fixed 32 MB new-generation semi-space (initial =
maximum, `$_vmOptions`), the same for every engine.
The per-case ratio is the median of the seven rill / alien_signals ratios.
Absolute times below are medians in microseconds per workload. The signals_core
reference runs separately after the pairs and does not enter the verdict.

A family score is the geometric mean of its case ratios for each round
index, followed by the median across those seven scores. Q1–Q3 uses linear
interpolation at the 25th and 75th percentiles. The budget is 1.10× for graph
workloads and 1.35× for CellX. A Q1–Q3 width greater than 10% of the median
makes a family **uncertain** and prompts a rerun on an idle machine.
The gate runs only on a local arm64 machine before a release, never in CI:
the CI runners are shared hosted machines whose load is outside this
gate's control, and the budgets were calibrated on arm64.
Otherwise, a median above budget fails and a median within budget passes.
Depth checks use independent processes and retain their pass criteria.

Warm workloads time writes, reads and validation on prebuilt observed graphs.
Cold workloads build a fresh unobserved chain outside the timer and time its
first terminal read. The cold limit is found by binary search. The warm
depth check pre-evaluates each node before attaching a terminal effect.
Timings include adapter overhead.

Workloads follow [js-reactivity-benchmark](https://github.com/transitive-bullshit/js-reactivity-benchmark/tree/b79242895c35307da995dd271d6f1b570472a826).
Dynamic workloads use Dart's seeded RNG. CellX alternates the two upstream
input tuples on the warm graph.

| Case | alien_signals | signals_core | rill | Paired median | Q1–Q3 |
| --- | ---: | ---: | ---: | ---: | ---: |
''');
  for (final MapEntry(key: name, value: result) in results.entries) {
    final cells = adapterNames.map((name) => _cell(result.engines[name]!));
    final summary = result.ratios.isEmpty ? null : summarize(result.ratios);
    output.writeln(
      '| $name | ${cells.join(' | ')} | '
      '${summary == null ? '— | —' : '${_ratio(summary.median)} | ${_interval(summary)}'} |',
    );
  }
  output.write('''

| Workload family | Paired median | Q1–Q3 | Budget | Verdict |
| --- | ---: | ---: | ---: | --- |
''');
  for (final MapEntry(key: family, value: summary) in families.entries) {
    final budget = _budget(family);
    output.writeln(
      '| $family | ${_ratio(summary.median)} | ${_interval(summary)} | '
      '${budget.toStringAsFixed(2)}× | ${judge(summary, budget).name} |',
    );
  }
  final uncertain = families.entries.any(
    (entry) => judge(entry.value, _budget(entry.key)) == BudgetStatus.uncertain,
  );
  final verdict = failures.isNotEmpty
      ? 'fail'
      : (uncertain ? 'uncertain' : 'pass');
  output.writeln('\n**Gate verdict** $verdict.');
  for (final failure in failures) {
    output.writeln('- $failure');
  }
  return output.toString();
}

Future<Sample> _sample(
  String exe,
  String name,
  String adapter,
  int window,
) async {
  final process = await Process.run(
    exe,
    [adapter, '$window', '1'],
    environment: {'DART_VM_OPTIONS': _vmOptions},
  );
  if (process.exitCode != 0) {
    throw StateError(
      '$name / $adapter failed\n${process.stdout}\n${process.stderr}',
    );
  }
  return jsonDecode(process.stdout as String) as Sample;
}

Sample _aggregate(List<Sample> samples) {
  final first = samples.first;
  if (_time(first) == null) return first;
  final timings = samples.map((sample) => _time(sample)!.toDouble()).toList();
  return {
    ...first,
    'samples_ns': timings,
    'median_ns': summarize(timings).median,
  };
}

Future<CaseResult> _measure(
  String exe,
  String name,
  int index,
  int rounds,
  int window,
) async {
  final engines = <String, Sample>{};
  final ratios = <double>[];
  final pairs = <List<Sample>>[];
  final depthCheck = name == 'cold-limit' || name == 'warm-300000';
  if (depthCheck) {
    for (final adapter in adapterNames) {
      engines[adapter] = await _sample(exe, name, adapter, window);
    }
  } else {
    final alien = <Sample>[];
    final rill = <Sample>[];
    for (var round = 0; round < rounds; round++) {
      // Keep the reference run and compiler outside each pair.
      final order = (index + round).isEven ? [_alien, _rill] : [_rill, _alien];
      final pair = <Sample>[
        for (final adapter in order) await _sample(exe, name, adapter, window),
      ];
      pairs.add(pair);
      final a = pair.firstWhere((sample) => sample['adapter'] == _alien);
      final r = pair.firstWhere((sample) => sample['adapter'] == _rill);
      alien.add(a);
      rill.add(r);
      final at = _time(a);
      final rt = _time(r);
      if (at == null || rt == null) {
        // A cold stack overflow has no comparable timing. Reject a case
        // that loses timing midway rather than discarding individual pairs.
        if (round != 0)
          throw StateError('$name lost a timing in round ${round + 1}');
        break;
      }
      ratios.add(rt / at);
    }
    engines[_alien] = _aggregate(alien);
    engines[_rill] = _aggregate(rill);
    engines[_reference] = await _sample(exe, name, _reference, window);
  }
  return (engines: engines, ratios: ratios, pairs: pairs);
}

List<String> _failures(
  Map<String, CaseResult> results,
  Map<String, RatioSummary> families,
) {
  final alienDepth = results['cold-limit']?.engines[_alien]?['depth'] as int?;
  final rillDepth = results['cold-limit']?.engines[_rill]?['depth'] as int?;
  return [
    for (final MapEntry(key: family, value: summary) in families.entries)
      if (judge(summary, _budget(family)) == BudgetStatus.fail)
        '$family median ${_ratio(summary.median)} (Q1–Q3 ${_interval(summary)}) '
            'exceeds ${_budget(family).toStringAsFixed(2)}×',
    for (final MapEntry(key: name, value: result) in results.entries)
      if (_time(result.engines[_alien]!) != null &&
          _time(result.engines[_rill]!) == null)
        '$name has an alien_signals timing but no rill timing',
    if (results.containsKey('cold-limit') &&
        (alienDepth == null || rillDepth == null || rillDepth < alienDepth))
      'cold first read reaches $rillDepth layers versus $alienDepth',
    if (results.containsKey('warm-300000') &&
        results['warm-300000']!.engines[_rill]!['status'] != 'pass')
      'warm propagation did not reach 300,000 layers',
  ];
}

Future<String> _loadAverage() async {
  try {
    final uptime = await Process.run('uptime', const []);
    if (uptime.exitCode != 0) return 'unavailable';
    final match = RegExp(
      r'load averages?:\s*([0-9.]+)[,\s]+([0-9.]+)[,\s]+([0-9.]+)',
    ).firstMatch(uptime.stdout as String);
    if (match != null) return [match[1], match[2], match[3]].join(' / ');
  } on ProcessException {
    return 'unavailable';
  }
  return 'unavailable';
}

Future<void> main(List<String> args) async {
  final smoke = args.contains('--smoke');
  final gate = args.contains('--gate');
  if (smoke && gate)
    throw ArgumentError('The performance gate needs full samples.');
  final filters = args
      .where((arg) => arg != '--smoke' && arg != '--gate')
      .toList();
  final selected = filters.isEmpty ? cases : filters;
  if (selected.toSet().length != selected.length ||
      !selected.every(cases.contains)) {
    throw ArgumentError.value(
      filters,
      'cases',
      'Use names from the cases list',
    );
  }
  if (filters.isNotEmpty && !smoke) {
    throw ArgumentError(
      'Filtered runs require --smoke to preserve the full baseline.',
    );
  }
  final loadAverage = await _loadAverage();
  stderr.writeln('Load average (1m / 5m / 15m) $loadAverage');
  stderr.writeln('Rerun on an idle machine if a workload is uncertain.');
  final scratch = Directory.systemTemp.createTempSync('rill-bench-');
  final results = <String, CaseResult>{};
  final window = smoke ? 10 : _windowMs;
  final rounds = smoke ? 1 : _rounds;
  final output = Directory('../.out')..createSync();
  try {
    for (final (index, name) in selected.indexed) {
      final exe = '${scratch.path}/sample';
      final build = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        '-DCASE=$name',
        'bin/sample.dart',
        '-o',
        exe,
      ]);
      if (build.exitCode != 0) {
        throw StateError(
          '$name compile failed\n${build.stdout}\n${build.stderr}',
        );
      }
      results[name] = await _measure(exe, name, index, rounds, window);
      stderr.writeln('$name verified');
    }
    final system = Platform.operatingSystem == 'macos'
        ? (await Process.run('sysctl', [
            '-n',
            'machdep.cpu.brand_string',
          ])).stdout.toString().trim()
        : Platform.operatingSystem;
    final environment =
        '$system, ${Platform.version.split(' (').first}, ${Platform.operatingSystem}';
    final json = File('${output.path}/${smoke ? 'bench-smoke' : 'bench'}.json');
    final families = _families(results);
    final failures = _failures(results, families);
    json.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'environment': environment,
        'load_average': loadAverage,
        'window_ms': window,
        'rounds': rounds,
        'results': {
          for (final MapEntry(key: name, value: result) in results.entries) name: {...result.engines, 'paired_ratios': result.ratios, 'pairs': result.pairs},
        },
        'families': {
          for (final MapEntry(key: family, value: summary) in families.entries) family: {'median': summary.median, 'q1': summary.q1, 'q3': summary.q3, 'relative_iqr': relativeIqr(summary), 'budget': _budget(family), 'verdict': judge(summary, _budget(family)).name},
        },
        'failures': failures,
      })}\n',
    );
    if (!smoke) {
      final report = File('../docs/bench.md');
      final previous = report.existsSync() ? report.readAsStringSync() : '';
      final appendix = previous.indexOf('\n## Ablation');
      final notes = appendix < 0 ? '' : previous.substring(appendix);
      report.writeAsStringSync(
        _report(results, families, environment, loadAverage, failures) + notes,
      );
    }
    stdout.writeln(json.path);
    for (final MapEntry(key: family, value: summary) in families.entries) {
      final budget = _budget(family);
      final verdict = judge(summary, budget);
      stderr.writeln(
        '$family: ${_ratio(summary.median)} '
        '(Q1–Q3 ${_interval(summary)}), budget ${budget.toStringAsFixed(2)}×, '
        '${verdict.name}',
      );
      if (verdict == BudgetStatus.uncertain && !smoke) {
        stderr.writeln(
          'Warning: $family relative IQR is '
          '${(relativeIqr(summary) * 100).toStringAsFixed(1)}% (>10%). '
          'Rerun on an idle machine.',
        );
      }
    }
    if (gate) {
      failures.forEach(stderr.writeln);
      if (failures.isNotEmpty) exitCode = 1;
    }
  } finally {
    scratch.deleteSync(recursive: true);
  }
}
