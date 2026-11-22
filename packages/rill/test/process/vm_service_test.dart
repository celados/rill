@Tags(['process'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

const fixture = 'test/process/fixtures/app.dart';

/// A fixture VM with its service connection and the main isolate.
final class Fixture {
  Fixture._(this.process, this.service, this.isolate, this.stats);

  final Process process;
  final VmService service;
  final IsolateRef isolate;
  final Map<String, Object?> stats;

  static Future<Fixture> start({required bool asserts}) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      if (asserts) '--enable-asserts' else '--no-enable-asserts',
      '--enable-vm-service=0',
      fixture,
      '--wait',
    ]);
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    final stderrText = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(stderrText.write);
    String? uri;
    Map<String, Object?>? stats;
    await for (final line in lines.timeout(const Duration(seconds: 60))) {
      uri ??= RegExp(r'listening on (http://\S+)').firstMatch(line)?[1];
      if (line.startsWith('{')) {
        stats = jsonDecode(line) as Map<String, Object?>;
        break;
      }
    }
    if (uri == null || stats == null) {
      process.kill();
      fail('Fixture did not start: $stderrText');
    }
    final ws = Uri.parse(uri).replace(scheme: 'ws');
    final service = await vmServiceConnectUri('${ws}ws');
    final vm = await service.getVM();
    return Fixture._(process, service, vm.isolates!.single, stats);
  }

  Future<Map<String, Object?>> call(
    String method, [
    Map<String, String> args = const {},
  ]) async {
    final response = await service.callServiceExtension(
      method,
      isolateId: isolate.id,
      args: args,
    );
    return response.json!;
  }

  Future<List<String>> extensions() async =>
      (await service.getIsolate(isolate.id!)).extensionRPCs ?? const [];

  Future<void> stop() async {
    await service.dispose();
    await process.stdin.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 30)), 0);
  }
}

void main() {
  test('debug VM serves ext.rill.graph, why and active', () async {
    final app = await Fixture.start(asserts: true);
    try {
      expect(
        await app.extensions(),
        containsAll(['ext.rill.graph', 'ext.rill.why', 'ext.rill.active']),
      );

      final graph = await app.call('ext.rill.graph');
      expect(graph['type'], 'RillGraph');
      final nodes = {
        for (final node in (graph['nodes']! as List).cast<Map>())
          node['label']: node,
      };
      expect(nodes.keys, containsAll(['count', 'doubled', 'render']));
      expect(nodes['count']!['location'], '$fixture:11');
      expect(nodes['doubled']!['deps'], [nodes['count']!['id']]);

      final why = await app.call('ext.rill.why', {'target': 'render'});
      final records = (why['records']! as List).cast<Map>();
      expect(records.map((record) => record['run']), [1, 2, 3]);
      final last = records.last;
      final text = last['text']! as String;
      expect(text, contains('← signal count'));
      expect(text, contains('at $fixture:22'));
      printOnFailure(text);
      if (Platform.environment['RILL_PRINT_WHY'] != null) {
        print(const JsonEncoder.withIndent('  ').convert(why));
      }

      final active = await app.call('ext.rill.active');
      expect(active['type'], 'RillActive');
      final tasks = (active['tasks']! as List).cast<Map>();
      expect(tasks.single['label'], 'sync.task');
      expect(tasks.single['key'], 'poll');
      final effects = (active['effects']! as List).cast<Map>();
      expect(effects.single['label'], 'render');
      final scopes = (active['scopes']! as List).cast<Map>();
      final root = scopes.singleWhere((scope) => scope['label'] == 'app');
      expect(
        (root['children']! as List).cast<Map>().single['label'],
        'session',
      );
    } finally {
      await app.stop();
    }
  });

  test('without asserts nothing is recorded or registered', () async {
    final app = await Fixture.start(asserts: false);
    try {
      expect(app.stats, {
        'enabled': false,
        'why': 0,
        'nodes': 0,
        'location': null,
        'seen': ['n=0', 'n=2', 'n=4'],
      });
      expect(
        (await app.extensions()).where((name) => name.startsWith('ext.rill.')),
        isEmpty,
      );
    } finally {
      await app.stop();
    }
  });

  test('AOT without asserts drops the debug code', () async {
    final dir = await Directory.systemTemp.createTemp('rill-release-');
    addTearDown(() => dir.delete(recursive: true));
    Future<File> compile(String name, {required bool asserts}) async {
      final output = '${dir.path}/$name';
      final result = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        if (asserts) '--enable-asserts',
        '-o',
        output,
        fixture,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      return File(output);
    }

    final release = await compile('release', asserts: false);
    final run = await Process.run(release.path, const []);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    expect(jsonDecode(run.stdout as String), {
      'enabled': false,
      'why': 0,
      'nodes': 0,
      'location': null,
      'seen': ['n=0', 'n=2', 'n=4'],
    });

    // The extension names and the warning text live only in debug code. They
    // survive tree shaking with asserts, so their absence shows the release
    // binary dropped that code.
    bool mentions(File binary, String text) =>
        latin1.decode(binary.readAsBytesSync()).contains(text);
    final debug = await compile('debug', asserts: true);
    for (final name in [
      'ext.rill.graph',
      'ext.rill.why',
      'ext.rill.active',
      '(rill docs/diagnostics/',
    ]) {
      expect(mentions(debug, name), isTrue, reason: name);
      expect(mentions(release, name), isFalse, reason: name);
    }
  });
}
