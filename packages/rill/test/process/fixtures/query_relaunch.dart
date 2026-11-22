// In a process of their own (debug and AOT), also imported by
// query_relaunch_test.dart. The cases are user code inside one query's step
// sending another query a stream event; with stream events asynchronous
// they assert what still holds: final values,
// no superseded round past its wait, resources released, no round owed by
// finite work of any depth. Prints one JSON line.
import 'dart:async';
import 'dart:convert';

import 'package:rill/internal.dart';
import 'package:rill/rill.dart';

Future<void> turns([int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// #1 / #2: D (stream) installs 2 or relaunches while upstream B
/// resubscribes in the same batch; B's onListen sends D 3 ([variant]
/// `latest`) or sends D's other input A 2 (`install`, `launch`).
Future<List<String>> siblings(String variant) async {
  final downFeed = StreamController<int>.broadcast(sync: true);
  final aFeed = StreamController<int>.broadcast(sync: true);
  final a = computedStream<int>((_) => aFeed.stream);
  final events = <String>[];
  final bFeeds = <StreamController<int>>[];
  var armed = false;
  final toA = variant != 'latest';
  final b = computedStream<int>((_) {
    final c = StreamController<int>.broadcast(
      sync: true,
      onListen: () {
        if (!armed) return;
        armed = false;
        events.add(toA ? 'B sends A=2' : 'B sends D=3');
        (toA ? aFeed : downFeed).add(toA ? 2 : 3);
      },
    );
    bFeeds.add(c);
    return c.stream;
  });
  final keepA = effect(() => a.value, (_, _, _) {});
  final keepB = effect(() => b.value, (_, _, _) {});
  aFeed.add(1);
  bFeeds.last.add(1);
  await turns(1);
  final bValue = computed(() => b.value.valueOrNull);
  final down = computedStream<int>((_) {
    final id = a.value.valueOrNull;
    bValue.value;
    events.add('D.start $id');
    return downFeed.stream;
  });
  final stop = effect(() => down.value, (s, _, _) {
    events.add(
      'D ${s.valueOrNull}${s is AsyncData<int> && s.stale ? ' stale' : ''}',
    );
  });
  downFeed.add(1);
  await turns(1);
  armed = true;
  events.add('batch');
  batch(() {
    variant == 'launch' ? down.invalidate() : downFeed.add(2);
    b.invalidate();
  });
  await turns();
  events.add('final ${down.peek()}');
  stop();
  keepA();
  keepB();
  for (final c in [...bFeeds, aFeed, downFeed]) {
    await c.close();
  }
  return events;
}

/// #2: D's loader waits on cached A; mounting D invalidates B, whose
/// onListen sends A 2. Round 1 must not pass its await with 1.
Future<List<String>> siblingWait() async {
  final fa = StreamController<int>.broadcast(sync: true);
  final bs = <StreamController<int>>[];
  final a = computedStream<int>((_) => fa.stream);
  var armed = false;
  final log = <String>[];
  final b = computedStream<int>((_) {
    final c = StreamController<int>.broadcast(
      sync: true,
      onListen: () {
        if (!armed) return;
        armed = false;
        log.add('B sends A=2');
        fa.add(2);
      },
    );
    bs.add(c);
    return c.stream;
  });
  final oa = effect(() => a.value, (_, _, _) {});
  final ob = effect(() => b.value, (_, _, _) {});
  fa.add(1);
  bs.last.add(1);
  await turns(1);
  final stable = computed(() => b.value.valueOrNull);
  final attach = signal(false, watched: b.invalidate);
  var runs = 0;
  final d = computedAsync<int>((q) async {
    final run = ++runs;
    final f = q.wait(a);
    stable.value;
    attach.value;
    log.add('start $run');
    final id = await f;
    log.add('resume $run:$id');
    return id;
  });
  armed = true;
  final off = effect(() => d.value, (_, _, _) {});
  await turns();
  log.add('final ${d.peek()}');
  off();
  oa();
  ob();
  for (final c in [fa, ...bs]) {
    await c.close();
  }
  return log;
}

/// #4: a chain of [n] stream queries, each asking its upstream's parity;
/// each comparator sends its upstream 3 once. Only the last is sent 3 from
/// outside. Acyclic: every query installs 3, each in a microtask of its
/// own, none owing a round and none nesting another.
Future<String> cascade(int n) async {
  final feeds = <StreamController<int>>[],
      nodes = <AsyncComputed<int>>[],
      stops = <void Function()>[];
  final seen = List.filled(n, 0);
  var armed = false, runs = 0;
  final sent = List.filled(n, false);
  for (var i = 0; i < n; i++) {
    final feed = StreamController<int>.broadcast(sync: true);
    final p = i == 0 ? null : nodes.last;
    final parity = p == null
        ? null
        : computed(() => p.value.valueOrNull?.isOdd);
    final index = i;
    final q = computedStream<int>(
      (_) {
        parity?.value;
        runs++;
        return feed.stream;
      },
      equals: (x, y) {
        if (armed && index > 0 && !sent[index]) {
          sent[index] = true;
          feeds[index - 1].add(3);
        }
        return x == y;
      },
    );
    feeds.add(feed);
    nodes.add(q);
    stops.add(
      effect(() => q.value, (s, _, _) => seen[index] = s.valueOrNull ?? 0),
    );
    feed.add(1);
    await turns(1);
  }
  armed = true;
  String? threw;
  try {
    feeds.last.add(3);
    for (var t = 0; t < 4 * n && seen.first != 3; t++) {
      await Future<void>.delayed(Duration.zero);
    }
  } on Object catch (e) {
    threw = '$e'.split('\n').first;
  }
  final delivered = seen.where((x) => x == 3).length;
  for (final stop in stops.reversed) {
    stop();
  }
  for (final f in feeds) {
    f.close();
  }
  return '${threw ?? 'ok'} $delivered/$n runs=${runs - n}';
}

/// #5: a leased, unobserved stream query; [how] (`peek` or `invalidate`)
/// makes its round stale. The stale round's producer ends with it, lease or
/// not; the lease keeps only the answer.
Future<Map<String, Object?>> coldLease(String how) async {
  final events = <String>[];
  final lease = Scope(), id = signal(1);
  final q = computedStream<int>(
    (ctx) {
      final n = id.value;
      ctx.cancelled.then((_) => events.add('cancelled $n'));
      final feed = StreamController<int>.broadcast(
        sync: true,
        onListen: () => events.add('opened $n'),
        onCancel: () => events.add('closed $n'),
      );
      return feed.stream;
    },
    keepAlive: lease,
    retain: const Duration(seconds: 60),
  );
  final off = effect(() => q.value, (_, _, _) {});
  await turns(2);
  off();
  await turns(2);
  id.value = 2;
  if (how == 'peek') q.peek();
  if (how == 'invalidate') q.invalidate();
  await turns();
  final result = {
    'flight': activeQueryCount,
    'streams': activeQueryStreamCount,
    'events': [...events],
  };
  lease.dispose();
  await turns();
  return result;
}

/// A wait made on a round that has returned is a late wait:
/// it throws and opens nothing.
Future<Map<String, Object?>> leaseAfterEnd() async {
  final id = signal(1), lease = Scope(), done = Completer<int>();
  var sockets = 0;
  final feed = StreamController<int>.broadcast(
    sync: true,
    onListen: () => sockets++,
  );
  final upstream = computedStream<int>((_) => feed.stream);
  late Query attempt;
  final owner = computedAsync<int>((q) async {
    attempt = q;
    id.value;
    return done.future;
  }, keepAlive: lease);
  effect(() => owner.value, (_, _, _) {})();
  await turns(2);
  owner.invalidate();
  done.complete(1);
  await turns(2);
  String threw;
  try {
    attempt.wait(upstream);
    threw = 'none';
  } on StateError catch (e) {
    threw = '${e.message}'.split(':').first;
  }
  await turns(2);
  final result = {
    'threw': threw,
    'opened': sockets,
    'flight': activeQueryCount,
    'streams': activeQueryStreamCount,
  };
  lease.dispose();
  await turns();
  await feed.close();
  return result;
}

/// R4c: retain 60 s, no lease; the last reader leaves, the input changes.
/// A cold read ([read]) samples the new question and the round in flight
/// is cancelled (the pull semantics); without it the round keeps going and
/// its answer lands stale.
Future<Map<String, Object?>> retainRead({required bool read}) async {
  final id = signal(1), result = Completer<int>();
  final events = <String>[];
  final q = computedAsync<int>((ctx) {
    final n = id.value;
    events.add('start $n');
    ctx.cancelled.then((_) => events.add('cancel $n'));
    return result.future;
  }, retain: const Duration(seconds: 60));
  final stop = effect(() => q.value, (_, _, _) {});
  stop();
  await turns(2);
  id.value = 2;
  if (read) q.peek();
  await turns(2);
  final before = [activeQueryCount, activeQueryTimerCount];
  result.complete(11);
  await turns(2);
  final out = {
    'before': before,
    'after': [activeQueryCount, activeQueryTimerCount],
    'state': '${q.peek()}',
    'events': [...events],
  };
  q.invalidate();
  await turns();
  return out;
}

/// Runs [body], reporting an error that escapes it instead of crashing.
Future<Object?> guarded(Future<Object?> Function() body) {
  final done = Completer<Object?>();
  runZonedGuarded(
    () async {
      final result = await body();
      if (!done.isCompleted) done.complete(result);
    },
    (e, _) {
      if (!done.isCompleted) done.complete('escaped: $e'.split('\n').first);
    },
  );
  return done.future;
}

final cases = <String, Future<Object?> Function()>{
  'latest': () => siblings('latest'),
  'install': () => siblings('install'),
  'launch': () => siblings('launch'),
  'wait': siblingWait,
  'cascade': () => cascade(300),
  // Only when named: deep chains.
  'cascade2200': () => cascade(2200),
  'cascade5000': () => cascade(5000),
  'leasePeek': () => coldLease('peek'),
  'leaseInvalidate': () => coldLease('invalidate'),
  'leaseAfterEnd': leaseAfterEnd,
  'retainRead': () => retainRead(read: true),
  'retainPlain': () => retainRead(read: false),
};

/// Runs the named cases (all but the deep ones by default) in this order.
Future<void> main(List<String> args) async {
  print(
    jsonEncode({
      for (final MapEntry(:key, :value) in cases.entries)
        if (args.isEmpty
            ? !key.startsWith('cascade') || key == 'cascade'
            : args.contains(key))
          key: await guarded(value),
    }),
  );
}
