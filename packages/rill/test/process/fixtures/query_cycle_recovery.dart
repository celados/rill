// In a process of its own (debug and AOT): a cycle untied from the other end recovers cold and
// never reruns hot; a hundred and twenty independent landings owe no
// round; an upstream event leaves a downstream install stale; a stream
// event during the comparator is the answer taken; a query upstream of a
// cycle lands once. Prints one JSON line; a runaway exits 42 first.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

void bound(int runs) {
  if (runs == 1000) {
    print('1000 runs before the first timer');
    exit(42);
  }
}

List<String> untied() {
  final on = signal(false), escape = signal(false);
  var runs = 0;
  late Computed<int> a, b;
  a = computed(() {
    bound(++runs);
    return on.value ? b.value : 0;
  });
  b = computed(() {
    bound(++runs);
    return escape.value ? 7 : a.value;
  });
  Rill.onError = (_, _) {};
  final stops = [
    effect(() => read(a), (_, _, _) {}),
    effect(() => read(b), (_, _, _) {}),
  ];
  on.value = true;
  escape.value = true;
  final hot = [read(a), read(b)];
  for (final stop in stops) {
    stop();
  }
  Rill.onError = null;
  return [...hot, read(a), read(b)];
}

Future<int> fanout() async {
  const count = 120;
  final events = StreamController<int>.broadcast(sync: true);
  final queries = [
    for (var i = 0; i < count; i++) computedStream<int>((_) => events.stream),
  ];
  var seen = 0;
  final stops = [
    for (var i = 0; i < count; i++)
      effect(() => queries[i].value, (s, _, _) {
        if (s.valueOrNull == 1) seen++;
      }),
  ];
  batch(() => events.add(1));
  await turns();
  for (final stop in stops) {
    stop();
  }
  await events.close();
  return seen;
}

Future<List<String>> upstream() async {
  final ctl = StreamController<int>.broadcast(sync: true),
      old = Completer<int>(),
      next = Completer<int>();
  final up = computedStream<int>((_) => ctl.stream), log = <String>[];
  final down = computedAsync<int>(
    (_) async {
      final target = up.value.valueOrNull;
      if (target == null) return 3;
      return target == 1 ? old.future : next.future;
    },
    equals: (a, b) {
      if (b == 77) ctl.add(2);
      return a == b;
    },
  );
  final stop = effect(() => down.value, (s, _, _) => log.add('$s'));
  await turns();
  ctl.add(1);
  old.complete(77);
  await turns();
  // The comparator's event is asynchronous: 77 may install for
  // the old question; once up moved on it is stale.
  final before = down.peek();
  next.complete(8);
  await turns();
  final result = [
    before is AsyncData<int> && before.stale ? 'stale' : '$before',
    '${down.peek()}',
  ];
  stop();
  await ctl.close();
  return result;
}

Future<String> latest() async {
  final ctl = StreamController<int>.broadcast(sync: true);
  final q = computedStream<int>(
    (_) => ctl.stream,
    equals: (a, b) {
      if (b == 2) ctl.add(3);
      return a == b;
    },
  );
  final stop = effect(() => q.value, (_, _, _) {});
  ctl.add(1);
  batch(() => ctl.add(2));
  await turns();
  final result = '${q.peek()}';
  stop();
  await ctl.close();
  return result;
}

Future<int> upstreamOfACycle() async {
  final gate = signal(false), e2 = signal(false);
  var loads = 0;
  late Computed<int> a, b;
  late AsyncComputed<int> q2;
  b = computed(() => e2.value ? a.value : 0);
  q2 = computedAsync((_) async {
    bound(++loads);
    return b.value;
  });
  a = computed(() => gate.value ? b.value : (q2.value.valueOrNull ?? 0));
  Rill.onError = (_, _) {};
  final stops = [
    effect(() => read(a), (_, _, _) {}),
    effect(() => q2.value, (_, _, _) {}),
  ];
  await turns();
  batch(() {
    gate.value = true;
    e2.value = true;
  });
  await turns();
  for (final stop in stops) {
    stop();
  }
  Rill.onError = null;
  return loads;
}

/// A cold read of a cycle, then of the same nodes once it is untied: the
/// validation must not revisit a node still in its cycle.
List<String> coldCycle() {
  final enabled = signal(false);
  late Computed<int> a;
  final b = computed(() => a.value + 1);
  a = computed(() => enabled.value ? b.value : 3);
  final first = read(b);
  enabled.value = true;
  final cycled = read(b);
  enabled.value = false;
  return [first, cycled, read(b)];
}

Future<void> main() async {
  print(
    jsonEncode({
      'coldCycle': coldCycle(),
      'untied': untied(),
      'fanout': await fanout(),
      'upstream': await upstream(),
      'latest': await latest(),
      'upstreamOfACycle': await upstreamOfACycle(),
    }),
  );
}
