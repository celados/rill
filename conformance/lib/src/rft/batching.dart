// Port of rft batching.ts at 745e6eb. See LICENSE in this directory.
import '../../adapter.dart';
import 'fixture.dart';

final batchingCases = <Fixture>[
  /**
   *  S(a) → E(eff)
   *
   * Nested batch: inner batch completes but outer is still open.
   * Effect fires only once when the outermost batch ends.
   */
  Fixture(66, "nested batches: outer completion triggers propagation", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var runs = 0;
    fw.effect(() {
      a.read();
      runs++;
    });
    expect(runs).toBe(1);
    fw.batch(() {
      a.write(1);
      fw.batch(() {
        a.write(2);
      });
      // Inner batch complete but outer still open
      expect(runs).toBe(1);
      a.write(3);
    });
    expect(runs).toBe(2);
    expect(a.read()).toBe(3);
  }),

  /**
   *  S(a)
   *
   * Signal reads inside a batch reflect the latest written value
   * immediately (write-then-read consistency within the batch).
   */
  Fixture(67, "signals readable with updated value inside batch", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    fw.batch(() {
      a.write(1);
      expect(a.read()).toBe(1);
      a.write(2);
      expect(a.read()).toBe(2);
    });
  }),

  /**
   *  S(a) → E(eff)
   *
   * Batch callback throws after writing. The framework may commit the
   * write (effects then run with it) or roll it back (nothing runs).
   * Either way the state must be consistent and later writes must
   * still propagate.
   */
  Fixture(69, "throwing batch leaves a consistent state", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var runs = 0;
    var seen = -1;
    fw.effect(() {
      seen = a.read();
      runs++;
    });
    expect(runs).toBe(1);
    try {
      fw.batch(() {
        a.write(1);
        throw FixtureError("batch error");
      });
    } catch (_) {}
    if (jsStrictEqual(a.read(), 1)) {
      expect(runs).toBe(2);
      expect(seen).toBe(1);
    } else {
      expect(a.read()).toBe(0);
      expect(runs).toBe(1);
    }
    a.write(2);
    expect(seen).toBe(2);
  }),

  /**
   *  S(a) → E(eff)  [created inside batch]
   *
   * An effect created inside a batch runs its initial execution
   * immediately (synchronously), not deferred to batch end.
   */
  Fixture(70, "effect first run is immediate even inside batch", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var runs = 0;
    fw.batch(() {
      fw.effect(() {
        a.read();
        runs++;
      });
      expect(runs).toBe(1);
    });
  }),

  /**
   *  S(a) → E(eff)
   *
   * batch { a.write(1); a.write(2); a.write(3) } — effect observes
   * [0, 3] only; intermediate values 1 and 2 are never seen.
   */
  Fixture(72, "intermediate values skipped (only final value observed)", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final values = <dynamic>[];
    fw.effect(() {
      values.add(a.read());
    });
    expect(values).toEqual(<dynamic>[0]);
    fw.batch(() {
      a.write(1);
      a.write(2);
      a.write(3);
    });
    expect(values).toEqual(<dynamic>[0, 3]);
  }),

  /**
   *  S(a) ─→ C(c) → E(eff)
   *  S(b) ─→ /
   *
   * batch { a.write(1); b.write(-1) } — c = a+b still equals 0.
   * Effect must NOT re-run (computed value unchanged).
   */
  Fixture(
    119,
    "batch: computed same result despite source change — no effect run",
    (ReactiveAdapter fw) {
      final a = fw.signal<dynamic>(0);
      final b = fw.signal<dynamic>(0);
      final c = fw.computed<dynamic>(() => a.read() + b.read());
      var runs = 0;
      fw.effect(() {
        c.read();
        runs++;
      });
      expect(runs).toBe(1);
      expect(c.read()).toBe(0);
      fw.batch(() {
        a.write(1);
        b.write(-1);
      });
      expect(c.read()).toBe(0);
      expect(runs).toBe(1);
    },
  ),

  /**
   *  S(a) → E(eff1)  cleanup: b.write(a.read())
   *  S(b) → E(eff2)
   *
   * When eff1's cleanup writes to b, eff2 must settle on the final
   * value of b. (Only the final value is checked, not the number of
   * notifications.)
   */
  Fixture(
    120,
    "cleanup writes inside effect: downstream settles on final value",
    (ReactiveAdapter fw) {
      final a = fw.signal<dynamic>(0);
      final b = fw.signal<dynamic>(0);
      final log = <dynamic>[];
      fw.effect(() {
        a.read();
        return () {
          b.write(a.read());
        };
      });
      fw.effect(() {
        log.add("b:${b.read()}");
      });
      log.length = 0;
      a.write(1);
      expect(log.length).toBeGreaterThanOrEqual(1);
      expect(log[log.length - 1]).toBe("b:1");
    },
  ),

  /**
   *  S(a) → E(good)
   *  S(a) → E(bad)   ← throws when a > 0
   *
   * One effect throws during batch flush. The other (good) effect
   * must still run with the updated value.
   */
  Fixture(121, "pending effects run even if some effects throw during batch", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var goodRuns = 0;
    fw.effect(() {
      a.read();
      goodRuns++;
    });
    try {
      fw.effect(() {
        if (a.read() > 0) throw FixtureError("bad effect");
      });
    } catch (_) {}
    expect(goodRuns).toBe(1);
    try {
      fw.batch(() {
        a.write(1);
      });
    } catch (_) {}
    expect(goodRuns).toBeGreaterThanOrEqual(2);
  }),

  /**
   *  S(a) → E(eff)
   *
   * After a batch completes, subsequent writes propagate normally
   * (one write = one effect run), verifying batch state is fully reset.
   */
  Fixture(122, "post-batch writes work normally", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var runs = 0;
    fw.effect(() {
      a.read();
      runs++;
    });
    expect(runs).toBe(1);
    fw.batch(() {
      a.write(1);
    });
    expect(runs).toBe(2);
    a.write(2);
    expect(runs).toBe(3);
    expect(a.read()).toBe(2);
  }),

  /**
   *  S(a) → E(eff)
   *
   * Multiple consecutive batches that each write then revert to the
   * original value. Effect must never re-run (all batches are no-ops).
   */
  Fixture(123, "repeated no-op batches don't re-trigger effects", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var runs = 0;
    fw.effect(() {
      a.read();
      runs++;
    });
    expect(runs).toBe(1);
    fw.batch(() {
      a.write(1);
      a.write(0);
    });
    expect(runs).toBe(1);
    fw.batch(() {
      a.write(2);
      a.write(0);
    });
    expect(runs).toBe(1);
    fw.batch(() {
      a.write(3);
      a.write(0);
    });
    expect(runs).toBe(1);
    a.write(5);
    expect(runs).toBe(2);
  }),

  /**
   *  S(a) → E(eff) → dispose
   *
   * batch { a.write(1); dispose(); a.write(2) } — effect is disposed
   * mid-batch. It must NOT run at batch end despite pending notification.
   */
  Fixture(124, "trigger+dispose+retrigger in batch = no run", (
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
      a.write(3);
    });
    expect(runs).toBe(2);
  }),

  /**
   *  S(a) → C(c) → E(eff)
   *
   * batch { a.write(5); a.write(0) } — source reverts to original.
   * Computed and effect must NOT re-evaluate.
   */
  Fixture(125, "batch: source reverts → computed not notified", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final c = fw.computed<dynamic>(() => a.read() * 2);
    var runs = 0;
    fw.effect(() {
      c.read();
      runs++;
    });
    expect(runs).toBe(1);
    fw.batch(() {
      a.write(5);
      a.write(0);
    });
    expect(runs).toBe(1);
    expect(c.read()).toBe(0);
  }),

  /**
   *  S(a) → E(eff)  [created inside batch after write]
   *
   * batch { a.write(42); effect(...) } — effect created after the
   * write sees the updated value 42 on its initial run.
   */
  Fixture(126, "new effect inside batch after write sees updated value", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var seen = -1;
    fw.batch(() {
      a.write(42);
      fw.effect(() {
        seen = a.read();
      });
    });
    expect(seen).toBe(42);
  }),

  /**
   *  S(a) → C(b) → C(c)
   *
   * batch { a.write(5); c.read() } — pulling c inside the batch
   * forces eager evaluation of the entire upstream chain (b and c).
   */
  Fixture(128, "reading computed in batch forces upstream evaluation", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() => a.read() + 1);
    final c = fw.computed<dynamic>(() => b.read() * 2);
    fw.batch(() {
      a.write(5);
      expect(c.read()).toBe(12);
      expect(b.read()).toBe(6);
    });
  }),

  /**
   *      S(a)
   *     /    \
   *   C(c1)  C(c2) → E(eff)
   *
   * batch { a.write(5); c1.read() } — reading sibling c1 inside
   * the batch must NOT trigger c2's effect early; effect fires
   * only when the batch completes.
   */
  Fixture(129, "reading one computed doesn't notify sibling effect early", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final c1 = fw.computed<dynamic>(() => a.read() + 1);
    final c2 = fw.computed<dynamic>(() => a.read() * 2);
    var c2Runs = 0;
    fw.effect(() {
      c2.read();
      c2Runs++;
    });
    expect(c2Runs).toBe(1);
    fw.batch(() {
      a.write(5);
      c1.read();
      expect(c2Runs).toBe(1);
    });
    expect(c2Runs).toBe(2);
  }),

  /**
   *  S(a) → E(eff1)  writes: b.write(a+1), c.write(a+2)
   *  S(b) ─→ E(eff2)
   *  S(c) ─→ /
   *
   * Writes inside an effect body: eff2 must settle on the final
   * values of both b and c. (Only the final value is checked, not the
   * number of notifications.)
   */
  Fixture(130, "effect inner writes: downstream settles on final values", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    final c = fw.signal<dynamic>(0);
    final log = <dynamic>[];
    fw.effect(() {
      final v = a.read();
      b.write(v + 1);
      c.write(v + 2);
    });
    fw.effect(() {
      log.add("${b.read()},${c.read()}");
    });
    log.length = 0;
    a.write(10);
    expect(log[log.length - 1]).toBe("11,12");
  }),

  /**
   *  S(a) → C(c1) → C(c2) → E(eff)
   *  S(b) ────────→ /
   *
   * batch { a.write(5); a.write(0); b.write(20) } — a reverts but b
   * changes. c2 = c1 + b must still update because b changed.
   */
  Fixture(131, "derived-of-derived: source reverts in batch", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(10);
    final c1 = fw.computed<dynamic>(() => a.read() * 2);
    final c2 = fw.computed<dynamic>(() => c1.read() + b.read());
    var runs = 0;
    fw.effect(() {
      c2.read();
      runs++;
    });
    expect(runs).toBe(1);
    fw.batch(() {
      a.write(5);
      a.write(0);
      b.write(20);
    });
    expect(c2.read()).toBe(20);
    expect(runs).toBe(2);
  }),

  /**
   *  S(a) ─→ E(eff)
   *  S(b) ─→ /
   *
   * Two independent signals change inside one batch. Effect fires
   * exactly once and both signals have their final values.
   */
  Fixture(74, "multiple signals grouped in single update", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    var runs = 0;
    fw.effect(() {
      a.read();
      b.read();
      runs++;
    });
    expect(runs).toBe(1);
    fw.batch(() {
      a.write(1);
      b.write(1);
    });
    expect(runs).toBe(2);
    expect(a.read()).toBe(1);
    expect(b.read()).toBe(1);
  }),
];
