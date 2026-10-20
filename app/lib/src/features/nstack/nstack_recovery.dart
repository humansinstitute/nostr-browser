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
    this.workspaceOwnerNpub,
  });

  final String hostUrl;
  final String? workspaceId;
  final String? workspaceOwnerNpub;
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
        if (workspaceOwnerNpub != null)
          'workspace_owner_npub': workspaceOwnerNpub,
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
    final workspaceOwnerNpub = value['workspace_owner_npub']?.toString().trim();
    return NStackRecoveryPointer(
      hostUrl: hostUrl,
      workspaceId:
          workspaceId == null || workspaceId.isEmpty ? null : workspaceId,
      workspaceOwnerNpub:
          workspaceOwnerNpub == null || workspaceOwnerNpub.isEmpty
              ? null
              : workspaceOwnerNpub,
      objectId: objectId,
      sha256: hash,
      snapshotRevision: revision,
      updatedAt: updatedAt.toUtc(),
      relays: relays,
    );
  }
}

class NStackBackupTarget {
  const NStackBackupTarget({
    required this.hostUrl,
    required this.workspaceId,
    required this.workspaceOwnerNpub,
    required this.identityNpub,
    required this.canManageNamespace,
  });

  final String hostUrl;
  final String workspaceId;
  final String workspaceOwnerNpub;
  final String identityNpub;
  final bool canManageNamespace;
}

enum NStackBackupNamespaceState { enabled, managerRequired }

