import 'dart:async';
import 'dart:io';

import 'package:rill/rill.dart';
import 'package:rill/wire.dart';
import 'package:test/test.dart';
import 'package:feed_store/store.dart';

final class FakeBackend implements Backend {
  final snapshots = <Completer<Json>>[];
  final polls = <Completer<Json>>[];
  final reports = <Completer<int>>[];
  final pairs = <Completer<String>>[];
  final starts = <Completer<Json>>[];
  final actions = <Completer<void>>[];
  final requests = <(int, bool)>[];
  bool closed = false;

  Future<T> _request<T>(List<Completer<T>> calls) {
    final pending = Completer<T>();
    calls.add(pending);
    return pending.future;
  }

  @override
  Future<Json> snapshot() => _request(snapshots);
  @override
  Future<Json> tick({required int since, required bool withDetails}) {
    requests.add((since, withDetails));
    return _request(polls);
  }

  @override
  Future<int> report() => _request(reports);
  @override
  Future<String> pair() => _request(pairs);
  @override
  Future<Json> startSweep() => _request(starts);
  @override
  void close() => closed = true;
  Future<void> action() => _request(actions);
}

Json sweep(int id, {bool ended = false}) => {'id': id, 'ended': ended};
Json snapshot(String label) => {
  'groups': ['group-$label'],
  'nodes': [label],
};

Future<void> drain() => Future<void>.delayed(Duration.zero);

void feed(Wire<Object?> wire, Object? json) =>
    transact((tx) => wire.stage(tx, json));

