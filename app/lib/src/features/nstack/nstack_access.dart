import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nstack_models.dart';
import 'nstack_store.dart';

const nstackSupportedCapabilities = <String>{
  'workspace.read',
  'storage.read',
  'storage.write',
  'events.read',
  'events.write',
};

class NStackException implements Exception {
  const NStackException(this.code, this.message);
  final String code;
  final String message;

  Map<String, String> toJson() => {'code': code, 'message': message};
  @override
  String toString() => '$code: $message';
}

class NStackDiscoveryGrant {
  const NStackDiscoveryGrant({
    required this.origin,
    required this.stackIds,
    required this.workspaceIds,
    required this.updatedAt,
  });

  final String origin;
  final Map<String, String> stackIds;
  final Map<String, String> workspaceIds;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'origin': origin,
        'stack_ids': stackIds,
        'workspace_ids': workspaceIds,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  static NStackDiscoveryGrant? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final origin = normalizeNStackOrigin(value['origin']?.toString() ?? '');
    final updatedAt = DateTime.tryParse(value['updated_at']?.toString() ?? '');
    if (origin.isEmpty || updatedAt == null) return null;
    Map<String, String>? map(Object? raw) {
      if (raw is! Map) return null;
      final result = <String, String>{};
      for (final entry in raw.entries) {
        final key = entry.key.toString().trim();
        final id = entry.value.toString().trim();
        if (key.isEmpty || id.isEmpty || result.containsValue(id)) return null;
        result[key] = id;
      }
      return result;
    }

    final stackIds = map(value['stack_ids']);
    final workspaceIds = map(value['workspace_ids']);
    if (stackIds == null || workspaceIds == null) return null;
    return NStackDiscoveryGrant(
      origin: origin,
      stackIds: Map.unmodifiable(stackIds),
      workspaceIds: Map.unmodifiable(workspaceIds),
      updatedAt: updatedAt.toUtc(),
    );
  }
}

class NStackGrantStore extends ChangeNotifier {
  NStackGrantStore({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const keyPrefix = 'wingman.nstack.discovery-grants.v1.';
  final SharedPreferencesAsync _preferences;
  final Map<String, Map<String, NStackDiscoveryGrant>> _cache = {};

  Future<List<NStackDiscoveryGrant>> list(String signerNpub) async {
    final grants = await _load(signerNpub);
    return List.unmodifiable(grants.values);
  }

  Future<NStackDiscoveryGrant?> find(String signerNpub, String origin) async {
    return (await _load(signerNpub))[normalizeNStackOrigin(origin)];
  }

  Future<void> put(String signerNpub, NStackDiscoveryGrant grant) async {
    final identity = signerNpub.trim();
    if (identity.isEmpty || grant.origin.isEmpty) {
      throw const NStackException('locked', 'Unlock a Nostr identity first.');
    }
    final grants =
        Map<String, NStackDiscoveryGrant>.from(await _load(identity));
    grants[grant.origin] = grant;
    await _save(identity, grants);
  }

  Future<void> revokeOrigin(String signerNpub, String origin) async {
    final identity = signerNpub.trim();
    final grants =
        Map<String, NStackDiscoveryGrant>.from(await _load(identity));
    grants.remove(normalizeNStackOrigin(origin));
    await _save(identity, grants);
  }

  Future<Map<String, NStackDiscoveryGrant>> _load(String signerNpub) async {
    final identity = signerNpub.trim();
    if (identity.isEmpty) return const {};
    final cached = _cache[identity];
    if (cached != null) return cached;
    final result = <String, NStackDiscoveryGrant>{};
    final raw = await _preferences.getString('$keyPrefix$identity');
    try {
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map<String, dynamic> &&
          decoded['version'] == 1 &&
          decoded['grants'] is List) {
        for (final item in decoded['grants'] as List) {
          final grant = NStackDiscoveryGrant.tryParse(item);
          if (grant != null) result[grant.origin] = grant;
        }
      }
    } catch (_) {/* Corrupt grants fail closed. */}
    _cache[identity] = result;
    return result;
  }

  Future<void> _save(
      String identity, Map<String, NStackDiscoveryGrant> grants) async {
    await _preferences.setString(
      '$keyPrefix$identity',
      jsonEncode({
        'version': 1,
        'grants': [for (final grant in grants.values) grant.toJson()],
      }),
    );
    _cache[identity] = grants;
    notifyListeners();
  }
}

class NStackCapabilityHandle {
  const NStackCapabilityHandle({
    required this.handle,
    required this.documentId,
    required this.origin,
    required this.identity,
    required this.stackInternalId,
    required this.stackId,
    required this.capabilities,
    required this.createdAt,
    required this.expiresAt,
    this.workspaceInternalId,
    this.workspaceId,
  });

