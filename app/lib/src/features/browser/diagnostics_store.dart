import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local evidence only. Grants are deliberately never persisted.
class DiagnosticsStore {
  static const storageKey = 'wingman.diagnostics.v1';
  static const maxEvents = 2000;
  static const maxBytes = 512 * 1024;
  static const retention = Duration(minutes: 30);
  final SharedPreferencesAsync preferences;
  final DateTime Function() clock;
  Future<void> _tail = Future.value();

  DiagnosticsStore(
      {SharedPreferencesAsync? preferences, DateTime Function()? clock})
      : preferences = preferences ?? SharedPreferencesAsync(),
        clock = clock ?? DateTime.now;

  static String scopeKey(
          String origin, String identity, String workspace, String tab) =>
      sha256
          .convert(utf8.encode(jsonEncode([origin, identity, workspace, tab])))
          .toString();

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Map<String, List<Map<String, dynamic>>>> _load() async {
    final raw = await preferences.getString(storageKey);
    final result = <String, List<Map<String, dynamic>>>{};
    if (raw == null) return result;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          if (entry.key is String && entry.value is List) {
            final events = (entry.value as List)
                .map((e) => sanitize(e, clock()))
                .whereType<Map<String, dynamic>>()
                .toList();
            if (events.isNotEmpty) result[entry.key as String] = _bound(events);
          }
        }
      }
    } catch (_) {
      // Corrupt or obsolete evidence is never treated as trusted state.
    }
    return result;
  }

  List<Map<String, dynamic>> _bound(List<Map<String, dynamic>> events) {
    events.sort((a, b) => (a['ts'] as num).compareTo(b['ts'] as num));
    if (events.length > maxEvents) {
      events.removeRange(0, events.length - maxEvents);
    }
    var bytes = utf8.encode(jsonEncode(events)).length;
    var dropped = 0;
    while (dropped < events.length && bytes > maxBytes) {
      bytes -= utf8.encode(jsonEncode(events[dropped])).length +
          (events.length - dropped > 1 ? 1 : 0);
      dropped++;
    }
    if (dropped > 0) events.removeRange(0, dropped);
    return events;
  }

  Future<void> _save(Map<String, List<Map<String, dynamic>>> scopes) async {
    // Also bound the entire native store, including abandoned tab contexts.
    while (scopes.length > 16 ||
        utf8.encode(jsonEncode(scopes)).length > maxBytes) {
      final oldest = scopes.keys.reduce((a, b) =>
          (scopes[a]!.first['ts'] as num) < (scopes[b]!.first['ts'] as num)
              ? a
              : b);
      scopes[oldest]!.removeAt(0);
      if (scopes[oldest]!.isEmpty) scopes.remove(oldest);
    }
    if (scopes.isEmpty) {
      await preferences.remove(storageKey);
    } else {
      await preferences.setString(storageKey, jsonEncode(scopes));
    }
  }

  Future<int> append(String scope, List<dynamic> input) =>
      _serialized(() async {
        if (input.length > 100) {
          throw StateError('Diagnostics batch exceeds 100 events.');
        }
        final scopes = await _load();
        final events = input
            .map((e) => sanitize(e, clock()))
            .whereType<Map<String, dynamic>>()
            .toList();
        if (events.isNotEmpty) {
          scopes[scope] = _bound([...?scopes[scope], ...events]);
        }
        await _save(scopes);
        return events.length;
      });

  Future<List<Map<String, dynamic>>> snapshot(String scope) =>
      _serialized(() async {
        final scopes = await _load();
        await _save(scopes);
        return scopes[scope] ?? [];
      });

  Future<void> clear(String scope) => _serialized(() async {
        final scopes = await _load();
        scopes.remove(scope);
        await _save(scopes);
      });

  Future<void> prune() => _serialized(() async => _save(await _load()));

  static Map<String, dynamic>? sanitize(dynamic input, DateTime now) {
    if (input is! Map) return null;
    final ts = input['ts'];
    if (ts is! num ||
        !ts.isFinite ||
        ts < now.millisecondsSinceEpoch - retention.inMilliseconds ||
        ts > now.millisecondsSinceEpoch + 5000) {
      return null;
    }
    const sources = {'browser', 'worker', 'network', 'ui', 'host'};
    const levels = {'trace', 'debug', 'info', 'warn', 'error'};
    const codes = {
      'console',
      'exception',
      'rejection',
      'sync',
      'worker',
      'request',
      'resource',
      'navigation',
      'interaction',
      'lifecycle',
      'transport',
      'webview',
      'recovery'
    };
    const names = {
      'Error',
      'TypeError',
      'RangeError',
      'SyntaxError',
      'ReferenceError',
      'AbortError',
      'NetworkError',
      'TransactionInactiveError',
      'SecurityError'
    };
    final event = <String, dynamic>{
      'ts': ts,
      'source': sources.contains(input['source']) ? input['source'] : 'browser',
      'level': levels.contains(input['level']) ? input['level'] : 'info',
      'code': codes.contains(input['code']) ? input['code'] : 'console'
    };
    const operations = {
      'sync',
      'startup-sync',
      'sse',
      'storage',
      'workspace-key',
      'message-timing',
      'worker-failure',
      'report-open',
      'report-send',
      'thread-close',
      'navigation'
    };
    const errorCodes = {
      'pg_read_authority_changed',
      'pg_read_authority_resetting',
      'worker_unavailable',
      'storage_unavailable'
    };
    if (operations.contains(input['operation'])) {
      event['operation'] = input['operation'];
    }
    if (errorCodes.contains(input['errorCode'])) {
      event['errorCode'] = input['errorCode'];
    }
    if (names.contains(input['name'])) event['name'] = input['name'];
    if ({'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'}
        .contains(input['method'])) {
      event['method'] = input['method'];
    }
    final status = input['status'];
    if (status is int && status >= 0 && status <= 599) event['status'] = status;
    final duration = input['durationMs'];
    if (duration is num && duration.isFinite && duration >= 0) {
      event['durationMs'] = duration.clamp(0, 3600000).round();
    }
    final route = input['route'];
    if (route is String) {
      const allowed = {
        'api',
        'v4',
        'flightdeck-pg',
        'workspaces',
        'channels',
        'threads',
        'messages',
        'tasks',
        'docs',
        'body',
        'comments',
        'files',
        'storage',
        'prepare',
        'complete',
        'download-url',
        'sync',
        'events',
        'stream',
        'members',
        'groups',
        'scopes',
        'bundles',
        'updates',
        'health',
        'assets',
        'index.html',
        'version.json'
      };
      try {
        final uri = Uri.parse('https://diagnostics.invalid').resolve(route);
        event['route'] =
            '/${uri.path.split('/').where((part) => part.isNotEmpty).take(12).map((part) => allowed.contains(part) ? part : ':id').join('/')}';
      } catch (_) {
        event['route'] = '/:unknown';
      }
    }
    final stack = input['stack'];
    if (stack is String) {
      const assetPattern =
          r'(?:index|diagnostics-worker|sync-worker|tower-pg-materialization-worker|tiptap-editor-adapter|task-description-editor|pg-record-delta|pg-device-checkpoints)-[A-Za-z0-9_-]{8,16}\.js';
      final safeFrame =
          RegExp('^at (?:<frame>|$assetPattern):\\d{1,7}:\\d{1,7}\$');
      final approvedFrame = RegExp(
          '(?:/|^)($assetPattern)(?:\\?[^\\s)]*)?:\\d{1,7}:\\d{1,7}\\)?\$');
      final frames = <String>[];
      for (final line in stack.split('\n').take(9)) {
        if (safeFrame.hasMatch(line)) {
          frames.add(line);
          continue;
        }
        final match = RegExp(
                r'(?:https?://|file:///|/)[^\s)]*?:(\d{1,7}):(\d{1,7})\)?\s*$')
            .firstMatch(line);
        if (match != null) {
          final asset = approvedFrame.firstMatch(line)?.group(1) ?? '<frame>';
          frames.add('at $asset:${match[1]}:${match[2]}');
        }
      }
      if (frames.isNotEmpty) event['stack'] = frames.take(8).join('\n');
    }
    return event;
  }
}
