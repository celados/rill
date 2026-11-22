// Port of rft staleEvaluation.ts at 745e6eb. See LICENSE in this directory.
import '../../adapter.dart';
import 'fixture.dart';

final staleEvaluationCases = <Fixture>[
  /**
   *  S(a) ─→ C(b) ─→ C(d)
   *  S(a) ─→ C(c) ─→ C(d)
   *
   * Diamond dependency: both C(b) and C(c) depend on S(a),
   * and C(d) depends on both. After a single write to S(a),
   * C(b) should re-evaluate exactly once and C(d) exactly once.
   */
  Fixture(94, "stale invocation does not trigger pending computations", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var bCalls = 0;
    final b = fw.computed<dynamic>(() {
      bCalls++;
      return a.read();
    });
    final c = fw.computed<dynamic>(() {
      a.read();
      return "c";
    });
    var dCalls = 0;
    final d = fw.computed<dynamic>(() {
      dCalls++;
      return "${b.read()} ${c.read()}";
    });
    expect(d.read()).toBe("0 c");
    bCalls = 0;
    dCalls = 0;
    a.write(1);
    expect(d.read()).toBe("1 c");
    expect(bCalls).toBe(1);
    expect(dCalls).toBe(1);
  }),

  /**
   *  S(a) ─→ C(b) ─→ C(c)
   *
   * Linear chain: after S(a) changes, C(b) must be
   * re-evaluated before C(c) so that C(c) never sees a
   * stale intermediate value.
   */
  Fixture(95, "stale computations evaluated before their dependees", (
    ReactiveAdapter fw,
  ) {
    final order = <dynamic>[];
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() {
      order.add("b");
      return a.read();
    });
    final c = fw.computed<dynamic>(() {
      order.add("c");
      return b.read();
    });
    expect(c.read()).toBe(0);
    order.length = 0;
    a.write(1);
    expect(c.read()).toBe(1);
    expect(order.indexOf("b")).toBeLessThan(order.indexOf("c"));
  }),

  /**
   *  S(a) ─→ C(b) ─→ C(c) ─→ C(d)
   *           +1       +1       +1
   *
   * After writing S(a)=10, reading any node in the chain
   * (b, c, d) must return the fully updated value — no
   * stale intermediate results.
   */
  Fixture(158, "stale chained computed accessed after update: values fresh", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() => a.read() + 1);
    final c = fw.computed<dynamic>(() => b.read() + 1);
    final d = fw.computed<dynamic>(() => c.read() + 1);
    expect(d.read()).toBe(3);
    a.write(10);
    expect(b.read()).toBe(11);
    expect(c.read()).toBe(12);
    expect(d.read()).toBe(13);
  }),

  /**
   *  S(a) ─→ C(b)
   *     (write a=5)
   *  S(a) ─→ C(b) ─→ C(c)   (c created after write)
   *
   * A computed created after its upstream signal has already
   * been written must still pick up the dirty value on first
   * read and remain reactive to further writes.
   */
  Fixture(159, "pending computation created after dirty signal still updates", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() => a.read() * 2);
    a.write(5);
    final c = fw.computed<dynamic>(() => b.read() + 1);
    expect(c.read()).toBe(11);
    a.write(10);
    expect(c.read()).toBe(21);
  }),

  /**
   *  S(a) ─→ C(b) ─→ C(c)
   *    │               │
   *    └───────────────→ C(d) = a + c
   *
   * C(d) depends on both S(a) directly and C(c) transitively.
   * During dirty-checking of C(d), the framework must first
   * refresh the indirect path (b → c) so that C(d) sees
   * consistent values from both branches.
   */
  Fixture(97, "flags indirectly updated during dirty-checking", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() => a.read());
    final c = fw.computed<dynamic>(() => b.read());
    final d = fw.computed<dynamic>(() {
      // d depends on both a and c
      return a.read() + c.read();
    });
    expect(d.read()).toBe(0);
    a.write(1);
    // a=1, b=1, c=1, d=1+1=2
    expect(d.read()).toBe(2);
  }),
];
