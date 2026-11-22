// Port of rft graphPropagation.ts at 745e6eb. See LICENSE in this directory.
import '../../adapter.dart';
import 'fixture.dart';

final graphPropagationCases = <Fixture>[
  /**
   *     S(a)
   *    /    \
   *  C(b)  C(c)
   *    \    /
   *     C(d)
   *
   * Classic diamond. d must evaluate only once per update.
   */
  Fixture(1, "diamond", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>("a");
    final b = fw.computed<dynamic>(() => a.read());
    final c = fw.computed<dynamic>(() => a.read());
    var dCalls = 0;
    final d = fw.computed<dynamic>(() {
      dCalls++;
      return b.read() + " " + c.read();
    });
    expect(d.read()).toBe("a a");
    expect(dCalls).toBe(1);
    a.write("aa");
    expect(d.read()).toBe("aa aa");
    expect(dCalls).toBe(2);
  }),

  /**
   *     S(a)
   *    /    \
   *  C(b)  C(c)
   *    \    /
   *     C(d)
   *      |
   *     C(e)
   *
   * Diamond with a tail. e must evaluate only once.
   */
  Fixture(2, "diamond + tail", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>("a");
    final b = fw.computed<dynamic>(() => a.read());
    final c = fw.computed<dynamic>(() => a.read());
    final d = fw.computed<dynamic>(() => b.read() + " " + c.read());
    var eCalls = 0;
    final e = fw.computed<dynamic>(() {
      eCalls++;
      return d.read();
    });
    expect(e.read()).toBe("a a");
    expect(eCalls).toBe(1);
    a.write("aa");
    expect(e.read()).toBe("aa aa");
    expect(eCalls).toBe(2);
  }),

  /**
   *       S(a)
   *      /    \
   *    C(b)  C(c)
   *     |      |
   *     |    C(d)
   *      \    /
   *       C(e)
   *      /    \
   *    C(f)  C(g)
   *
   * Asymmetric diamond (different depths) with fan-out at the bottom.
   * e, f, g each evaluate only once.
   */
  Fixture(3, "jagged diamond + tails", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>("a");
    final b = fw.computed<dynamic>(() => a.read());
    final c = fw.computed<dynamic>(() => a.read());
    final d = fw.computed<dynamic>(() => c.read());
    var eCalls = 0;
    final e = fw.computed<dynamic>(() {
      eCalls++;
      return b.read() + " " + d.read();
    });
    var fCalls = 0;
    final f = fw.computed<dynamic>(() {
      fCalls++;
      return e.read();
    });
    var gCalls = 0;
    final g = fw.computed<dynamic>(() {
      gCalls++;
      return e.read();
    });
    expect(f.read()).toBe("a a");
    expect(g.read()).toBe("a a");
    eCalls = 0;
    fCalls = 0;
    gCalls = 0;
    a.write("b");
    expect(e.read()).toBe("b b");
    expect(eCalls).toBe(1);
    expect(f.read()).toBe("b b");
    expect(fCalls).toBe(1);
    expect(g.read()).toBe("b b");
    expect(gCalls).toBe(1);
  }),

  /**
   *    S(a)
   *    / |
   *  C(b)|
   *    \ |
   *    C(c)
   *      |
   *    C(d)
   *
   * Skip-connection: c reads both a and b (a's child).
   * d must evaluate only once despite two paths from a to c.
   */
  Fixture(5, "drop A→B→A updates", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(2);
    final b = fw.computed<dynamic>(() => a.read() - 1);
    final c = fw.computed<dynamic>(() => a.read() + b.read());
    var dCalls = 0;
    final d = fw.computed<dynamic>(() {
      dCalls++;
      return "d: ${c.read()}";
    });
    expect(d.read()).toBe("d: 3");
    expect(dCalls).toBe(1);
    a.write(4);
    expect(d.read()).toBe("d: 7");
    expect(dCalls).toBe(2);
  }),

  /**
   *      S(a)
   *     /    \
   *   C(b)  *C(c)  ← c always returns "c"
   *     \    /
   *      C(d)
   *
   * One branch unchanged. d must still update from b.
   */
  Fixture(6, "one unchanged dep does not block update from changed dep", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>("a");
    final b = fw.computed<dynamic>(() => a.read());
    final c = fw.computed<dynamic>(() {
      a.read();
      return "c";
    });
    var dCalls = 0;
    final d = fw.computed<dynamic>(() {
      dCalls++;
      return b.read() + " " + c.read();
    });
    expect(d.read()).toBe("a c");
    dCalls = 0;
    a.write("aa");
    expect(d.read()).toBe("aa c");
    expect(dCalls).toBe(1);
  }),

  /**
   *      S(a)
   *     /    \
   *   *C(b)  *C(c)  ← both always return constants
   *     \    /
   *      C(d)
   *
   * Both branches unchanged. d must NOT re-evaluate (propagation cut).
   */
  Fixture(7, "unchanged computed values stop propagation to downstream", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>("a");
    final b = fw.computed<dynamic>(() {
      a.read();
      return "b";
    });
    final c = fw.computed<dynamic>(() {
      a.read();
      return "c";
    });
    var dCalls = 0;
    final d = fw.computed<dynamic>(() {
      dCalls++;
      return b.read() + " " + c.read();
    });
    expect(d.read()).toBe("b c");
    dCalls = 0;
    a.write("aa");
    expect(d.read()).toBe("b c");
    expect(dCalls).toBe(0);
  }),

  /**
   *     S(a)
   *    /    \
   *  C(b)  C(c)
   *    \    /
   *     C(d)
   *
   * Diamond — verify evaluation order: d runs after both b and c.
   */
  Fixture(8, "topological order", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final order = <dynamic>[];
    final b = fw.computed<dynamic>(() {
      final v = a.read();
      order.add("b");
      return v;
    });
    final c = fw.computed<dynamic>(() {
      final v = a.read();
      order.add("c");
      return v;
    });
    final d = fw.computed<dynamic>(() {
      final v = b.read() + c.read();
      order.add("d");
      return v;
    });
    expect(d.read()).toBe(0);
    order.length = 0;
    a.write(1);
    expect(d.read()).toBe(2);
    expect(order.indexOf("d")).toBeGreaterThan(order.indexOf("b"));
    expect(order.indexOf("d")).toBeGreaterThan(order.indexOf("c"));
    expect(order.where((x) => jsStrictEqual(x, "d")).toList()).toHaveLength(1);
  }),

  /**
   *  S(a) → C(b)
   *    \    /
   *     C(c)
   *    /
   *  S(a) → C(d)  [same a]
   *
   *  a→b, {a,b}→c, {a,c}→d
   *
   * Increasing fan-in at each level. Each node evaluates once.
   */
  Fixture(9, "linear convergence", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() => a.read());
    var cCalls = 0;
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return a.read() + b.read();
    });
    var dCalls = 0;
    final d = fw.computed<dynamic>(() {
      dCalls++;
      return a.read() + c.read();
    });
    expect(d.read()).toBe(0);
    cCalls = 0;
    dCalls = 0;
    a.write(1);
    expect(d.read()).toBe(3);
    expect(cCalls).toBe(1);
    expect(dCalls).toBe(1);
  }),

  /**
   *  a→b, {b,a}→c, {c,b}→d, {d,c}→e
   *
   *  S(a) ─→ C(b) ─→ C(c) ─→ C(d) ─→ C(e)
   *    \─────→ /  \─────→ /  \─────→ /
   *
   * Each level reads previous two. Naive impl is O(2^n).
   * Each node must evaluate exactly once.
   */
  Fixture(10, "exponential convergence", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() => a.read());
    var cCalls = 0;
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return b.read() + a.read();
    });
    var dCalls = 0;
    final d = fw.computed<dynamic>(() {
      dCalls++;
      return c.read() + b.read();
    });
    var eCalls = 0;
    final e = fw.computed<dynamic>(() {
      eCalls++;
      return d.read() + c.read();
    });
    expect(e.read()).toBe(0);
    cCalls = 0;
    dCalls = 0;
    eCalls = 0;
    a.write(1);
    expect(e.read()).toBe(5);
    expect(cCalls).toBe(1);
    expect(dCalls).toBe(1);
    expect(eCalls).toBe(1);
  }),

  /**
   *  S(a) → C(c) ← E(e1)  [disposed]
   *                ← E(e2)  [still alive]
   *
   * Two effects share one computed. After e1 disposes,
   * e2 must still receive updates.
   */
  Fixture(116, "other listeners still notified after one disposes", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final c = fw.computed<dynamic>(() => a.read() * 2);
    var runs1 = 0;
    var runs2 = 0;
    final dispose1 = fw.effect(() {
      c.read();
      runs1++;
    });
    fw.effect(() {
      c.read();
      runs2++;
    });
    expect(runs1).toBe(1);
    expect(runs2).toBe(1);
    dispose1();
    a.write(1);
    expect(runs1).toBe(1);
    expect(runs2).toBe(2);
    a.write(2);
    expect(runs1).toBe(1);
    expect(runs2).toBe(3);
  }),

  /**
   *       S(a)
   *      / |  \
   *   C(b) *C(c) *C(d)  ← c, d always return constants
   *      \ |  /
   *       C(e)
   *
   * Three-way diamond, two branches constant. e must still update from b.
   */
  Fixture(157, "three-way diamond: sub updates when two of three deps unmark", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>("a");
    final b = fw.computed<dynamic>(() => a.read());
    final c = fw.computed<dynamic>(() {
      a.read();
      return "c";
    });
    final d = fw.computed<dynamic>(() {
      a.read();
      return "d";
    });
    var eCalls = 0;
    final e = fw.computed<dynamic>(() {
      eCalls++;
      return b.read() + " " + c.read() + " " + d.read();
    });
    expect(e.read()).toBe("a c d");
    eCalls = 0;
    a.write("aa");
    expect(e.read()).toBe("aa c d");
    expect(eCalls).toBe(1);
  }),

  /**
   *  S(a) → C(b) → C(c)
   *                  |
   *                 E(eff)  ← subscribes after c.read()
   *
   * Computed is read directly first, then an effect subscribes.
   * Effect must still be notified on subsequent changes.
   */
  Fixture(190, "computed notifies newly-subscribed effect after prior read", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() => a.read());
    final c = fw.computed<dynamic>(() => b.read());
    c.read();
    var runs = 0;
    fw.effect(() {
      c.read();
      runs++;
    });
    expect(runs).toBe(1);
    a.write(1);
    expect(runs).toBe(2);
  }),

  /**
   *  S(s) → C(c)
   *           |
   *         E(eff)  ← subscribes after s already changed
   *
   * Source changes before effect subscribes.
   * Effect must see the latest value, not stale.
   */
  Fixture(
    191,
    "effect sees latest computed value when subscribing after source change",
    (ReactiveAdapter fw) {
      final s = fw.signal<dynamic>(0);
      final c = fw.computed<dynamic>(() => s.read());
      c.read();
      s.write(1);
      dynamic seen = undefined;
      fw.effect(() {
        seen = c.read();
      });
      expect(seen).toBe(1);
    },
  ),

  /**
   *    S(s)
   *      |
   *    *C(c)  ← 0 until s >= 10, then 1
   *      |
   *    E(eff)
   *
   * Computed value unchanged despite source change.
   * Effect must NOT re-run (propagation cut by value-equality),
   * but must re-run once the computed value actually changes.
   */
  Fixture(192, "effect not re-run when computed dep value unchanged", (
    ReactiveAdapter fw,
  ) {
    final s = fw.signal<dynamic>(0);
    final c = fw.computed<dynamic>(() => (jsTruthy(s.read() >= 10) ? 1 : 0));
    var runs = 0;
    fw.effect(() {
      c.read();
      runs++;
    });
    expect(runs).toBe(1);
    s.write(1);
    expect(runs).toBe(1);
    s.write(10);
    expect(runs).toBe(2);
  }),

  /**
   *  S(a)  S(b)
   *    \    /
   *     C(c)
   *      |
   *    E(eff)
   *
   * Two independent signals feed one computed.
   * Both change — c and effect must evaluate only once each.
   */
  Fixture(204, "multi-source fan-in", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(1);
    final b = fw.signal<dynamic>(10);
    var cCalls = 0;
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return a.read() + b.read();
    });
    var runs = 0;
    fw.effect(() {
      c.read();
      runs++;
    });
    expect(c.read()).toBe(11);
    expect(runs).toBe(1);
    cCalls = 0;
    runs = 0;
    fw.batch(() {
      a.write(2);
      b.write(20);
    });
    expect(c.read()).toBe(22);
    expect(cCalls).toBe(1);
    expect(runs).toBe(1);
  }),

  /**
   *  S(a)    S(b)
   *    | \  / |
   *    |  \/  |
   *    |  /\  |
   *    | /  \ |
   *  C(c)   C(d)
   *     \   /
   *      C(e)
   *
   * Two signals cross-feed two computeds joining at e.
   * Both signals change — e reflects both writes. (How many times
   * c, d and e evaluate is #146's design difference, not checked here.)
   */
  Fixture(205, "multi-source cross-diamond", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(1);
    final b = fw.signal<dynamic>(10);
    final c = fw.computed<dynamic>(() => a.read() + b.read());
    final d = fw.computed<dynamic>(() => a.read() * b.read());
    final e = fw.computed<dynamic>(() => c.read() + d.read());
    expect(e.read()).toBe(21);
    a.write(2);
    b.write(20);
    expect(e.read()).toBe(62);
    expect(c.read()).toBe(22);
    expect(d.read()).toBe(40);
  }),

  /**
   *       S(a)
   *      /    \
   *    C(b)  C(c)
   *      \    /
   *       C(d)
   *      /    \
   *    C(e)  C(f)
   *      \    /
   *       C(g)
   *
   * Two diamonds stacked. Each node evaluates once.
   */
  Fixture(206, "stacked diamonds", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(1);
    final b = fw.computed<dynamic>(() => a.read());
    final c = fw.computed<dynamic>(() => a.read());
    var dCalls = 0;
    final d = fw.computed<dynamic>(() {
      dCalls++;
      return b.read() + c.read();
    });
    final e = fw.computed<dynamic>(() => d.read());
    final f = fw.computed<dynamic>(() => d.read());
    var gCalls = 0;
    final g = fw.computed<dynamic>(() {
      gCalls++;
      return e.read() + f.read();
    });
    expect(g.read()).toBe(4);
    dCalls = 0;
    gCalls = 0;
    a.write(2);
    expect(g.read()).toBe(8);
    expect(dCalls).toBe(1);
    expect(gCalls).toBe(1);
  }),

  /**
   *             S(a)
   *       / / |  |  \ \
   *     C0 C1 C2 C3 C4 C5
   *      |  |  |  |  |  |
   *     E0 E1 E2 E3 E4 E5
   *
   * Wide fan-out: one signal, many computed+effect pairs.
   * All effects fire exactly once.
   */
  Fixture(207, "wide fan-out: all effects fire once", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final N = 6;
    final runs = List<int>.filled(N, 0);
    for (var i = 0; i < N; i++) {
      final c = fw.computed<dynamic>(() => a.read() + i);
      final idx = i;
      fw.effect(() {
        c.read();
        runs[idx]++;
      });
    }
    for (var i = 0; i < N; i++) expect(runs[i]).toBe(1);
    a.write(1);
    for (var i = 0; i < N; i++) expect(runs[i]).toBe(2);
    a.write(2);
    for (var i = 0; i < N; i++) expect(runs[i]).toBe(3);
  }),

  /**
   *  S(a) → C(b) → C(c) → C(d)
   *                         /
   *  S(a) → C(e) ─────────
   *
   *  depth-3 path and depth-1 path join at f.
   *  f must evaluate only once despite large depth difference.
   */
  Fixture(208, "deep asymmetric join (depth 3 vs 1)", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(1);
    final b = fw.computed<dynamic>(() => a.read());
    final c = fw.computed<dynamic>(() => b.read());
    final d = fw.computed<dynamic>(() => c.read());
    final e = fw.computed<dynamic>(() => a.read());
    var fCalls = 0;
    final f = fw.computed<dynamic>(() {
      fCalls++;
      return d.read() + e.read();
    });
    expect(f.read()).toBe(2);
    fCalls = 0;
    a.write(2);
    expect(f.read()).toBe(4);
    expect(fCalls).toBe(1);
  }),

  /**
   *  S(a)  S(b)  S(c)
   *    |           |
   *    |         C(d)  ← d reads c
   *    |          /
   *    C(e)      ← e reads b, d
   *
   * Three unbatched writes, then one read of e. d is reachable and
   * stale, so it is evaluated exactly once before e uses it.
   */
  Fixture(189, "multi-signal change: reachable computed evaluated once", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(1);
    final b = fw.signal<dynamic>(1);
    final c = fw.signal<dynamic>(1);
    var dCalls = 0;
    final d = fw.computed<dynamic>(() {
      dCalls++;
      return c.read();
    });
    final e = fw.computed<dynamic>(() {
      b.read();
      return jsTruthy(a.read() > 0) ? d.read() : 0;
    });
    expect(e.read()).toBe(1);
    dCalls = 0;
    a.write(2);
    b.write(2);
    c.write(2);
    expect(e.read()).toBe(2);
    expect(dCalls).toBe(1);
  }),
];
