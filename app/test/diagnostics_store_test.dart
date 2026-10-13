import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/features/browser/diagnostics_store.dart';

void main() {
  late DateTime now;
  late DiagnosticsStore store;
  Map<String, dynamic> event([int delta = 0]) => {
        'ts': now.millisecondsSinceEpoch + delta,
        'source': 'browser',
        'level': 'error',
        'code': 'exception',
      };
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    now = DateTime.utc(2026, 10, 7);
    store = DiagnosticsStore(clock: () => now);
  });
  test('shared protocol fixtures match the browser schema', () {
    final fixtures = jsonDecode(
        File('../docs/diagnostics-fixtures.json').readAsStringSync());
    final at = DateTime.fromMillisecondsSinceEpoch(fixtures['now'] as int);
    for (final fixture in fixtures['fixtures']) {
      expect(
          DiagnosticsStore.sanitize(fixture['input'], at), fixture['expected']);
    }
  });
  test('native sanitizer excludes content and URL secrets before persistence',
      () async {
    await store.append('scope', [
      {
        ...event(),
        'message': 'secret',
        'body': 'private chat',
        'headers': {'Authorization': 'secret'},
        'name': 'TypeError',
        'route':
            '/api/v4/workspaces/private-id/docs/document?token=secret#secret',
        'stack':
            'TypeError: secret\n at foo (https://user:secret@example.test/assets/app.js:12:3)\nsecret',
        'method': 'POST',
        'status': 500,
        'durationMs': 10,
      }
    ]);
    final saved = (await store.snapshot('scope')).single;
    expect(saved['route'], '/api/v4/workspaces/:id/docs/:id');
    expect(saved['stack'], 'at <frame>:12:3');
    final raw =
        await SharedPreferencesAsync().getString(DiagnosticsStore.storageKey);
    for (final sensitive in [
      'secret',
      'private chat',
      'example.test',
      'private-id',
      'Authorization'
    ]) {
      expect(raw, isNot(contains(sensitive)));
    }
    expect(
        saved.keys,
        unorderedEquals([
          'ts',
          'source',
          'level',
          'code',
          'name',
          'route',
          'stack',
          'method',
          'status',
          'durationMs'
        ]));
  });
  test(
      'malformed/future/expired events are discarded and unknown fields stripped',
      () async {
    expect(
        await store.append('scope', [
          event(-1800001),
          event(5001),
          {...event(), 'code': 'invalid text'},
          {...event(), 'source': 'unknown'},
          {...event(), 'durationMs': double.infinity},
          'oops'
        ]),
        3);
    expect(
        (await store.snapshot('scope'))
            .every((event) => !event.containsKey('durationMs')),
        true);
    await expectLater(store.append('scope', List.generate(101, (_) => event())),
        throwsStateError);
  });
  test(
      'scope isolation includes origin identity workspace and stable tab context',
      () async {
    final key = DiagnosticsStore.scopeKey(
        'https://app.test', 'identity', 'workspace', 'tab');
    await store.append(key, [event()]);
    for (final parts in [
      ['https://other.test', 'identity', 'workspace', 'tab'],
      ['https://app.test', 'other', 'workspace', 'tab'],
      ['https://app.test', 'identity', 'other', 'tab'],
      ['https://app.test', 'identity', 'workspace', 'other'],
    ]) {
      expect(
          await store.snapshot(DiagnosticsStore.scopeKey(
              parts[0], parts[1], parts[2], parts[3])),
          isEmpty);
    }
    final fresh = DiagnosticsStore(clock: () => now);
    expect(await fresh.snapshot(key), hasLength(1));
    await fresh.clear(key);
    expect(await store.snapshot(key), isEmpty);
  });
  test('serialized writes retain concurrent append and clear ordering',
      () async {
    await Future.wait([
      store.append('scope', [event()]),
      store.append('scope', [event(1)])
    ]);
    expect(await store.snapshot('scope'), hasLength(2));
    await Future.wait([
      store.clear('scope'),
      store.append('scope', [event(2)])
    ]);
    expect(await store.snapshot('scope'), hasLength(1));
  });
  test('event count byte size and entire abandoned-scope store are bounded',
      () async {
    final big = {
      ...event(),
      'route':
          '/flightdeck-pg/workspaces/download-url/flightdeck-pg/workspaces/download-url/flightdeck-pg/workspaces/download-url/flightdeck-pg/workspaces/download-url',
      'stack': List.generate(8, (i) => 'at <frame>:1234567:1234567').join('\n')
    };
    for (var i = 0; i < 24; i++) {
      await store.append('scope', List.generate(100, (_) => big));
    }
    final events = await store.snapshot('scope');
    expect(events.length, lessThanOrEqualTo(DiagnosticsStore.maxEvents));
    expect(utf8.encode(jsonEncode(events)).length,
        lessThanOrEqualTo(DiagnosticsStore.maxBytes));
    for (var i = 0; i < 20; i++) {
      await store.append('other-$i', [event()]);
    }
    final raw = (await SharedPreferencesAsync()
        .getString(DiagnosticsStore.storageKey))!;
    expect(
        utf8.encode(raw).length, lessThanOrEqualTo(DiagnosticsStore.maxBytes));
    expect((jsonDecode(raw) as Map).length, lessThanOrEqualTo(16));
  });
  test('pruning expires data across every scope, including after recovery',
      () async {
    await store.append('a', [event()]);
    await store.append('b', [event()]);
    now = now.add(const Duration(minutes: 31));
    await store.prune();
    expect(
        await SharedPreferencesAsync().getString(DiagnosticsStore.storageKey),
        isNull);
  });
}