void main() {
  late FeedStore store;
  late FakeBackend first;
  late List<String> notices;
  setUp(() {
    store = FeedStore();
    first = FakeBackend();
    store.attach(first);
    notices = [];
    addTearDown(store.dispose);
    addTearDown(store.notices.listen(notices.add));
  });

  test('old end cannot overwrite a newer running sweep', () async {
    feed(store.sweepWire, sweep(1));
    final finish = store.endSweep(sweep(1, ended: true));
    feed(store.sweepWire, sweep(2));
    first.snapshots.single.complete(snapshot('old'));
    await finish;
    expect(store.sweep.value!.id, 2);
    expect(store.nodes.value, isEmpty);
  });

  test('an ended round can land when the running round was missed', () async {
    feed(store.sweepWire, sweep(1, ended: true));
    final end = store.endSweep(sweep(2, ended: true));
    first.snapshots.single.complete(snapshot('two'));
    await end;
    expect(store.sweep.value!.id, 2);
    expect(store.nodes.value, ['two']);
  });

  test('same round joins one snapshot request', () async {
    final a = store.endSweep(sweep(1, ended: true));
    final b = store.endSweep(sweep(1, ended: true));
    expect(first.snapshots, hasLength(1));
    first.snapshots.single.complete(snapshot('one'));
    await Future.wait([a, b]);
    expect(store.sweep.value!.ended, true);
  });

  for (final oldFirst in [false, true]) {
    test(
      'different round supersedes old end (old answers first=$oldFirst)',
      () async {
        final early = store.endSweep(sweep(1, ended: true));
        final late = store.endSweep(sweep(2, ended: true));
        expect(first.snapshots, hasLength(2));
        final order = oldFirst ? [0, 1] : [1, 0];
        for (final i in order) {
          first.snapshots[i].complete(snapshot(i == 0 ? 'old' : 'new'));
          await drain();
        }
        await Future.wait([early, late]);
        expect(store.sweep.value!.id, 2);
        expect(store.nodes.value, ['new']);
      },
    );
  }

  test('session replacement revokes old ended reply', () async {
    final pending = store.endSweep(sweep(1, ended: true));
    final second = FakeBackend();
    store.attach(second);
    expect(first.closed, true);
    first.snapshots.single.complete(snapshot('retired'));
    await pending;
    await drain();
    expect(store.sweep.value, null);
    expect(store.nodes.value, isEmpty);
  });

  test('failed snapshot request leaves sweep eligible', () async {
    final end = store.endSweep(sweep(1, ended: true));
    first.snapshots.single.completeError(StateError('snapshot unavailable'));
    await end;
    expect(store.sweep.value!.ended, isTrue);
    expect(store.nodes.value, isEmpty);
  });

  test(
    'bad snapshot rolls back its groups and nodes but keeps sweep',
    () async {
      feed(store.groupsWire, ['group-old']);
      feed(store.nodesWire, ['old']);
      final end = store.endSweep(sweep(1, ended: true));
      first.snapshots.single.complete({
        'groups': ['new group'],
        'nodes': 'bad',
      });
      await end;
      expect(store.sweep.value!.ended, true);
      expect(store.groups.value, ['group-old']);
      expect(store.nodes.value, ['old']);
    },
  );

  test(
    'bad sweep drops prepared snapshot and reports the round once',
    () async {
      final broken = store.endSweep({'id': 1, 'ended': 'bad'});
      first.snapshots.single.complete(snapshot('replay'));
      await broken;
      await store.endSweep({'id': 1, 'ended': 'bad'});
      expect((first.snapshots.length, notices.length), (1, 1));
      expect(store.sweep.value, null);
      expect(store.nodes.value, isEmpty);
      final next = store.endSweep(sweep(2, ended: true));
      first.snapshots[1].complete(snapshot('replay'));
      await next;
      expect(store.nodes.value, ['replay']);
      expect(store.sweep.value!.id, 2);
    },
  );

  test(
    'newer snapshot writer only conflicts with the optional snapshot group',
    () async {
      final end = store.endSweep(sweep(1, ended: true));
      feed(store.nodesWire, ['newer']);
      first.snapshots.single.complete(snapshot('stale'));
      await end;
      expect(store.nodes.value, ['newer']);
      expect(store.groups.value, isEmpty);
      expect(store.sweep.value!.ended, true);
    },
  );

  test('batch ABA invalidates a sweep end started during the batch', () async {
    final original = Sweep(1);
    late Future<void> end;
    batch(() {
      transact((tx) => store.sweepWire.set(tx, original));
      end = store.endSweep(sweep(1, ended: true));
      transact((tx) => store.sweepWire.set(tx, const Sweep(2)));
      transact((tx) => store.sweepWire.set(tx, original));
    });
    first.snapshots.single.complete(snapshot('stale'));
    await end;
    expect(store.sweep.value, same(original));
    expect(store.nodes.value, isEmpty);
  });

  for (final tickFirst in [false, true]) {
    test(
      'first sweep receipt wins and poll still publishes cursor (tick first=$tickFirst)',
      () async {
        final poll = store.poll();
        final start = store.sweepAll();
        await store.sweepAll();
        expect(first.starts, hasLength(1));
        expect(store.busy, false);
        final reply = {'cursor': 17, 'sweep': sweep(1)};
        if (tickFirst) {
          first.polls.single.complete(reply);
          await poll;
          first.starts.single.complete(sweep(2));
        } else {
          first.starts.single.complete(sweep(2));
          await start;
          first.polls.single.complete(reply);
        }
        await Future.wait([poll, start]);
        expect(store.sweep.value!.id, tickFirst ? 1 : 2);
        expect(store.cursor.value, 17);
      },
    );
  }

  test(
    'old polling failure does not count or release the new session poll',
    () async {
      final old = store.poll();
      final second = FakeBackend();
      store.attach(second);
      final current = store.poll();
      first.polls.single.completeError(StateError('retired'));
      await old;
      await drain();
      expect(store.failures, 0);
      await store.poll();
      expect(second.polls, hasLength(1));
      second.polls.single.complete({'cursor': 1});
      await current;
      expect(store.cursor.value, 1);
    },
  );

  test(
    'five poll failures raise trouble and a successful poll clears it',
    () async {
      for (var i = 0; i < 5; i++) {
        final pending = store.poll();
        first.polls.last.completeError(StateError('offline'));
        await pending;
      }
      expect(store.failures, 5);
      expect(store.trouble.value, contains('offline'));
      final success = store.poll();
      first.polls.last.complete({'cursor': 3});
      await success;
      expect(store.failures, 0);
      expect(store.trouble.value, isNull);
    },
  );

  test('overlapping commands remain busy until both finish and report current failure', () async {
    final a = store.act((c) => (c as FakeBackend).action());
    final b = store.act((c) => (c as FakeBackend).action());
    expect(store.busy, true);
    first.actions.first.complete();
    expect(await a, true);
    expect(store.busy, true);
    first.actions.last.completeError(StateError('current'));
    expect(await b, false);
    expect(store.busy, false);
    expect(notices.single, contains('current'));
    expect(store.refreshRequests, 2);
  });

  test(
    'replacement suppresses old outcomes, notices, report and pairing results',
    () async {
      final success = store.act((c) => (c as FakeBackend).action());
      final failure = store.act((c) => (c as FakeBackend).action());
      final report = store.report();
      final pair = store.pair();
      final second = FakeBackend();
      store.attach(second);
      expect(first.closed, true);
      expect(store.busy, false);
      final currentReport = store.report();
      final currentPair = store.pair();
      first.actions.first.complete();
      first.actions.last.completeError(StateError('old'));
      first.reports.single.complete(1);
      first.pairs.single.complete('old');
      expect(await success, false);
      expect(await failure, false);
      expect(await report, null);
      expect(await pair, null);
      expect(notices, isEmpty);
      expect(store.busy, true);
      second.reports.single.complete(2);
      second.pairs.single.complete('current');
      expect(await currentReport, 2);
      expect(await currentPair, 'current');
      expect(store.busy, false);
    },
  );

  test(
    'scope replacement can precede delivery of an already settled action',
    () async {
      final pending = store.report();
      first.reports.single.complete(1);
      scheduleMicrotask(() => store.attach(FakeBackend()));
      expect(await pending, isNull);
    },
  );

  test('a missing sweep round is reported once', () async {
    final invalid = {'ended': true};
    final firstAttempt = store.endSweep(invalid);
    first.snapshots.single.complete(snapshot('invalid'));
    await firstAttempt;
    await store.endSweep(invalid);
    expect(first.snapshots, hasLength(1));
    expect(notices, hasLength(1));
  });

  test('busy readers follow the replacement scope', () async {
    final observed = <bool>[];
    addTearDown(
      effect(() => store.busy, (value, _, _) {
        observed.add(value);
      }),
    );
    final old = store.act((c) => (c as FakeBackend).action());
    final second = FakeBackend();
    store.attach(second);
    final current = store.act((c) => (c as FakeBackend).action());
    second.actions.single.complete();
    expect(await current, true);
    expect(await old, false);
    expect(observed, [false, true, false, true, false]);
  });
  for (final ended in [false, true]) {
    for (final pollFirst in [false, true]) {
      test(
        'poll/sweepAll preserve the winning sweep ($ended, $pollFirst)',
        () async {
          final poll = store.poll();
          final start = store.sweepAll();
          if (!pollFirst) {
            first.starts.single.complete(sweep(2));
            await start;
          }
          first.polls.single.complete({
            'cursor': 42,
            'sweep': sweep(1, ended: ended),
          });
          await poll;
          if (pollFirst && ended) {
            expect(first.snapshots, hasLength(1));
            first.snapshots.single.complete(snapshot('first'));
            await drain();
          } else {
            expect(first.snapshots, isEmpty);
          }
          if (pollFirst) {
            first.starts.single.complete(sweep(2));
            await start;
          }
          expect(store.cursor.peek(), 42);
          expect(store.sweep.peek()!.id, pollFirst ? 1 : 2);
          expect(store.sweep.peek()!.ended, pollFirst && ended);
        },
      );
    }
  }

  test(
    'identical ended wire cannot authorize a snapshot after sweep ABA',
    () async {
      final ended = sweep(1, ended: true);
      final end = store.endSweep(ended);
      feed(store.sweepWire, sweep(2));
      feed(store.sweepWire, ended);
      first.snapshots.single.complete(snapshot('obsolete'));
      await end;
      expect(store.nodes.peek(), isEmpty);
    },
  );

  test(
    'attach resets the prior backend cursor, snapshots and ledgers',
    () async {
      final poll = store.poll();
      first.polls.single.complete({'cursor': 550, 'sweep': sweep(1)});
      await poll;
      feed(store.groupsWire, ['old']);
      feed(store.nodesWire, ['old']);
      final second = FakeBackend();
      store.attach(second);
      expect(store.sweep.peek(), isNull);
      expect(store.nodes.peek(), isEmpty);
      expect(store.groups.peek(), isEmpty);
      final next = store.poll();
      expect(second.requests.single.$1, 0);
      second.polls.single.complete({'cursor': 1, 'sweep': sweep(1)});
      await next;
      expect(store.sweep.peek()!.id, 1);
    },
  );

  test('two polls share the same in-flight end request', () async {
    final ended = sweep(1, ended: true);
    for (final cursor in [1, 2]) {
      final poll = store.poll();
      first.polls.last.complete({'cursor': cursor, 'sweep': ended});
      await poll;
    }
    expect(first.snapshots, hasLength(1));
    first.snapshots.single.complete(snapshot('once'));
    await drain();
    expect(store.nodes.peek(), ['once']);
  });

  test('completed rounds deduplicate, refused rounds can retry', () async {
    final ended = sweep(1, ended: true);
    final lost = store.endSweep(ended);
    feed(store.sweepWire, sweep(2));
    first.snapshots.single.complete(snapshot('obsolete'));
    await lost;
    final retry = store.endSweep(ended);
    expect(first.snapshots, hasLength(2));
    first.snapshots.last.complete(snapshot('accepted'));
    await retry;
    final poll = store.poll();
    first.polls.single.complete({'cursor': 1, 'sweep': ended});
    await poll;
    expect(first.snapshots, hasLength(2));
    expect(store.nodes.peek(), ['accepted']);
  });

  test('the store has no hand checks, parent, overwrite or ignore', () {
    final source = File('lib/store.dart').readAsStringSync();
    for (final banned in [
      'scope.disposed',
      'parent:',
      'overwrite',
      'ignore:',
    ]) {
      expect(source, isNot(contains(banned)), reason: banned);
    }
  });
}
