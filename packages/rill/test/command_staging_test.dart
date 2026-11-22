import 'dart:async';

import 'package:rill/rill.dart';
import 'package:test/test.dart';

Future<void> drain() => Future<void>.delayed(Duration.zero);

void main() {
  for (final invalidEvent in [false, true]) {
    test('rejects widened staging types (event=$invalidEvent)', () async {
      final owner = Scope();
      addTearDown(owner.dispose);
      final left = signal(0), right = signal(0);
      final received = <int>[], observed = <int>[], errors = <Object>[];
      final bus = Events<int>();
      addTearDown(bus.listen(received.add));
      addTearDown(
        effect(() => left.value, (value, _, _) {
          observed.add(value);
        }),
      );
      late Outcome<bool> result;
      await runZonedGuarded(() async {
        result = await owner.slot().run(
          (t) async => t.publish((p) {
            p.set(left, 1);
            if (invalidEvent) {
              p.emit(bus, 1.5);
              p.emit(bus, 2);
            } else {
              p.set(right, 1.5);
            }
          }),
        );
        await drain();
      }, (error, _) => errors.add(error));
      expect(
        result,
        isA<Failed<bool>>().having((e) => e.error, 'error', isA<TypeError>()),
      );
      expect((left.peek(), right.peek()), (0, 0));
      expect(observed, [0]);
      expect(received, isEmpty);
      expect(errors, isEmpty);
    });
  }

  test('queued RPC failure stays in the admission error zone', () async {
    final owner = Scope();
    addTearDown(owner.dispose);
    final queue = owner.slot(onBusy: OnBusy.queue);
    final gate = Completer<int>(), order = <String>[], errors = <Object>[];
    final first = queue.run((_) => gate.future);
    late Completer<int> rpc;
    late Future<Outcome<int>> second;
    runZonedGuarded(() {
      rpc = Completer<int>();
      second = queue.run((_) {
        order.add('second');
        return rpc.future;
      });
    }, (error, _) => errors.add(error));
    final third = queue.run((_) async {
      order.add('third');
      return 3;
    });
    gate.complete(1);
    await first;
    await drain();
    final failure = StateError('rpc failed');
    rpc.completeError(failure);
    await drain();
    expect(errors, isEmpty);
    expect(order, ['second', 'third']);
    expect(
      await second,
      isA<Failed<int>>().having((e) => e.error, 'error', same(failure)),
    );
    expect((await third as Done<int>).value, 3);
    expect(queue.busy.peek(), isFalse);
  });

  test('matching keys of distinct result types obey the slot policy', () async {
    final owner = Scope();
    addTearDown(owner.dispose);
    final slot = owner.slot(onBusy: OnBusy.parallel);
    final gate = Completer<int>();
    final first = slot.run<int>((_) => gate.future, key: 'same');
    final joined = slot.run<int>((_) async => -1, key: 'same');
    final second = slot.run<String>((_) async => 'distinct', key: 'same');
    expect(joined, same(first));
    expect((await second as Done<String>).value, 'distinct');
    gate.complete(1);
    expect((await first as Done<int>).value, 1);
  });
}
