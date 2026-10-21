import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/nostr_crypto.dart';
import 'nstack_models.dart';
import 'nstack_store.dart';

const nstackWorkspaceResponseMaxBytes = 256 * 1024;
const nstackWorkspaceDiscoveryTimeout = Duration(seconds: 10);
const nstackFlightDeckWorkspacePageSize = 200;
const nstackFlightDeckWorkspaceTotalLimit = 1000;
const nstackFlightDeckWorkspacePageLimit = 10;
const nstackFlightDeckCursorMaxLength = 4096;

class NStackWorkspaceDiscoveryException implements Exception {
  const NStackWorkspaceDiscoveryException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

abstract class NStackWorkspaceDiscovery {
  Future<List<NStackWorkspace>> discover({
    required String address,
    required String identityNpub,
    required String secret,
  });
}

class TowerNStackWorkspaceDiscovery implements NStackWorkspaceDiscovery {
  TowerNStackWorkspaceDiscovery({
    http.Client? client,
    this.timeout = nstackWorkspaceDiscoveryTimeout,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  @override
  Future<List<NStackWorkspace>> discover({
    required String address,
    required String identityNpub,
    required String secret,
  }) async {
    final root = canonicalNStackUrl(address);
    if (root == null) {
      throw const NStackWorkspaceDiscoveryException(
          'invalid_address', 'Enter a valid HTTPS NStack address.');
    }
    NostrIdentity signer;
    try {
      signer = NostrCrypto.importIdentity(secret);
    } catch (_) {
      throw const NStackWorkspaceDiscoveryException(
          'locked', 'Unlock the active Nostr identity first.');
    }
    if (signer.npub != identityNpub) {
      throw const NStackWorkspaceDiscoveryException('identity_changed',
          'The unlocked identity changed before discovery.');
    }

    final rootUri = Uri.parse(root);
    final basePath = rootUri.path.replaceFirst(RegExp(r'/+$'), '');
    final legacyUrl = rootUri.replace(
      path: '$basePath/api/v4/workspaces',
      queryParameters: {'member_npub': identityNpub},
    );
    try {
      final legacy = validateWorkspaceDiscoveryResponse(
        await _getJson(legacyUrl, secret),
      );
      final flightDeck = await _discoverFlightDeckWorkspaces(
        rootUri: rootUri,
        basePath: basePath,
        secret: secret,
      );
      return _mergeWorkspaceSources(legacy, flightDeck);
    } on NStackWorkspaceDiscoveryException {
      rethrow;
    } on TimeoutException {
      throw const NStackWorkspaceDiscoveryException(
          'timeout', 'Workspace discovery timed out.');
    } catch (_) {
      throw const NStackWorkspaceDiscoveryException(
          'network_error', 'NStack workspace discovery failed.');
    }
  }

  Future<List<_FlightDeckWorkspace>> _discoverFlightDeckWorkspaces({
    required Uri rootUri,
    required String basePath,
    required String secret,
  }) async {
    final result = <_FlightDeckWorkspace>[];
    final workspaceIds = <String>{};
    final stableRemoteIds = <String>{};
    final cursors = <String>{};
    String? cursor;
    for (var pageNumber = 0;
        pageNumber < nstackFlightDeckWorkspacePageLimit;
        pageNumber++) {
      final url = rootUri.replace(
        path: '$basePath/api/v4/flightdeck-pg/workspaces',
        queryParameters: {
          'limit': '$nstackFlightDeckWorkspacePageSize',
          if (cursor != null) 'cursor': cursor,
        },
      );
      Object? response;
      try {
        response = await _getJson(
          url,
          secret,
          allowUnsupportedEndpoint: pageNumber == 0,
        );
      } on NStackWorkspaceDiscoveryException catch (error) {
        if (pageNumber == 0 && error.code == 'unsupported_endpoint') {
          return const [];
        }
        rethrow;
      }
      final page = _validateFlightDeckWorkspaceDiscoveryResponse(
        response,
        verifiedTowerRoot: rootUri,
      );
      for (final item in page.workspaces) {
        if (!workspaceIds.add(item.workspace.remoteId)) {
          throw const NStackWorkspaceDiscoveryException('invalid_response',
              'NStack returned a duplicate Flight Deck workspace.');
        }
        if (!stableRemoteIds.add(item.workspace.stableRemoteId!)) {
          throw const NStackWorkspaceDiscoveryException('invalid_response',
              'NStack returned a duplicate linked workspace identity.');
        }
        result.add(item);
        if (result.length > nstackFlightDeckWorkspaceTotalLimit) {
          throw const NStackWorkspaceDiscoveryException('invalid_response',
              'NStack returned too many Flight Deck workspaces.');
        }
      }
      cursor = page.nextCursor;
      if (cursor == null) return List.unmodifiable(result);
      if (!cursors.add(cursor)) {
        throw const NStackWorkspaceDiscoveryException('invalid_response',
            'NStack repeated a Flight Deck workspace cursor.');
      }
      if (result.length >= nstackFlightDeckWorkspaceTotalLimit) {
        throw const NStackWorkspaceDiscoveryException('invalid_response',
            'NStack Flight Deck workspace response exceeded the total limit.');
      }
    }
    throw const NStackWorkspaceDiscoveryException('invalid_response',
        'NStack Flight Deck workspace response exceeded the page limit.');
  }

  Future<Object?> _getJson(
    Uri url,
    String secret, {
    bool allowUnsupportedEndpoint = false,
  }) async {
    final authorization = NostrCrypto.signNip98(
      secret: secret,
      method: 'GET',
      url: url.toString(),
    ).authorization;
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      'GET',
      url,
      abortTrigger: abort.future,
    )
      ..followRedirects = false
      ..headers['accept'] = 'application/json'
      ..headers['authorization'] = authorization;
    try {
      final bytes = await _read(
        request,
        allowUnsupportedEndpoint: allowUnsupportedEndpoint,
      ).timeout(timeout, onTimeout: () {
        abort.complete();
        throw TimeoutException('Workspace discovery timed out.');
      });
      try {
        return jsonDecode(utf8.decode(bytes));
      } catch (_) {
        throw const NStackWorkspaceDiscoveryException(
            'invalid_response', 'NStack returned malformed workspace data.');
      }
    } on NStackWorkspaceDiscoveryException {
      rethrow;
    } on TimeoutException {
      throw const NStackWorkspaceDiscoveryException(
          'timeout', 'Workspace discovery timed out.');
    } catch (_) {
      throw const NStackWorkspaceDiscoveryException(
          'network_error', 'NStack workspace discovery failed.');
    }
  }

  Future<List<int>> _read(
    http.BaseRequest request, {
    required bool allowUnsupportedEndpoint,
  }) async {
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      if (allowUnsupportedEndpoint &&
          const {404, 405, 501}.contains(response.statusCode)) {
        throw const NStackWorkspaceDiscoveryException('unsupported_endpoint',
            'This NStack does not expose Flight Deck workspace discovery.');
      }
      throw NStackWorkspaceDiscoveryException('http_error',
          'NStack returned HTTP ${response.statusCode} during discovery.');
    }
    if (response.contentLength case final length?
        when length > nstackWorkspaceResponseMaxBytes) {
      throw const NStackWorkspaceDiscoveryException(
          'invalid_response', 'Workspace response is too large.');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      bytes.addAll(chunk);
      if (bytes.length > nstackWorkspaceResponseMaxBytes) {
        throw const NStackWorkspaceDiscoveryException(
            'invalid_response', 'Workspace response is too large.');
      }
    }
    return bytes;
  }
}

List<NStackWorkspace> validateWorkspaceDiscoveryResponse(Object? value) {
  if (value is! Map<String, dynamic> || value['workspaces'] is! List) {
    throw const NStackWorkspaceDiscoveryException(
        'invalid_response', 'NStack workspace response has an invalid shape.');
  }
  final rawWorkspaces = value['workspaces'] as List;
  if (rawWorkspaces.length > 1000) {
    throw const NStackWorkspaceDiscoveryException(
        'invalid_response', 'NStack returned too many workspaces.');
  }
  final result = <NStackWorkspace>[];
  final stableIds = <String>{};
  for (final raw in rawWorkspaces) {
    if (raw is! Map<String, dynamic>) {
      throw const NStackWorkspaceDiscoveryException(
          'invalid_response', 'NStack returned an invalid workspace.');
    }
    final workspaceId = _safeText(raw['workspace_id'], 128);
    final name = _safeText(raw['name'], 256);
    final owner =
        _validNpub(raw['creator_npub'] ?? raw['workspace_owner_npub']);
    final workspaceService =
        _validNpub(raw['workspace_service_npub'] ?? raw['workspace_npub']);
    final directUrl = raw['direct_https_url'] == null
        ? null
        : canonicalNStackUrl(raw['direct_https_url'].toString());
    final service =
        raw['service_npub'] == null ? null : _validNpub(raw['service_npub']);
    if (workspaceId == null ||
        name == null ||
        owner == null ||
        workspaceService == null ||
        (raw['direct_https_url'] != null && directUrl == null) ||
        (raw['service_npub'] != null && service == null) ||
        !stableIds.add(workspaceId)) {
      throw const NStackWorkspaceDiscoveryException('invalid_response',
          'NStack returned incomplete, invalid, or duplicate workspace identity.');
    }
    result.add(NStackWorkspace(
      id: '',
      name: name,
      remoteId: workspaceId,
      stableRemoteId: workspaceId,
      workspaceOwnerNpub: owner,
      workspaceServiceNpub: workspaceService,
      directHttpsUrl: directUrl,
      serviceNpub: service,
    ));
  }
  return List.unmodifiable(result);
}

class _FlightDeckWorkspace {
  const _FlightDeckWorkspace({
    required this.workspace,
    this.v4WorkspaceId,
  });

