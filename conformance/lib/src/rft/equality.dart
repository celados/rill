// Port of rft equality.ts at 745e6eb. See LICENSE in this directory.
import '../../adapter.dart';
import 'fixture.dart';

final equalityCases = <Fixture>[
  /**
   *  S(a) → C(c)
   *
   * Writing the same primitive value to a signal must not cause
   * its downstream computed to re-evaluate.
   */
  Fixture(28, "same primitive value — no propagation", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(1);
    var cCalls = 0;
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return a.read();
    });
    expect(c.read()).toBe(1);
    expect(cCalls).toBe(1);
    // Write same value
    a.write(1);
    expect(c.read()).toBe(1);
    expect(cCalls).toBe(1);
  }),

  /**
   *  S(a) → *C(b) → C(c) → C(d)
   *
   * b clamps to 0 or 1. Once b stabilizes at 1, further changes
   * to a must not propagate past b — c and d stay untouched.
   */
  Fixture(34, "pruning stops at first unchanged node", (ReactiveAdapter fw) {
    // A → B → C → D
    // B always returns constant after first change
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() => (jsTruthy(a.read() > 0) ? 1 : 0));
    var cCalls = 0;
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return b.read();
    });
    var dCalls = 0;
    final d = fw.computed<dynamic>(() {
      dCalls++;
      return c.read();
    });
    expect(d.read()).toBe(0);
    cCalls = 0;
    dCalls = 0;
    a.write(1);
    expect(d.read()).toBe(1);
    cCalls = 0;
    dCalls = 0;
    // a changes but b still returns 1
    a.write(2);
    expect(d.read()).toBe(1);
    expect(cCalls).toBe(0);
    expect(dCalls).toBe(0);
  }),

  /**
   *  S(s) → C(c1) → *C(c2) → E(eff)
   *
   * c2 always returns 5 regardless of c1. Even with an active
   * effect subscription, the effect must not re-run when s changes
   * because c2's value never changes.
   */
  Fixture(
    169,
    "live pruning: effect not re-run when intermediate computed returns same",
    (ReactiveAdapter fw) {
      final s = fw.signal<dynamic>(0);
      final c1 = fw.computed<dynamic>(() => s.read());
      final c2 = fw.computed<dynamic>(() {
        c1.read();
        return 5;
      });
      var runs = 0;
      fw.effect(() {
        c2.read();
        runs++;
      });
      expect(runs).toBe(1);
      s.write(1);
      expect(runs).toBe(1);
      s.write(2);
      expect(runs).toBe(1);
    },
  ),

  /**
   *  S(a) → *C(b) → C(c)
   *
   * b always returns the same object reference regardless of a.
   * Existing equality tests (#28/#34) use primitive values; this
   * verifies the same value-cut behaviour for non-primitive output.
   * c must NOT re-evaluate because b's reference is unchanged.
   */
  Fixture(220, "computed same object reference — no downstream propagation", (
    ReactiveAdapter fw,
  ) {
    final obj = <String, dynamic>{"x": 1};
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() {
      a.read();
      return obj;
    });
    var cCalls = 0;
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return b.read();
    });
    expect(c.read()).toBe(obj);
    cCalls = 0;
    a.write(1);
    expect(c.read()).toBe(obj);
    expect(cCalls).toBe(0);
  }),
];
