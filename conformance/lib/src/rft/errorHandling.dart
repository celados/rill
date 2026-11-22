// Port of rft errorHandling.ts at 745e6eb. See LICENSE in this directory.
import '../../adapter.dart';
import 'fixture.dart';

final errorHandlingCases = <Fixture>[
  /**
   *  S(a) → C(b) ⚡ throws when a===0
   *
   * Computed throws on its initial evaluation. After fixing the
   * signal, the computed must return the correct value.
   */
  Fixture(84, "graph stays consistent after error in initial computed", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() {
      if (jsStrictEqual(a.read(), 0)) throw FixtureError("initial error");
      return a.read();
    });
    expect(() => b.read()).toThrow("initial error");
    a.write(1);
    expect(b.read()).toBe(1);
  }),

  /**
   *  S(a) ← E(eff ⚡ throws when a===1, → cleanup)
   *
   * Effect throws on re-run. The cleanup from the previous
   * successful run must still be called.
   */
  Fixture(89, "effect cleanup reset when effect throws", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var cleanupCalled = false;
    try {
      fw.effect(() {
        a.read();
        if (jsStrictEqual(a.read(), 1)) {
          throw FixtureError("effect error");
        }
        return () {
          cleanupCalled = true;
        };
      });
    } catch (_) {}
    try {
      a.write(1);
    } catch (_) {}
    // Cleanup from previous successful run should have been called
    expect(cleanupCalled).toBe(true);
  }),

  /**
   *  S(a) ← E(eff → cleanup ⚡ throws)
   *
   * Cleanup itself throws. The effect must not enter an infinite
   * loop; subsequent updates must be bounded.
   */
  Fixture(90, "effect disposed when cleanup throws", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var effectRuns = 0;
    Dispose dispose = () {};
    try {
      dispose = fw.effect(() {
        effectRuns++;
        a.read();
        return () {
          throw FixtureError("cleanup error");
        };
      });
    } catch (_) {}
    try {
      a.write(1);
    } catch (_) {}
    final runsAfterError = effectRuns;
    try {
      a.write(2);
    } catch (_) {}
    // Effect should be bounded — not infinite loop due to cleanup error
    expect(effectRuns).toBeLessThanOrEqual(runsAfterError + 1);
    // Disposal runs the throwing cleanup once more; that is not under test.
    try {
      dispose();
    } catch (_) {}
  }),

  /**
   *  S(a) → C(bad) ⚡     S(b) → C(good)
   *
   * After an exception in bad, the good branch must still
   * re-evaluate normally on subsequent writes to b.
   */
  Fixture(91, "exception halts propagation but other branches remain intact", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(10);
    final bad = fw.computed<dynamic>(() {
      if (a.read() > 0) throw FixtureError("branch error");
      return a.read();
    });
    var goodCalls = 0;
    final good = fw.computed<dynamic>(() {
      goodCalls++;
      return b.read() * 2;
    });
    expect(good.read()).toBe(20);
    a.write(1);
    try {
      bad.read();
    } catch (_) {}
    // Good branch should still work
    goodCalls = 0;
    b.write(20);
    expect(good.read()).toBe(40);
    expect(goodCalls).toBe(1);
  }),

  /**
   *  S(a) → C(b) ⚡ throws when a===1
   *
   * After error and recovery, no stale scheduled state remains.
   * Subsequent writes produce correct values without ghost re-runs.
   */
  Fixture(92, "no stale scheduled updates left after exception", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() {
      if (jsStrictEqual(a.read(), 1)) throw FixtureError("stale error");
      return a.read() * 2;
    });
    expect(b.read()).toBe(0);
    a.write(1);
    expect(() => b.read()).toThrow("stale error");
    // After recovery, no stale state should remain
    a.write(2);
    expect(b.read()).toBe(4);
    a.write(3);
    expect(b.read()).toBe(6);
  }),

  /**
   *  batch { S(a).write; throw } ← E(eff)
   *
   * User code throws inside a batch. The batch's signal write
   * must still flush, the effect must fire, and the graph must
   * remain consistent after the throw.
   */
  Fixture(154, "batch throw: effects survive, graph consistent", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var runs = 0;
    fw.effect(() {
      a.read();
      runs++;
    });
    expect(runs).toBe(1);
    try {
      fw.batch(() {
        a.write(1);
        throw FixtureError("batch boom");
      });
    } catch (_) {}
    expect(runs).toBeGreaterThanOrEqual(2);
    a.write(2);
    expect(runs).toBeGreaterThanOrEqual(3);
    expect(a.read()).toBe(2);
  }),

  /**
   *  S(a) → C(c) ⚡ throws when a===0 ← E(eff)
   *
   * Computed throws while being watched by an effect. Re-reading
   * the computed must not recompute excessively (error is cached).
   * After recovery write, the computed returns normally.
   */
  Fixture(155, "errors cached when watched by effect (live caching)", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var computeCalls = 0;
    final c = fw.computed<dynamic>(() {
      computeCalls++;
      if (jsStrictEqual(a.read(), 0)) throw FixtureError("live error");
      return a.read();
    });
    try {
      fw.effect(() {
        try {
          c.read();
        } catch (_) {}
      });
    } catch (_) {}
    final callsAfter = computeCalls;
    try {
      c.read();
    } catch (_) {}
    expect(computeCalls).toBeLessThanOrEqual(callsAfter + 1);
    a.write(1);
    expect(c.read()).toBe(1);
  }),

  /**
   *  S(a)  S(b)  S(c) → C(d)
   *  E1 reads a; E2 ⚡ reads a; E3 reads a,d
   *
   * E2 throws when a===2. After the failed flush, writing to
   * unrelated signal b must NOT re-trigger E3.
   */
  Fixture(
    177,
    "skipped effects from failed flush not re-triggered by unrelated signal",
    (ReactiveAdapter fw) {
      final a = fw.signal<dynamic>(0);
      final b = fw.signal<dynamic>(0);
      final c = fw.signal<dynamic>(0);
      final d = fw.computed<dynamic>(() => c.read());
      fw.effect(() {
        a.read();
      });
      try {
        fw.effect(() {
          if (jsStrictEqual(a.read(), 2)) throw FixtureError("effect2 error");
        });
      } catch (_) {}
      var effect3Runs = 0;
      fw.effect(() {
        a.read();
        d.read();
        effect3Runs++;
      });
      effect3Runs = 0;
      try {
        a.write(2);
      } catch (_) {}
      effect3Runs = 0;
      b.write(1);
      expect(effect3Runs).toBe(0);
    },
  ),

  /**
   *  S(a) → C(b) ⚡ → C(c)
   *
   * b throws, causing downstream c to also throw. After recovery
   * both b and c must return correct values.
   */
  Fixture(211, "computed error chain: downstream computed also throws", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() {
      if (jsStrictEqual(a.read(), 1)) throw FixtureError("source error");
      return a.read();
    });
    final c = fw.computed<dynamic>(() => b.read() * 2);
    expect(c.read()).toBe(0);
    a.write(1);
    expect(() => c.read()).toThrow();
    // Recovery: both b and c return to normal
    a.write(2);
    expect(b.read()).toBe(2);
    expect(c.read()).toBe(4);
  }),

  /**
   *  S(a) ← E(e1)
   *  S(a) ← E(e2 ⚡ throws when a===1)
   *  S(a) ← E(e3)
   *  S(b) ← E(e4)
   *
   * e2 throws during propagation of a(1), which may halt the
   * flush. On a subsequent write to unrelated signal b, only
   * b-dependent effects must run — a-dependent effects skipped
   * by the earlier halt must NOT leak into the new flush.
   */
  Fixture(247, "flush queue consistent after effect throw", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    var e3Runs = 0;
    fw.effect(() {
      a.read();
    });
    try {
      fw.effect(() {
        if (jsStrictEqual(a.read(), 1)) throw FixtureError("e2 error");
      });
    } catch (_) {}
    fw.effect(() {
      a.read();
      e3Runs++;
    });
    fw.effect(() {
      b.read();
    });
    e3Runs = 0;
    try {
      a.write(1);
    } catch (_) {}
    e3Runs = 0;
    try {
      b.write(1);
    } catch (_) {}
    expect(e3Runs).toBe(0);
  }),

  /**
   *  S(a) → C(b) ⚡ throws when a is true
   *
   * Computed alternates between throwing and returning "ok".
   * Each transition must work correctly in both directions.
   */
  Fixture(93, "exception recovery in computed", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(true);
    final b = fw.computed<dynamic>(() {
      if (jsTruthy(a.read())) throw FixtureError("fail");
      return "ok";
    });
    expect(() => b.read()).toThrow("fail");
    a.write(false);
    expect(b.read()).toBe("ok");
    a.write(true);
    expect(() => b.read()).toThrow("fail");
  }),
];
