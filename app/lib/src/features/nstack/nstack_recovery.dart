import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/nip44.dart';
import '../../core/nostr_crypto.dart';
import 'nstack_models.dart';
import 'nstack_store.dart';

class NStackSettingsSnapshot {
  const NStackSettingsSnapshot({
    required this.identityNpub,
    required this.createdAt,
    required this.registry,
  });

  final String identityNpub;
  final DateTime createdAt;
  final NStackRegistry registry;

  Map<String, dynamic> toJson() => {
        'schema': 'org.wingman.nbrowser.settings-snapshot',
        'version': 1,
        'identity_npub': identityNpub,
        'created_at': createdAt.toUtc().toIso8601String(),
        'registry': registry.toJson(),
      };

  String canonicalJson() => jsonEncode(toJson());

  static NStackSettingsSnapshot parse(String raw, String expectedIdentity) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded['schema'] != 'org.wingman.nbrowser.settings-snapshot' ||
        decoded['version'] != 1 ||
        decoded['identity_npub'] != expectedIdentity) {
      throw const FormatException(
          'settings snapshot schema or identity mismatch');
    }
    final createdAt =
        DateTime.tryParse(decoded['created_at']?.toString() ?? '');
    final registry = NStackRegistry.tryParse(decoded['registry']);
    if (createdAt == null || registry == null) {
      throw const FormatException('invalid settings snapshot');
    }
    return NStackSettingsSnapshot(
      identityNpub: expectedIdentity,
      createdAt: createdAt.toUtc(),
      registry: registry,
    );
  }
}

class NStackRecoveryPointer {
  const NStackRecoveryPointer({
    required this.hostUrl,
    required this.objectId,
    required this.sha256,
    required this.snapshotRevision,
    required this.updatedAt,
    required this.relays,
    this.workspaceId,
  });

  final String hostUrl;
  final String? workspaceId;
  final String objectId;
  final String sha256;
  final int snapshotRevision;
  final DateTime updatedAt;
  final List<String> relays;

  Map<String, dynamic> toJson() => {
        'schema': 'org.wingman.nbrowser.recovery-pointer',
        'version': 1,
        'host_url': hostUrl,
        if (workspaceId != null) 'workspace_id': workspaceId,
        'object_id': objectId,
        'sha256': sha256,
        'snapshot_schema_version': 1,
        'snapshot_revision': snapshotRevision,
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'relays': relays,
      };

  static NStackRecoveryPointer parse(String raw) {
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> ||
        value['schema'] != 'org.wingman.nbrowser.recovery-pointer' ||
        value['version'] != 1 ||
        value['snapshot_schema_version'] != 1) {
      throw const FormatException('invalid recovery pointer schema');
    }
    final hostUrl = canonicalNStackUrl(value['host_url']?.toString());
    final objectId = value['object_id']?.toString().trim() ?? '';
    final hash = value['sha256']?.toString().toLowerCase() ?? '';
    final revision = value['snapshot_revision'];
    final updatedAt = DateTime.tryParse(value['updated_at']?.toString() ?? '');
    final relayValues = value['relays'];
    final relays = relayValues is List
        ? relayValues
            .map((item) => item.toString())
            .where(isNStackRecoveryRelay)
            .toSet()
            .toList(growable: false)
        : const <String>[];
    if (hostUrl == null ||
        !RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(objectId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        revision is! int ||
        revision < 0 ||
        updatedAt == null ||
        relays.isEmpty) {
      throw const FormatException('invalid recovery pointer');
    }
    final workspaceId = value['workspace_id']?.toString().trim();
    return NStackRecoveryPointer(
      hostUrl: hostUrl,
      workspaceId:
          workspaceId == null || workspaceId.isEmpty ? null : workspaceId,
      objectId: objectId,
      sha256: hash,
      snapshotRevision: revision,
      updatedAt: updatedAt.toUtc(),
      relays: relays,
    );
  }
}

abstract class NStackStorageClient {
  Future<String> upload({
    required String hostUrl,
    required String ownerNpub,
    required String secret,
    required List<int> bytes,
    required String sha256,
  });

