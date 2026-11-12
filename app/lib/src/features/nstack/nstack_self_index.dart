import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../core/nip44.dart';
import '../../core/nostr_crypto.dart';
import 'nstack_models.dart';

const workspaceIndexIdentityKeys = [
  'workspace_id',
  'tower_service_npub',
  'workspace_service_npub',
  'workspace_owner_npub',
  'app_npub'
];
typedef WorkspaceIndexPublish = Future<bool> Function(
    String relay, Map<String, dynamic> event);

typedef WorkspaceIndexQuery = Future<List<Map<String, dynamic>>> Function(
    String relay, Map<String, dynamic> filter);

class NStackIndexLocator {
  const NStackIndexLocator(this.origin, this.identity, this.label);
  final String origin;
  final Map<String, String> identity;
  final String label;
  String get workspaceId => identity['workspace_id']!;
  String get towerNpub => identity['tower_service_npub']!;
}

class NStackDiscoveredTower {
  const NStackDiscoveredTower(this.origin, this.towerNpub);
  final String origin, towerNpub;
}

/// Relay indexes are candidates only; every identity needs fresh Tower /me verification.
class NStackSelfIndexDiscovery {
  NStackSelfIndexDiscovery(
      {http.Client? client,
      WorkspaceIndexQuery? query,
      WorkspaceIndexPublish? publish})
      : _client = client ?? http.Client(),
        _query = query ?? queryWorkspaceIndexes,
        _publish = publish ?? publishWorkspaceIndexEvent;
  final http.Client _client;
  final WorkspaceIndexQuery _query;
  final WorkspaceIndexPublish _publish;
  static const relays = ['wss://relay.primal.net', 'wss://relay.damus.io'];
  Future<List<NStackDiscoveredTower>> discover(
      {required String identityNpub, required String secret}) async {
    final user = NostrCrypto.importIdentity(secret);
    if (user.npub != identityNpub) {
      throw StateError('Discovery identity changed.');
    }
    final events = <Map<String, dynamic>>[];
    var complete = 0;
    await Future.wait(relays.map((relay) async {
      try {
        final batch = await _query(relay, {
          'kinds': [33356],
          'authors': [user.publicKeyHex],
          '#p': [user.publicKeyHex],
          'limit': 1000
        });
        if (batch.length >= 1000) return;
        events.addAll(batch);
        complete++;
      } catch (_) {/* another relay can provide a complete result */}
    }));
    if (complete == 0) {
      throw StateError(
          'Tower discovery failed. Retry or add an HTTPS address.');
    }
    final candidates = await workspaceIndexCandidates(events, secret: secret);
    if (candidates.length > 100) throw StateError('Too many Tower candidates.');
    final towers = <String, NStackDiscoveredTower>{};
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    for (final candidate in candidates) {
      if (DateTime.now().isAfter(deadline)) {
        break;
      }
      try {
        await verify(candidate, secret: secret)
            .timeout(const Duration(seconds: 10));
        towers['${candidate.origin}|${candidate.towerNpub}'] =
            NStackDiscoveredTower(candidate.origin, candidate.towerNpub);
      } catch (_) {/* stale/revoked/unreachable candidates are isolated */}
    }
    return towers.values.toList()..sort((a, b) => a.origin.compareTo(b.origin));
  }

  Future<void> announce(NStackIndexLocator locator,
      {required String secret}) async {
    await verify(locator, secret: secret).timeout(const Duration(seconds: 10));
    final user = NostrCrypto.importIdentity(secret);
    final app = NostrCrypto.publicKeyHexFromNpub(nbrowserAppNpub);
    final time = DateTime.now().toUtc().toIso8601String();
    final d =
        'fd-self:${NostrCrypto.sha256Hex(utf8.encode('v1:${user.publicKeyHex}:$app:${locator.towerNpub}:${locator.workspaceId}'))}';
    final event = NostrCrypto.signEvent(secret: secret, event: {
      'kind': 33356,
      'tags': [
        ['d', d],
        ['p', user.publicKeyHex],
        ['app_pub', app],
        ['protocol', 'workspace-self-index'],
        ['v', '1']
      ],
      'content': await Nip44().encrypt(
          secret: secret,
          peerPublicKeyHex: user.publicKeyHex,
          plaintext: jsonEncode({
            'type': 'flightdeck_workspace_self_index',
            'version': 1,
            'app': {
              'app_npub': nbrowserAppNpub,
              'app_pubkey': app,
              'namespace': 'flightdeck_pg'
            },
            'user_npub': user.npub,
            'issued_at': time,
            'updated_at': time,
            'workspace': {
              'type': 'wingman_workspace_locator',
              'version': 1,
              'tower_base_url': locator.origin,
              ...locator.identity,
              'label': locator.label
            },
            'state': {'deleted': false},
          })),
    });
    for (final relay in relays) {
      try {
        if (!await _publish(relay, event)) {
          continue;
        }
        final read = await _query(relay, {
          'ids': [event['id']],
          'limit': 1
        });
        final exact =
            read.where((candidate) => candidate['id'] == event['id']).toList();
        final decoded = await workspaceIndexCandidates(exact, secret: secret);
        if (decoded.any((candidate) =>
            candidate.origin == locator.origin &&
            workspaceIndexIdentityKeys.every(
                (key) => candidate.identity[key] == locator.identity[key]))) {
          return;
        }
      } catch (_) {
        /* next relay; success requires both ACK and exact readback */
      }
    }
    throw StateError('Workspace announcement pending. Retry later.');
  }

