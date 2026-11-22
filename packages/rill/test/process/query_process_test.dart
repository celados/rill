@Tags(['process'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// These cases need a process: the cycle cases compile AOT and must not starve their
// event loop, the others force GC through the VM service or allocation
// pressure.

/// Runs [executable] and decodes its one JSON line, killing it after
/// [limit] (a hang fails fast; a known slow case passes a longer limit).
Future<Map<String, Object?>> runJson(
  String executable,
  List<String> args, {
  Duration limit = const Duration(seconds: 10),
}) async {
  final process = await Process.start(executable, args);
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  final code = await process.exitCode.timeout(
    limit,
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  final text = await out;
  expect(code, 0, reason: 'exit $code\n$text${await err}');
  final line = text.split('\n').lastWhere((l) => l.startsWith('{'));
  return jsonDecode(line) as Map<String, Object?>;
}

void main() {
  const expected = {
    'before': 'AsyncData<int>(0)',
    'cycled': true,
    'cycledLoads': 2,
    'recovered': 'AsyncData<int>(0)',
    'loads': 3,
  };
  const cycle = 'test/process/fixtures/query_cycle.dart';

  test('cycle_formed_after_success_lands_once_in_debug', () async {
    expect(
      await runJson(Platform.resolvedExecutable, ['--enable-asserts', cycle]),
      expected,
    );
  });

  test('cycle_formed_after_success_lands_once_in_aot', () async {
    final dir = await Directory.systemTemp.createTemp('rill-cycle-');
    addTearDown(() => dir.delete(recursive: true));
    final exe = '${dir.path}/cycle';
    final build = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '-o',
      exe,
      cycle,
    ]);
    expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
    expect(await runJson(exe, const []), expected);
  });

  const landing = 'test/process/fixtures/query_independent_landing.dart';
  const untied = {
    'before': ['cycle', 'cycle'],
    'after': ['cycle', '7'],
    'cold': ['7', '7'],
  };

  test('independent_landing_recovers_once_untied_in_debug', () async {
    expect(
      await runJson(Platform.resolvedExecutable, ['--enable-asserts', landing]),
      untied,
    );
  });

  test('independent_landing_recovers_once_untied_in_aot', () async {
    final dir = await Directory.systemTemp.createTemp('rill-landing-');
    addTearDown(() => dir.delete(recursive: true));
    final exe = '${dir.path}/landing';
    final build = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '-o',
      exe,
      landing,
    ]);
    expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
    expect(await runJson(exe, const []), untied);
  });

  const twoCycles = 'test/process/fixtures/query_two_cycles.dart';
  const twoCyclesExpected = {
    // Two launches each to fail, one more each to recover: bounded.
    'cycles': [2, 2, 3, 3],
    // Hot after the event (b recovers, a and d keep the error: no L2), then
    // read cold once unobserved.
    'diamond': ['cycle', '7', 'cycle', '7', '7', '14'],
  };

  test('cycles_and_reentry_in_debug', () async {
    expect(
      await runJson(Platform.resolvedExecutable, [
        '--enable-asserts',
        twoCycles,
      ]),
      twoCyclesExpected,
    );
  });

  test('cycles_and_reentry_in_aot', () async {
    final dir = await Directory.systemTemp.createTemp('rill-twoCycles-');
    addTearDown(() => dir.delete(recursive: true));
    final exe = '${dir.path}/twoCycles';
    final build = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '-o',
      exe,
      twoCycles,
    ]);
    expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
    expect(await runJson(exe, const []), twoCyclesExpected);
  });

  const cycleRecovery = 'test/process/fixtures/query_cycle_recovery.dart';
  const cycleRecoveryExpected = {
    'coldCycle': ['4', 'cycle', '4'],
    // Hot: b recovers, a keeps the error and never reruns (L0, no L2);
    // cold, both recover.
    'untied': ['cycle', '7', '7', '7'],
    'fanout': 120,
    // Stream events are asynchronous: the old install ends stale.
    'upstream': ['stale', 'AsyncData<int>(8)'],
    'latest': 'AsyncData<int>(3)',
    'upstreamOfACycle': 2,
  };

  test('cycles_rounds_and_installs_in_debug', () async {
    expect(
      await runJson(Platform.resolvedExecutable, [
        '--enable-asserts',
        cycleRecovery,
      ]),
      cycleRecoveryExpected,
    );
  });

  test('cycles_rounds_and_installs_in_aot', () async {
    final dir = await Directory.systemTemp.createTemp('rill-cycleRecovery-');
    addTearDown(() => dir.delete(recursive: true));
    final exe = '${dir.path}/cycleRecovery';
    final build = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '-o',
      exe,
      cycleRecovery,
    ]);
    expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
    expect(await runJson(exe, const []), cycleRecoveryExpected);
  });

  const ordering = 'test/process/fixtures/query_ordering.dart';
  const orderingExpected = {
    'coldSample': {'threw': null, 'samplesAfterUnmount': 0, 'active': 0},
    // Stream events are asynchronous: eventual results.
    'launch': [
      'factory 1',
      'listen 1',
      'cancel 1',
      'source 2',
      '…',
      'factory 2',
      'listen 2',
      'cancel 2',
    ],
    'wait': ['ok', 'resume 2:2', 'down AsyncData<int>(2)'],
    'forward': 'ok 51/51 starts=0',
    'reverse': 'ok 51/51 starts=0',
    'reverse120': 'ok 120/120 starts=0',
    // The L1 boundary as specified: b inherits c's held cycle while c is hot.
    'partial': {
      'hot': ['10', 'cycle', 'cycle'],
      'readers': 0,
      'cold': 'cycle',
      'remount': 'cycle',
      'stillHot': 'cycle',
      'released': ['10', '11', '10'],
    },
  };

  test('asynchronous_events_converge_and_cold_cools_in_debug', () async {
    expect(
      await runJson(Platform.resolvedExecutable, [
        '--enable-asserts',
        ordering,
      ]),
      orderingExpected,
    );
  });

  test('asynchronous_events_converge_and_cold_cools_in_aot', () async {
    final dir = await Directory.systemTemp.createTemp('rill-ordering-');
    addTearDown(() => dir.delete(recursive: true));
    final exe = '${dir.path}/ordering';
    final build = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '-o',
      exe,
      ordering,
    ]);
    expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
    expect(await runJson(exe, const []), orderingExpected);
    expect(await runJson(exe, const ['deep']), {
      'deep': 'ok 2000/2000 starts=0',
    });
  });

  const relaunch = 'test/process/fixtures/query_relaunch.dart';
  const relaunchExpected = {
    // Stream events are asynchronous: the fifth round's cases end
    // on their final values; no superseded round resumes with a new answer.
    'latest': [
      'D null', 'D.start 1', 'D 1', 'batch', 'B sends D=3', 'D 2', 'D 3', //
      'final AsyncData<int>(3)',
    ],
    'install': [
      'D null', 'D.start 1', 'D 1', 'batch', 'B sends A=2', 'D 2', //
      'D 2 stale', 'D.start 2', 'final AsyncData<int>(2, refreshing, stale)',
    ],
    'launch': [
      'D null', 'D.start 1', 'D 1', 'batch', 'D 1', 'D.start 1', //
      'B sends A=2', 'D 1 stale', 'D.start 2',
      'final AsyncData<int>(1, refreshing, stale)',
    ],
    'wait': [
      'start 1', 'B sends A=2', 'resume 1:1', 'start 2', 'resume 2:2', //
      'final AsyncData<int>(2)',
    ],
    'cascade': 'ok 300/300 runs=0',
    'leasePeek': {
      'flight': 0, 'streams': 0, //
      'events': ['opened 1', 'closed 1', 'cancelled 1'],
    },
    'leaseInvalidate': {
      'flight': 0, 'streams': 0, //
      'events': ['opened 1', 'closed 1', 'cancelled 1'],
    },
    'leaseAfterEnd': {
      'threw': 'RILL_READ_AFTER_AWAIT', 'opened': 0, 'flight': 0, //
      'streams': 0,
    },
    // R4c: a cold read that finds a new question cancels; without it the
    // retained round lands stale.
    'retainRead': {
      'before': [0, 0], 'after': [0, 0], 'state': 'AsyncLoading<int>()', //
      'events': ['start 1', 'cancel 1'],
    },
    'retainPlain': {
      'before': [1, 1], 'after': [0, 0], //
      'state': 'AsyncData<int>(11, refreshing, stale)', 'events': ['start 1'],
    },
  };

  test('synchronous_sends_converge_in_debug', () async {
    expect(
      await runJson(Platform.resolvedExecutable, [
        '--enable-asserts',
        relaunch,
      ]),
      relaunchExpected,
    );
    // The JIT stack overflowed at about 1,400 levels in the fifth round.
    expect(
      await runJson(Platform.resolvedExecutable, [
        '--enable-asserts',
        relaunch,
        'cascade2200',
      ]),
      {'cascade2200': 'ok 2200/2200 runs=0'},
    );
  });

  test('synchronous_sends_converge_in_aot', () async {
    final dir = await Directory.systemTemp.createTemp('rill-relaunch-');
    addTearDown(() => dir.delete(recursive: true));
    final exe = '${dir.path}/relaunch';
    final build = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '-o',
      exe,
      relaunch,
    ]);
    expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
    expect(await runJson(exe, const []), relaunchExpected);
    // Deep chains cost quadratic time (a known limit, v0.5.x): 5,000 levels
    // take about 6 s on an M1 Pro and more on a CI runner.
    expect(
      await runJson(exe, const [
        'cascade2200',
        'cascade5000',
      ], limit: const Duration(seconds: 60)),
      {
        'cascade2200': 'ok 2200/2200 runs=0',
        'cascade5000': 'ok 5000/5000 runs=0',
      },
    );
  });

  test('cooled_query_is_not_held_by_a_pending_future', () async {
    expect(
      await runJson(Platform.resolvedExecutable, [
        '--enable-vm-service=0',
        '--disable-service-auth-codes',
        'test/process/fixtures/query_gc.dart',
      ]),
      {'cooledAlive': false, 'settled': 'AsyncData<int>(7)'},
    );
  });

  const reconcile = 'test/process/fixtures/query_reconcile.dart';
  const reconcileExpected = {
    'fan99': 'returned 99/99',
    'fan180': 'returned 180/180',
    'gc': {'relinked': 0, 'control': 0},
    'feedback': 'RILL_INFINITE_LOOP within 100',
  };

  test('no_scheduler_rounds_feedback_or_relink_table_in_debug', () async {
    expect(
      await runJson(Platform.resolvedExecutable, [
        '--enable-asserts',
        '--enable-vm-service=0',
        '--disable-service-auth-codes',
        reconcile,
        'service',
      ]),
      reconcileExpected,
    );
  });

  test('no_scheduler_rounds_feedback_or_relink_table_in_aot', () async {
    final dir = await Directory.systemTemp.createTemp('rill-reconcile-');
    addTearDown(() => dir.delete(recursive: true));
    final exe = '${dir.path}/reconcile';
    final build = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '-o',
      exe,
      reconcile,
    ]);
    expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
    expect(await runJson(exe, const []), reconcileExpected);
  });

  const accept = 'test/process/fixtures/query_accept.dart';
  const cacheExpected = {
    'cache': {
      'cooled': {'stored': 0, 'control': 0, 'waited': 0, 'active': 0},
      'coldReadLoading': 384,
    },
  };
  const slotExpected = {
    'slot': {
      'disposed': {'tasks': 0, 'pages': 0, 'scopes': 0, 'taskObjects': 0},
      'completed': {'tasks': 0, 'pages': 0, 'scopes': 0, 'taskObjects': 0},
      'zoneErrors': 0,
    },
  };

  Future<String> compileAccept() async {
    final dir = await Directory.systemTemp.createTemp('rill-accept-');
    addTearDown(() => dir.delete(recursive: true));
    final exe = '${dir.path}/accept';
    final build = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '-o',
      exe,
      accept,
    ]);
    expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
    return exe;
  }

  List<String> debugAccept(String mode) => [
    '--enable-asserts',
    '--enable-vm-service=0',
    '--disable-service-auth-codes',
    accept,
    mode,
    'service',
  ];

  test('cooled_query_releases_its_answer_in_debug', () async {
    expect(
      await runJson(Platform.resolvedExecutable, debugAccept('cache')),
      cacheExpected,
    );
  });

  test('cooled_query_releases_its_answer_in_aot', () async {
    expect(
      await runJson(await compileAccept(), const ['cache']),
      cacheExpected,
    );
  });

  test('disposed_scope_releases_a_task_on_a_pending_future_in_debug', () async {
    expect(
      await runJson(Platform.resolvedExecutable, debugAccept('slot')),
      slotExpected,
    );
  });

  test('disposed_scope_releases_a_task_on_a_pending_future_in_aot', () async {
    expect(await runJson(await compileAccept(), const ['slot']), slotExpected);
  });

  const ownersExpected = {
    'owners': {
      'pending': {'scopes': 0, 'tasks': 0},
      'settled': {'scopes': 0, 'tasks': 0},
      'zoneErrors': 0,
    },
  };

  test('pending_future_holds_no_disposed_scope_or_task_in_debug', () async {
    expect(
      await runJson(Platform.resolvedExecutable, debugAccept('owners')),
      ownersExpected,
    );
  });

  test('pending_future_holds_no_disposed_scope_or_task_in_aot', () async {
    expect(
      await runJson(await compileAccept(), const ['owners']),
      ownersExpected,
    );
  });
}