  final NStackWorkspace workspace;
  final String? v4WorkspaceId;
}

class _FlightDeckWorkspacePage {
  const _FlightDeckWorkspacePage({
    required this.workspaces,
    required this.nextCursor,
  });

  final List<_FlightDeckWorkspace> workspaces;
  final String? nextCursor;
}

_FlightDeckWorkspacePage _validateFlightDeckWorkspaceDiscoveryResponse(
  Object? value, {
  required Uri verifiedTowerRoot,
}) {
  if (value is! Map<String, dynamic> || value['workspaces'] is! List) {
    throw const NStackWorkspaceDiscoveryException('invalid_response',
        'NStack Flight Deck workspace response has an invalid shape.');
  }
  final nextCursor = value['next_cursor'] == null
      ? null
      : _safeText(value['next_cursor'], nstackFlightDeckCursorMaxLength);
  if (value['next_cursor'] != null && nextCursor == null) {
    throw const NStackWorkspaceDiscoveryException('invalid_response',
        'NStack returned an invalid Flight Deck workspace cursor.');
  }
  final rawWorkspaces = value['workspaces'] as List;
  if (rawWorkspaces.length > nstackFlightDeckWorkspacePageSize) {
    throw const NStackWorkspaceDiscoveryException(
        'invalid_response', 'NStack returned an oversized workspace page.');
  }
  final result = <_FlightDeckWorkspace>[];
  final workspaceIds = <String>{};
  final stableIds = <String>{};
  var omitted = 0;
  for (final raw in rawWorkspaces) {
    if (raw is! Map<String, dynamic> ||
        raw['identity'] is! Map<String, dynamic>) {
      omitted++;
      continue;
    }
    final identity = raw['identity'] as Map<String, dynamic>;
    final workspaceId = _safeText(identity['workspace_id'], 128);
    if (workspaceId != null && !workspaceIds.add(workspaceId)) {
      throw const NStackWorkspaceDiscoveryException('invalid_response',
          'NStack returned a duplicate Flight Deck workspace identity.');
    }
    final name = _safeText(raw['label'], 256);
    final owner = _validNpub(identity['workspace_owner_npub']);
    final workspaceService = _validNpub(identity['workspace_service_npub']);
    final service = _validNpub(identity['tower_service_npub']);
    final membership = raw['membership'];
    final membershipRole = membership is Map<String, dynamic>
        ? _safeText(membership['role'], 32)
        : null;
    final v4WorkspaceId = raw['v4_workspace_id'] == null
        ? null
        : _safeText(raw['v4_workspace_id'], 128);
    final stableId = v4WorkspaceId ?? workspaceId;
    if (stableId != null && !stableIds.add(stableId)) {
      throw const NStackWorkspaceDiscoveryException('invalid_response',
          'NStack returned a duplicate linked Flight Deck workspace identity.');
    }
    if (workspaceId == null ||
        name == null ||
        owner == null ||
        workspaceService == null ||
        service == null ||
        membershipRole == null ||
        (raw['v4_workspace_id'] != null && v4WorkspaceId == null)) {
      omitted++;
      continue;
    }
    final directUrl = _boundFlightDeckTowerUrl(
      raw['tower_base_url'],
      verifiedTowerRoot: verifiedTowerRoot,
    );
    if (directUrl == null) {
      omitted++;
      continue;
    }
    result.add(_FlightDeckWorkspace(
      v4WorkspaceId: v4WorkspaceId,
      workspace: NStackWorkspace(
        id: '',
        name: name,
        remoteId: workspaceId,
        stableRemoteId: v4WorkspaceId ?? workspaceId,
        workspaceOwnerNpub: owner,
        workspaceServiceNpub: workspaceService,
        directHttpsUrl: directUrl,
        serviceNpub: service,
        membershipRole: membershipRole,
      ),
    ));
  }
  if (result.isEmpty && omitted > 0) {
    throw const NStackWorkspaceDiscoveryException('invalid_response',
        'NStack returned no usable Flight Deck workspace identities.');
  }
  return _FlightDeckWorkspacePage(
    workspaces: List.unmodifiable(result),
    nextCursor: nextCursor,
  );
}

String? _boundFlightDeckTowerUrl(
  Object? value, {
  required Uri verifiedTowerRoot,
}) {
  final raw = _safeText(value, 2048);
  if (raw == null) return null;
  final reported = Uri.tryParse(raw);
  if (reported == null ||
      reported.host.isEmpty ||
      reported.userInfo.isNotEmpty ||
      reported.query.isNotEmpty ||
      reported.fragment.isNotEmpty) {
    throw const NStackWorkspaceDiscoveryException('invalid_response',
        'NStack returned a Flight Deck Tower URL outside the verified discovery address.');
  }
  final verifiedScheme = verifiedTowerRoot.scheme.toLowerCase();
  final reportedScheme = reported.scheme.toLowerCase();
  final sameScheme = reportedScheme == verifiedScheme;
  final proxyDowngrade = verifiedScheme == 'https' && reportedScheme == 'http';
  final compatiblePort = sameScheme
      ? reported.port == verifiedTowerRoot.port
      : !verifiedTowerRoot.hasPort &&
          (!reported.hasPort || reported.port == 80);
  if ((!sameScheme && !proxyDowngrade) ||
      reported.host.toLowerCase() != verifiedTowerRoot.host.toLowerCase() ||
      !compatiblePort) {
    throw const NStackWorkspaceDiscoveryException('invalid_response',
        'NStack returned a Flight Deck Tower URL outside the verified discovery address.');
  }
  final verifiedPath = verifiedTowerRoot.path == '/'
      ? ''
      : verifiedTowerRoot.path.replaceFirst(RegExp(r'/+$'), '');
  final reportedPath = reported.path == '/'
      ? ''
      : reported.path.replaceFirst(RegExp(r'/+$'), '');
  if (reportedPath.isNotEmpty && reportedPath != verifiedPath) {
    throw const NStackWorkspaceDiscoveryException('invalid_response',
        'NStack returned a Flight Deck Tower URL outside the verified discovery address.');
  }
  return canonicalNStackUrl(verifiedTowerRoot.toString());
}

List<NStackWorkspace> _mergeWorkspaceSources(
  List<NStackWorkspace> legacy,
  List<_FlightDeckWorkspace> flightDeck,
) {
  final merged = <String, NStackWorkspace>{};
  final legacyByRemoteId = <String, NStackWorkspace>{};
  for (final workspace in legacy) {
    final stableId = _workspaceStableIdentity(
        workspace.stableRemoteId!, workspace.workspaceOwnerNpub!);
    merged[stableId] = workspace;
    legacyByRemoteId[workspace.remoteId] = workspace;
  }
  for (final item in flightDeck) {
    final workspace = item.workspace;
    final linkedLegacy = item.v4WorkspaceId == null
        ? null
        : legacyByRemoteId[item.v4WorkspaceId];
    if (linkedLegacy != null &&
        linkedLegacy.workspaceOwnerNpub != workspace.workspaceOwnerNpub) {
      throw const NStackWorkspaceDiscoveryException('invalid_response',
          'NStack returned conflicting linked workspace ownership.');
    }
    merged[_workspaceStableIdentity(
        workspace.stableRemoteId!, workspace.workspaceOwnerNpub!)] = workspace;
  }
  final remoteIds = <String>{};
  if (merged.values.any((workspace) => !remoteIds.add(workspace.remoteId))) {
    throw const NStackWorkspaceDiscoveryException('invalid_response',
        'NStack returned conflicting workspace identities.');
  }
  return List.unmodifiable(merged.values);
}

String _workspaceStableIdentity(String remoteId, String ownerNpub) =>
    '$remoteId\u0000$ownerNpub';

class NStackWorkspaceDiscoveryService {
  NStackWorkspaceDiscoveryService({
    required this.registryStore,
    NStackWorkspaceDiscovery? discovery,
    DateTime Function()? clock,
  })  : discovery = discovery ?? TowerNStackWorkspaceDiscovery(),
        _clock = clock ?? DateTime.now;

