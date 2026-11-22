// Ownership rules: one minimal counterexample per rule, plus regressions.
import 'dart:async';

import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:test/test.dart';

final class _Store {
  final count = signal(1);
  late final doubled = computed(() => count.value * 2, name: 'doubled');
}

final class _Reader extends Subscriber {
  _Reader() : super();
  @override
  void notify() {}
}

void main() {
  tearDown(() {
    Rill.onError = null;
    bindingReadGuard = null;
  });

  group('derived nodes belong to no owner', () {
    test('late_final_computed_survives_first_reader', () {
      final store = _Store();
      final page = Scope(name: 'page');
      // The first read happens in the page's effect: the initializer runs in
      // whatever context reads it first, and nothing takes it from there.
      final seen = <int>[];
      page.effect(() => store.doubled.value, (v, _, _) => seen.add(v));
      page.dispose();
      expect(store.doubled.peek(), 2);
      store.count.value = 3;
      expect(store.doubled.value, 6);
      expect(seen, [2]);
    });

    test('computed_has_no_dispose', () {
      final node = computed(() => 1);
      expect(() => (node as dynamic).dispose, throwsNoSuchMethodError);
    });

    test('cold_computed_keeps_no_reverse_edge', () {
      final source = signal(1);
      final derived = computed(() => source.value + 1);
      expect(derived.value, 2);
      expect(subscriberCount(source), 0);
      final stop = effect(() => derived.value, (_, _, _) {});
      expect(subscriberCount(source), 1);
      stop();
      expect(subscriberCount(source), 0);
      checkGraph([source, derived]);
    });
  });

  group('there is no ambient owner', () {
    test('scope_constructor_is_always_root', () {
      final outer = Scope(name: 'outer');
      Scope? inApply, inCompute;
      outer.effect(() => computed(() => inCompute ??= Scope()).value, (
        _,
        _,
        _,
      ) {
        inApply ??= Scope();
      });
      outer.dispose();
      expect((inApply!.disposed, inCompute!.disposed), (false, false));
      inApply!.dispose();
      inCompute!.dispose();
    });

    test('effect_created_in_apply_is_unowned', () {
      final owner = Scope();
      final leaf = signal(0);
      void Function()? inner;
      owner.effect(() => 0, (_, _, _) {
        // Not registered with onCleanup, not named: the caller owns it.
        inner = effect(() => leaf.value, (_, _, _) {});
      });
      owner.dispose();
      expect(subscriberCount(leaf), 1);
      inner!();
      expect(subscriberCount(leaf), 0);
    });
  });

  group('effects belong to an explicit owner', () {
    test('scope_effect_stops_with_scope', () {
      final scope = Scope();
      final source = signal(0);
      final seen = <int>[];
      scope.effect(() => source.value, (v, _, onCleanup) {
        seen.add(v);
        onCleanup(() => seen.add(-v - 1));
      });
      source.value = 1;
      scope.dispose();
      source.value = 2;
      expect(seen, [0, -1, 1, -2]);
      expect(subscriberCount(source), 0);
    });

    test('scope_effect_stop_unlinks_registration', () {
      final scope = Scope();
      final order = <String>[];
      scope.onDispose(() => order.add('first'));
      final stop = scope.effect(
        () => 0,
        (_, _, onCleanup) => onCleanup(() => order.add('effect')),
      );
      scope.onDispose(() => order.add('last'));
      stop();
      stop();
      scope.dispose();
      expect(order, ['effect', 'last', 'first']);
    });

    test('unowned_effect_stops_by_disposer', () {
      final source = signal(0);
      final stop = effect(() => source.value, (_, _, _) {});
      expect(subscriberCount(source), 1);
      stop();
      expect(subscriberCount(source), 0);
    });
  });

  group('onCleanup', () {
    test('nested_effect_registered_with_on_cleanup_stops_on_rerun', () {
      final outer = signal(0);
      final leaf = signal(0);
      final stop = effect(() => outer.value, (_, _, onCleanup) {
        onCleanup(effect(() => leaf.value, (_, _, _) {}));
      });
      for (var i = 1; i <= 5; i++) {
        outer.value = i;
      }
      expect(subscriberCount(leaf), 1);
      stop();
    });

    test('nested_effect_registered_with_on_cleanup_stops_with_outer', () {
      final outer = signal(0);
      final leaf = signal(0);
      final stop = effect(() => outer.value, (_, _, onCleanup) {
        onCleanup(effect(() => leaf.value, (_, _, _) {}));
      });
      for (var i = 1; i <= 5; i++) {
        outer.value = i;
      }
      stop();
      expect(subscriberCount(leaf), 0);
    });

    test('apply_throwing_after_on_cleanup_still_cleans_up', () {
      final errors = <Object>[];
      Rill.onError = (error, _) => errors.add(error);
      final outer = signal(0);
      final leaf = signal(0);
      final stop = effect(() => outer.value, (v, _, onCleanup) {
        onCleanup(effect(() => leaf.value, (_, _, _) {}));
        throw StateError('after the resource');
      });
      expect(errors, hasLength(1));
      expect(subscriberCount(leaf), 1);
      outer.value = 1;
      expect(errors, hasLength(2));
      expect(subscriberCount(leaf), 1, reason: 'the first run was cleaned');
      stop();
      expect(subscriberCount(leaf), 0);
    });

    test('on_cleanup_runs_last_first_and_late_calls_join_or_run', () async {
      final log = <String>[];
      final source = signal(0);
      late OnCleanup kept;
      final stop = effect(() => source.value, (v, _, onCleanup) {
        kept = onCleanup;
        onCleanup(() => log.add('a$v'));
        onCleanup(() => log.add('b$v'));
      });
      source.value = 1;
      expect(log, ['b0', 'a0']);
      // A late call joins the effect's current run.
      kept(() => log.add('late'));
      source.value = 2;
      expect(log, ['b0', 'a0', 'late', 'b1', 'a1']);
      stop();
      expect(log.sublist(5), ['b2', 'a2']);
      // Once stopped, a late registration runs at once.
      kept(() => log.add('after stop'));
      expect(log.last, 'after stop');
    });

    test('scope_effect_is_not_use_result', () {
      // Compiles without an ignore: the owner keeps it.
      final scope = Scope();
      scope.effect(() => 0, (_, _, _) {});
      scope.dispose();
    });
  });

  group('library snapshots are not untracked reads', () {
    test('slot_run_first_part_is_not_tracked_by_its_starter', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final slot = owner.slot();
      final read = signal(0, name: 'read by the task');
      final reader = _Reader();
      addTearDown(reader.dispose);
      late Future<Outcome<int>> run;
      reader.track(() {
        run = slot.run((_) async => read.value);
      });
      expect(subscriberCount(read), 0);
      expect(await run, isA<Done<int>>());
    });

    test('slot_run_and_apply_are_explicit_snapshots', () async {
      final flagged = <String?>[];
      bindingReadGuard = (name) => flagged.add(name?.split(' ').first);
      final owner = Scope();
      addTearDown(owner.dispose);
      final a = signal(1, name: 'a'), b = signal(2, name: 'b');
      final stop = effect(() => a.value, (_, _, _) => b.value);
      addTearDown(stop);
      final run = owner.slot().run((_) async {
        final first = b.value;
        await Future<void>.value();
        return first + b.value;
      });
      expect(flagged, isEmpty, reason: 'apply and the first part');
      expect(await run, isA<Done<int>>());
      // After the await the body is no longer the library's snapshot.
      expect(flagged, ['b']);
      // A bare read outside any reader is still flagged.
      a.value;
      expect(flagged, ['b', 'a']);
    });
  });
}
