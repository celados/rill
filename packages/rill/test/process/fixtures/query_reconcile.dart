// Settled fans, feedback through new queries and relinks, in a process of
// their own (debug and AOT), also imported by query_reconcile_test.dart.
// These were regressions of a former global query scheduler; with it gone the queries are back on the flush's single
// after-flush channel. Prints one JSON line.
//
// Arguments: `service` collects garbage through the VM service (run with
// --enable-vm-service=0 --disable-service-auth-codes); otherwise allocation
// pressure collects it (AOT, where the service is unavailable).
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:isolate';

import 'package:rill/rill.dart';
import 'package:vm_service/vm_service_io.dart';

/// A1: [n] independent stream queries, each observed only by its own
/// `settled()`, each sent one value in one batch. No feedback edge exists:
/// the batch returns and every query settles.
Future<String> settleFan(int n) async {
  final feeds = [
    for (var i = 0; i < n; i++) StreamController<int>.broadcast(sync: true),
  ];
  final queries = [for (final c in feeds) computedStream<int>((_) => c.stream)];
  final waits = [for (final q in queries) q.settled()];
  var outcome = 'returned';
  try {
    batch(() {
      for (final c in feeds) {
        c.add(7);
      }
    });
  } on Object catch (e) {
    outcome = 'threw ${'$e'.split(':').take(2).join(':')}';
  }
  final done = await Future.wait(waits)
      .timeout(const Duration(seconds: 2), onTimeout: () => const []);
  for (final c in feeds) {
    await c.close();
  }
  return '$outcome ${done.where((s) => s.valueOrNull == 7).length}/$n';
}

/// A2: one effect creates a new query on every run; the query's onListen
/// flips the signal the effect reads. Every query is new, but the feedback
/// runs through one signal and one effect: the flush runs out of rounds.
/// [watchdog] stops the flipping, so a runaway shows as a count instead of
/// a hang.
String feedback({int watchdog = 2000}) {
  final trigger = signal(false);
  var starts = 0;
  void Function()? stop;
  String outcome;
  try {
    stop = effect(() => trigger.value, (v, _, _) {
      computedStream<int>((_) {
        final c = StreamController<int>.broadcast(
          sync: true,
          onListen: () {
            if (++starts < watchdog) trigger.value = !v;
          },
        );
        return c.stream;
      }).settled().ignore();
    });
    outcome = 'returned';
  } on StateError catch (e) {
    outcome = '${e.message}'.split(':').first;
  }
  stop?.call();
  return starts <= 100 ? '$outcome within 100' : '$outcome after $starts';
}

@pragma('vm:never-inline')
List<WeakReference<Computed<int>>> screens(int n, {required bool relink}) => [
  for (var i = 0; i < n; i++) screen(relink: relink),
];

/// A3: a plain computed mounted, switched to another branch (it gains an
/// input while live), unmounted.
@pragma('vm:never-inline')
WeakReference<Computed<int>> screen({required bool relink}) {
  final toggle = signal(false), a = signal(0), b = signal(7);
  final c = computed(() => toggle.value ? b.value : a.value);
  final stop = effect(() => c.value, (_, _, _) {});
  if (relink) toggle.value = true;
  stop();
  return WeakReference(c);
}

/// A3: after a query has run, unmounted computeds that switched branches
/// are collectable as soon as nothing references them: no query-side table
/// holds them until the next query transition.
Future<Map<String, int>> relinkedGc({required bool service}) async {
  final query = computedAsync<int>((_) async => 7);
  await query.settled();
  await Future<void>.delayed(Duration.zero);
  final relinked = screens(512, relink: true);
  final control = screens(512, relink: false);
  // Unrelated plain work, no query transition.
  final dirt = signal(0);
  final stop = effect(() => dirt.value, (_, _, _) {});
  for (var i = 0; i < 8000; i++) {
    dirt.value = i;
  }
  stop();
  await Future<void>.delayed(Duration.zero);
  if (service) {
    final info = await dev.Service.getInfo();
    final vm = await vmServiceConnectUri('${info.serverWebSocketUri}');
    final isolate = dev.Service.getIsolateId(Isolate.current)!;
    for (var i = 0; i < 3; i++) {
      await vm.getAllocationProfile(isolate, gc: true);
    }
    await vm.dispose();
  } else {
    final pressure = List<List<Object?>?>.filled(6, null);
    for (var i = 0; i < 400; i++) {
      pressure[i % pressure.length] = List<Object?>.filled(30000, i);
      if (i % 30 == 0) await Future<void>.delayed(Duration.zero);
    }
  }
  int alive(List<WeakReference<Object>> refs) =>
      refs.where((r) => r.target != null).length;
  return {'relinked': alive(relinked), 'control': alive(control)};
}

Future<void> main(List<String> args) async {
  final result = <String, Object?>{
    'fan99': await settleFan(99),
    'fan180': await settleFan(180),
    'gc': await relinkedGc(service: args.contains('service')),
    'feedback': feedback(),
  };
  print(jsonEncode(result));
  exit(0);
}
