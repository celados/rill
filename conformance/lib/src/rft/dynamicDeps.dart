// Port of rft dynamicDeps.ts at 745e6eb. See LICENSE in this directory.
import '../../adapter.dart';
import 'fixture.dart';

final dynamicDepsCases = <Fixture>[
  /**
   *  S(cond) ─→ C(c)
   *  S(a)   ?─→ C(c)   (when cond = true)
   *  S(b)   ?─→ C(c)   (when cond = false)
   *
   * Only the active branch dep triggers recomputation.
   * Writing to the inactive dep must not cause c to re-evaluate.
   */
  Fixture(12, "active dep triggers, inactive dep does not", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>("a");
    final b = fw.signal<dynamic>("b");
    final cond = fw.signal<dynamic>(true);
    var cCalls = 0;
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return jsTruthy(cond.read()) ? a.read() : b.read();
    });
    expect(c.read()).toBe("a");
    expect(cCalls).toBe(1);
    // b is inactive, changing it should not trigger c
    b.write("bb");
    expect(c.read()).toBe("a");
    expect(cCalls).toBe(1);
    // a is active, changing it should trigger c
    a.write("aa");
    expect(c.read()).toBe("aa");
    expect(cCalls).toBe(2);
  }),

  /**
   *  S(cond) ─→ C(c)
   *  S(a)   ?─→ C(c)   (when cond = true)
   *  S(b)   ?─→ C(c)   (when cond = false)
   *
   * After switching cond from true to false, the old dep (a)
   * must be deactivated: writing to a must not trigger c.
   * The new dep (b) must be active.
   */
  Fixture(13, "switching branches deactivates old deps", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>("a");
    final b = fw.signal<dynamic>("b");
    final cond = fw.signal<dynamic>(true);
    var cCalls = 0;
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return jsTruthy(cond.read()) ? a.read() : b.read();
    });
    expect(c.read()).toBe("a");
    cCalls = 0;
    // Switch to b branch
    cond.write(false);
    expect(c.read()).toBe("b");
    cCalls = 0;
    // a is now inactive
    a.write("aa");
    expect(c.read()).toBe("b");
    expect(cCalls).toBe(0);
    // b is now active
    b.write("bb");
    expect(c.read()).toBe("bb");
    expect(cCalls).toBe(1);
  }),

  /**
   *  S(a) ─→ C(c)
   *  S(cond) ─→ C(d)
   *  C(c)   ?─→ C(d)   (when cond = true)
   *  S(b)   ?─→ C(d)   (when cond = false)
   *
   * cond and a change simultaneously. After the switch, d reads c
   * which depends on the updated a. The newly-acquired dep (c) must
   * be up-to-date before d evaluates.
   */
  Fixture(14, "new deps updated before dependee", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(1);
    final b = fw.signal<dynamic>(10);
    final cond = fw.signal<dynamic>(false);
    final c = fw.computed<dynamic>(() => a.read());
    final d = fw.computed<dynamic>(
      () => (jsTruthy(cond.read()) ? c.read() : b.read()),
    );
    expect(d.read()).toBe(10);
    // Switch to c branch, and change a at the same time
    cond.write(true);
    a.write(2);
    // d should see the updated a through c
    expect(d.read()).toBe(2);
  }),

  /**
   *  S(a) ─→ C(b)
   *  S(a) ─→ C(c)
   *  C(b) ?─→ C(c)   (when a <= 0)
   *
   * c reads a directly; when a > 0 it returns a, otherwise it
   * falls through to b (which also reads a). Toggling a between
   * positive and zero switches which branch is taken.
   */
  Fixture(16, "lazy branch", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() => a.read());
    final c = fw.computed<dynamic>(
      () => (jsTruthy(a.read() > 0) ? a.read() : b.read()),
    );
    expect(c.read()).toBe(0);
    a.write(1);
    expect(c.read()).toBe(1);
    a.write(0);
    expect(c.read()).toBe(0);
  }),

  /**
   *  S(toggle) ─→ C(p)
   *  S(state) ?─→ C(p)   (when toggle = true)
   *  S(state)  ─→ C(pp)
   *               E(eff) ← reads p
   *
   * p and pp both subscribe to state. When toggle flips to false,
   * p drops its subscription to state. This cleanup must not
   * accidentally remove pp's independent subscription to state.
   */
  Fixture(165, "computed dep cleanup doesn't delete sibling subscription", (
    ReactiveAdapter fw,
  ) {
    final toggle = fw.signal<dynamic>(true);
    final state = fw.signal<dynamic>(1);
    final p = fw.computed<dynamic>(
      () => (jsTruthy(toggle.read()) ? state.read() : 111),
    );
    final pp = fw.computed<dynamic>(() => state.read());
    fw.effect(() {
      p.read();
    });
    toggle.write(false);
    expect(p.read()).toBe(111);
    state.write(2);
    expect(pp.read()).toBe(2);
  }),

  /**
   *  S(flag) ─→ C(c)
   *  S(src) ?─→ C(c)   (when flag = true)
   *              |
   *             E(eff)
   *
   * flag=true: c reads src. flag flips to false: c drops src.
   * src changes while inactive. flag flips back to true:
   * c must re-subscribe to src and see its updated value.
   */
  Fixture(166, "after dep removed via branch switch, re-subscribing works", (
    ReactiveAdapter fw,
  ) {
    final flag = fw.signal<dynamic>(true);
    final src = fw.signal<dynamic>(1);
    final c = fw.computed<dynamic>(
      () => (jsTruthy(flag.read()) ? src.read() : 0),
    );
    var seen = -1;
    fw.effect(() {
      seen = c.read();
    });
    expect(seen).toBe(1);
    flag.write(false);
    expect(seen).toBe(0);
    src.write(2);
    flag.write(true);
    expect(seen).toBe(2);
  }),

  /**
   *  S(items) ─→ C(isLoaded) ─→ C(msg)
   *                                |
   *                              E(eff)
   *
   * items toggles between undefined and arrays. isLoaded is a
   * boolean gate; msg maps it to a string. Repeated writes must
   * propagate correctly through the chain to the effect.
   */
  Fixture(194, "chained computed dirty reallocation via effect", (
    ReactiveAdapter fw,
  ) {
    // items → isLoaded (boolean) → msg (string)
    // effect observes msg. Repeated writes to items.
    var seen = "";
    final items = fw.signal<dynamic>(undefined);
    final isLoaded = fw.computed<dynamic>(() => jsTruthy(items.read()));
    final msg = fw.computed<dynamic>(
      () => jsTruthy(isLoaded.read()) ? "loaded" : "not loaded",
    );
    fw.effect(() {
      seen = msg.read();
    });
    expect(seen).toBe("not loaded");
    items.write(<dynamic>[1, 2, 3]);
    expect(seen).toBe("loaded");
    items.write(<dynamic>[4, 5]);
    expect(seen).toBe("loaded");
    items.write(undefined);
    expect(seen).toBe("not loaded");
  }),

  /**
   *  S(items) ─→ C(isLoaded) ─→ C(msg)
   *
   * Same chain as #194 but driven by manual reads instead of an
   * effect. Intermediate reads of isLoaded are interleaved between
   * writes and final reads of msg. The chain must stay consistent.
   */
  Fixture(195, "chained computed dirty reallocation via manual read", (
    ReactiveAdapter fw,
  ) {
    // Same chain as #194 but driven by manual reads with
    // intermediate computed reads interleaved.
    final items = fw.signal<dynamic>(undefined);
    final isLoaded = fw.computed<dynamic>(() => jsTruthy(items.read()));
    final msg = fw.computed<dynamic>(
      () => jsTruthy(isLoaded.read()) ? "loaded" : "not loaded",
    );
    expect(msg.read()).toBe("not loaded");
    items.write(<dynamic>[1, 2, 3]);
    // Read intermediate computed before final
    isLoaded.read();
    expect(msg.read()).toBe("loaded");
    items.write(undefined);
    expect(msg.read()).toBe("not loaded");
  }),

  /**
   *  S(src1) ─→ C(c1)
   *  S(src1) ─→ C(c2) ← S(src2)
   *     C(c1) ─→ C(c3) ← C(c2)
   *
   * Diamond through src1. When src1 changes 0→2, c1 changes but
   * c2 stays the same (src1%2 is still 0). c3 must still
   * re-evaluate because c1 changed. When src2 then changes,
   * c3 must re-evaluate again.
   */
  Fixture(
    196,
    "maybe-dirty diamond: first dep unmarked, second still triggers",
    (ReactiveAdapter fw) {
      // c1 = src1, c2 = (src1 % 2) + src2, c3 = f(c1, c2)
      // When src1: 0→2, c1 changes but c2 stays 0. c3 must still re-evaluate.
      // When src2: 0→1, c2 changes. c3 must re-evaluate again.
      var c3Calls = 0;
      final src1 = fw.signal<dynamic>(0);
      final src2 = fw.signal<dynamic>(0);
      final c1 = fw.computed<dynamic>(() => src1.read());
      final c2 = fw.computed<dynamic>(() => (src1.read() % 2) + src2.read());
      final c3 = fw.computed<dynamic>(() {
        c3Calls++;
        return c1.read() + c2.read();
      });
      c3.read();
      expect(c3Calls).toBe(1);
      src1.write(2);
      c3.read();
      expect(c3Calls).toBe(2);
      src2.write(1);
      c3.read();
      expect(c3Calls).toBe(3);
    },
  ),

  /**
   *  S(src) ─→ C(c1) ─→ C(c2) ─→ E(eff)
   *             c1 = src % 2
   *             c2 = c1 + 1
   *
   * Multiple writes to src (all even) leave c1's output at 0.
   * c1 re-evaluates, but value-equality must stop propagation:
   * c2 and the effect must not re-run.
   */
  Fixture(
    197,
    "chained value-equality stops propagation across multiple writes",
    (ReactiveAdapter fw) {
      // src → c1 (src % 2) → c2 (c1 + 1) → effect
      // Multiple writes to src that don't change c1's output.
      // c2 and effect should not re-run.
      var c1Calls = 0;
      var c2Calls = 0;
      var effectRuns = 0;
      final src = fw.signal<dynamic>(0);
      final c1 = fw.computed<dynamic>(() {
        c1Calls++;
        return src.read() % 2;
      });
      final c2 = fw.computed<dynamic>(() {
        c2Calls++;
        return c1.read() + 1;
      });
      fw.effect(() {
        c2.read();
        effectRuns++;
      });
      expect(effectRuns).toBe(1);
      c1Calls = 0;
      c2Calls = 0;
      effectRuns = 0;
      // All even numbers: c1 stays 0
      src.write(2);
      src.write(4);
      src.write(6);
      expect(c1Calls).toBeGreaterThanOrEqual(1);
      expect(c2Calls).toBe(0);
      expect(effectRuns).toBe(0);
    },
  ),

  /**
   *  S(cond) ─→ E(eff)
   *  S(a)   ?─→ E(eff)   (when cond = true)
   *
   * Initially cond=false so a is not tracked. After cond flips
   * to true, the effect discovers a as a new dep. Subsequent
   * writes to a must trigger the effect.
   */
  Fixture(198, "effect discovers new branch deps", (ReactiveAdapter fw) {
    // Effect has dynamic branch: cond ? a : "other".
    // Initially cond=false, a is not tracked.
    // After cond→true, changing a should trigger effect.
    final cond = fw.signal<dynamic>(false);
    final a = fw.signal<dynamic>("value");
    var runs = 0;
    var seen = "";
    fw.effect(() {
      runs++;
      seen = jsTruthy(cond.read()) ? a.read() : "other";
    });
    expect(seen).toBe("other");
    expect(runs).toBe(1);
    // a is inactive — should not trigger
    a.write("Hi");
    expect(seen).toBe("other");
    expect(runs).toBe(1);
    // Switch branch → a becomes active
    cond.write(true);
    expect(seen).toBe("Hi");
    expect(runs).toBe(2);
    // a is now active
    a.write("World");
    expect(seen).toBe("World");
    expect(runs).toBe(3);
  }),

  /**
   *  S(cond) ─→ E(eff)
   *  S(a)   ?─→ E(eff)   (when cond = true)
   *
   * Initially cond=true so a is tracked. After cond flips to
   * false, a becomes inactive. Subsequent writes to a must NOT
   * trigger the effect.
   */
  Fixture(199, "effect ignores inactive branch dep", (ReactiveAdapter fw) {
    // Effect has dynamic branch: cond ? a : "other".
    // Initially cond=true, a is tracked.
    // After cond→false, changing a should NOT trigger effect.
    final cond = fw.signal<dynamic>(true);
    final a = fw.signal<dynamic>("value");
    var runs = 0;
    var seen = "";
    fw.effect(() {
      runs++;
      seen = jsTruthy(cond.read()) ? a.read() : "other";
    });
    expect(seen).toBe("value");
    expect(runs).toBe(1);
    // Switch to inactive branch
    cond.write(false);
    expect(seen).toBe("other");
    expect(runs).toBe(2);
    // a is now inactive — should not trigger
    a.write("changed");
    expect(seen).toBe("other");
    expect(runs).toBe(2);
  }),

  /**
   *  S(a)  S(b)  S(c)  S(fx1Out)  S(fx2Out)
   *
   *  E(fx1): c<2 ?─→ a
   *          c>1 ?─→ b
   *          writes fx1Out
   *
   *  E(fx2): c>1 ?─→ a
   *          c<3 ?─→ b
   *          always reads fx1Out
   *          writes fx2Out
   *
   * Two effects with overlapping deps that shift based on a
   * shared condition signal c. Changing b must only trigger the
   * effect(s) that currently read it. Changing c reshuffles
   * which deps each effect tracks.
   */
  Fixture(200, "independent dep tracking across effects with dynamic deps", (
    ReactiveAdapter fw,
  ) {
    // Two effects with overlapping deps that change branches
    // based on a shared condition signal.
    // fx1: c<2 → reads a; c>1 → reads b
    // fx2: c>1 → reads a; c<3 → reads b; also reads fx1 output
    final a = fw.signal<dynamic>(1);
    final b = fw.signal<dynamic>(2);
    final c = fw.signal<dynamic>(0);
    final fx1Out = fw.signal<dynamic>(0);
    final fx2Out = fw.signal<dynamic>(0);
    var fx1Runs = 0;
    fw.effect(() {
      fx1Runs++;
      num result = 0;
      if (c.read() < 2) result += a.read();
      if (c.read() > 1) result += b.read();
      fx1Out.write(result);
    });
    var fx2Runs = 0;
    fw.effect(() {
      fx2Runs++;
      num result = 0;
      if (c.read() > 1) result += a.read();
      if (c.read() < 3) result += b.read();
      result += fx1Out.read();
      fx2Out.write(result);
    });
    // c=0: fx1 reads a(1)→1, fx2 reads b(2)+fx1Out(1)→3
    expect(fx1Out.read()).toBe(1);
    expect(fx2Out.read()).toBe(3);
    fx1Runs = 0;
    fx2Runs = 0;
    // b changes: fx1 doesn't read b (c<2 only), fx2 reads b
    b.write(3);
    expect(fx1Out.read()).toBe(1);
    expect(fx2Out.read()).toBe(4);
    expect(fx1Runs).toBe(0);
    expect(fx2Runs).toBe(1);
    fx1Runs = 0;
    fx2Runs = 0;
    // c=2: fx1 reads b(3)→3, fx2 reads a(1)+b(3)+fx1Out(3)→7
    c.write(2);
    expect(fx1Out.read()).toBe(3);
    expect(fx2Out.read()).toBe(7);
  }),
];
