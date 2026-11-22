import 'dart:math';

import 'package:rill_conformance/adapter.dart';

import 'kairo.dart';

Workload cellx(ReactiveAdapter fw, int depth) {
  const start = [1, 2, 3, 4];
  const changed = [4, 3, 2, 1];
  final sources = start.map(fw.signal).toList();
  var layer = sources.map((value) => value.read).toList();
  final observed = List<int>.filled(4, 0);
  for (var level = 0; level < depth; level++) {
    final [a, b, c, d] = layer;
    final values = [
      fw.computed(b),
      fw.computed(() => a() - c()),
      fw.computed(() => b() + d()),
      fw.computed(c),
    ];
    final isLast = level == depth - 1;
    for (var index = 0; index < values.length; index++) {
      fw.effect(() {
        final value = values[index].read();
        if (isLast) observed[index] = value;
      });
      values[index].read();
    }
    layer = values.map((value) => value.read).toList();
  }
  List<int> oracle(List<int> source) {
    var [a, b, c, d] = source;
    for (var i = 0; i < depth; i++) {
      (a, b, c, d) = (b, a - c, b + d, c);
    }
    return [a, b, c, d];
  }

  void verify(List<int> expected) {
    for (var i = 0; i < expected.length; i++) {
      check(
        layer[i]() == expected[i] && observed[i] == expected[i],
        'cellx output $i',
      );
    }
  }

  var update = false;
  final initial = oracle(start);
  final updated = oracle(changed);
  verify(initial);
  return () {
    update = !update;
    final next = update ? changed : start;
    fw.batch(() {
      for (var i = 0; i < sources.length; i++) {
        sources[i].write(next[i]);
      }
    });
    verify(update ? updated : initial);
  };
}

int _fib(int value) => value < 2 ? 1 : _fib(value - 1) + _fib(value - 2);
int _hard(int value) => value + _fib(16);

Workload mol(ReactiveAdapter fw) {
  final a = fw.signal(0);
  final b = fw.signal(0);
  final c = fw.computed(() => a.read() % 2 + b.read() % 2);
  final d = fw.computed(
    () => List.generate(5, (i) => i + a.read() % 2 - b.read() % 2),
  );
  final e = fw.computed(() => _hard(c.read() + a.read() + d.read()[0]));
  final f = fw.computed(() {
    final value = d.read()[2];
    return _hard(value == 0 ? b.read() : value);
  });
  final g = fw.computed(() {
    final parity = c.read();
    return parity +
        (parity == 0 ? e.read() % 2 : parity) +
        d.read()[4] +
        f.read();
  });
  var observed = (0, 0, 0);
  fw.effect(() {
    observed = (_hard(g.read()), observed.$2, observed.$3);
  });
  fw.effect(() {
    observed = (observed.$1, g.read(), observed.$3);
  });
  fw.effect(() {
    observed = (observed.$1, observed.$2, _hard(f.read()));
  });
  var i = 0;
  return () {
    fw.batch(() {
      b.write(1);
      a.write(1 + i * 2);
    });
    fw.batch(() {
      a.write(2 + i * 2);
      b.write(2);
    });
    check(observed == (3201, 1604, 3196), 'mol output $observed');
    i = (i + 1) % 10000;
  };
}

typedef DynamicConfig = ({
  int width,
  int layers,
  double staticFraction,
  int fanIn,
  double readFraction,
  int writes,
});

Workload dynamicGraph(ReactiveAdapter fw, DynamicConfig config) {
  final (:width, :layers, :staticFraction, :fanIn, :readFraction, :writes) =
      config;
  final topology = Random(42);
  final staticNodes = List.generate(
    layers - 1,
    (_) => List.generate(width, (_) => topology.nextDouble() < staticFraction),
  );
  final selection = Random(42);
  final selected = List.generate(width, (i) => i);
  final skipped = (width * (1 - readFraction)).round();
  for (var i = 0; i < skipped; i++) {
    selected.removeAt(selection.nextInt(selected.length));
  }

  final sources = List.generate(width, (i) => fw.signal(i.toDouble()));
  var row = sources.map((node) => node.read).toList();
  for (final isStatic in staticNodes) {
    final previous = row;
    row = List.generate(width, (index) {
      final inputs = List.generate(fanIn, (i) => previous[(index + i) % width]);
      return fw.computed(() {
        final first = inputs[0]();
        final drop = !isStatic[index] && first.toInt().isOdd
            ? first.toInt() % (fanIn - 1) + 1
            : -1;
        var sum = first;
        for (var i = 1; i < inputs.length; i++) {
          if (i != drop) sum += inputs[i]();
        }
        return sum;
      }).read;
    });
  }
  final observed = List<double>.filled(selected.length, 0);
  for (var i = 0; i < selected.length; i++) {
    fw.effect(() {
      observed[i] = row[selected[i]]();
    });
  }

  // Alternate two precomputed write sequences so each invocation mutates a warm graph.
  final sequences = [
    List.generate(writes, (i) => (i + i % width).toDouble()),
    List.generate(writes, (i) => (i + i % width + writes * 2).toDouble()),
  ];
  final oracleSources = List.generate(width, (i) => i.toDouble());
  List<double> oracle(List<double> sequence) {
    for (var i = 0; i < sequence.length; i++) {
      oracleSources[i % width] = sequence[i];
    }
    var values = oracleSources;
    for (final isStatic in staticNodes) {
      final previous = values;
      values = List.generate(width, (index) {
        final first = previous[index];
        final omit = !isStatic[index] && first.toInt().isOdd;
        var value = first;
        for (var offset = 1; offset < fanIn; offset++) {
          if (omit && offset - 1 == first % (fanIn - 1)) continue;
          value += previous[(index + offset) % width];
        }
        return value;
      });
    }
    return selected.map((index) => values[index]).toList();
  }

  final expected = sequences.map(oracle).toList();
  // The first sequence only writes indices the second sequence also writes.
  var next = 0;
  return () {
    final sequence = sequences[next];
    for (var i = 0; i < writes; i++) {
      fw.batch(() {
        sources[i % width].write(sequence[i]);
        for (final leaf in selected) {
          row[leaf]();
        }
      });
    }
    for (var i = 0; i < selected.length; i++) {
      final value = expected[next][i];
      check(
        row[selected[i]]() == value && observed[i] == value,
        'dynamic output ${selected[i]}',
      );
    }
    next = 1 - next;
  };
}
