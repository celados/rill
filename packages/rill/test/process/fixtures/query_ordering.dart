// In a process of its own (debug and AOT): an unobserved query in flight that samples a clock on every read
// cools without sampling; a value sent upstream by a cancelled attempt's
// onCancel ends on the new question; one sent by an attach hook never
// resumes the old round with it; a 51-query chain changed in reverse in one
// batch finishes and owes no round (stream events are asynchronous, so these
// assert eventual results); a cold read below a hot
// RILL_CYCLE inherits the error. Prints one JSON line; a
// runaway shows in its counts.
import 'dart:async';
import 'dart:convert';

import 'package:rill/internal.dart';
import 'package:rill/rill.dart';

Future<void> turns() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String read(Readable<int> node) {
  try {
    return '${node.value}';
  } on Object catch (e) {
    return '$e'.contains('RILL_CYCLE') ? 'cycle' : '$e';
  }
}

/// #1: unmounting the last reader of a query in flight that reads a clock
/// sampled (and advanced) on every read.
Future<Map<String, Object?>> coldSample() async {
  var samples = 0;
  final pending = Completer<int>();
  // Stops advancing after 1000 samples, so a runaway shows in the count.
  final clock = bindingSignal(
    0,
    sample: () => samples < 1000 ? ++samples : samples,
  );
  final query = computedAsync<int>((q) {
    clock.value;
    return pending.future;
  });
  final stop = effect(() => query.value, (_, _, _) {});
  final mounted = samples;
  String? threw;
  try {
    stop();
  } on Object catch (e) {
    threw = '$e';
  }
  await turns();
  return {
    'threw': threw,
    'samplesAfterUnmount': samples - mounted,
    'active': activeQueryCount,
  };
}

/// #2: the old stream's onCancel sends the upstream a new id.
Future<List<String>> launch() async {
  final source = StreamController<int>.broadcast(sync: true);
  final up = computedStream<int>((_) => source.stream);
  final keep = effect(() => up.value, (_, _, _) {});
  source.add(1);
  await turns();
  var advance = false;
  final events = <String>[], controllers = <StreamController<int>>[];
  final down = computedStream<int>((q) {
    final id = up.value.requireValue;
    events.add('factory $id');
    final c = StreamController<int>.broadcast(
      sync: true,
      onListen: () => events.add('listen $id'),
      onCancel: () {
        events.add('cancel $id');
        if (advance) {
          advance = false;
          events.add('source 2');
          source.add(2);
        }
      },
    );
    controllers.add(c);
    return c.stream;
  });
  final off = effect(() => down.value, (_, _, _) {});
  advance = true;
  down.invalidate();
  await turns();
  off();
  keep();
  for (final c in controllers) {
    await c.close();
  }
  await source.close();
  // The value onCancel sends is an asynchronous event: the retry
  // may start on 1 before 2 replaces it. Its start and its end are fixed.
  return [...events.take(4), '…', ...events.sublist(events.length - 3)];
}

/// #3: an attach hook read by the loader sends the upstream a new value
/// while the loader's tracked wait holds the cached one.
Future<List<String>> wait() async {
  final feed = StreamController<int>.broadcast(sync: true);
  final up = computedStream<int>((_) => feed.stream);
  final stopUp = effect(() => up.value, (_, _, _) {});
  feed.add(1);
  await turns();
  var runs = 0;
  final events = <String>[];
  final attach = signal(
    0,
    watched: () {
      events.add('attach');
      feed.add(2);
    },
  );
  final down = computedAsync<int>((q) async {
    final id = ++runs;
    events.add('start $id');
    final value = q.wait(up);
    attach.value;
    final got = await value;
    events.add('resume $id:$got');
    return got;
  });
  final stop = effect(() => down.value, (_, _, _) {});
  await turns();
  events.add('down ${down.peek()}');
  stop();
  stopUp();
  await feed.close();
  // The attach hook's 2 is an asynchronous event: round 1 may be
  // delivered 1 while 1 is the answer, never 2.
  return [
    events.contains('resume 1:2') ? 'old round resumed with 2' : 'ok',
    ...events.where((e) => e.startsWith('resume 2') || e.startsWith('down')),
  ];
}

