// Two answers that outlived their owners. With `service` the
// fixture forces GC through the VM service (debug); without it, it applies
// allocation pressure (AOT has no service). Prints one JSON line.
//
// `cache`: a cooled `retain: 0` query whose handle is still stored holds no
// answer: the computed's cached state and its answer key let go when it
// cools, not at the next read, and a cold read still sees AsyncLoading.
// `slot`: a disposed scope's task whose body returned a Future that never
// completes holds no page model: cancelling cuts the run off the Future.
// It holds no Scope and no Task either: a count of active
// tasks only says the task left the scheduler, so the fixture watches the
// Scope and the Task themselves.
//
// `owners`: the same without a page model, the way a page
// waits on a shared SDK-ready Future: the body reaches neither its Scope
// nor its Task once it returned, so a cut link must not reach them either.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:rill/debug.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:vm_service/vm_service.dart' show VmService;
import 'package:vm_service/vm_service_io.dart';

const pages = 128;

// ---- #2: cooled queries -------------------------------------------------

final held = <AsyncComputed<Object>>[];
final answers = <WeakReference<Uint8List>>[];

Future<Uint8List> load(Query _) async {
  final answer = Uint8List(32768);
  answers.add(WeakReference(answer));
  return answer;
}

@pragma('vm:never-inline')
Future<void> visit({required bool store}) async {
  final q = computedAsync<Uint8List>(load);
  if (store) held.add(q);
  await q.settled();
}

/// An upstream a downstream waited on: its answer key caches the answer too.
@pragma('vm:never-inline')
Future<void> visitWaited() async {
  final up = computedAsync<Uint8List>(load);
  final down = computedAsync<int>((q) async => (await q.wait(up)).length);
  held.addAll([up, down]);
  await down.settled();
}

int alive(Iterable<WeakReference<Object>> refs) =>
    refs.where((r) => r.target != null).length;

Future<Map<String, Object?>> cache(Future<void> Function() collect) async {
  for (var i = 0; i < 2 * pages; i++) {
    await visit(store: i < pages);
  }
  for (var i = 0; i < pages; i++) {
    await visitWaited();
  }
  await collect();
  final cooled = {
    'stored': alive(answers.take(pages)),
    'control': alive(answers.skip(pages).take(pages)),
    'waited': alive(answers.skip(2 * pages)),
    'active': activeQueryCount,
  };
  final loading = held.where((q) => q.peek() is AsyncLoading).length;
  // The cold reads above started loads again; let them land and cool.
  await Future<void>.delayed(Duration.zero);
  held.clear();
  return {'cooled': cooled, 'coldReadLoading': loading};
}

// ---- #3: a scope disposed under a pending Future ------------------------

final sharedReady = Completer<int>();

final scopes = <WeakReference<Scope>>[];
final tasks = <WeakReference<Task>>[];

final class PageModel {
  final input = signal(1);
  final owner = Scope();

  /// The run holds this tear-off as its body until it starts, and the page
  /// as its key for as long as the run is reachable: from the pending Future
  /// below, unless cancelling cut it.
  Future<int> start(Task task) {
    tasks.add(WeakReference(task));
    // The shared SDK Future itself holds nothing of the page.
    return sharedReady.future;
  }
}

@pragma('vm:never-inline')
List<WeakReference<PageModel>> leave() {
  final refs = <WeakReference<PageModel>>[];
  for (var i = 0; i < pages; i++) {
    final page = PageModel();
    scopes.add(WeakReference(page.owner));
    page.owner.slot().run(page.start, key: page).ignore();
    page.owner.dispose();
    refs.add(WeakReference(page));
  }
  return refs;
}

Future<Map<String, Object?>> slot(Future<void> Function() collect) async {
  final errors = <Object>[];
  return runZonedGuarded(() async {
    // A lazy global first touched in a task body would be created in that
    // task's debug zone and keep it (the zone's value is the task): the SDK
    // Future exists before any page asks for it.
    sharedReady.isCompleted;
    final refs = leave();
    Map<String, int> count() => {
      'tasks': activeTaskCount,
      'pages': alive(refs),
      'scopes': alive(scopes),
      'taskObjects': alive(tasks),
    };
    await collect();
    final disposed = count();
    // The late answer is swallowed: no zone error, no disposed state touched.
    sharedReady.complete(1);
    await collect();
    return {
      'disposed': disposed,
      'completed': count(),
      'zoneErrors': errors.length,
    };
  }, (error, _) => errors.add(error))!;
}

// ---- owners on a pending shared Future ---------------------------------

final sdkReady = Completer<int>();
final ownerScopes = <WeakReference<Scope>>[];
final ownerTasks = <WeakReference<Task>>[];

@pragma('vm:never-inline')
void visitOwners() {
  for (var i = 0; i < pages; i++) {
    final owner = Scope();
    ownerScopes.add(WeakReference(owner));
    owner.slot().run((task) {
      ownerTasks.add(WeakReference(task));
      return sdkReady.future;
    }).ignore();
    owner.dispose();
  }
}

Future<Map<String, Object?>> owners(Future<void> Function() collect) async {
  final errors = <Object>[];
  return runZonedGuarded(() async {
    sdkReady.isCompleted; // Created outside any task zone, as in `slot`.
    visitOwners();
    Map<String, int> count() => {
      'scopes': alive(ownerScopes),
      'tasks': alive(ownerTasks),
    };
    await collect();
    final pending = count();
    sdkReady.complete(1);
    await collect();
    return {
      'pending': pending,
      'settled': count(),
      'zoneErrors': errors.length,
    };
  }, (error, _) => errors.add(error))!;
}

// ---- collection ---------------------------------------------------------

final _pressure = List<List<int>?>.filled(24, null);

@pragma('vm:never-inline')
void _allocate(int i) => _pressure[i % 24] = List<int>.filled(65000, i);

Future<void> main(List<String> args) async {
  final useService = args.contains('service');
  VmService? service;
  String? isolate;
  if (useService) {
    final info = await dev.Service.getInfo();
    service = await vmServiceConnectUri('${info.serverWebSocketUri}');
    isolate = dev.Service.getIsolateId(Isolate.current);
  }
  Future<void> collect() async {
    await Future<void>.delayed(Duration.zero);
    // The debug change log retains values on purpose; it is not the owner.
    RillDebug.clear();
    if (service != null) {
      for (var i = 0; i < 3; i++) {
        await service.getAllocationProfile(isolate!, gc: true);
      }
    } else {
      for (var i = 0; i < 1600; i++) {
        _allocate(i);
        if (i % 25 == 0) await Future<void>.delayed(Duration.zero);
      }
    }
  }

  final result = <String, Object?>{
    if (args.contains('cache')) 'cache': await cache(collect),
    if (args.contains('slot')) 'slot': await slot(collect),
    if (args.contains('owners')) 'owners': await owners(collect),
  };
  await service?.dispose();
  print(jsonEncode(result));
}
