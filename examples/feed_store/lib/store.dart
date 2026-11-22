import 'dart:async';

import 'package:rill/rill.dart';
import 'package:rill/wire.dart';

typedef Json = Map<String, Object?>;

abstract interface class Backend {
  Future<Json> snapshot();
  Future<Json> tick({required int since, required bool withDetails});
  Future<int> report();
  Future<String> pair();
  Future<Json> startSweep();
  void close();
}

final class Sweep {
  const Sweep(this.id, {this.ended = false});
  factory Sweep.fromWire(Object? wire) {
    if (wire case {'id': final int id, 'ended': final bool ended}) {
      return Sweep(id, ended: ended);
    }
    throw const FormatException('sweep');
  }
  final int id;
  final bool ended;
}

final class _Session {
  _Session(this.scope, this.client)
    : ends = scope.slot(),
      actions = scope.slot(onBusy: OnBusy.parallel),
      poll = scope.slot(onBusy: OnBusy.skip),
      starts = scope.slot(onBusy: OnBusy.skip);
  final Scope scope;

  /// The session's dependency is a field: its type is the contract.
  final Backend client;
  final Slot ends, actions, poll, starts;
  int ticks = 0, failures = 0;
  Object? badRound = const Object();
}

/// `t.publish` or `transact`: the same staging code serves both.
typedef Commit = bool Function(void Function(Tx tx) stage);

final class FeedStore {
  final _root = Scope(name: 'feed');
  final _session = signal<_Session?>(null);

  /// Wire-fed fields: the store stages them; pages read [sweep], [groups]
  /// and [nodes]. Public only so the scenarios can feed them directly.
  final sweepWire = Wire<Sweep?>(null, Sweep.fromWire, name: 'sweep');
  final groupsWire = Wire<List<String>>(const [], _names, name: 'groups');
  final nodesWire = Wire<List<String>>(const [], _names, name: 'nodes');
  Readable<Sweep?> get sweep => sweepWire.readable;
  Readable<List<String>> get groups => groupsWire.readable;
  Readable<List<String>> get nodes => nodesWire.readable;
  late final sweeping = computed(() => sweep.value?.ended != true);
  final cursor = signal(0);
  final trouble = signal<String?>(null);
  final notices = Events<String>();

  bool get busy => _session.value?.actions.busy.value ?? false;
  int get failures => _session.peek()?.failures ?? 0;
  int refreshRequests = 0;

  void attach(Backend backend) => batch(() {
    _session.peek()?.scope.dispose();
    cursor.value = 0;
    trouble.value = null;
    // A wire reset forgets its ledger with the value: one commit.
    transact((tx) {
      sweepWire.set(tx, null);
      groupsWire.set(tx, const []);
      nodesWire.set(tx, const []);
    });
    final scope = _root.child(name: 'session');
    scope.onDispose(backend.close);
    _session.value = _Session(scope, backend);
  });

  void dispose() => batch(() {
    _root.dispose();
    _session.value = null;
  });

  Future<void> endSweep(Json next) => _endSweep(next);
  Future<void> poll() => _tick();
  Future<bool> act(Future<void> Function(Backend) action) => _act(action);
  Future<int?> report() async =>
      switch (await _runAction((backend) => backend.report())) {
        Done(:final value) => value,
        _ => null,
      };
  Future<String?> pair() async =>
      switch (await _runAction((backend) => backend.pair())) {
        Done(:final value) => value,
        _ => null,
      };

  /// [since] is the sweep the caller saw before its own request (the poll
  /// hands its condition over); a direct call takes it now.
  Future<void> _endSweep(Json next, [Unchanged? since]) async {
    final session = _session.peek(), round = next['id'];
    if (session == null || session.badRound == round) return;
    final asked = since ?? Unchanged(sweep);
    await session.ends.run((t) async {
      // Admission: the sweep moved on since; do not fetch a snapshot for it.
      if (!asked.holds) return;
      final shown = [Unchanged(groups), Unchanged(nodes)];
      final snapshot = await session.client.snapshot().orNull;
      try {
        t.publish((tx) {
          tx.require(asked);
          if (snapshot != null) {
            try {
              // A newer snapshot writer or a bad snapshot drops only the snapshot part.
              tx.part(() {
                shown.forEach(tx.require);
                _stageSnapshot(tx, snapshot);
              });
            } on Object {
              // The snapshot stays as it was; the sweep still lands.
            }
          }
          sweepWire.stage(tx, next); // a bad sweep fails the whole commit
        });
      } on FormatException catch (error) {
        session.badRound = round;
        notices.emit('sweep result unreadable: $error');
      }
    }, key: round);
  }

  Future<Outcome<T>?> _runAction<T>(Future<T> Function(Backend) action) async {
    final session = _session.peek();
    if (session == null) return null;
    // Decided at delivery: a session closed before this caller resumes
    // delivers Stale(ownerDisposed), never Done.
    final outcome = await session.actions.run((t) => action(session.client));
    _refreshCurrent();
    if (outcome case Failed(:final error)) notices.emit('$error');
    return outcome;
  }

  Future<bool> _act(Future<void> Function(Backend) action) async =>
      await _runAction(action) is Done<void>;

  Future<void> _tick() async {
    final session = _session.peek();
    if (session == null) return;
    await session.poll.run((t) async {
      // The reply's sweep part yields to a sweep installed while the request
      // was in flight; telemetry only needs the task alive.
      final sweepAsked = Unchanged(sweep);
      final Json tick;
      try {
        tick = await session.client.tick(
          since: cursor.peek(),
          withDetails: session.ticks % 5 == 0,
        );
      } on Object catch (error) {
        if (!t.alive) return;
        if (++session.failures == 5) {
          t.publish((tx) => tx.set(trouble, 'backend unreachable: $error'));
        }
        return;
      }
      if (_acceptTick(t.publish, tick, sweepAsked)) {
        session.ticks++;
        session.failures = 0;
      }
    });
  }

  bool _acceptTick(Commit commit, Json tick, Unchanged sweepAsked) => batch(() {
    final published = commit((tx) {
      tx.set(cursor, tick['cursor'] as int);
      tx.set(trouble, null);
    });
    if (!published) return false;
    if (tick['sweep'] case final Json wire
        when wire['ended'] == true && sweeping.peek()) {
      if (sweepAsked.holds) unawaited(_endSweep(wire, sweepAsked));
    } else if (tick['sweep'] case final Json wire when wire['ended'] == false) {
      commit((tx) {
        tx.require(sweepAsked);
        sweepWire.stage(tx, wire);
      });
    }
    return true;
  });

  Future<void> sweepAll() async {
    final session = _session.peek();
    await session?.starts.run((t) async {
      // The first sweep receipt wins: a poll that installed one meanwhile
      // keeps it.
      final asked = Unchanged(sweep);
      final reply = await session.client.startSweep();
      t.publish((tx) {
        tx.require(asked);
        sweepWire.stage(tx, reply);
      });
    });
  }

  void _refreshCurrent() {
    if (_session.peek() != null) refreshRequests++;
  }

  void _stageSnapshot(Tx tx, Json snapshot) {
    groupsWire.stage(tx, snapshot['groups']);
    nodesWire.stage(tx, snapshot['nodes']);
  }
}

List<String> _names(Object? wire) => List<String>.unmodifiable(wire as List);

extension<T> on Future<T> {
  Future<T?> get orNull async {
    try {
      return await this;
    } on Object {
      return null;
    }
  }
}