/// #4: a chain of [n] stream queries, each asking only its upstream's
/// parity, all changed from 1 to 3 in one batch in [order].
Future<String> chain(int n, {required bool reverse}) async {
  final channels = <StreamController<int>>[],
      queries = <AsyncComputed<int>>[],
      stops = <void Function()>[],
      seen = <int?>[];
  var starts = 0;
  for (var i = 0; i < n; i++) {
    final c = StreamController<int>.broadcast(sync: true);
    final prev = i == 0 ? null : queries.last;
    final parity = prev == null
        ? null
        : computed(() => prev.value.valueOrNull?.isOdd);
    final q = computedStream<int>((_) {
      parity?.value;
      starts++;
      return c.stream;
    });
    seen.add(null);
    final index = i;
    stops.add(effect(() => q.value, (s, _, _) => seen[index] = s.valueOrNull));
    c.add(1);
    // Stream events are asynchronous: each level answers before the next.
    await Future<void>.delayed(Duration.zero);
    channels.add(c);
    queries.add(q);
  }
  starts = 0;
  String? threw;
  try {
    batch(() {
      for (final c in reverse ? channels.reversed : channels) {
        c.add(3);
      }
    });
  } on Object catch (e) {
    threw = '$e';
  }
  for (var t = 0; t < 4 * n && seen.contains(1); t++) {
    await Future<void>.delayed(Duration.zero);
  }
  for (final stop in stops.reversed) {
    stop();
  }
  for (final c in channels) {
    await c.close();
  }
  return '${threw ?? 'ok'} ${seen.where((x) => x == 3).length}/$n '
      'starts=$starts';
}

/// #5: a cycle a → b → c → a untied at a; b unmounted while another page
/// still observes c. b's cold read and remount inherit c's held RILL_CYCLE
/// (L1, no L2) until c cools.
Map<String, Object?> partial() {
  final trigger = signal(false), breaker = signal(false);
  late Computed<int> a, b, c;
  a = computed(() => breaker.value ? 10 : b.value);
  b = computed(() => c.value + 1);
  c = computed(() => trigger.value ? a.value : 1);
  Rill.onError = (_, _) {};
  final nodes = [a, b, c];
  final stops = [for (final n in nodes) effect(() => read(n), (_, _, _) {})];
  trigger.value = true;
  breaker.value = true;
  final hot = nodes.map(read).toList();
  stops[1]();
  final readers = subscriberCount(b);
  final cold = read(b);
  String? remounted;
  final again = effect(() => read(b), (v, _, _) => remounted = v);
  again();
  // Unmount another page and remount at once: c stays hot through it.
  stops[0]();
  stops[0] = effect(() => read(a), (_, _, _) {});
  final stillHot = read(b);
  for (final stop in [stops[0], stops[2]]) {
    stop();
  }
  final released = nodes.map(read).toList();
  Rill.onError = null;
  return {
    'hot': hot,
    'readers': readers,
    'cold': cold,
    'remount': remounted,
    'stillHot': stillHot,
    'released': released,
  };
}

/// Runs [body], reporting an error that escapes it (a flush in a
/// microtask throws there) instead of crashing the process.
Future<Object?> guarded(Future<Object?> Function() body) {
  final done = Completer<Object?>();
  runZonedGuarded(
    () async {
      final result = await body();
      if (!done.isCompleted) done.complete(result);
    },
    (e, _) {
      if (!done.isCompleted) done.complete('escaped: $e');
    },
  );
  return done.future;
}

/// Runs the named cases (all but `deep` by default) in this order.
Future<void> main(List<String> args) async {
  final cases = <String, Future<Object?> Function()>{
    'coldSample': coldSample,
    'launch': launch,
    'wait': wait,
    'forward': () => chain(51, reverse: false),
    'reverse': () => chain(51, reverse: true),
    'reverse120': () => chain(120, reverse: true),
    // Only when named (AOT): no flush nests along the chain.
    'deep': () => chain(2000, reverse: true),
    'partial': () async => partial(),
  };
  print(
    jsonEncode({
      for (final MapEntry(:key, :value) in cases.entries)
        if (args.isEmpty ? key != 'deep' : args.contains(key))
          key: await guarded(value),
    }),
  );
}
