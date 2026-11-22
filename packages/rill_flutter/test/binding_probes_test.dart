import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:rill_flutter/rill_flutter.dart';

// Binding probes: State scope identity, bridge sampling, shared pulses and
// tracked subclasses. Frame questions without a binding live in
// binding_free_test.dart, which must run before any binding exists.

final _input = signal(0);
Scope? _first, _during;
Object? _registration;
int _runs = 0;

class _Owner extends StatefulWidget {
  const _Owner();
  @override
  State<_Owner> createState() => _OwnerState();
}

class _OwnerState extends State<_Owner> with ReactiveState<_Owner> {
  @override
  void initState() {
    super.initState();
    _first = scope;
    scope.onDispose(() {
      _during = scope;
      try {
        scope.effect(() => _input.value, (_, _, _) => _runs++);
      } on StateError catch (error) {
        _registration = error;
      }
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _Late extends StatefulWidget {
  const _Late(this.onDisposed);
  final void Function(Scope) onDisposed;
  @override
  State<_Late> createState() => _LateState();
}

class _LateState extends State<_Late> with ReactiveState<_Late> {
  @override
  void dispose() {
    super.dispose();
    widget.onDisposed(scope);
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _NamedReactive extends Reactive {
  const _NamedReactive({required super.builder});
}

void main() {
  testWidgets('state_scope_identity_is_fixed_during_dispose', (tester) async {
    await tester.pumpWidget(const _Owner());
    await tester.pumpWidget(const SizedBox());
    _input.value = 1;
    expect(identical(_first, _during), isTrue);
    expect(_first!.disposed, isTrue);
    expect('$_registration', contains('RILL_DISPOSED'));
    expect((_runs, subscriberCount(_input)), (0, 0));
  });

  testWidgets('state_scope_first_asked_after_dispose_is_disposed', (
    tester,
  ) async {
    Scope? late;
    await tester.pumpWidget(_Late((scope) => late = scope));
    await tester.pumpWidget(const SizedBox());
    expect(late!.disposed, isTrue);
    expect(() => late!.onDispose(() {}), throwsA(isA<StateError>()));
  });

  testWidgets('unchanged_samples_an_unobserved_bridge', (tester) async {
    final native = ValueNotifier<int>(1);
    addTearDown(native.dispose);
    final bridge = native.toReadable();
    final out = signal(0);
    final owner = Scope();
    addTearDown(owner.dispose);
    final barrier = Completer<void>();
    final task = owner.slot().run((t) async {
      final snapshot = bridge.peek();
      final asked = Unchanged(bridge);
      await barrier.future;
      return t.publish(
        (p) => p
          ..require(asked)
          ..set(out, snapshot),
      );
    });
    native.value = 2;
    barrier.complete();
    final result = await task as Done<bool>;
    expect((result.value, out.peek()), (false, 0));
  });

  testWidgets('pulse_handles_taken_before_observation_share_one_timer', (
    tester,
  ) async {
    final a = Pulse.minute, b = Pulse.minute;
    final c = Pulse.phase(const Duration(seconds: 2));
    final d = Pulse.phase(const Duration(seconds: 2));
    expect(identical(a, b), isTrue);
    expect(identical(c, d), isTrue);
    await tester.pumpWidget(
      Reactive(
        builder: (_) {
          a.value;
          b.value;
          return const SizedBox();
        },
      ),
    );
    expect((activePulseCount, activeBindingTimerCount), (1, 1));
    await tester.pumpWidget(const SizedBox());
    expect((activePulseCount, activeBindingTimerCount), (0, 0));
  });

  testWidgets('reactive_subclass_forwarding_builder_is_a_tracked_reader', (
    tester,
  ) async {
    final width = signal(1);
    await tester.pumpWidget(
      _NamedReactive(builder: (_) => SizedBox(width: width.value.toDouble())),
    );
    width.value = 4;
    await tester.pump();
    expect(tester.widget<SizedBox>(find.byType(SizedBox)).width, 4);
  });

  testWidgets('untracked_read_in_list_generate_inside_builder_throws', (
    tester,
  ) async {
    debugInstallRillGuards(tester.binding.buildOwner!);
    final width = signal(1);
    await tester.pumpWidget(
      Builder(
        builder: (_) => Column(
          children: List.generate(
            1,
            (_) => SizedBox(width: width.value.toDouble()),
          ),
        ),
      ),
    );
    expect('${tester.takeException()}', contains('RILL_UNTRACKED_READ'));
  });
}
