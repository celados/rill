// Port of rft effectLifecycle.ts at 745e6eb. See LICENSE in this directory.
import '../../adapter.dart';
import 'fixture.dart';

final effectLifecycleCases = <Fixture>[
  /**
   *  S(a) ← E(eff)
   *
   * Effect callback executes synchronously upon creation.
   */
  Fixture(35, "effect runs callback immediately on creation", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var runs = 0;
    fw.effect(() {
      a.read();
      runs++;
    });
    expect(runs).toBe(1);
  }),

  /**
   *  S(a) ← E(eff)
   *
   * Effect re-runs each time its signal dependency changes.
   */
  Fixture(36, "effect re-runs when dependency changes", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>("a");
    final values = <dynamic>[];
    fw.effect(() {
      values.add(a.read());
    });
    expect(values).toEqual(<dynamic>["a"]);
    a.write("b");
    expect(values).toEqual(<dynamic>["a", "b"]);
    a.write("c");
    expect(values).toEqual(<dynamic>["a", "b", "c"]);
  }),

  /**
   *  S(a) ← E(eff → cleanup)
   *
   * The cleanup function returned by an effect runs before each
   * subsequent re-execution of that effect.
   */
  Fixture(38, "effect cleanup fn called before each re-run", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final log = <dynamic>[];
    fw.effect(() {
      final v = a.read();
      log.add("run:$v");
      return () {
        log.add("cleanup:$v");
      };
    });
    expect(log).toEqual(<dynamic>["run:0"]);
    a.write(1);
    expect(log).toEqual(<dynamic>["run:0", "cleanup:0", "run:1"]);
    a.write(2);
    expect(
      log,
    ).toEqual(<dynamic>["run:0", "cleanup:0", "run:1", "cleanup:1", "run:2"]);
  }),

  /**
   *  S(a) ← E(eff → cleanup) → dispose
   *
   * The cleanup function runs when the effect is disposed.
   */
  Fixture(39, "effect cleanup fn called on disposal", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var cleanupCalled = false;
    final dispose = fw.effect(() {
      a.read();
      return () {
        cleanupCalled = true;
      };
    });
    expect(cleanupCalled).toBe(false);
    dispose();
    expect(cleanupCalled).toBe(true);
  }),

  /**
   *  S(a) ← E(eff → cleanup reads S(b))
   *
   * Cleanup runs outside the tracking context, so reading a signal
   * inside cleanup must NOT create a dependency on that signal.
   */
  Fixture(40, "effect cleanup runs outside reactive evaluation context", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(100);
    var effectRuns = 0;
    fw.effect(() {
      a.read();
      effectRuns++;
      return () {
        // Reading b in cleanup should NOT create a dependency
        b.read();
      };
    });
    expect(effectRuns).toBe(1);
    a.write(1);
    expect(effectRuns).toBe(2);
    // b is only read in cleanup — should not trigger re-run
    b.write(200);
    expect(effectRuns).toBe(2);
  }),

  /**
   *  batch { S(a).write; E(eff).dispose }
   *
   * An effect disposed inside a batch that also writes to its
   * dependency must NOT execute when the batch flushes.
   */
  Fixture(42, "effect not executed if disposed during pending batch", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var runs = 0;
    final dispose = fw.effect(() {
      a.read();
      runs++;
    });
    expect(runs).toBe(1);
    fw.batch(() {
      a.write(1);
    });
    expect(runs).toBe(2);
    fw.batch(() {
      a.write(2);
      dispose();
    });
    expect(runs).toBe(2);
  }),

  /**
   *  S(a) ← E(eff) → self-dispose on 2nd run
   *
   * An effect that calls its own dispose function during execution
   * must not crash and must stop future re-runs.
   */
  Fixture(108, "effect self-dispose during execution is safe", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var runs = 0;
    Dispose? dispose;
    dispose = fw.effect(() {
      runs++;
      a.read();
      if (jsStrictEqual(runs, 2)) {
        dispose?.call();
      }
    });
    expect(runs).toBe(1);
    a.write(1);
    expect(runs).toBe(2);
    a.write(2);
    expect(runs).toBe(2);
  }),

  /**
   *  S(a) ← E(eff → cleanup) → dispose → dispose
   *
   * Calling dispose twice must not throw and cleanup must not run
   * more than twice total (once per dispose at most).
   */
  Fixture(110, "double-dispose is safe", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var cleanupCount = 0;
    final dispose = fw.effect(() {
      a.read();
      return () {
        cleanupCount++;
      };
    });
    dispose();
    expect(cleanupCount).toBe(1);
    expect(() => dispose()).not.toThrow();
    expect(cleanupCount).toBeLessThanOrEqual(2);
  }),

  /**
   *  S(a) ← E(eff → cleanup calls dispose)
   *
   * Cleanup itself calls dispose. The effect must not re-run after
   * the cleanup-triggered disposal.
   */
  Fixture(111, "cleanup-triggered dispose prevents re-run", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var runs = 0;
    Dispose? dispose;
    dispose = fw.effect(() {
      runs++;
      a.read();
      return () {
        dispose?.call();
      };
    });
    expect(runs).toBe(1);
    a.write(1);
    expect(runs).toBeLessThanOrEqual(2);
    a.write(2);
    expect(runs).toBeLessThanOrEqual(2);
  }),

  /**
   *  S(a)  S(b) ← E(eff) → self-dispose mid-run
   *
   * Effect reads a, self-disposes when a===1, then continues to
   * read b. After disposal, neither a nor b changes trigger re-run.
   */
  Fixture(141, "dispose during execution then continue: no re-run", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    var runs = 0;
    Dispose? dispose;
    dispose = fw.effect(() {
      runs++;
      final va = a.read();
      if (jsStrictEqual(va, 1)) {
        dispose?.call();
      }
      b.read();
    });
    expect(runs).toBe(1);
    a.write(1);
    expect(runs).toBe(2);
    b.write(1);
    expect(runs).toBe(2);
    a.write(2);
    expect(runs).toBe(2);
  }),

  /**
   *  S(a)  S(b) ← E(eff) → dispose
   *
   * After disposal, multiple writes to both dependencies must
   * never re-schedule the effect.
   */
  Fixture(143, "destroyed effect not re-scheduled on later updates", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    var runs = 0;
    final dispose = fw.effect(() {
      a.read();
      b.read();
      runs++;
    });
    expect(runs).toBe(1);
    dispose();
    a.write(1);
    b.write(1);
    a.write(2);
    b.write(2);
    expect(runs).toBe(1);
  }),

  /**
   *  S(a) ← E(inner → cleanup reads S(b))
   *  S(a) ← E(outer disposes inner when a===1)
   *
   * Inner effect's cleanup reads b. When outer disposes inner,
   * b must NOT become a dependency of the outer effect.
   */
  Fixture(178, "dispose cleanup reads don't leak to parent tracking context", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(100);
    var outerRuns = 0;
    final disposeInner = fw.effect(() {
      a.read();
      return () {
        b.read();
      };
    });
    fw.effect(() {
      a.read();
      outerRuns++;
      if (jsStrictEqual(a.read(), 1)) {
        disposeInner();
      }
    });
    outerRuns = 0;
    a.write(1);
    expect(outerRuns).toBe(1);
    outerRuns = 0;
    b.write(200);
    expect(outerRuns).toBe(0);
  }),

  /**
   *  S(a) ← E(eff creates C(c) reading a)
   *
   * Effect creates an inner computed each run. After re-run the
   * new computed must read the latest signal value.
   */
  Fixture(
    214,
    "effect recreates inner computed each run: new child sees latest value",
    (ReactiveAdapter fw) {
      final a = fw.signal<dynamic>(1);
      Readable<dynamic>? innerComputed;
      fw.effect(() {
        final c = fw.computed<dynamic>(() => a.read());
        a.read();
        innerComputed = c;
      });
      expect(innerComputed!.read()).toBe(1);
      a.write(2);
      expect(innerComputed!.read()).toBe(2);
      a.write(3);
      expect(innerComputed!.read()).toBe(3);
    },
  ),

  /**
   *  S(a) ← E1 → dispose
   *       ← E2  (created after E1 disposed)
   *
   * After an effect is disposed, creating a new effect on the
   * same signal must work normally — fresh subscription, normal
   * re-runs. Confirms dispose doesn't poison the signal's
   * subscriber set.
   */
  Fixture(217, "new effect after dispose works normally", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var e1Runs = 0;
    var e2Runs = 0;
    final dispose1 = fw.effect(() {
      a.read();
      e1Runs++;
    });
    expect(e1Runs).toBe(1);
    dispose1();
    a.write(1);
    expect(e1Runs).toBe(1);
    fw.effect(() {
      a.read();
      e2Runs++;
    });
    expect(e2Runs).toBe(1);
    a.write(2);
    expect(e2Runs).toBe(2);
    expect(e1Runs).toBe(1);
  }),

  /**
   *  S(a) ← E_outer (→ cleanup creates E_inner ← S(b))
   *
   * A common debounce-like pattern: an effect's cleanup creates a
   * fresh effect that subscribes to a different signal. The newly
   * created inner effect must run once on creation and react to
   * subsequent writes to its own dependency.
   */
  Fixture(222, "effect created inside cleanup tracks its own deps", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    var innerRuns = 0;
    fw.effect(() {
      a.read();
      return () {
        fw.effect(() {
          b.read();
          innerRuns++;
        });
      };
    });
    expect(innerRuns).toBe(0);
    // Trigger cleanup once — the cleanup-created effect should
    // run initially.
    a.write(1);
    expect(innerRuns).toBe(1);
    // The cleanup-created effect must track b independently.
    b.write(1);
    expect(innerRuns).toBe(2);
  }),

  /**
   *  S(a) → C(c) reads S(a)
   *  S(a) → E(eff → cleanup reads C(c))
   *
   * Cleanup reads a computed whose source has just changed. The
   * cleanup must observe the up-to-date computed value, not the
   * stale value captured before the write.
   */
  Fixture(229, "cleanup reads computed: sees fresh value", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final c = fw.computed<dynamic>(() => a.read() * 10);
    final seen = <dynamic>[];
    fw.effect(() {
      a.read();
      return () {
        seen.add(c.read());
      };
    });
    a.write(1);
    expect(seen).toEqual(<dynamic>[10]);
    a.write(2);
    expect(seen).toEqual(<dynamic>[10, 20]);
  }),

  /**
   *  S(a) → E1(eff → cleanup writes S(b))
   *  S(b) → E2(eff observes S(b))
   *
   * E1's cleanup writes to a signal observed by E2, all wrapped in
   * a batch. After the batch completes, E2 must reflect the value
   * produced by the cleanup.
   */
  Fixture(230, "cleanup writes signal inside batch propagates after flush", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    var e2Value = -1;
    fw.effect(() {
      a.read();
      return () {
        b.write(b.read() + 1);
      };
    });
    fw.effect(() {
      e2Value = b.read();
    });
    expect(e2Value).toBe(0);
    fw.batch(() {
      a.write(1);
    });
    expect(e2Value).toBe(1);
  }),

  /**
   *  S(a) → E(eff → cleanup{ untracked{ S(b).read } })
   *
   * Cleanup wraps a signal read in untracked. Since cleanup already
   * runs outside any tracking context (#40), this should also leave
   * no subscription. Tests that untracked composes correctly with
   * cleanup rather than producing a spurious dependency.
   */
  Fixture(231, "untracked inside cleanup: still no tracking", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(100);
    var runs = 0;
    fw.effect(() {
      a.read();
      runs++;
      return () {
        fw.untracked(() {
          b.read();
        });
      };
    });
    expect(runs).toBe(1);
    // b read only via untracked inside cleanup — must not retrigger.
    b.write(200);
    expect(runs).toBe(1);
    // a is still a real dep.
    a.write(1);
    expect(runs).toBe(2);
  }),

  /**
   *  S(a) → E(eff → cleanup{ S(b).write; read C(c) where C(c) reads S(b) })
   *
   * Inside cleanup we write to b, then read computed c which depends
   * on b. c must reflect the just-written value of b — the write must
   * propagate to c before the cleanup's read in the same tick.
   */
  Fixture(
    233,
    "cleanup write then read of dependent computed: sees new value",
    (ReactiveAdapter fw) {
      final a = fw.signal<dynamic>(0);
      final b = fw.signal<dynamic>(0);
      final c = fw.computed<dynamic>(() => b.read());
      final seen = <dynamic>[];
      fw.effect(() {
        a.read();
        return () {
          b.write(99);
          seen.add(c.read());
        };
      });
      expect(seen).toEqual(<dynamic>[]);
      a.write(1);
      expect(seen).toEqual(<dynamic>[99]);
    },
  ),

  /**
   *  S(a) → E1{ batch{ S(b).write, S(b).write } }
   *  S(b) → E2
   *
   * E1's body opens a batch and writes b twice. E2 (observer of b)
   * must run exactly once per E1 run, seeing only the final batched
   * value of b — not each intermediate write.
   *
   * E1 reads only a. Reading b there would make E1 depend on its own
   * write, which is the effect cycle of #61, not batching.
   */
  Fixture(235, "batch inside effect body coalesces writes", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    var observerRuns = 0;
    var observerLast = -1;
    fw.effect(() {
      final base = a.read() * 11;
      fw.batch(() {
        b.write(base + 10);
        b.write(base + 11);
      });
    });
    fw.effect(() {
      observerLast = b.read();
      observerRuns++;
    });
    // After setup: b = 11; observer ran once with b=11
    expect(observerLast).toBe(11);
    observerRuns = 0;
    a.write(1);
    // E1 re-runs, batch writes b: 11 → 21 → 22
    // Observer should fire exactly once with b=22
    expect(observerRuns).toBe(1);
    expect(observerLast).toBe(22);
  }),

  /**
   *  S(a) → E(eff → cleanup writes S(a))
   *
   * Cleanup writes the effect's own dep, which would normally re-
   * trigger the same effect. User code bounds the recursion with a
   * counter; framework must execute this without unbounded looping
   * or stack overflow.
   */
  Fixture(236, "cleanup write to own dep: bounded recursion completes", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var runs = 0;
    fw.effect(() {
      a.read();
      runs++;
      return () {
        if (runs < 5) {
          a.write(a.read() + 1);
        }
      };
    });
    expect(runs).toBe(1);
    a.write(1);
    // User-bounded by `runs < 5`. Framework must complete without
    // infinite looping or stack overflow. Final run count is bounded.
    expect(runs).toBeLessThanOrEqual(20);
  }),

  /**
   *  S(a) → E_outer{ E_inner }
   *
   * outer's old cleanup runs BEFORE outer's new body runs. Whether
   * and in which order inner cleanup runs is a design difference
   * (see #241 in Behavioral Differences).
   */
  Fixture(
    237,
    "cleanup ordering on outer re-run: outer cleanup before re-run",
    (ReactiveAdapter fw) {
      final a = fw.signal<dynamic>(0);
      final log = <dynamic>[];
      fw.effect(() {
        a.read();
        log.add("outer:run");
        fw.effect(() {
          log.add("inner:run");
          return () => log.add("inner:cleanup");
        });
        return () => log.add("outer:cleanup");
      });
      expect(log).toEqual(<dynamic>["outer:run", "inner:run"]);
      log.length = 0;
      a.write(1);
      final outerCleanupIdx = log.indexOf("outer:cleanup");
      final outerRunIdx = log.lastIndexOf("outer:run");
      expect(outerCleanupIdx).toBeGreaterThanOrEqual(0);
      expect(outerRunIdx).toBeGreaterThan(outerCleanupIdx);
    },
  ),

  /**
   *  E_outer{ E_inner } → dispose
   *
   * Disposing the outer effect must run its cleanup. Cascade and
   * its order are a design difference (see #241).
   */
  Fixture(238, "dispose runs outer cleanup with nested effects", (
    ReactiveAdapter fw,
  ) {
    final log = <dynamic>[];
    final dispose = fw.effect(() {
      log.add("outer:run");
      fw.effect(() {
        log.add("inner:run");
        return () => log.add("inner:cleanup");
      });
      return () => log.add("outer:cleanup");
    });
    log.length = 0;
    dispose();
    expect(log).toContain("outer:cleanup");
  }),

  /**
   *  S(a) → E_outer{ E_inner ─→ S(b) }
   *
   * Regression: when inner re-runs alone (via its own dep b), the
   * outer is touched via the notify chain. The next real outer
   * re-run (via a) must still produce a valid cleanup ordering.
   *
   * Invariant: same as #237 — outer cleanup before outer re-run.
   */
  Fixture(243, "cleanup ordering correct after prior inner-only re-run", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    final log = <dynamic>[];
    fw.effect(() {
      a.read();
      log.add("outer:run");
      fw.effect(() {
        b.read();
        log.add("inner:run");
        return () => log.add("inner:cleanup");
      });
      return () => log.add("outer:cleanup");
    });
    b.write(1);
    log.length = 0;
    a.write(1);
    final outerCleanupIdx = log.indexOf("outer:cleanup");
    final outerRunIdx = log.lastIndexOf("outer:run");
    expect(outerCleanupIdx).toBeGreaterThanOrEqual(0);
    expect(outerRunIdx).toBeGreaterThan(outerCleanupIdx);
  }),
];