  Future<List<int>> fetch({
    required String hostUrl,
    required String objectId,
    required String secret,
    required String expectedSha256,
  });
}

class TowerNStackStorageClient implements NStackStorageClient {
  TowerNStackStorageClient({http.Client? client})
      : _client = client ?? http.Client();
  final http.Client _client;

  @override
  Future<String> upload({
    required String hostUrl,
    required String ownerNpub,
    required String secret,
    required List<int> bytes,
    required String sha256,
  }) async {
    final root = canonicalNStackUrl(hostUrl);
    if (root == null) throw StateError('Host NStack HTTPS URL is invalid.');
    final prepareUrl = '$root/api/v4/storage/prepare';
    final prepareBody = jsonEncode({
      'owner_npub': ownerNpub,
      'content_type': 'application/vnd.wingman.nbrowser-settings+encrypted',
      'file_name': 'nbrowser-settings.enc',
      'size_bytes': bytes.length,
      'is_public': false,
      'metadata': {'purpose': 'nbrowser/settings-backup', 'schema_version': 1},
    });
    final prepared = await _jsonRequest(
      method: 'POST',
      url: prepareUrl,
      secret: secret,
      body: prepareBody,
    );
    final objectId = prepared['object_id']?.toString() ?? '';
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(objectId)) {
      throw StateError('Tower returned an invalid storage object.');
    }
    final uploadUrl = '$root/api/v4/storage/$objectId';
    final uploadBody = jsonEncode({'base64_data': base64Encode(bytes)});
    await _jsonRequest(
      method: 'PUT',
      url: uploadUrl,
      secret: secret,
      body: uploadBody,
    );
    final completeUrl = '$root/api/v4/storage/$objectId/complete';
    final completeBody = jsonEncode({'sha256_hex': sha256});
    await _jsonRequest(
      method: 'POST',
      url: completeUrl,
      secret: secret,
      body: completeBody,
    );
    return objectId;
  }

  @override
  Future<List<int>> fetch({
    required String hostUrl,
    required String objectId,
    required String secret,
    required String expectedSha256,
  }) async {
    final root = canonicalNStackUrl(hostUrl);
    if (root == null || !RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(objectId)) {
      throw StateError('Recovery storage pointer is invalid.');
    }
    final metadataUrl = '$root/api/v4/storage/$objectId';
    final metadata = await _jsonRequest(
      method: 'GET',
      url: metadataUrl,
      secret: secret,
    );
    if (metadata['sha256_hex']?.toString().toLowerCase() != expectedSha256 ||
        metadata['completed_at'] == null ||
        metadata['is_public'] == true) {
      throw StateError('Recovery object metadata or hash does not match.');
    }
    final contentUrl = '$root/api/v4/storage/$objectId/content';
    final authorization = NostrCrypto.signNip98(
      secret: secret,
      method: 'GET',
      url: contentUrl,
    ).authorization;
    final response = await _client.get(
      Uri.parse(contentUrl),
      headers: {'authorization': authorization},
    );
    if (response.statusCode != 200) {
      throw StateError('Tower recovery fetch failed (${response.statusCode}).');
    }
    if (NostrCrypto.sha256Hex(response.bodyBytes) != expectedSha256) {
      throw StateError('Recovery object bytes failed hash verification.');
    }
    return response.bodyBytes;
  }

  Future<Map<String, dynamic>> _jsonRequest({
    required String method,
    required String url,
    required String secret,
    String? body,
  }) async {
    final auth = NostrCrypto.signNip98(
      secret: secret,
      method: method,
      url: url,
      body: body,
    ).authorization;
    final request = http.Request(method, Uri.parse(url));
    request.headers['authorization'] = auth;
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = body;
    }
    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Tower request failed (${response.statusCode}).');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Tower returned malformed JSON.');
    }
    return decoded;
  }
}

abstract class NStackRecoveryRelay {
  List<String> get relays;
  Future<NStackRelayPublishResult> publish(Map<String, dynamic> event);
  Future<List<Map<String, dynamic>>> fetchHints(String publicKeyHex);
}