class NStackStorageException implements Exception {
  const NStackStorageException(this.code, this.message, {this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

abstract class NStackStorageClient {
  Future<NStackBackupNamespaceState> namespaceState({
    required NStackBackupTarget target,
    required String secret,
  });

  Future<void> enableNamespace({
    required NStackBackupTarget target,
    required String secret,
  });

  Future<NStackRecoveryPointer> upload({
    required NStackBackupTarget target,
    required String secret,
    required List<int> bytes,
    required String sha256,
    required int snapshotRevision,
    required DateTime updatedAt,
    required List<String> relays,
  });

  Future<NStackRecoveryPointer> readPointer({
    required NStackBackupTarget target,
    required String secret,
    required List<String> relays,
  });

  Future<List<int>> fetchObject({
    required NStackBackupTarget target,
    required NStackRecoveryPointer pointer,
    required String secret,
  });
}

class TowerNStackStorageClient implements NStackStorageClient {
  TowerNStackStorageClient({http.Client? client})
      : _client = client ?? http.Client();
  final http.Client _client;

  @override
  Future<NStackBackupNamespaceState> namespaceState({
    required NStackBackupTarget target,
    required String secret,
  }) async {
    final root = _root(target, secret);
    try {
      final response = await _jsonRequest(
        method: 'GET',
        url: _rowsUrl(root, target.workspaceId),
        secret: secret,
      );
      _validateWorkspaceBinding(response, target);
      return NStackBackupNamespaceState.enabled;
    } on NStackStorageException catch (error) {
      if (error.statusCode == 404 && error.code == 'app_not_found') {
        return NStackBackupNamespaceState.managerRequired;
      }
      rethrow;
    }
  }

  @override
  Future<void> enableNamespace({
    required NStackBackupTarget target,
    required String secret,
  }) async {
    if (!target.canManageNamespace) {
      throw const NStackStorageException(
        'workspace_manager_required',
        'A workspace manager must enable NBrowser backup for this workspace.',
        statusCode: 403,
      );
    }
    final root = _root(target, secret);
    final url = '$root/api/v4/workspaces/'
        '${Uri.encodeComponent(target.workspaceOwnerNpub)}/apps';
    final body = jsonEncode({
      'app_npub': nbrowserAppNpub,
      'app_name': 'NBrowser',
      'enabled': true,
      'capabilities': ['storage.private', 'app_rows.private_only'],
    });
    try {
      await _jsonRequest(method: 'POST', url: url, secret: secret, body: body);
    } on NStackStorageException catch (error) {
      if (error.statusCode == 403) {
        throw const NStackStorageException(
          'workspace_manager_required',
          'A workspace manager must enable NBrowser backup for this workspace.',
          statusCode: 403,
        );
      }
      rethrow;
    }
    if (await namespaceState(target: target, secret: secret) !=
        NStackBackupNamespaceState.enabled) {
      throw const NStackStorageException(
        'app_not_found',
        'Tower did not enable the NBrowser backup namespace.',
      );
    }
  }

  @override
  Future<NStackRecoveryPointer> upload({
    required NStackBackupTarget target,
    required String secret,
    required List<int> bytes,
    required String sha256,
    required int snapshotRevision,
    required DateTime updatedAt,
    required List<String> relays,
  }) async {
    final root = _root(target, secret);
    if (await namespaceState(target: target, secret: secret) !=
        NStackBackupNamespaceState.enabled) {
      throw const NStackStorageException(
        'app_not_found',
        'A workspace manager must enable NBrowser backup for this workspace.',
        statusCode: 404,
      );
    }
    final prepareUrl = '$root/api/v4/flightdeck-pg/workspaces/'
        '${target.workspaceId}/storage/prepare';
    final prepareBody = jsonEncode({
      'content_type': 'application/vnd.wingman.nbrowser-settings+json',
      'file_name': 'nbrowser-settings.nip44',
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
      throw const NStackStorageException(
          'invalid_response', 'Tower returned an invalid storage object.');
    }
    if (prepared['owner_npub'] != target.workspaceOwnerNpub) {
      throw const NStackStorageException('workspace_mismatch',
          'Tower prepared storage outside the selected workspace.');
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
    final completeBody =
        jsonEncode({'sha256_hex': sha256, 'size_bytes': bytes.length});
    await _jsonRequest(
      method: 'POST',
      url: completeUrl,
      secret: secret,
      body: completeBody,
    );
    await _verifyObjectMetadata(
      root: root,
      objectId: objectId,
      secret: secret,
      expectedSha256: sha256,
    );
    final pointerData = {
      'schema_version': 1,
      'workspace_id': target.workspaceId,
      'object_id': objectId,
      'sha256_hex': sha256,
      'status': 'complete',
      'snapshot_revision': snapshotRevision,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
    final rowsUrl = _rowsUrl(root, target.workspaceId);
    final createBody = jsonEncode({
      'row_id': 'current-v1',
      'visibility': 'private',
      'data': pointerData,
    });
    Map<String, dynamic> rowResponse;
    try {
      rowResponse = await _jsonRequest(
          method: 'POST', url: rowsUrl, secret: secret, body: createBody);
    } on NStackStorageException catch (error) {
      if (error.statusCode != 409 || error.code != 'row_conflict') rethrow;
      final existing = await _jsonRequest(
        method: 'GET',
        url: '$rowsUrl/current-v1',
        secret: secret,
      );
      _validateWorkspaceBinding(existing, target);
      rowResponse = await _jsonRequest(
        method: 'PATCH',
        url: '$rowsUrl/current-v1',
        secret: secret,
        body: jsonEncode({'visibility': 'private', 'data': pointerData}),
      );
    }
    _validateWorkspaceBinding(rowResponse, target);
    _validatePointerRow(rowResponse, target, objectId, sha256);
    return NStackRecoveryPointer(
      hostUrl: root,
      workspaceId: target.workspaceId,
      workspaceOwnerNpub: target.workspaceOwnerNpub,
      objectId: objectId,
      sha256: sha256,
      snapshotRevision: snapshotRevision,
      updatedAt: updatedAt.toUtc(),
      relays: relays,
    );
  }

  @override
  Future<NStackRecoveryPointer> readPointer({
    required NStackBackupTarget target,
    required String secret,
    required List<String> relays,
  }) async {
    final root = _root(target, secret);
    final response = await _jsonRequest(
      method: 'GET',
      url: '${_rowsUrl(root, target.workspaceId)}/current-v1',
      secret: secret,
    );
    _validateWorkspaceBinding(response, target);
    final row = response['row'];
    final data = row is Map<String, dynamic> ? row['data'] : null;
    if (row is! Map<String, dynamic> ||
        row['row_id'] != 'current-v1' ||
        row['owner_npub'] != target.identityNpub ||
        row['visibility'] != 'private' ||
        data is! Map<String, dynamic> ||
        data['schema_version'] != 1 ||
        data['workspace_id'] != target.workspaceId ||
        data['status'] != 'complete') {
      throw const NStackStorageException(
          'pointer_mismatch', 'Tower returned an invalid backup pointer.');
    }
    final objectId = data['object_id']?.toString() ?? '';
    final hash = data['sha256_hex']?.toString().toLowerCase() ?? '';
    final revision = data['snapshot_revision'];
    final updatedAt = DateTime.tryParse(data['updated_at']?.toString() ?? '');
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(objectId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        revision is! int ||
        revision < 0 ||
        updatedAt == null) {
      throw const NStackStorageException(
          'pointer_mismatch', 'Tower returned an invalid backup pointer.');
    }
    return NStackRecoveryPointer(
      hostUrl: root,
      workspaceId: target.workspaceId,
      workspaceOwnerNpub: target.workspaceOwnerNpub,
      objectId: objectId,
      sha256: hash,
      snapshotRevision: revision,
      updatedAt: updatedAt.toUtc(),
      relays: relays,
    );
  }

  @override
  Future<List<int>> fetchObject({
    required NStackBackupTarget target,
    required NStackRecoveryPointer pointer,
    required String secret,
  }) async {
    final root = _root(target, secret);
    if (pointer.hostUrl != root ||
        pointer.workspaceId != target.workspaceId ||
        pointer.workspaceOwnerNpub != target.workspaceOwnerNpub) {
      throw const NStackStorageException('workspace_mismatch',
          'The backup pointer does not match the selected workspace.');
    }
    await _verifyObjectMetadata(
      root: root,
      objectId: pointer.objectId,
      secret: secret,
      expectedSha256: pointer.sha256,
    );
    final contentUrl = '$root/api/v4/storage/${pointer.objectId}/content';
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
      throw NStackStorageException('storage_fetch_failed',
          'Tower recovery fetch failed (${response.statusCode}).',
          statusCode: response.statusCode);
    }
    if (NostrCrypto.sha256Hex(response.bodyBytes) != pointer.sha256) {
      throw const NStackStorageException(
          'hash_mismatch', 'Recovery object bytes failed hash verification.');
    }
    return response.bodyBytes;
  }

  String _root(NStackBackupTarget target, String secret) {
    final root = canonicalNStackUrl(target.hostUrl);
    NostrIdentity? signer;
    try {
      signer = NostrCrypto.importIdentity(secret);
    } catch (_) {}
    if (root == null ||
        !isWorkspaceUuid(target.workspaceId) ||
        signer?.npub != target.identityNpub) {
      throw const NStackStorageException(
          'invalid_destination', 'The selected backup workspace is invalid.');
    }
    return root;
  }

  String _rowsUrl(String root, String workspaceId) =>
      '$root/api/v4/flightdeck-pg/workspaces/$workspaceId/apps/'
      '$nbrowserAppNpub/db/settings-backups/rows';

  Future<void> _verifyObjectMetadata({
    required String root,
    required String objectId,
    required String secret,
    required String expectedSha256,
  }) async {
    final metadata = await _jsonRequest(
      method: 'GET',
      url: '$root/api/v4/storage/$objectId',
      secret: secret,
    );
    if (metadata['sha256_hex']?.toString().toLowerCase() != expectedSha256 ||
        metadata['completed_at'] == null ||
        metadata['is_public'] == true) {
      throw const NStackStorageException(
          'hash_mismatch', 'Recovery object metadata or hash does not match.');
    }
  }

  void _validateWorkspaceBinding(
      Map<String, dynamic> response, NStackBackupTarget target) {
    if (response['workspace_id'] != target.workspaceId ||
        response['workspace_owner_npub'] != target.workspaceOwnerNpub) {
      throw const NStackStorageException('workspace_mismatch',
          'Tower response does not match the selected workspace.');
    }
  }

  void _validatePointerRow(Map<String, dynamic> response,
      NStackBackupTarget target, String objectId, String sha256) {
    final row = response['row'];
    final data = row is Map<String, dynamic> ? row['data'] : null;
    if (row is! Map<String, dynamic> ||
        row['row_id'] != 'current-v1' ||
        row['owner_npub'] != target.identityNpub ||
        row['visibility'] != 'private' ||
        data is! Map<String, dynamic> ||
        data['workspace_id'] != target.workspaceId ||
        data['object_id'] != objectId ||
        data['sha256_hex'] != sha256 ||
        data['status'] != 'complete') {
      throw const NStackStorageException(
          'pointer_mismatch', 'Tower returned an invalid backup pointer.');
    }
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
      String code = 'tower_request_failed';
      String? message;
      try {
        final error = jsonDecode(response.body);
        if (error is Map<String, dynamic>) {
          code = error['code']?.toString() ?? code;
          message = error['error']?.toString() ?? error['message']?.toString();
        }
      } catch (_) {}
      if (response.statusCode == 403) {
        message ??=
            'Workspace access was denied. Refresh access or ask a workspace manager to enable NBrowser backup.';
      }
      throw NStackStorageException(
        code,
        message ?? 'Tower request failed (${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const NStackStorageException(
          'invalid_response', 'Tower returned malformed JSON.');
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

  Future<NStackBackupNamespaceState> namespaceState({
    required String identityNpub,
    required String secret,
  }) async {
    _verifyIdentity(identityNpub, null, secret);
    final target =
        _selectedTarget(await registryStore.load(identityNpub), identityNpub);
    return storage.namespaceState(target: target, secret: secret);
  }

  Future<void> enableNamespace({
    required String identityNpub,
    required String secret,
  }) async {
    _verifyIdentity(identityNpub, null, secret);
    final target =
        _selectedTarget(await registryStore.load(identityNpub), identityNpub);
    await storage.enableNamespace(target: target, secret: secret);
  }

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
        if (error is NStackStorageException) 'error_code': error.code,
        'error_message': error.toString(),
      });
      rethrow;
    }
  }

  Future<NStackRelayPublishResult> _publish({
    required String identityNpub,
    required String publicKeyHex,
    required String secret,
  }) async {
    _verifyIdentity(identityNpub, publicKeyHex, secret);
    final registry = await registryStore.load(identityNpub);
    final target = _selectedTarget(registry, identityNpub);
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
    final pointer = await storage.upload(
      target: target,
      secret: secret,
      bytes: bytes,
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
      'last_published_object_id': pointer.objectId,
      'workspace_id': target.workspaceId,
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
    _verifyIdentity(identityNpub, publicKeyHex, secret);
    final current = await registryStore.load(identityNpub);
    final target = _selectedTarget(current, identityNpub);
    final pointer = await storage.readPointer(
      target: target,
      secret: secret,
      relays: relay.relays,
    );
    final bytes = await storage.fetchObject(
      target: target,
      pointer: pointer,
      secret: secret,
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
    if (snapshot.createdAt != pointer.updatedAt) {
      throw StateError('Recovery pointer and snapshot timestamps conflict.');
    }
    if (current.revision > pointer.snapshotRevision) {
      throw StateError(
          'Recovery snapshot is older than current local settings.');
    }
    var event = <String, dynamic>{};
    final candidate = selectLatestValidHint(
      await relay.fetchHints(publicKeyHex),
      publicKeyHex,
    );
    if (candidate != null) {
      try {
        final hintJson = await nip44.decrypt(
          secret: secret,
          peerPublicKeyHex: publicKeyHex,
          payload: candidate['content'].toString(),
        );
        final hint = NStackRecoveryPointer.parse(hintJson);
        final eventTime = DateTime.fromMillisecondsSinceEpoch(
          (candidate['created_at'] as int) * 1000,
          isUtc: true,
        );
        if (hint.hostUrl == pointer.hostUrl &&
            hint.workspaceId == pointer.workspaceId &&
            (hint.workspaceOwnerNpub == null ||
                hint.workspaceOwnerNpub == pointer.workspaceOwnerNpub) &&
            hint.objectId == pointer.objectId &&
            hint.sha256 == pointer.sha256 &&
            hint.snapshotRevision == pointer.snapshotRevision &&
            eventTime.millisecondsSinceEpoch ~/ 1000 ==
                pointer.updatedAt.millisecondsSinceEpoch ~/ 1000) {
          event = Map<String, dynamic>.from(candidate);
        }
      } catch (_) {
        // The workspace row is authoritative. A legacy or malformed hint can
        // neither select another workspace nor block a valid row recovery.
      }
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
      if (preview.event['id'] != null)
        'last_restored_event_id': preview.event['id'],
      'last_restored_object_id': preview.pointer.objectId,
      'success': true,
    });
  }

  void _verifyIdentity(
      String identityNpub, String? publicKeyHex, String secret) {
    final identity = NostrCrypto.importIdentity(secret);
    if (identity.npub != identityNpub ||
        (publicKeyHex != null && identity.publicKeyHex != publicKeyHex)) {
      throw StateError(
          'Unlock the matching identity before backup or recovery.');
    }
  }

  NStackBackupTarget _selectedTarget(
      NStackRegistry registry, String identityNpub) {
    final destination = registry.backupDestination;
    final stack = registry.backupStack;
    final workspace = registry.backupWorkspace;
    if (destination == null) {
      throw StateError('Choose a backup workspace first.');
    }
    if (stack == null ||
        workspace == null ||
        !registry.backupDestinationAvailable) {
      throw StateError(
          'The selected backup workspace is unavailable. Refresh access or choose another workspace.');
    }
    return NStackBackupTarget(
      hostUrl: workspace.directHttpsUrl!,
      workspaceId: destination.workspaceRemoteId,
      workspaceOwnerNpub: destination.workspaceOwnerNpub,
      identityNpub: identityNpub,
      canManageNamespace: workspace.canManageBackupNamespace,
    );
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
