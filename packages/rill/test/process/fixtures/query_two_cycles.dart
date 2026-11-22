// Two independent cycles, and a diamond whose input stream event recovers
// b at once and a and d once read cold.
// Prints one JSON line; a runaway cycle exits 42 before the first timer
// runs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rill/rill.dart';

Future<void> turn() => Future<void>.delayed(Duration.zero);

Future<void> turns() async {
  for (var i = 0; i < 6; i++) {
    await turn();
  }
}

String read(Readable<int> node) {
  try {
    return '${node.value}';
  } on Object catch (e) {
    return '$e'.contains('RILL_CYCLE') ? 'cycle' : '$e';
  }
}

Future<List<int>> twoCycles() async {
  final enabled = signal(false);
  final launches = [0, 0];
  final stops = <void Function()>[];
  for (var i = 0; i < 2; i++) {
    late AsyncComputed<int> query;
    final view = computed(
      () => enabled.value ? query.value.valueOrNull ?? 0 : 0,
    );
    query = computedAsync((_) async {
      if (++launches[i] == 1000) {
        print('1000 launches before the first timer: $launches');
        exit(42);
      }
      return view.value;
    });
    stops.add(effect(() => query.value, (_, _, _) {}));
  }
  await turn();
  enabled.value = true;
  await turn();
  final cycled = [...launches];
  enabled.value = false;
  await turns();
  for (final stop in stops) {
    stop();
  }
  return [...cycled, ...launches];
}

Future<List<String>> diamond() async {
  final events = StreamController<bool>.broadcast(sync: true);
  late Computed<int> a, b;
  final input = computedStream<bool>((_) => events.stream);
  a = computed(() => b.value);
  b = computed(() => input.value.valueOrNull == true ? 7 : a.value);
  final d = computed(() => a.value + b.value);
  final stops = [
    effect(() => read(b), (_, _, _) {}),
    effect(() => read(a), (_, _, _) {}),
    effect(() => read(d), (_, _, _) {}),
  ];
  await turns();
  events.add(true);
  await turns();
  final hot = [read(a), read(b), read(d)];
  await events.close();
  await turns();
  stops[1]();
  stops[2]();
  final cold = [read(a), read(b), read(d)];
  stops[0]();
  return [...hot, ...cold];
}

Future<void> main() async {
  print(jsonEncode({'cycles': await twoCycles(), 'diamond': await diamond()}));
}