class NStackRelayPublishResult {
  const NStackRelayPublishResult(this.acceptedRelays, this.totalRelays);
  final List<String> acceptedRelays;
  final int totalRelays;
  bool get published => acceptedRelays.isNotEmpty;
}

class WebSocketNStackRecoveryRelay implements NStackRecoveryRelay {
  WebSocketNStackRecoveryRelay({
    List<String> relays = const [
      'wss://relay.damus.io',
      'wss://relay.primal.net',
    ],
    this.timeout = const Duration(seconds: 5),
  }) : relays = relays.where(isNStackRecoveryRelay).toSet().toList();

  @override
  final List<String> relays;
  final Duration timeout;

  @override
  Future<NStackRelayPublishResult> publish(Map<String, dynamic> event) async {
    final accepted = await Future.wait(relays.map((relay) async {
      WebSocketChannel? channel;
      StreamSubscription<dynamic>? subscription;
      try {
        channel = WebSocketChannel.connect(Uri.parse(relay));
        final result = Completer<bool>();
        subscription = channel.stream.listen((message) {
          try {
            final frame = jsonDecode(message as String);
            if (frame is List &&
                frame.length >= 3 &&
                frame[0] == 'OK' &&
                frame[1] == event['id'] &&
                !result.isCompleted) {
              result.complete(frame[2] == true);
            }
          } catch (_) {}
        }, onError: (_) {
          if (!result.isCompleted) result.complete(false);
        }, onDone: () {
          if (!result.isCompleted) result.complete(false);
        });
        await channel.ready.timeout(timeout);
        channel.sink.add(jsonEncode(['EVENT', event]));
        return await result.future.timeout(timeout, onTimeout: () => false);
      } catch (_) {
        return false;
      } finally {
        await subscription?.cancel();
        try {
          await channel?.sink.close().timeout(timeout);
        } catch (_) {}
      }
    }));
    return NStackRelayPublishResult([
      for (var i = 0; i < relays.length; i++)
        if (accepted[i]) relays[i],
    ], relays.length);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchHints(String publicKeyHex) async {
    final batches = await Future.wait(
      relays.map((relay) => _fetchRelay(relay, publicKeyHex)),
    );
    return [for (final batch in batches) ...batch];
  }

  Future<List<Map<String, dynamic>>> _fetchRelay(
      String relay, String publicKeyHex) async {
    WebSocketChannel? channel;
    StreamSubscription<dynamic>? subscription;
    final events = <Map<String, dynamic>>[];
    try {
      channel = WebSocketChannel.connect(Uri.parse(relay));
      final done = Completer<void>();
      final subId =
          'nbrowser-recovery-${DateTime.now().microsecondsSinceEpoch}';
      subscription = channel.stream.listen((message) {
        try {
          final frame = jsonDecode(message as String);
          if (frame is List && frame.length >= 2 && frame[1] == subId) {
            if (frame[0] == 'EOSE' && !done.isCompleted) done.complete();
            if (frame[0] == 'EVENT' &&
                frame.length >= 3 &&
                frame[2] is Map<String, dynamic>) {
              events.add(frame[2] as Map<String, dynamic>);
            }
          }
        } catch (_) {}
      }, onError: (_) {
        if (!done.isCompleted) done.complete();
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      });
      await channel.ready.timeout(timeout);
      channel.sink.add(jsonEncode([
        'REQ',
        subId,
        {
          'kinds': [nstackRecoveryHintKind],
          'authors': [publicKeyHex],
          '#d': [nstackRecoveryHintDTag],
          'limit': 10,
        }
      ]));
      await done.future.timeout(timeout, onTimeout: () {});
      channel.sink.add(jsonEncode(['CLOSE', subId]));
      return events;
    } catch (_) {
      return const [];
    } finally {
      await subscription?.cancel();
      try {
        await channel?.sink.close().timeout(timeout);
      } catch (_) {}
    }
  }
}

class NStackRecoveryPreview {
  const NStackRecoveryPreview({
    required this.event,
    required this.pointer,
    required this.snapshot,
  });
  final Map<String, dynamic> event;
  final NStackRecoveryPointer pointer;
  final NStackSettingsSnapshot snapshot;
}

class NStackRecoveryService {
  NStackRecoveryService({
    required this.registryStore,
    required this.storage,
    required this.relay,
    Nip44? nip44,
    NStackRecoveryStatusStore? statusStore,
    DateTime Function()? clock,
  })  : nip44 = nip44 ?? Nip44(),
        statusStore = statusStore ?? NStackRecoveryStatusStore(),
        _clock = clock ?? DateTime.now;

