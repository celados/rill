import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

// Frame questions without a binding. No testWidgets here: the file runs without a binding, as a
// plain controller test does.
void main() {
  test('controller_test_without_binding_reads_through_a_listenable', () {
    final s = signal(2);
    final listenable = s.toListenable();
    var heard = 0;
    void listener() => heard++;
    listenable.addListener(listener);
    expect(s.value, 2);
    s.value = 3;
    expect((listenable.value, heard), (3, 1));
    listenable.removeListener(listener);
  });

  test('controller_test_without_binding_runs_bridged_effects', () async {
    final native = ValueNotifier<int>(1);
    final bridge = native.toReadable();
    final seen = <int>[];
    final stop = effect(() => bridge.value, (v, _, _) => seen.add(v));
    native.value = 2;
    await Future<void>.delayed(Duration.zero);
    expect(seen, [1, 2]);
    stop();
    native.dispose();
  });

  test('controller_test_without_binding_reads_a_pulse', () {
    final minute = Pulse.minute.toListenable();
    void listener() {}
    minute.addListener(listener);
    expect(minute.value, isA<DateTime>());
    minute.removeListener(listener);
  });
}
