// A small app for the VM service and release-mode checks.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rill/debug.dart';
import 'package:rill/rill.dart';

Future<void> main(List<String> args) async {
  final app = Scope(name: 'app');
  final count = signal(0, name: 'count');
  final doubled = computed(() => count.value * 2, name: 'doubled');
  final label = computed(() => 'n=${doubled.value}');
  final seen = <String>[];
  app.effect(() => label.value, (value, _, _) {
    seen.add(value);
  }, name: 'render');
  final sync = app.child(name: 'session').slot(name: 'sync');
  final gate = Completer<int>();
  final pending = sync.run((_) => gate.future, key: 'poll');
  count.value = 1;
  batch(() => count.value = 2);
  stdout.writeln(
    jsonEncode({
      'enabled': RillDebug.enabled,
      'why': RillDebug.why().length,
      'nodes': RillDebug.graph()['count'],
      'location': RillDebug.describe(count)?.location?.toString(),
      'seen': seen,
    }),
  );
  if (!args.contains('--wait')) {
    gate.complete(0);
    await pending;
    app.dispose();
    return;
  }
  await stdin.drain<void>();
  gate.complete(0);
  await pending;
  app.dispose();
}
