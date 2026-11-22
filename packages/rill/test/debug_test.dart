import 'dart:async';
import 'dart:convert';

import 'package:rill/debug.dart';
import 'package:rill/internal.dart';
import 'package:rill/rill.dart';
import 'package:test/test.dart';

/// The line of the caller.
int here() {
  final frame = StackTrace.current.toString().split('\n')[1];
  return int.parse(RegExp(r':(\d+):\d+\)$').firstMatch(frame)![1]!);
}

String at(int line) => 'test/debug_test.dart:$line';

String? location(Object node) => RillDebug.describe(node)?.location?.toString();

Matcher _code(String code, [Object? message]) => isA<StateError>().having(
  (error) => error.message,
  'message',
  allOf(
    startsWith('$code: '),
    message is String ? endsWith(message) : message ?? anything,
  ),
);

// A user helper: the creation site is the helper, not rill.
Computed<int> doubledOf(Readable<int> source) =>
    computed(() => source.value * 2);
final helperLine = here() - 1;

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(RillDebug.clear);
  tearDown(() => diagnosticHook = null);

  group('names and creation sites', () {
    test('every node kind records the caller outside rill', () async {
      expect(RillDebug.enabled, isTrue);
      final (a, aLine) = (signal(0), here());
      final (b, bLine) = (computed(() => a.value), here());
      final (stop, eLine) = (effect(() => b.value, (_, _, _) {}), here());
      addTearDown(stop);
      final (scope, sLine) = (Scope(name: 'root'), here());
      addTearDown(scope.dispose);
      final (q, qLine) = (computedAsync((_) async => a.value), here());
      expect(location(a), at(aLine));
      expect(location(b), at(bLine));
      expect(location(scope), at(sLine));
      expect(location(q), at(qLine));
      final effectNode = RillDebug.why(stop).single;
      expect(effectNode.node.location.toString(), at(eLine));
      expect(effectNode.initial, isTrue);
      expect(RillDebug.describe(a)!.label, 'signal@${at(aLine)}');
      expect(RillDebug.describe(q)!.kind, 'asyncComputed');
    });

    test('creation through layers of rill code resolves to the user', () {
      final root = Scope();
      addTearDown(root.dispose);
      final (child, childLine) = (root.child(name: 'session'), here());
      final (slot, slotLine) = (child.slot(name: 'sync'), here());
      final (inner, innerLine) = (computed(() => 1), here());
      final (doubled, _) = (doubledOf(signal(1)), here());
      final (query, queryLine) = (
        computedAsync((_) async => 1, name: 'user'),
        here(),
      );
      expect(location(child), at(childLine));
      expect(location(slot), at(slotLine));
      expect(location(inner), at(innerLine));
      expect(location(doubled), at(helperLine));
      expect(location(query), at(queryLine - 1));
      // Internal nodes are named after the object that owns them.
      final graph = RillDebug.graph()['nodes']! as List<Object?>;
      final labels = graph.map((node) => (node! as Map)['label']).toSet();
      expect(
        labels,
        containsAll([
          'sync.busy',
          'user.question',
          'user.retry',
          'user.landed',
        ]),
      );
    });

    test('a slot task records the run call', () async {
      final scope = Scope(name: 'store');
      addTearDown(scope.dispose);
      final slot = scope.slot(name: 'sweep');
      final gate = Completer<void>();
      final (result, line) = (slot.run((_) => gate.future), here());
      final task = (RillDebug.active()['tasks']! as List).single as Map;
      expect(task['label'], 'sweep.task');
      expect(task['location'], at(line));
      expect((task['slot']! as Map)['label'], 'sweep');
      gate.complete();
      await result;
    });

    test('errors name unnamed nodes by their creation site', () {
      final (source, sourceLine) = (signal(0), here());
      final (bad, badLine) = (
        computed(() {
          source.value = 1;
          return 0;
        }),
        here() - 4,
      );
      expect(
        () => bad.value,
        throwsA(
          _code(
            'RILL_WRITE_IN_COMPUTATION',
            'Cannot write signal@${at(sourceLine)} during '
                'computed@${at(badLine)}.',
          ),
        ),
      );
      final named = signal(0, name: 'count');
      final namedLine = here() - 1;
      final reader = computed(() {
        named.value = 2;
        return 0;
      }, name: 'reader');
      expect(
        () => reader.value,
        throwsA(
          _code(
            'RILL_WRITE_IN_COMPUTATION',
            contains('count (signal at ${at(namedLine)})'),
          ),
        ),
      );

      late final Computed<int> cycle;
      cycle = computed(() => cycle.value);
      final cycleLine = here() - 1;
      expect(
        () => cycle.value,
        throwsA(_code('RILL_CYCLE', contains('computed@${at(cycleLine)}'))),
      );

      final (owner, ownerLine) = (Scope(), here());
      owner.dispose();
      expect(
        owner.child,
        throwsA(_code('RILL_DISPOSED', contains('scope@${at(ownerLine)}'))),
      );
    });

    test('diagnostic hooks receive the location for unnamed nodes', () async {
      final diagnostics = <(String, String?)>[];
      diagnosticHook = (code, name) => diagnostics.add((code, name));
      final (query, line) = (computedAsync((_) async => 1), here());
      query.value;
      await settle();
      expect(diagnostics, [
        ('RILL_COLD_QUERY_READ', 'asyncComputed@${at(line)}'),
      ]);
    });

    test('a caught reactive read is legal and silent', () {
      final diagnostics = <(String, String?)>[];
      diagnosticHook = (code, name) => diagnostics.add((code, name));
      final failing = computed<int>(() => throw StateError('x'));
      final fallback = computed(() {
        try {
          return failing.value;
        } on StateError {
          return 0;
        }
      });
      expect(fallback.value, 0);
      expect(diagnostics, isEmpty);
    });

    test('an infinite loop names the written node and the write site', () {
      final (ping, pingLine) = (signal(0), here());
      var writeLine = 0;
      final stop = effect(() => ping.value, (value, _, _) {
        writeLine = here() + 1;
        if (value > 0) ping.value = value + 1;
      });
      addTearDown(stop);
      expect(
        () => ping.value = 1,
        throwsA(
          _code(
            'RILL_INFINITE_LOOP',
            contains('signal@${at(pingLine)} at ${at(writeLine)}'),
          ),
        ),
      );
    });
  });

  group('warnings without a hook', () {
    test('print once per site with the name, site and docs page', () async {
      final printed = <String>[];
      final late = signal(1, name: 'late');
      final lateLine = here() - 1;
      final gate = Completer<void>();
      var readLine = 0, otherLine = 0;
      await runZoned(
        () async {
          final query = computedAsync((_) async {
            await gate.future;
            for (var i = 0; i < 2; i++) {
              readLine = here() + 1;
              late.value;
            }
            otherLine = here() + 1;
            return late.value;
          });
          final first = query.settled();
          gate.complete();
          await first;
          await query.refresh();
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );
      expect(printed, [
        'RILL_READ_AFTER_AWAIT at ${at(readLine)}: late (signal at '
            '${at(lateLine)}) was read after an await in computedAsync, or '
            'inside the async* body of computedStream, and is not tracked. '
            'Read it before the first await (computedStream: in the '
            'synchronous fn before returning the stream), or use peek() for a '
            'snapshot. (rill docs/diagnostics/RILL_READ_AFTER_AWAIT.md)',
        startsWith('RILL_READ_AFTER_AWAIT at ${at(otherLine)}: late '),
      ]);
    });

    test('a late write prints its write site', () async {
      final printed = <String>[];
      final owner = Scope();
      final target = signal(0, name: 'late');
      final gate = Completer<void>();
      late final int writeLine;
      await runZoned(
        () async {
          final task = owner.slot().run((_) async {
            await gate.future;
            writeLine = here() + 1;
            target.value = 1;
          });
          owner.dispose();
          gate.complete();
          await task;
          await settle();
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );
      expect(
        printed.single,
        startsWith('RILL_LATE_WRITE at ${at(writeLine)}: late (signal at '),
      );
    });

    test('a hook replaces printing', () async {
      final printed = <String>[];
      final hooked = <(String, String?)>[];
      diagnosticHook = (code, name) => hooked.add((code, name));
      final late = signal(1);
      final line = here() - 1;
      await runZoned(
        () async {
          final query = computedAsync((_) async {
            await Future<void>.delayed(Duration.zero);
            return late.value;
          });
          await query.settled();
          await settle();
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );
      expect(printed, isEmpty);
      expect(hooked, [('RILL_READ_AFTER_AWAIT', 'signal@${at(line)}')]);
    });
  });

  group('why a reader ran', () {
    test('a computed chain reaches the write and its call site', () {
      final count = signal(1, name: 'count');
      final doubled = computed(() => count.value * 2, name: 'doubled');
      final label = computed(() => 'n=${doubled.value}', name: 'label');
      final stop = effect(() => label.value, (_, _, _) {}, name: 'render');
      addTearDown(stop);
      count.value = 2;
      final writeLine = here() - 1;
      final why = RillDebug.lastWhy(stop)!;
      expect(why.kind, 'effect');
      expect(why.run, 2);
      expect(why.initial, isFalse);
      final labelCause = why.causes.single;
      expect(labelCause.node.label, 'label');
      expect(labelCause.change, 'value');
      final doubledCause = labelCause.causes.single;
      expect(doubledCause.node.label, 'doubled');
      final write = doubledCause.causes.single;
      expect(write.node.label, 'count');
      expect(write.change, 'write');
      expect(write.revision, nodeRevision(count));
      expect(write.site.toString(), at(writeLine));
      expect(RillDebug.why('render').map((record) => record.run), [1, 2]);
      expect(
        why.toString(),
        stringContainsInOrder([
          'effect render',
          'ran (#2)',
          '← computed label',
          '← computed doubled',
          '← signal count',
          'written @',
          at(writeLine),
        ]),
      );
    });

    test('an equal computed output stops the chain and records nothing', () {
      final count = signal(1, name: 'count');
      final positive = computed(() => count.value > 0, name: 'positive');
      final stop = effect(() => positive.value, (_, _, _) {});
      addTearDown(stop);
      count.value = 2;
      expect(RillDebug.why(stop).map((record) => record.run), [1]);
    });

    test('a batch reports every input written in it', () {
      final a = signal(0, name: 'a');
      final b = signal(0, name: 'b');
      final stop = effect(() => a.value + b.value, (_, _, _) {});
      addTearDown(stop);
      late final int aLine, bLine;
      batch(() {
        a.value = 1;
        aLine = here() - 1;
        b.value = 1;
        bLine = here() - 1;
        a.value = 2;
      });
      final why = RillDebug.lastWhy(stop)!;
      expect(why.run, 2);
      final causes = {for (final cause in why.causes) cause.node.label: cause};
      expect(causes.keys, unorderedEquals(['a', 'b']));
      // The latest write in the batch is the one the effect consumed.
      expect(causes['a']!.site.toString(), at(aLine + 4));
      expect(causes['b']!.site.toString(), at(bLine));
    });

    test('a later round names the apply and the run that wrote', () {
      final source = signal(0, name: 'source');
      final relay = signal(0, name: 'relay');
      final first = effect(() => source.value, (value, _, _) {
        relay.value = value * 10;
      }, name: 'copy');
      final writeLine = here() - 2;
      final second = effect(() => relay.value, (_, _, _) {}, name: 'show');
      addTearDown(first);
      addTearDown(second);
      source.value = 3;
      final why = RillDebug.lastWhy(second)!;
      final relayCause = why.causes.single;
      expect(relayCause.node.label, 'relay');
      expect(relayCause.site.toString(), at(writeLine));
      expect(relayCause.origin, 'apply of copy');
      final trigger = relayCause.trigger!;
      expect(trigger.node.label, 'copy');
      expect(trigger.run, 2);
      expect(trigger.causes.single.node.label, 'source');
      expect(
        why.toString(),
        stringContainsInOrder([
          'show',
          '← signal relay',
          'apply of copy',
          'copy',
          'ran (#2)',
          '← signal source',
        ]),
      );
    });

    test('publication records the task that installed the value', () async {
      final scope = Scope(name: 'store');
      addTearDown(scope.dispose);
      final slot = scope.slot(name: 'sweep');
      final shown = signal(0, name: 'shown');
      final stop = effect(() => shown.value, (_, _, _) {}, name: 'view');
      addTearDown(stop);
      await slot.run((task) async {
        task.publish((p) => p.set(shown, 5));
      });
      final cause = RillDebug.lastWhy(stop)!.causes.single;
      expect(cause.origin, 'publish by sweep.task');
      expect(cause.site.toString(), startsWith('test/debug_test.dart:'));
    });

    test('a query re-ask names the input that changed', () async {
      final key = signal(1, name: 'key');
      final user = computedAsync((_) async => key.value, name: 'user');
      final stop = effect(() => user.value, (_, _, _) {});
      addTearDown(stop);
      await settle();
      key.value = 2;
      await settle();
      final asked = RillDebug.why(user);
      expect(asked.map((record) => record.kind).toSet(), {'query'});
      expect(asked.last.run, 2);
      expect(asked.last.causes.single.node.label, 'key');
      // The effect saw the state settle, written by the query.
      final settled = RillDebug.lastWhy(stop)!.causes.single;
      expect(settled.node.label, 'user');
      final landing = settled.causes.firstWhere(
        (cause) => cause.node.label == 'user.landed',
      );
      expect(landing.origin, 'settle of user');
    });

    test('the buffer keeps the newest records', () {
      final previous = RillDebug.capacity;
      addTearDown(() => RillDebug.capacity = previous);
      RillDebug.capacity = 3;
      final count = signal(0);
      final stop = effect(() => count.value, (_, _, _) {});
      addTearDown(stop);
      for (var i = 1; i <= 5; i++) {
        count.value = i;
      }
      expect(RillDebug.why(stop).map((record) => record.run), [4, 5, 6]);
      expect(() => RillDebug.capacity = 0, throwsArgumentError);
    });
  });

  group('snapshots', () {
    test('graph lists nodes with names, sites, revisions and edges', () {
      final count = signal(1, name: 'count');
      final doubled = computed(() => count.value * 2, name: 'doubled');
      final stop = effect(() => doubled.value, (_, _, _) {}, name: 'render');
      addTearDown(stop);
      final graph = jsonDecode(jsonEncode(RillDebug.graph())) as Map;
      expect(graph['type'], 'RillGraph');
      expect(graph['enabled'], isTrue);
      expect(graph['revisionClock'], revisionClock);
      final nodes = {
        for (final node in (graph['nodes'] as List).cast<Map>())
          node['label']: node,
      };
      final c = nodes['count']!, d = nodes['doubled']!, e = nodes['render']!;
      expect(c['kind'], 'signal');
      expect(c['revision'], nodeRevision(count));
      expect(c['valueType'], 'int');
      expect(c['location'], startsWith('test/debug_test.dart:'));
      expect(d['deps'], [c['id']]);
      expect(d['subs'], [e['id']]);
      expect(c['subs'], [d['id']]);
      expect(e['kind'], 'effect');
      expect(e['runs'], 1);
      for (final key in [
        'id',
        'kind',
        'name',
        'label',
        'location',
        'version',
        'dirty',
        'pending',
        'disposed',
        'deps',
        'subs',
      ]) {
        expect(c, contains(key));
      }
      expect(RillDebug.graph(limit: 1)['truncated'], isTrue);
    });

    test('active lists effects, slot tasks and the scope tree', () async {
      final store = Scope(name: 'store');
      addTearDown(store.dispose);
      final session = store.child(name: 'session');
      final count = signal(0);
      final stop = session.effect(
        () => count.value,
        (_, _, _) {},
        name: 'watch',
      );
      final slot = session.slot(name: 'poll', onBusy: OnBusy.queue);
      final gate = Completer<void>();
      final first = slot.run((_) => gate.future, key: 'tick');
      final second = slot.run((_) async {});
      final active = jsonDecode(jsonEncode(RillDebug.active())) as Map;
      expect(active['type'], 'RillActive');
      expect(active['counts'], containsPair('tasks', 2));
      final effects = (active['effects'] as List).cast<Map>();
      final watch = effects.singleWhere((e) => e['label'] == 'watch');
      expect(watch['runs'], 1);
      final tasks = (active['tasks'] as List).cast<Map>();
      expect(tasks.map((t) => t['key']), ['tick', null]);
      expect(tasks.map((t) => t['queued']), [false, true]);
      expect(tasks.first['policy'], 'queue');
      final roots = (active['scopes'] as List).cast<Map>();
      final storeJson = roots.singleWhere((s) => s['label'] == 'store');
      final sessionJson = (storeJson['children'] as List).single as Map;
      expect(sessionJson['label'], 'session');
      expect(sessionJson['effects'], [watch['id']]);
      // The owner survives _Effect losing its field (a debug Expando).
      expect(watch['owner'], sessionJson['id']);
      expect(sessionJson['slots'], hasLength(1));
      stop();
      gate.complete();
      await first;
      await second;
      final after = RillDebug.active();
      expect((after['tasks']! as List), isEmpty);
      store.dispose();
      final scopes = (RillDebug.active()['scopes']! as List).cast<Map>();
      expect(scopes.where((s) => s['label'] == 'store'), isEmpty);
    });

    test('why JSON carries the chain and its text', () {
      final count = signal(0, name: 'count');
      final stop = effect(() => count.value, (_, _, _) {}, name: 'render');
      addTearDown(stop);
      count.value = 1;
      final json = jsonDecode(
        jsonEncode(RillDebug.whyJson(target: 'render', limit: 1)),
      ) as Map;
      expect(json['type'], 'RillWhy');
      final record = (json['records'] as List).single as Map;
      expect(record['kind'], 'effect');
      expect(record['run'], 2);
      expect((record['node'] as Map)['label'], 'render');
      final cause = (record['causes'] as List).single as Map;
      expect(cause['change'], 'write');
      expect(cause['site'], startsWith('test/debug_test.dart:'));
      expect(record['text'], contains('← signal count ('));
      expect(record['text'], contains(') written @'));
    });
  });
}
