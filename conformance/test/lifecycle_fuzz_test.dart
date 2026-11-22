import 'package:rill_conformance/lifecycle_fuzz.dart';
import 'package:test/test.dart';

void main() {
  test('rill lifecycle and cycle recovery across 100,000 generated steps', () {
    var steps = 0;
    for (var seed = 0; seed < 100; seed++) {
      steps += runLifecycleFuzz(seed, 100);
    }
    expect(steps, 100000);
  });
}