  final NStackRegistryStore registryStore;
  final NStackStorageClient storage;
  final NStackRecoveryRelay relay;
  final Nip44 nip44;
  final NStackRecoveryStatusStore statusStore;
  final DateTime Function() _clock;

  Future<NStackRelayPublishResult> publish({
    required String identityNpub,
    required String publicKeyHex,
    required String secret,
  }) async {
    try {
      return await _publish(
        identityNpub: identityNpub,
        publicKeyHex: publicKeyHex,
        secret: secret,
      );
    } catch (error) {
      await statusStore.save(identityNpub, {
        'last_publish_failure_at': _clock().toUtc().toIso8601String(),
        'success': false,
        'error': error.runtimeType.toString(),
      });
      rethrow;
    }
  }

  Future<NStackRelayPublishResult> _publish({
    required String identityNpub,
    required String publicKeyHex,
    required String secret,
  }) async {
    final identity = NostrCrypto.importIdentity(secret);
    if (identity.npub != identityNpub ||
        identity.publicKeyHex != publicKeyHex) {
      throw StateError('Unlock the matching identity before backup.');
    }
    final registry = await registryStore.load(identityNpub);
    final host = registry.hostStack;
    if (host == null) throw StateError('Select a host NStack first.');
    final snapshot = NStackSettingsSnapshot(
      identityNpub: identityNpub,
      createdAt: _clock().toUtc(),
      registry: registry,
    );
    final encryptedSnapshot = await nip44.encrypt(
      secret: secret,
      peerPublicKeyHex: publicKeyHex,
      plaintext: snapshot.canonicalJson(),
    );
    final bytes = utf8.encode(encryptedSnapshot);
    final hash = NostrCrypto.sha256Hex(bytes);
    final objectId = await storage.upload(
      hostUrl: host.url,
      ownerNpub: identityNpub,
      secret: secret,
      bytes: bytes,
      sha256: hash,
    );
    final workspaceId =
        host.workspaces.isEmpty ? null : host.workspaces.first.remoteId;
    final pointer = NStackRecoveryPointer(
      hostUrl: host.url,
      workspaceId: workspaceId,
      objectId: objectId,
      sha256: hash,
      snapshotRevision: registry.revision,
      updatedAt: snapshot.createdAt,
      relays: relay.relays,
    );
    final encryptedPointer = await nip44.encrypt(
      secret: secret,
      peerPublicKeyHex: publicKeyHex,
      plaintext: jsonEncode(pointer.toJson()),
    );
    final event = NostrCrypto.signEvent(secret: secret, event: {
      'kind': nstackRecoveryHintKind,
      'created_at': snapshot.createdAt.millisecondsSinceEpoch ~/ 1000,
      'tags': [
        ['d', nstackRecoveryHintDTag],
      ],
      'content': encryptedPointer,
    });
    final result = await relay.publish(event);
    await statusStore.save(identityNpub, {
      'last_published_at': snapshot.createdAt.toIso8601String(),
      'last_published_event_id': event['id'],
      'last_published_object_id': objectId,
      'accepted_relays': result.acceptedRelays,
      'total_relays': result.totalRelays,
      'success': result.published,
    });
    return result;
  }

