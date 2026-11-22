// A query outside a computed cycle lands; b, which reads it, recovers at once; a closed the
// cycle without an edge, keeps the error while hot and recovers
// once read cold. Prints one JSON line; a runaway never gets there.
import 'dart:async';
import 'dart:convert';

import 'package:rill/rill.dart';

Future<void> main() async {
  final finish = Completer<bool>();
  final input = computedAsync<bool>((_) => finish.future);
  late Computed<int> a, b;
  a = computed(() => b.value);
  b = computed(() => input.value.valueOrNull == true ? 7 : a.value);
  String read(Computed<int> node) {
    try {
      return '${node.value}';
    } on Object catch (e) {
      return '$e'.contains('RILL_CYCLE') ? 'cycle' : '$e';
    }
  }

  final stopB = effect(() => read(b), (_, _, _) {});
  final stopA = effect(() => read(a), (_, _, _) {});
  final before = [read(a), read(b)];
  finish.complete(true);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  final after = [read(a), read(b)];
  stopA();
  final cold = [read(a), read(b)];
  stopB();
  print(jsonEncode({'before': before, 'after': after, 'cold': cold}));
}