  final String handle;
  final String documentId;
  final String origin;
  final String identity;
  final String stackInternalId;
  final String stackId;
  final String? workspaceInternalId;
  final String? workspaceId;
  final Set<String> capabilities;
  final DateTime createdAt;
  final DateTime expiresAt;
}

class NStackAccessService extends ChangeNotifier {
  NStackAccessService({
    required this.registryStore,
    required this.grantStore,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final NStackRegistryStore registryStore;
  final NStackGrantStore grantStore;
  final DateTime Function() _clock;
  final Map<String, NStackCapabilityHandle> _handles = {};

  List<NStackCapabilityHandle> get activeHandles {
    _pruneExpired();
    return List.unmodifiable(_handles.values);
  }

  Future<Map<String, dynamic>> applyDiscoveryDecision({
    required String identity,
    required String origin,
    required Set<String>? approvedStackInternalIds,
    required bool includeWorkspaces,
  }) {
    if (approvedStackInternalIds == null) {
      throw const NStackException(
          'consent_denied', 'NStack discovery was denied.');
    }
    return disclose(
      identity: identity,
      origin: origin,
      stackInternalIds: approvedStackInternalIds.toList(),
      includeWorkspaces: includeWorkspaces,
    );
  }

  Future<Map<String, dynamic>> disclose({
    required String identity,
    required String origin,
    required List<String> stackInternalIds,
    required bool includeWorkspaces,
  }) async {
    _requireIdentity(identity);
    final normalizedOrigin = _requireOrigin(origin);
    final registry = await registryStore.load(identity);
    final requested = stackInternalIds.toSet();
    if (requested.isEmpty ||
        requested.any((id) => !registry.stacks.any((s) => s.id == id))) {
      throw const NStackException(
          'invalid_request', 'Select at least one available NStack.');
    }
    final old = await grantStore.find(identity, normalizedOrigin);
    final stackIds = <String, String>{};
    final workspaceIds = <String, String>{};
    for (final stack
        in registry.stacks.where((s) => requested.contains(s.id))) {
      stackIds[stack.id] = old?.stackIds[stack.id] ?? newNStackOpaqueId();
      if (includeWorkspaces) {
        for (final workspace in stack.workspaces) {
          final key = '${stack.id}/${workspace.id}';
          workspaceIds[key] = old?.workspaceIds[key] ?? newNStackOpaqueId();
        }
      }
    }
    final grant = NStackDiscoveryGrant(
      origin: normalizedOrigin,
      stackIds: Map.unmodifiable(stackIds),
      workspaceIds: Map.unmodifiable(workspaceIds),
      updatedAt: _clock().toUtc(),
    );
    await grantStore.put(identity, grant);
    notifyListeners();
    return {'disclosed': stackIds.length, 'workspaces': includeWorkspaces};
  }

  Future<List<Map<String, dynamic>>> listNStacks(
      String identity, String origin) async {
    final state = await _state(identity, origin);
    final registry = state.$1;
    final grant = state.$2;
    return [
      for (final stack in registry.stacks)
        if (grant.stackIds[stack.id] case final opaque?)
          {
            'id': opaque,
            'name': stack.name,
            'host': registry.hostStackId == stack.id,
            'available': true,
          },
    ];
  }

  Future<List<Map<String, dynamic>>> listWorkspaces({
    required String identity,
    required String origin,
    required String stackId,
  }) async {
    final state = await _state(identity, origin);
    final internalStackId = _internalId(state.$2.stackIds, stackId);
    if (internalStackId == null) {
      throw const NStackException(
          'not_disclosed', 'The NStack was not disclosed to this origin.');
    }
    final stack =
        state.$1.stacks.where((s) => s.id == internalStackId).firstOrNull;
    if (stack == null) {
      throw const NStackException(
          'stack_unavailable', 'The disclosed NStack is no longer available.');
    }
    return [
      for (final workspace in stack.workspaces)
        if (state.$2.workspaceIds['${stack.id}/${workspace.id}']
            case final opaque?)
          {'id': opaque, 'name': workspace.name},
    ];
  }

  Future<Map<String, dynamic>> createHandle({
    required String documentId,
    required String identity,
    required String origin,
    required String stackId,
    required List<String> capabilities,
    String? workspaceId,
    Duration duration = const Duration(minutes: 15),
  }) async {
    if (documentId.trim().isEmpty) {
      throw const NStackException('stale_handle', 'Document was revoked.');
    }
    final requested = capabilities.toSet();
    if (requested.isEmpty) {
      throw const NStackException(
          'invalid_request', 'At least one capability is required.');
    }
    final unsupported = requested.difference(nstackSupportedCapabilities);
    if (unsupported.isNotEmpty) {
      throw NStackException('unsupported_capability',
          'Unsupported capability: ${unsupported.first}.');
    }
    if (duration <= Duration.zero || duration > const Duration(hours: 8)) {
      throw const NStackException(
          'invalid_request', 'Duration must be between 1 second and 8 hours.');
    }
    final state = await _state(identity, origin);
    final internalStackId = _internalId(state.$2.stackIds, stackId);
    if (internalStackId == null) {
      throw const NStackException(
          'not_disclosed', 'The NStack was not disclosed to this origin.');
    }
    final stack =
        state.$1.stacks.where((s) => s.id == internalStackId).firstOrNull;
    if (stack == null) {
      throw const NStackException(
          'stack_unavailable', 'The NStack is no longer available.');
    }
    String? internalWorkspaceId;
    if (workspaceId != null) {
      final scoped = <String, String>{
        for (final entry in state.$2.workspaceIds.entries)
          if (entry.key.startsWith('$internalStackId/')) entry.key: entry.value,
      };
      final internalKey = _internalId(scoped, workspaceId);
      if (internalKey == null) {
        throw const NStackException(
            'not_disclosed', 'The workspace was not disclosed to this origin.');
      }
      internalWorkspaceId = internalKey.split('/').last;
      if (!stack.workspaces.any((w) => w.id == internalWorkspaceId)) {
        throw const NStackException('stack_unavailable',
            'The disclosed workspace is no longer available.');
      }
    }
    final now = _clock().toUtc();
    final token = newNStackOpaqueId();
    final handle = NStackCapabilityHandle(
      handle: token,
      documentId: documentId,
      origin: normalizeNStackOrigin(origin),
      identity: identity,
      stackInternalId: stack.id,
      stackId: stackId,
      workspaceInternalId: internalWorkspaceId,
      workspaceId: workspaceId,
      capabilities: Set.unmodifiable(requested),
      createdAt: now,
      expiresAt: now.add(duration),
    );
    _handles[token] = handle;
    notifyListeners();
    return {
      'handle': token,
      'stackId': stackId,
      if (workspaceId != null) 'workspaceId': workspaceId,
      'capabilities': requested.toList()..sort(),
      'expiresAt': handle.expiresAt.toIso8601String(),
      'connection': {
        'transport': 'https',
        'url': stack.url,
        if (stack.fipsEndpoint != null) ...{
          'fipsEndpoint': stack.fipsEndpoint,
          'peerNpub': stack.peerNpub,
        },
      },
    };
  }

  void revokeHandle({
    required String documentId,
    required String identity,
    required String origin,
    required String handle,
  }) {
    final active = _handles[handle];
    if (active == null ||
        active.documentId != documentId ||
        active.identity != identity ||
        active.origin != normalizeNStackOrigin(origin)) {
      throw const NStackException(
          'stale_handle', 'Capability handle is stale or revoked.');
    }
    _handles.remove(handle);
    notifyListeners();
  }

  void revokeDocument(String documentId) {
    final before = _handles.length;
    _handles.removeWhere((_, value) => value.documentId == documentId);
    if (_handles.length != before) notifyListeners();
  }

  void revokeFromManagement(String handle) {
    if (_handles.remove(handle) != null) notifyListeners();
  }

  Future<void> revokeOrigin(String identity, String origin) async {
    final normalized = normalizeNStackOrigin(origin);
    await grantStore.revokeOrigin(identity, normalized);
    final before = _handles.length;
    _handles.removeWhere(
        (_, value) => value.identity == identity && value.origin == normalized);
    if (_handles.length != before) notifyListeners();
  }

  void revokeIdentity(String identity) {
    final before = _handles.length;
    _handles.removeWhere((_, value) => value.identity == identity);
    if (_handles.length != before) notifyListeners();
  }

  void revokeStack(String stackInternalId) {
    final before = _handles.length;
    _handles
        .removeWhere((_, value) => value.stackInternalId == stackInternalId);
    if (_handles.length != before) notifyListeners();
  }

  Future<(NStackRegistry, NStackDiscoveryGrant)> _state(
      String identity, String origin) async {
    _requireIdentity(identity);
    final normalizedOrigin = _requireOrigin(origin);
    final grant = await grantStore.find(identity, normalizedOrigin);
    if (grant == null) {
      throw const NStackException(
          'not_disclosed', 'Request NStack discovery first.');
    }
    return (await registryStore.load(identity), grant);
  }

  void _pruneExpired() {
    final now = _clock().toUtc();
    _handles.removeWhere((_, value) => !value.expiresAt.isAfter(now));
  }

  void _requireIdentity(String identity) {
    if (identity.trim().isEmpty) {
      throw const NStackException('locked', 'Unlock a Nostr identity first.');
    }
  }

  String _requireOrigin(String origin) {
    final normalized = normalizeNStackOrigin(origin);
    if (normalized.isEmpty) {
      throw const NStackException(
          'invalid_request', 'A verified HTTPS or local origin is required.');
    }
    return normalized;
  }
}

String? _internalId(Map<String, String> ids, String opaque) {
  for (final entry in ids.entries) {
    if (entry.value == opaque) return entry.key;
  }
  return null;
}

String normalizeNStackOrigin(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return '';
  final scheme = uri.scheme.toLowerCase();
  final local = {'localhost', '127.0.0.1', '::1', 'wingman.local'}
      .contains(uri.host.toLowerCase());
  if (scheme != 'https' && !(scheme == 'http' && local)) return '';
  return uri
      .replace(
        scheme: scheme,
        host: uri.host.toLowerCase(),
        path: '',
        query: '',
        fragment: '',
      )
      .toString();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
