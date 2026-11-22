// Starts without a binding, like binding_free_test.dart: the binding is
// initialized inside the test, after a pulse is already observed.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

void main() {
  test('pulse_observed_before_the_binding_follows_its_lifecycle', () async {
    expect(BindingBase.debugBindingType(), isNull);
    final pulse = Pulse.every(const Duration(milliseconds: 20));
    final stop = effect(() => pulse.value, (_, _, _) {});
    expect(activePulseCount, 1);

    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Flutter announces no binding: the next tick at the latest registers
    // the lifecycle observer and stops the paused pulse.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(activePulseCount, 0);
    expect(activeBindingTimerCount, 0);

    // Registered now: resuming restarts it without any graph activity.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(activePulseCount, 1);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(activePulseCount, 0);
    expect(activeBindingTimerCount, 0);
    stop();
  });
}