  Future<void> verify(NStackIndexLocator candidate,
      {required String secret}) async {
    final url = Uri.parse(
        '${candidate.origin}/api/v4/flightdeck-pg/workspaces/${candidate.workspaceId}/me');
    final request = http.Request('GET', url)
      ..followRedirects = false
      ..headers['accept'] = 'application/json'
      ..headers['x-flightdeck-pg-app-npub'] = candidate.identity['app_npub']!
      ..headers['authorization'] = NostrCrypto.signNip98(
              secret: secret, method: 'GET', url: url.toString())
          .authorization;
    final response =
        await _client.send(request).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200 ||
        (response.contentLength ?? 0) > 256 * 1024) {
      throw StateError('Membership unavailable.');
    }
    final bytes = <int>[];
    await for (final chunk
        in response.stream.timeout(const Duration(seconds: 10))) {
      bytes.addAll(chunk);
      if (bytes.length > 256 * 1024) {
        throw StateError('Membership response too large.');
      }
    }
    final body = jsonDecode(utf8.decode(bytes));
    if (body is! Map ||
        body['identity'] is! Map ||
        workspaceIndexIdentityKeys
            .any((key) => body['identity'][key] != candidate.identity[key])) {
      throw StateError('Membership identity mismatch.');
    }
  }
}

String _singleton(Map<String, dynamic> event, String key) {
  final tags = (event['tags'] as List)
      .where((tag) => tag is List && tag.isNotEmpty && tag[0] == key)
      .toList();
  if (tags.length != 1 ||
      (tags.single as List).length != 2 ||
      tags.single[1] is! String) {
    throw const FormatException('Invalid index tag');
  }
  return tags.single[1] as String;
}

String _indexOrigin(Object? raw) {
  if (raw is! String || raw.length > 2048) {
    throw const FormatException('Invalid origin');
  }
  final uri = Uri.parse(raw);
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException('HTTPS origin required');
  }
  return uri.replace(path: '').toString();
}

/// Resolve address replacements before decryption so deletion never revives an older locator.
Future<List<NStackIndexLocator>> workspaceIndexCandidates(
    List<Map<String, dynamic>> events,
    {required String secret,
    int? now}) async {
  final user = NostrCrypto.importIdentity(secret);
  final latest = <String, Map<String, dynamic>>{};
  final clock = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  for (final event in events) {
    try {
      if (jsonEncode(event).length > 64 * 1024 ||
          !NostrCrypto.verifyEvent(event) ||
          event['kind'] != 33356 ||
          event['pubkey'] != user.publicKeyHex ||
          event['created_at'] is! int ||
          event['created_at'] > clock + 300) {
        continue;
      }
      final dTag = (event['tags'] as List)
          .where((tag) => tag is List && tag.length >= 2 && tag[0] == 'd')
          .firstOrNull;
      if (dTag == null || dTag[1] is! String) {
        continue;
      }
      final d = dTag[1] as String;
      final old = latest[d];
      if (old == null ||
          event['created_at'] > old['created_at'] ||
          (event['created_at'] == old['created_at'] &&
              (event['id'] as String).compareTo(old['id'] as String) < 0)) {
        latest[d] = event;
      }
    } catch (_) {}
  }
  final candidates = <NStackIndexLocator>[];
  for (final event in latest.values) {
    try {
      if (_singleton(event, 'p') != user.publicKeyHex ||
          _singleton(event, 'protocol') != 'workspace-self-index' ||
          _singleton(event, 'v') != '1') {
        continue;
      }
      final app = _singleton(event, 'app_pub');
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(app)) continue;
      final p = jsonDecode(await Nip44().decrypt(
          secret: secret,
          peerPublicKeyHex: user.publicKeyHex,
          payload: event['content'] as String));
      if (p is! Map ||
          p['type'] != 'flightdeck_workspace_self_index' ||
          p['version'] != 1 ||
          p['user_npub'] != user.npub ||
          p['state'] is! Map ||
          p['state']['deleted'] is! bool) {
        continue;
      }
      final appPayload = p['app'];
      if (appPayload is! Map ||
          appPayload['app_pubkey'] != app ||
          appPayload['namespace'] != 'flightdeck_pg' ||
          NostrCrypto.publicKeyHexFromNpub(appPayload['app_npub'] as String) !=
              app) {
        continue;
      }
      final w = p['workspace'];
      if (w is! Map ||
          w['type'] != 'wingman_workspace_locator' ||
          w['version'] != 1) {
        continue;
      }
      final origin = _indexOrigin(w['tower_base_url']);
      final identity = w['identity'] ?? w;
      if (identity is! Map) continue;
      final fields = <String, String>{};
      for (final key in workspaceIndexIdentityKeys) {
        final value = identity[key];
        if (value is! String) throw const FormatException('Missing identity');
        if (key == 'workspace_id') {
          if (!RegExp(
                  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
              .hasMatch(value)) {
            throw const FormatException('Invalid workspace');
          }
        } else {
          NostrCrypto.publicKeyHexFromNpub(value);
        }
        fields[key] = value;
      }
      final expected =
          'fd-self:${NostrCrypto.sha256Hex(utf8.encode('v1:${user.publicKeyHex}:$app:${fields['tower_service_npub']}:${fields['workspace_id']}'))}';
      if (_singleton(event, 'd') != expected || p['state']['deleted'] == true) {
        continue;
      }
      final label = w['label'] is String ? w['label'] as String : 'Workspace';
      candidates.add(NStackIndexLocator(origin, fields,
          label.length > 256 ? label.substring(0, 256) : label));
    } catch (_) {
      /* malformed/unreadable candidate does not hide other addresses */
    }
  }
  return candidates;
}

