import 'dart:async';
import 'dart:isolate';

import 'adapter.dart';
import 'src/rft/graphPropagation.dart';
import 'src/rft/dynamicDeps.dart';
import 'src/rft/computedEval.dart';
import 'src/rft/equality.dart';
import 'src/rft/effectLifecycle.dart';
import 'src/rft/nestedEffects.dart';
import 'src/rft/innerWrite.dart';
import 'src/rft/cycleDetection.dart';
import 'src/rft/batching.dart';
import 'src/rft/untracked.dart';
import 'src/rft/errorHandling.dart';
import 'src/rft/staleEvaluation.dart';
import 'src/rft/memoryGc.dart';
import 'src/rft/behaviorDifferences.dart';
import 'src/rft/fixture.dart';

final fixtures = List<Fixture>.unmodifiable([
  ...graphPropagationCases,
  ...dynamicDepsCases,
  ...computedEvalCases,
  ...equalityCases,
  ...effectLifecycleCases,
  ...nestedEffectsCases,
  ...innerWriteCases,
  ...cycleDetectionCases,
  ...batchingCases,
  ...untrackedCases,
  ...errorHandlingCases,
  ...staleEvaluationCases,
  ...memoryGcCases,
  ...behaviorDifferencesCases,
]);

enum Outcome { pass, variant, fail }

typedef Result = ({Outcome outcome, String detail});

Future<Result> observe(String adapter, Fixture fixture) async {
  final port = ReceivePort();
  final worker = await Isolate.spawn(
    _runFixture,
    (port.sendPort, adapter, fixture.id),
    onExit: port.sendPort,
    onError: port.sendPort,
  );
  try {
    final message = await port.first.timeout(
      Duration(seconds: fixture.mayNotTerminate ? 5 : 10),
    );
    if (message is Result) return message;
    return (outcome: Outcome.fail, detail: 'Worker exited: $message');
  } on TimeoutException {
    return (outcome: Outcome.fail, detail: 'Worker timed out');
  } finally {
    worker.kill(priority: Isolate.immediate);
    port.close();
  }
}

void _runFixture((SendPort, String, int) request) {
  final (port, name, id) = request;
  final fixture = fixtures.singleWhere((fixture) => fixture.id == id);
  final adapter = adapterFor(name);
  Result result;
  try {
    Object? variant;
    adapter.run(() => variant = fixture.run(adapter));
    if (fixture.variants.isEmpty) {
      result = (outcome: Outcome.pass, detail: '');
    } else if (fixture.variants.contains(variant)) {
      result = (outcome: Outcome.variant, detail: variant as String);
    } else {
      result = (outcome: Outcome.fail, detail: 'Undeclared variant: $variant');
    }
  } on Object catch (error, stack) {
    final location = stack
        .toString()
        .split('\n')
        .firstWhere(
          (frame) =>
              frame.contains('/rft/') && !frame.contains('/fixture.dart:'),
          orElse: () => '',
        );
    result = (
      outcome: Outcome.fail,
      detail: '$error ${location.trim()}'.trim(),
    );
  }
  Isolate.exit(port, result);
}
