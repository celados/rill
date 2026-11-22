import 'package:rill_conformance/adapter.dart';

typedef Workload = void Function();

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void _write(ReactiveAdapter fw, Writable<int> head, int value) {
  fw.batch(() => head.write(value));
}

int _busy() {
  var result = 0;
  for (var i = 0; i < 100; i++) {
    result++;
  }
  return result;
}

Workload avoidable(ReactiveAdapter fw) {
  final head = fw.signal(0);
  final first = fw.computed(head.read);
  final second = fw.computed(() {
    first.read();
    return 0;
  });
  var computes = 0;
  final third = fw.computed(() {
    computes++;
    return _busy() - 100 + second.read() + 1;
  });
  final fourth = fw.computed(() => third.read() + 2);
  final last = fw.computed(() => fourth.read() + 3);
  var effects = 0;
  fw.effect(() {
    check(last.read() + _busy() == 106, 'avoidable effect value');
    effects++;
  });
  return () {
    _write(fw, head, 1);
    for (var i = 0; i < 1000; i++) {
      _write(fw, head, i);
      check(last.read() == 6, 'avoidable value');
    }
    check(
      computes == 1 && effects == 1,
      'avoidable propagation escaped cutoff',
    );
  };
}

Workload broad(ReactiveAdapter fw) {
  final head = fw.signal(0);
  final observed = List<int>.filled(50, 0);
  final leaves = List.generate(50, (index) {
    final current = fw.computed(() => head.read() + index);
    final leaf = fw.computed(() => current.read() + 1);
    fw.effect(() {
      observed[index] = leaf.read();
    });
    return leaf;
  });
  return () {
    _write(fw, head, 1);
    for (var i = 0; i < 50; i++) {
      _write(fw, head, i);
      check(leaves.last.read() == i + 50, 'broad value');
    }
    for (var index = 0; index < observed.length; index++) {
      check(observed[index] == 50 + index, 'broad effect value');
    }
  };
}

Readable<int> chain(ReactiveAdapter fw, int depth, int Function() source) {
  var previous = source;
  for (var i = 0; i < depth; i++) {
    final read = previous;
    previous = fw.computed(() => read() + 1).read;
  }
  return Readable(previous);
}

Workload deep(ReactiveAdapter fw) {
  final head = fw.signal(0);
  final tail = chain(fw, 50, head.read);
  var observed = 0;
  fw.effect(() {
    observed = tail.read();
  });
  return () {
    _write(fw, head, 1);
    for (var i = 0; i < 50; i++) {
      _write(fw, head, i);
      check(tail.read() == i + 50 && observed == i + 50, 'deep value');
    }
  };
}

Workload diamond(ReactiveAdapter fw) {
  final head = fw.signal(0);
  final arms = List.generate(5, (_) => fw.computed(() => head.read() + 1));
  final total = fw.computed(() => arms.fold(0, (sum, arm) => sum + arm.read()));
  var observed = 0;
  fw.effect(() {
    observed = total.read();
  });
  return () {
    _write(fw, head, 1);
    check(total.read() == 10, 'diamond setup');
    for (var i = 0; i < 500; i++) {
      _write(fw, head, i);
      check(
        total.read() == (i + 1) * 5 && observed == (i + 1) * 5,
        'diamond value',
      );
    }
  };
}

Workload mux(ReactiveAdapter fw) {
  final heads = List.generate(100, (_) => fw.signal(0));
  final all = fw.computed(() => heads.map((head) => head.read()).toList());
  final leaves = List.generate(heads.length, (index) {
    final split = fw.computed(() => all.read()[index]);
    return fw.computed(() => split.read() + 1);
  });
  final observed = List<int>.filled(leaves.length, 0);
  for (var index = 0; index < leaves.length; index++) {
    fw.effect(() {
      observed[index] = leaves[index].read();
    });
  }
  return () {
    for (final multiplier in [1, 2]) {
      for (var i = 0; i < 10; i++) {
        final value = i * multiplier;
        _write(fw, heads[i], value);
        check(
          leaves[i].read() == value + 1 && observed[i] == value + 1,
          'mux value',
        );
      }
    }
  };
}

Workload repeated(ReactiveAdapter fw) {
  final head = fw.signal(0);
  final total = fw.computed(() {
    var sum = 0;
    for (var i = 0; i < 30; i++) {
      sum += head.read();
    }
    return sum;
  });
  return _observeWrites(fw, head, total, (i) => i * 30);
}

Workload triangle(ReactiveAdapter fw) {
  final head = fw.signal(0);
  var read = head.read;
  final prefix = <int Function()>[];
  for (var i = 0; i < 10; i++) {
    final previous = read;
    prefix.add(previous);
    read = fw.computed(() => previous() + 1).read;
  }
  final total = fw.computed(() => prefix.fold(0, (sum, read) => sum + read()));
  return _observeWrites(fw, head, total, (i) => 45 + i * 10);
}

Workload unstable(ReactiveAdapter fw) {
  final head = fw.signal(0);
  final doubled = fw.computed(() => head.read() * 2);
  final negated = fw.computed(() => -head.read());
  final value = fw.computed(() {
    var sum = 0;
    for (var i = 0; i < 20; i++) {
      sum += head.read().isOdd ? doubled.read() : negated.read();
    }
    return sum;
  });
  return _observeWrites(fw, head, value, (i) => i * (i.isOdd ? 40 : -20));
}

Workload _observeWrites(
  ReactiveAdapter fw,
  Writable<int> head,
  Readable<int> tail,
  int Function(int) expected,
) {
  var observed = 0;
  fw.effect(() {
    observed = tail.read();
  });
  void verify(int i) {
    final value = expected(i);
    check(
      tail.read() == value && observed == value,
      'propagation value on write $i',
    );
  }

  return () {
    _write(fw, head, 1);
    verify(1);
    for (var i = 0; i < 100; i++) {
      _write(fw, head, i);
      verify(i);
    }
  };
}
