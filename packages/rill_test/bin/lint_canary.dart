// Proves rill_lint is running for this package: drops a file with known
// violations into lib/, analyzes the package the way the gate does, and fails
// unless rill_lint reports on that file. The analyzer drops plugins without a
// word in some layouts (a nested package with its own package_config, see
// docs/lint.md#插件静默), so "analyze passed" alone proves nothing.
//
// Usage, from the package root: dart run rill_test:lint_canary
import 'dart:io';

const _name = '__rill_lint_canary.dart';

const _source = '''
// Written by `dart run rill_test:lint_canary`, deleted when it finishes.
import 'package:rill/rill.dart';

final _source = signal(0);

final _derived = computed(() {
  _source.value = 1;
  return 0;
});

Future<void> _late() async {
  await Future<void>.value();
  _source.value = 2;
}
''';

Future<void> main(List<String> args) async {
  final root = Directory(args.isEmpty ? '.' : args.single).absolute;
  final lib = Directory('${root.path}/lib');
  if (!lib.existsSync()) {
    stderr.writeln('rill_lint canary: ${root.path} has no lib/.');
    exit(2);
  }
  final canary = File('${lib.path}/$_name');
  if (canary.existsSync()) {
    stderr.writeln(
      'rill_lint canary: ${canary.path} exists; a previous run was cut short. Delete it.',
    );
    exit(2);
  }
  ProcessResult result;
  canary.writeAsStringSync(_source);
  final cleanup = ProcessSignal.sigint.watch().listen((_) {
    if (canary.existsSync()) canary.deleteSync();
    exit(130);
  });
  try {
    result = await Process.run('dart', [
      'analyze',
      '--format=machine',
      root.path,
    ]);
  } finally {
    if (canary.existsSync()) canary.deleteSync();
    await cleanup.cancel();
  }
  final fired = <String>{
    for (final line in '${result.stdout}\n${result.stderr}'.split('\n'))
      if (line.split('|') case [_, _, final code, final file, ...]
          when file.endsWith(_name) && code.toLowerCase().startsWith('rill_'))
        code.toLowerCase(),
  };
  if (fired.isEmpty) {
    stderr.writeln(
      'rill_lint canary: no rill_lint diagnostic on lib/$_name, so the plugin is not running here.\n'
      'Check that analysis_options.yaml at the package root lists rill_lint under plugins with\n'
      'rill_write_in_computed or rill_write_after_await enabled, and that no nested package with\n'
      'its own .dart_tool/package_config.json sits inside the analyzed tree (exclude it under\n'
      'analyzer.exclude and analyze it on its own). See rill docs/lint.md#插件静默.',
    );
    exit(1);
  }
  stdout.writeln(
    'rill_lint canary: plugin active (${(fired.toList()..sort()).join(', ')}).',
  );
}
