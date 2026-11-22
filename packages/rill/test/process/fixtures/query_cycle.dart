// A query that answers, then joins a cycle through a plain
// computed that reads it back. Prints one JSON line; a defect never gets
// there (the landing relaunches the cycle every microtask).
import 'dart:convert';

import 'package:rill/rill.dart';

Future<void> main() async {
  final flag = signal(false);
  late final AsyncComputed<int> q;
  final view = computed<int>(() => flag.value ? (q.value.valueOrNull ?? 0) : 0);
  var loads = 0;
  q = computedAsync<int>((_) async {
    loads++;
    return view.value;
  });
  final states = <String>[];
  final stop = effect(() => q.value, (state, _, _) => states.add('$state'));
  Future<void> turn() => Future<void>.delayed(Duration.zero);
  await turn();
  final before = q.peek();
  flag.value = true;
  await turn();
  await turn();
  final cycled = q.peek();
  final cycledLoads = loads;
  flag.value = false;
  await turn();
  await turn();
  stop();
  print(
    jsonEncode({
      'before': '$before',
      'cycled':
          cycled is AsyncError<int> && '${cycled.error}'.contains('RILL_CYCLE'),
      'cycledLoads': cycledLoads,
      'recovered': '${q.peek()}',
      'loads': loads,
    }),
  );
}
