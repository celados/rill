// A cooled Future query is not kept alive by a producer
// Future that never completes, while a pending settled() keeps its query
// until it answers. Forces GC through the VM service; prints one JSON line.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:isolate';

import 'package:rill/rill.dart';
import 'package:vm_service/vm_service_io.dart';

@pragma('vm:never-inline')
WeakReference<AsyncComputed<int>> mountAndCool(Future<int> result) {
  final q = computedAsync<int>((_) => result);
  effect(() => q.value, (_, _, _) {})();
  return WeakReference(q);
}

@pragma('vm:never-inline')
Future<AsyncState<int>> settleOnly(Future<int> result) =>
    computedAsync<int>((_) => result).settled();

Future<void> main() async {
  final info = await dev.Service.getInfo();
  final service = await vmServiceConnectUri('${info.serverWebSocketUri}');
  final isolate = dev.Service.getIsolateId(Isolate.current)!;
  Future<void> collect() async {
    for (var i = 0; i < 3; i++) {
      await service.getAllocationProfile(isolate, gc: true);
    }
  }

  final never = Completer<int>();
  final cooled = mountAndCool(never.future);
  final later = Completer<int>();
  final settled = settleOnly(later.future);
  await Future<void>.delayed(Duration.zero);
  await collect();
  final cooledAlive = cooled.target != null;
  later.complete(7);
  final answer = await settled.timeout(const Duration(seconds: 5));
  await service.dispose();
  print(jsonEncode({'cooledAlive': cooledAlive, 'settled': '$answer'}));
}