  Future<NStackRecoveryPreview> retrieve({
    required String identityNpub,
    required String publicKeyHex,
    required String secret,
  }) async {
    final identity = NostrCrypto.importIdentity(secret);
    if (identity.npub != identityNpub ||
        identity.publicKeyHex != publicKeyHex) {
      throw StateError('Unlock the matching identity before recovery.');
    }
    final event = selectLatestValidHint(
      await relay.fetchHints(publicKeyHex),
      publicKeyHex,
    );
    if (event == null) throw StateError('No valid recovery hint was found.');
    final pointerJson = await nip44.decrypt(
      secret: secret,
      peerPublicKeyHex: publicKeyHex,
      payload: event['content'].toString(),
    );
    final pointer = NStackRecoveryPointer.parse(pointerJson);
    final bytes = await storage.fetch(
      hostUrl: pointer.hostUrl,
      objectId: pointer.objectId,
      secret: secret,
      expectedSha256: pointer.sha256,
    );
    if (NostrCrypto.sha256Hex(bytes) != pointer.sha256) {
      throw StateError('Recovery object hash mismatch.');
    }
    final snapshotJson = await nip44.decrypt(
      secret: secret,
      peerPublicKeyHex: publicKeyHex,
      payload: utf8.decode(bytes),
    );
    final snapshot = NStackSettingsSnapshot.parse(snapshotJson, identityNpub);
    if (snapshot.registry.revision != pointer.snapshotRevision) {
      throw StateError(
          'Recovery pointer revision conflicts with the snapshot.');
    }
    final eventTime = DateTime.fromMillisecondsSinceEpoch(
      (event['created_at'] as int) * 1000,
      isUtc: true,
    );
    if (snapshot.createdAt != pointer.updatedAt ||
        eventTime.millisecondsSinceEpoch ~/ 1000 !=
            pointer.updatedAt.millisecondsSinceEpoch ~/ 1000) {
      throw StateError('Recovery hint and snapshot timestamps conflict.');
    }
    final current = await registryStore.load(identityNpub);
    if (current.revision > pointer.snapshotRevision) {
      throw StateError(
          'Recovery snapshot is older than current local settings.');
    }
    return NStackRecoveryPreview(
      event: Map.unmodifiable(event),
      pointer: pointer,
      snapshot: snapshot,
    );
  }

  Future<void> restoreConfirmed(
      String identityNpub, NStackRecoveryPreview preview) async {
    if (preview.snapshot.identityNpub != identityNpub) {
      throw StateError('Recovery identity changed before restore.');
    }
    await registryStore.replaceAtomic(identityNpub, preview.snapshot.registry);
    await statusStore.save(identityNpub, {
      'last_restored_at': _clock().toUtc().toIso8601String(),
      'last_restored_event_id': preview.event['id'],
      'last_restored_object_id': preview.pointer.objectId,
      'success': true,
    });
  }
}

Map<String, dynamic>? selectLatestValidHint(
    Iterable<Map<String, dynamic>> events, String expectedAuthor) {
  final valid = events.where((event) {
    final tags = event['tags'];
    final dTags = tags is List
        ? tags
            .whereType<List>()
            .where((tag) => tag.isNotEmpty && tag[0] == 'd')
            .toList()
        : const <List>[];
    final exactD = dTags.length == 1 &&
        dTags.single.length == 2 &&
        dTags.single[1] == nstackRecoveryHintDTag;
    return event['kind'] == nstackRecoveryHintKind &&
        event['pubkey']?.toString().toLowerCase() ==
            expectedAuthor.toLowerCase() &&
        exactD &&
        NostrCrypto.verifyEvent(event);
  }).toList();
  valid.sort((a, b) {
    final created = (b['created_at'] as int).compareTo(a['created_at'] as int);
    return created != 0
        ? created
        : a['id'].toString().compareTo(b['id'].toString());
  });
  return valid.isEmpty ? null : valid.first;
}

class NStackRecoveryStatusStore {
  NStackRecoveryStatusStore({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();
  static const _prefix = 'wingman.nstack.recovery-status.v1.';
  final SharedPreferencesAsync _preferences;

  Future<Map<String, dynamic>?> load(String identity) async {
    final raw = await _preferences.getString('$_prefix${identity.trim()}');
    try {
      final decoded = raw == null ? null : jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String identity, Map<String, dynamic> status) {
    return _preferences.setString(
        '$_prefix${identity.trim()}', jsonEncode({'version': 1, ...status}));
  }
}

bool isNStackRecoveryRelay(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      (uri.scheme == 'wss' || uri.scheme == 'ws') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}