Future<List<Map<String, dynamic>>> queryWorkspaceIndexes(
    String relay, Map<String, dynamic> filter) async {
  WebSocketChannel? channel;
  StreamSubscription<dynamic>? subscription;
  final result = Completer<List<Map<String, dynamic>>>();
  unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  final events = <Map<String, dynamic>>[];
  final sub = 'nbrowser-index-${DateTime.now().microsecondsSinceEpoch}';
  var frames = 0;
  void fail() {
    if (!result.isCompleted) {
      result.completeError(StateError('Incomplete relay query.'));
    }
  }

  try {
    channel = WebSocketChannel.connect(Uri.parse(relay));
    subscription = channel.stream.listen((raw) {
      if (++frames > 2000) {
        fail();
        return;
      }
      if (raw is! String || raw.length > 64 * 1024) return;
      try {
        final frame = jsonDecode(raw);
        if (frame is! List ||
            frame.length < 2 ||
            frame[1] != sub ||
            result.isCompleted) {
          return;
        }
        if (frame[0] == 'EOSE') result.complete(events);
        if (frame[0] == 'CLOSED') fail();
        if (frame[0] == 'EVENT' &&
            frame.length == 3 &&
            frame[2] is Map<String, dynamic>) {
          events.add(frame[2] as Map<String, dynamic>);
          if (events.length >= 1000) fail();
        }
      } catch (_) {}
    }, onError: (_) => fail(), onDone: fail);
    await channel.ready.timeout(const Duration(seconds: 8));
    channel.sink.add(jsonEncode(['REQ', sub, filter]));
    return await result.future.timeout(const Duration(seconds: 8));
  } finally {
    await subscription?.cancel();
    unawaited(channel?.sink.close().catchError((_) {}) ?? Future<void>.value());
  }
}

Future<bool> publishWorkspaceIndexEvent(
    String relay, Map<String, dynamic> event) async {
  WebSocketChannel? channel;
  StreamSubscription<dynamic>? subscription;
  final result = Completer<bool>();
  try {
    channel = WebSocketChannel.connect(Uri.parse(relay));
    subscription = channel.stream.listen((raw) {
      if (raw is! String || raw.length > 64 * 1024 || result.isCompleted) {
        return;
      }
      try {
        final frame = jsonDecode(raw);
        if (frame is List &&
            frame.length >= 3 &&
            frame[0] == 'OK' &&
            frame[1] == event['id']) {
          result.complete(frame[2] == true);
        }
      } catch (_) {}
    }, onError: (_) {
      if (!result.isCompleted) {
        result.complete(false);
      }
    }, onDone: () {
      if (!result.isCompleted) {
        result.complete(false);
      }
    });
    await channel.ready.timeout(const Duration(seconds: 8));
    channel.sink.add(jsonEncode(['EVENT', event]));
    return await result.future.timeout(const Duration(seconds: 8));
  } finally {
    await subscription?.cancel();
    unawaited(channel?.sink.close().catchError((_) {}) ?? Future<void>.value());
  }
}