  final NStackRegistryStore registryStore;
  final NStackWorkspaceDiscovery discovery;
  final DateTime Function() _clock;

  Future<NStackEntry> add({
    required String identityNpub,
    required String secret,
    required String address,
  }) async {
    final canonical = canonicalNStackUrl(address);
    if (canonical == null) {
      throw const NStackWorkspaceDiscoveryException(
          'invalid_address', 'Enter a valid HTTPS NStack address.');
    }
    final registry = await registryStore.load(identityNpub);
    final existing =
        registry.stacks.where((stack) => stack.url == canonical).firstOrNull;
    if (existing != null) {
      return refresh(
        identityNpub: identityNpub,
        secret: secret,
        stackId: existing.id,
      );
    }
    final discovered = await discovery.discover(
      address: canonical,
      identityNpub: identityNpub,
      secret: secret,
    );
    final identities =
        discovered.map((w) => w.serviceNpub).whereType<String>().toSet();
    if (identities.length == 1) {
      final matches =
          registry.stacks.where((s) => s.publicIdentity == identities.single);
      if (matches.isNotEmpty) {
        return registryStore.applyWorkspaceDiscovery(
          identityNpub,
          candidate: matches.first.copyWith(url: canonical),
          expectedPreviousUrl: matches.first.url,
          discovered: discovered,
          refreshedAt: _clock().toUtc(),
        );
      }
    }
    final candidate = NStackEntry(
      id: newNStackOpaqueId(),
      name: 'NStack',
      url: canonical,
    );
    return registryStore.applyWorkspaceDiscovery(
      identityNpub,
      candidate: candidate,
      discovered: discovered,
      refreshedAt: _clock().toUtc(),
    );
  }

