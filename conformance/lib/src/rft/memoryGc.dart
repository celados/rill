// Port of rft memoryGc.ts at 745e6eb. See LICENSE in this directory.
import '../../adapter.dart';
import 'fixture.dart';

final memoryGcCases = <Fixture>[
  /**
   *  S(a) ─→ C(b) ─→ E(eff1)
   *               ─→ E(eff2)
   *       dispose both
   *  S(a) ─→ C(b)   (no listeners, links cleaned)
   *
   * After disposing both effects, writes to S(a) must not
   * trigger the disposed callbacks. The computed C(b) should
   * still be readable on demand.
   */
  Fixture(
    160,
    "computed after losing all listeners: disposed effects stop, value stays correct",
    (ReactiveAdapter fw) {
      final a = fw.signal<dynamic>(0);
      final b = fw.computed<dynamic>(() => a.read() * 2);
      var runs = 0;
      final dispose1 = fw.effect(() {
        b.read();
        runs++;
      });
      final dispose2 = fw.effect(() {
        b.read();
      });
      expect(runs).toBe(1);
      a.write(1);
      expect(runs).toBe(2);
      dispose1();
      dispose2();
      a.write(2);
      expect(runs).toBe(2);
      expect(b.read()).toBe(4);
    },
  ),

  /**
   *  S(a) ─→ C(b) ─→ C(c) ─→ C(d) ─→ E(eff)
   *                                  dispose()
   *  S(a) ─→ C(b) ─→ C(c) ─→ C(d)   (no listener)
   *
   * Disposing the sole effect at the end of a multi-level
   * computed chain must stop writes to S(a) from reaching it.
   * (Link cleanup itself is internal and not observed here.)
   * The computeds should still be readable on demand.
   */
  Fixture(
    161,
    "multi-level computed after all listeners removed: disposed effect stops, value stays correct",
    (ReactiveAdapter fw) {
      final a = fw.signal<dynamic>(0);
      final b = fw.computed<dynamic>(() => a.read() + 1);
      final c = fw.computed<dynamic>(() => b.read() + 1);
      final d = fw.computed<dynamic>(() => c.read() + 1);
      var runs = 0;
      final dispose = fw.effect(() {
        d.read();
        runs++;
      });
      expect(runs).toBe(1);
      a.write(1);
      expect(runs).toBe(2);
      dispose();
      a.write(2);
      expect(runs).toBe(2);
      expect(d.read()).toBe(5);
    },
  ),

  /**
   *  S(a) ─→ C(b) ─→ E(eff1)
   *               ─→ E(eff2)
   *       dispose eff1
   *  S(a) ─→ C(b) ──X E(eff1)
   *               ─→ E(eff2)
   *
   * Two effects share a computed. Disposing one must keep the
   * other's subscription intact — writes still trigger eff2 but
   * never trigger the disposed eff1.
   */
  Fixture(215, "partial dispose: sibling effect still notified", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() => a.read() * 2);
    var e1Runs = 0;
    var e2Runs = 0;
    final dispose1 = fw.effect(() {
      b.read();
      e1Runs++;
    });
    fw.effect(() {
      b.read();
      e2Runs++;
    });
    expect(e1Runs).toBe(1);
    expect(e2Runs).toBe(1);
    dispose1();
    e1Runs = 0;
    e2Runs = 0;
    a.write(1);
    expect(e1Runs).toBe(0);
    expect(e2Runs).toBe(1);
    a.write(2);
    expect(e1Runs).toBe(0);
    expect(e2Runs).toBe(2);
  }),
];
