// Run without asserts by release_commit_test.dart: the staging guard is
// debug only, so a reentrant write reaches the final check (C5a step 3).
import 'dart:convert';

import 'package:rill/rill.dart';

void main() {
  final target = signal(0), other = signal(0);
  final reentrant = transact((p) {
    p.set(target, 1);
    target.value = 2; // a decoder writing what it stages
    p.set(other, 1);
  });

  final source = signal(0), a = signal(0), b = signal(0);
  final asked = Unchanged(source);
  late bool kept;
  final broken = transact((p) {
    kept = p.part(() {
      p.require(asked);
      p.set(a, 1);
    });
    source.value = 1; // breaks the kept part's condition afterwards
    p.set(b, 1);
  });

  print(
    jsonEncode({
      'reentrant': reentrant,
      'target': target.peek(),
      'other': other.peek(),
      'kept': kept,
      'broken': broken,
      'a': a.peek(),
      'b': b.peek(),
    }),
  );
}
