import 'dart:convert';
import 'dart:io';

import 'package:rill_conformance/fuzz.dart';

void main(List<String> args) {
  const adapter = 'alien_signals';
  if (args case ['--replay', final path]) {
    final rows = jsonDecode(File(path).readAsStringSync()) as List;
    final result = runSequence(
      adapter,
      rows.cast<List<dynamic>>().map(Step.fromJson).toList(),
    );
    if (result != null) {
      stderr.writeln(result);
      exitCode = 1;
    }
    return;
  }
  final seed = args.isEmpty ? 0 : int.parse(args[0]);
  final length = args.length < 2 ? 1000 : int.parse(args[1]);
  final steps = generate(seed, length);
  final failure = runSequence(adapter, steps);
  if (failure != null) {
    stderr.writeln(explainFailure(adapter, seed, steps, failure));
    exitCode = 1;
  } else {
    stdout.writeln('$adapter seed=$seed: ${steps.length} steps matched');
  }
}