  Future<NStackEntry> changeAddress({
    required String identityNpub,
    required String secret,
    required String stackId,
    required String address,
  }) async {
    final canonical = canonicalNStackUrl(address);
    if (canonical == null) {
      throw const NStackWorkspaceDiscoveryException(
          'invalid_address', 'Enter a valid HTTPS NStack address.');
    }
    final registry = await registryStore.load(identityNpub);
    final current =
        registry.stacks.where((stack) => stack.id == stackId).firstOrNull;
    if (current == null) throw StateError('NStack no longer exists.');
    if (registry.stacks
        .any((stack) => stack.id != stackId && stack.url == canonical)) {
      throw const NStackWorkspaceDiscoveryException(
          'duplicate_address', 'That NStack address is already saved.');
    }
    final discovered = await discovery.discover(
      address: canonical,
      identityNpub: identityNpub,
      secret: secret,
    );
    return registryStore.applyWorkspaceDiscovery(
      identityNpub,
      candidate: current.copyWith(url: canonical),
      expectedPreviousUrl: current.url,
      discovered: discovered,
      refreshedAt: _clock().toUtc(),
    );
  }

  Future<NStackEntry> refresh({
    required String identityNpub,
    required String secret,
    required String stackId,
  }) async {
    final registry = await registryStore.load(identityNpub);
    final stack =
        registry.stacks.where((item) => item.id == stackId).firstOrNull;
    if (stack == null) throw StateError('NStack no longer exists.');
    final attemptedAt = _clock().toUtc();
    try {
      final discovered = await discovery.discover(
        address: stack.url,
        identityNpub: identityNpub,
        secret: secret,
      );
      return registryStore.applyWorkspaceDiscovery(
        identityNpub,
        candidate: stack,
        expectedPreviousUrl: stack.url,
        discovered: discovered,
        refreshedAt: attemptedAt,
      );
    } on NStackWorkspaceDiscoveryException catch (error) {
      await registryStore.markWorkspaceDiscoveryFailure(
        identityNpub,
        stackId: stack.id,
        expectedUrl: stack.url,
        attemptedAt: attemptedAt,
        errorCode: error.code,
        errorMessage: error.message,
      );
      rethrow;
    }
  }
}

String? _safeText(Object? value, int maximum) {
  if (value is! String ||
      value.isEmpty ||
      value.length > maximum ||
      value.trim() != value ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    return null;
  }
  return value;
}

String? _validNpub(Object? value) {
  final text = _safeText(value, 128);
  if (text == null) return null;
  try {
    NostrCrypto.publicKeyHexFromNpub(text);
    return text;
  } catch (_) {
    return null;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
