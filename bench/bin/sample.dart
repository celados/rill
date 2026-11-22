import 'dart:convert';
import 'dart:io';

import 'package:rill_bench/kairo.dart';
import 'package:rill_bench/other.dart';
import 'package:rill_conformance/adapter.dart';
import 'package:signals_core/signals_core.dart' show SignalEffectException;

const benchmark = String.fromEnvironment('CASE');

Workload _build(ReactiveAdapter fw) => switch (benchmark) {
  'kairo-avoidable' => avoidable(fw),
  'kairo-broad' => broad(fw),
  'kairo-deep' => deep(fw),
  'kairo-diamond' => diamond(fw),
  'kairo-mux' => mux(fw),
  'kairo-repeated' => repeated(fw),
  'kairo-triangle' => triangle(fw),
  'kairo-unstable' => unstable(fw),
  'mol' => mol(fw),
  'dynamic-simple' => dynamicGraph(fw, (
    width: 10,
    layers: 5,
    staticFraction: 1,
    fanIn: 2,
    readFraction: 0.2,
    writes: 500,
  )),
  'dynamic-component' => dynamicGraph(fw, (
    width: 10,
    layers: 10,
    staticFraction: 0.75,
    fanIn: 6,
    readFraction: 0.2,
    writes: 100,
  )),
  'dynamic-large' => dynamicGraph(fw, (
    width: 1000,
    layers: 12,
    staticFraction: 0.95,
    fanIn: 4,
    readFraction: 1,
    writes: 50,
  )),
  'dynamic-wide-dense' => dynamicGraph(fw, (
    width: 1000,
    layers: 5,
    staticFraction: 1,
    fanIn: 25,
    readFraction: 1,
    writes: 50,
  )),
  'dynamic-deep' => dynamicGraph(fw, (
    width: 5,
    layers: 500,
    staticFraction: 1,
    fanIn: 3,
    readFraction: 1,
    writes: 50,
  )),
  _ => cellx(fw, int.parse(benchmark.split('-').last)),
};

double _sample(int minimumMs, void Function(Stopwatch) invoke) {
  final measured = Stopwatch();
  final wallTime = Stopwatch()..start();
  var invocations = 0;
  do {
    invoke(measured);
    invocations++;
  } while (wallTime.elapsedMilliseconds < minimumMs);
  return measured.elapsedTicks * 1e9 / measured.frequency / invocations;
}

List<double> _measure(String adapter, int ms, int samples) {
  final fw = adapterFor(adapter);
  List<double> run(void Function(Stopwatch) invoke) {
    _sample(ms < 100 ? ms : 100, invoke);
    return List.generate(samples, (_) => _sample(ms, invoke));
  }

  if (benchmark.startsWith('cold-')) {
    final depth = int.parse(benchmark.split('-').last);
    var input = 0;
    return run((watch) {
      final source = fw.signal(input++);
      final tail = chain(fw, depth, source.read);
      watch.start();
      final result = tail.read();
      watch.stop();
      check(result == input - 1 + depth, 'cold chain value');
    });
  }
  // The process owns the graph's lifetime. An alien effect scope would
  // subscribe to top-level reads and grow its dependency list across samples.
  final workload = _build(fw);
  return run((watch) {
    watch.start();
    workload();
    watch.stop();
  });
}

bool _overflow(Object error) {
  var cause = error;
  while (cause is SignalEffectException) {
    final inner = cause.error;
    if (inner == null) break;
    cause = inner;
  }
  return cause is StackOverflowError;
}

int _coldLimit(ReactiveAdapter fw) {
  bool passes(int depth) {
    final source = fw.signal(1);
    final tail = chain(fw, depth, source.read);
    try {
      check(tail.read() == 1 + depth, 'cold depth value');
      return true;
    } on Object catch (error) {
      if (!_overflow(error)) rethrow;
      return false;
    }
  }

  var low = 0;
  var high = 1024;
  while (passes(high)) {
    low = high;
    high *= 2;
  }
  while (high - low > 1) {
    final mid = (low + high) ~/ 2;
    if (passes(mid)) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return low;
}

String _warmDepth(ReactiveAdapter fw, int depth) {
  final source = fw.signal(1);
  var read = source.read;
  for (var i = 0; i < depth; i++) {
    final previous = read;
    read = fw.computed(() => previous() + 1).read;
    check(read() == i + 2, 'prewarmed value');
  }
  var observed = 0;
  final stop = fw.effect(() => observed = read());
  check(observed == depth + 1, 'initial depth value');
  source.write(2);
  check(observed == depth + 2, 'warm depth value after write');
  try {
    stop();
    return 'pass';
  } on Object catch (error) {
    if (!_overflow(error)) rethrow;
    return 'stack overflow';
  }
}

void main(List<String> args) {
  final [adapter, millis, repetitions] = args;
  final envelope = {'case': benchmark, 'adapter': adapter};
  try {
    if (benchmark == 'cold-limit') {
      stdout.writeln(
        jsonEncode({...envelope, 'depth': _coldLimit(adapterFor(adapter))}),
      );
      return;
    }
    if (benchmark == 'warm-300000') {
      final teardown = _warmDepth(adapterFor(adapter), 300000);
      stdout.writeln(
        jsonEncode({...envelope, 'status': 'pass', 'teardown': teardown}),
      );
      return;
    }
    final samples = _measure(
      adapter,
      int.parse(millis),
      int.parse(repetitions),
    );
    final sorted = [...samples]..sort();
    stdout.writeln(
      jsonEncode({
        ...envelope,
        'samples_ns': samples,
        'median_ns': sorted[sorted.length ~/ 2],
      }),
    );
  } on Object catch (error) {
    if ((!benchmark.startsWith('cold-') && benchmark != 'warm-300000') ||
        !_overflow(error)) {
      rethrow;
    }
    stdout.writeln(jsonEncode({...envelope, 'status': 'stack overflow'}));
  }
}
