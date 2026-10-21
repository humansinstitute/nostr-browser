import 'dart:convert';

import '../browser/browser_bookmark_store.dart';

const nstackProtocolVersion = 1;
const nstackRegistryVersion = 2;
const nstackRecoveryHintKind = 30078;
const nstackRecoveryHintDTag = 'org.wingman.nbrowser.settings.v1';
const nbrowserAppNamespaceLabel = 'org.wingman.nbrowser.app-namespace.v1';
const nbrowserAppNamespaceDerivation =
    'sha256-counter-to-secp256k1-x:$nbrowserAppNamespaceLabel:0';
const nbrowserAppNpub =
    'npub104qc4t62zry5vrqnsevkazswgtdh87fy2vgc73sndellfnq7pa2sqrqjs0';

class NStackWorkspace {
  const NStackWorkspace({
    required this.id,
    required this.name,
    required this.remoteId,
    this.stableRemoteId,
    this.workspaceOwnerNpub,
    this.workspaceServiceNpub,
    this.directHttpsUrl,
    this.serviceNpub,
    this.membershipRole,
  });

  final String id;
  final String name;
  final String remoteId;
  final String? stableRemoteId;
  final String? workspaceOwnerNpub;
  final String? workspaceServiceNpub;
  final String? directHttpsUrl;
  final String? serviceNpub;
  final String? membershipRole;

  String get displayName => safeConnectionName(name, fallback: 'Workspace');
  String get displayLabel =>
      '$displayName · ${abbreviatedNpub(workspaceServiceNpub)}';

  bool get isDiscovered =>
      workspaceOwnerNpub != null && workspaceServiceNpub != null;

  bool get supportsBackup =>
      isDiscovered &&
      isWorkspaceUuid(remoteId) &&
      directHttpsUrl != null &&
      membershipRole != null;

  bool get canManageBackupNamespace =>
      const {'owner', 'manager', 'admin'}.contains(membershipRole);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'remote_id': remoteId,
        if (stableRemoteId != null) 'stable_remote_id': stableRemoteId,
        'workspace_owner_npub': workspaceOwnerNpub,
        'workspace_service_npub': workspaceServiceNpub,
        'direct_https_url': directHttpsUrl,
        'service_npub': serviceNpub,
        'membership_role': membershipRole,
      };

  static NStackWorkspace? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final id = _nonEmpty(value['id']);
    final name = _nonEmpty(value['name']);
    final remoteId = _nonEmpty(value['remote_id']);
    if (id == null || name == null || remoteId == null) return null;
    final stableRemoteId = value['stable_remote_id'] == null
        ? null
        : _boundedString(value['stable_remote_id'], 1, 128);
    final owner = _optionalNpub(value['workspace_owner_npub']);
    final workspaceService = _optionalNpub(value['workspace_service_npub']);
    final directUrl = canonicalNStackUrl(value['direct_https_url']?.toString());
    final service = _optionalNpub(value['service_npub']);
    final membershipRole = value['membership_role'] == null
        ? null
        : _boundedString(value['membership_role'], 1, 32);
    final hasDiscoveryMetadata = value['workspace_owner_npub'] != null ||
        value['workspace_service_npub'] != null ||
        value['stable_remote_id'] != null ||
        value['direct_https_url'] != null ||
        value['service_npub'] != null;
    if (hasDiscoveryMetadata &&
        (owner == null ||
            workspaceService == null ||
            (value['direct_https_url'] != null && directUrl == null) ||
            (value['service_npub'] != null && service == null))) {
      return null;
    }
    if (value['stable_remote_id'] != null && stableRemoteId == null) {
      return null;
    }
    return NStackWorkspace(
      id: id,
      name: name,
      remoteId: remoteId,
      stableRemoteId: stableRemoteId,
      workspaceOwnerNpub: owner,
      workspaceServiceNpub: workspaceService,
      directHttpsUrl: directUrl,
      serviceNpub: service,
      membershipRole: membershipRole,
    );
  }
}

class NStackBackupDestination {
  const NStackBackupDestination({
    required this.stackId,
    required this.workspaceId,
    required this.workspaceRemoteId,
    required this.workspaceOwnerNpub,
  });

  final String stackId;
  final String workspaceId;
  final String workspaceRemoteId;
  final String workspaceOwnerNpub;

  Map<String, dynamic> toJson() => {
        'stack_id': stackId,
        'workspace_id': workspaceId,
        'workspace_remote_id': workspaceRemoteId,
        'workspace_owner_npub': workspaceOwnerNpub,
      };

  static NStackBackupDestination? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final stackId = _nonEmpty(value['stack_id']);
    final workspaceId = _nonEmpty(value['workspace_id']);
    final remoteId = _nonEmpty(value['workspace_remote_id']);
    final owner = _optionalNpub(value['workspace_owner_npub']);
    if (stackId == null ||
        workspaceId == null ||
        remoteId == null ||
        !isWorkspaceUuid(remoteId) ||
        owner == null) {
      return null;
    }
    return NStackBackupDestination(
      stackId: stackId,
      workspaceId: workspaceId,
      workspaceRemoteId: remoteId,
      workspaceOwnerNpub: owner,
    );
  }
}

class NStackWorkspaceDiscoveryStatus {
  const NStackWorkspaceDiscoveryStatus({
    required this.lastAttemptAt,
    required this.stale,
    this.lastSuccessAt,
    this.errorCode,
    this.errorMessage,
  });

  final DateTime lastAttemptAt;
  final DateTime? lastSuccessAt;
  final bool stale;
  final String? errorCode;
  final String? errorMessage;

  bool get hasError => errorCode != null;

  Map<String, dynamic> toJson() => {
        'last_attempt_at': lastAttemptAt.toUtc().toIso8601String(),
        'last_success_at': lastSuccessAt?.toUtc().toIso8601String(),
        'stale': stale,
        'error': errorCode == null
            ? null
            : {'code': errorCode, 'message': errorMessage},
      };

  static NStackWorkspaceDiscoveryStatus? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final attempt =
        DateTime.tryParse(value['last_attempt_at']?.toString() ?? '');
    final success = value['last_success_at'] == null
        ? null
        : DateTime.tryParse(value['last_success_at'].toString());
    final error = value['error'];
    final errorCode = error is Map<String, dynamic>
        ? _boundedString(error['code'], 1, 64)
        : null;
    final errorMessage = error is Map<String, dynamic>
        ? _boundedString(error['message'], 1, 256)
        : null;
    if (attempt == null ||
        value['stale'] is! bool ||
        (value['last_success_at'] != null && success == null) ||
        (error != null && (errorCode == null || errorMessage == null))) {
      return null;
    }
    return NStackWorkspaceDiscoveryStatus(
      lastAttemptAt: attempt.toUtc(),
      lastSuccessAt: success?.toUtc(),
      stale: value['stale'] as bool,
      errorCode: errorCode,
      errorMessage: errorMessage,
    );
  }
}

class NStackBrowserSettings {
  const NStackBrowserSettings({
    this.bookmarks = const [],
    this.background,
    this.labelColour = '#ffffff',
    this.builtInStartup = false,
  });

  final List<BrowserBookmark> bookmarks;
  final String? background;
  final String labelColour;
  final bool builtInStartup;

  NStackBrowserSettings copyWith({
    List<BrowserBookmark>? bookmarks,
    String? background,
    bool clearBackground = false,
    String? labelColour,
    bool? builtInStartup,
  }) {
    return NStackBrowserSettings(
      bookmarks: bookmarks ?? this.bookmarks,
      background: clearBackground ? null : background ?? this.background,
      labelColour: labelColour ?? this.labelColour,
      builtInStartup: builtInStartup ?? this.builtInStartup,
    );
  }

  Map<String, dynamic> toJson() => {
        'bookmarks': [for (final bookmark in bookmarks) bookmark.toJson()],
        'background': background,
        'label_colour': safeLabelColour(labelColour),
        'built_in_startup': builtInStartup,
      };

  static NStackBrowserSettings tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return const NStackBrowserSettings();
    final seen = <String>{};
    final bookmarks = <BrowserBookmark>[];
    final rawBookmarks = value['bookmarks'];
    if (rawBookmarks is List) {
      for (final raw in rawBookmarks) {
        final bookmark = BrowserBookmark.tryParse(raw);
        if (bookmark != null && seen.add(bookmark.url)) bookmarks.add(bookmark);
      }
    }
    return NStackBrowserSettings(
      bookmarks: List.unmodifiable(bookmarks),
      background: safeBookmarkImage(value['background']?.toString()),
      labelColour: safeLabelColour(value['label_colour']?.toString()),
      builtInStartup: value['built_in_startup'] == true,
    );
  }
}

enum NStackServiceAvailability { available, unavailable, unknown }

class NStackService {
  const NStackService({
    required this.id,
    required this.kind,
    required this.endpoint,
    required this.version,
    required this.protocols,
    required this.capabilities,
    required this.availability,
    required this.checkedAt,
    this.nips = const [],
    this.buds = const [],
    this.actionable = false,
  });

  final String id;
  final String kind;
  final String endpoint;
  final String version;
  final List<String> protocols;
  final List<String> capabilities;
  final List<int> nips;
  final List<int> buds;
  final NStackServiceAvailability availability;
  final DateTime? checkedAt;
  final bool actionable;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'endpoint': endpoint,
        'version': version,
        'protocols': protocols,
        'capabilities': capabilities,
        'features': {'nips': nips, 'buds': buds},
        'availability': {
          'status': availability.name,
          'checked_at': checkedAt?.toUtc().toIso8601String(),
        },
        'actionable': actionable,
      };

  static NStackService? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final id = _boundedString(value['id'], 1, 64);
    final kind = _boundedString(value['kind'], 1, 64);
    final endpoint = _boundedString(value['endpoint'], 1, 2048);
    final version = _boundedString(value['version'], 1, 128);
    final protocols = _boundedStringList(value['protocols'], 32, 64);
    final capabilities = _boundedStringList(value['capabilities'], 64, 128);
    final features = value['features'];
    final availability = value['availability'];
    if (id == null ||
        kind == null ||
        endpoint == null ||
        version == null ||
        protocols == null ||
        capabilities == null ||
        features is! Map<String, dynamic> ||
        availability is! Map<String, dynamic>) {
      return null;
    }
    final serviceOrigin = _canonicalServiceOrigin(endpoint);
    final knownPair = switch (id) {
      'tower' => kind == 'tower' &&
          serviceOrigin != null &&
          {'https', 'http'}.contains(serviceOrigin.scheme),
      'relay' => kind == 'nostr_relay' &&
          serviceOrigin != null &&
          {'wss', 'ws'}.contains(serviceOrigin.scheme),
      'blossom' => kind == 'blossom' &&
          serviceOrigin != null &&
          {'https', 'http'}.contains(serviceOrigin.scheme),
      _ => serviceOrigin != null,
    };
    if (!knownPair) return null;
    final status = NStackServiceAvailability.values
        .where((item) => item.name == availability['status'])
        .firstOrNull;
    final checkedAt = availability['checked_at'] == null
        ? null
        : DateTime.tryParse(availability['checked_at'].toString())?.toUtc();
    final nips = _boundedIntList(features['nips'], 64);
    final buds = _boundedIntList(features['buds'], 64);
    if (status == null ||
        (availability['checked_at'] != null && checkedAt == null) ||
        nips == null ||
        buds == null) {
      return null;
    }
    return NStackService(
      id: id,
      kind: kind,
      endpoint: serviceOrigin.toString(),
      version: version,
      protocols: List.unmodifiable(protocols),
      capabilities: List.unmodifiable(capabilities),
      nips: List.unmodifiable(nips),
      buds: List.unmodifiable(buds),
      availability: status,
      checkedAt: checkedAt,
      actionable: {'tower', 'relay', 'blossom'}.contains(id) &&
          value['actionable'] == true,
    );
  }
}

class NStackServiceCatalogue {
  const NStackServiceCatalogue({
    required this.generatedAt,
    required this.fetchedAt,
    required this.cacheTtlSeconds,
    required this.services,
    this.towerNpub,
    this.stackName,
  });

  final DateTime generatedAt;
  final DateTime fetchedAt;
  final int cacheTtlSeconds;
  final String? towerNpub;
  final String? stackName;
  final List<NStackService> services;

  bool isStaleAt(DateTime now) =>
      !fetchedAt.add(Duration(seconds: cacheTtlSeconds)).isAfter(now.toUtc());

  NStackService? service(String id) =>
      services.where((service) => service.id == id).firstOrNull;

  Map<String, dynamic> toJson() => {
        'schema': 'org.wingman.nstack.services',
        'schema_version': 1,
        'generated_at': generatedAt.toUtc().toIso8601String(),
        'fetched_at': fetchedAt.toUtc().toIso8601String(),
        'cache_ttl_seconds': cacheTtlSeconds,
        'stack': {'tower_npub': towerNpub, 'name': stackName},
        'services': [for (final service in services) service.toJson()],
      };

  static NStackServiceCatalogue? tryParse(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['schema'] != 'org.wingman.nstack.services' ||
        value['schema_version'] != 1 ||
        value['stack'] is! Map<String, dynamic> ||
        value['services'] is! List) {
      return null;
    }
    final generatedAt =
        DateTime.tryParse(value['generated_at']?.toString() ?? '')?.toUtc();
    final fetchedAt =
        DateTime.tryParse(value['fetched_at']?.toString() ?? '')?.toUtc();
    final ttl = value['cache_ttl_seconds'];
    final stack = value['stack'] as Map<String, dynamic>;
    final towerNpub = _optionalNpub(stack['tower_npub']);
    final stackName =
        stack['name'] == null ? null : _boundedString(stack['name'], 1, 128);
    if (generatedAt == null ||
        fetchedAt == null ||
        ttl is! int ||
        ttl < 5 ||
        ttl > 3600 ||
        (stack['tower_npub'] != null && towerNpub == null) ||
        (stack['name'] != null && stackName == null)) {
      return null;
    }
    final services = <NStackService>[];
    final seen = <String>{};
    for (final raw in value['services'] as List) {
      final service = NStackService.tryParse(raw);
      if (service == null || !seen.add(service.id)) return null;
      services.add(service);
    }
    if (services.length > 32) return null;
    return NStackServiceCatalogue(
      generatedAt: generatedAt,
      fetchedAt: fetchedAt,
      cacheTtlSeconds: ttl,
      towerNpub: towerNpub,
      stackName: stackName,
      services: List.unmodifiable(services),
    );
  }
}

class NStackCatalogueStatus {
  const NStackCatalogueStatus({
    required this.checkedAt,
    this.catalogue,
    this.errorCode,
    this.errorMessage,
  });

  final DateTime checkedAt;
  final NStackServiceCatalogue? catalogue;
  final String? errorCode;
  final String? errorMessage;

  bool get hasError => errorCode != null;

  Map<String, dynamic> toJson() => {
        'checked_at': checkedAt.toUtc().toIso8601String(),
        'catalogue': catalogue?.toJson(),
        'error': errorCode == null
            ? null
            : {'code': errorCode, 'message': errorMessage},
      };

  static NStackCatalogueStatus? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final checkedAt =
        DateTime.tryParse(value['checked_at']?.toString() ?? '')?.toUtc();
    final catalogue = value['catalogue'] == null
        ? null
        : NStackServiceCatalogue.tryParse(value['catalogue']);
    final error = value['error'];
    final errorCode = error is Map<String, dynamic>
        ? _boundedString(error['code'], 1, 64)
        : null;
    final errorMessage = error is Map<String, dynamic>
        ? _boundedString(error['message'], 1, 256)
        : null;
    if (checkedAt == null ||
        (value['catalogue'] != null && catalogue == null) ||
        (error != null && (errorCode == null || errorMessage == null))) {
      return null;
    }
    return NStackCatalogueStatus(
      checkedAt: checkedAt,
      catalogue: catalogue,
      errorCode: errorCode,
      errorMessage: errorMessage,
    );
  }
}

class NStackEntry {
  const NStackEntry({
    required this.id,
    required this.name,
    required this.url,
    this.towerNpub,
    this.fipsEndpoint,
    this.peerNpub,
    this.workspaces = const [],
    this.settings = const NStackBrowserSettings(),
    this.catalogueStatus,
    this.workspaceDiscovery,
  });

  final String id;
  final String name;
  final String url;
  final String? towerNpub;

  String? get publicIdentity =>
      towerNpub ??
      catalogueStatus?.catalogue?.towerNpub ??
      workspaces.map((w) => w.serviceNpub).whereType<String>().firstOrNull;
  String get displayName => name == Uri.parse(url).host
      ? 'NStack'
      : safeConnectionName(name, fallback: 'NStack');
  String get displayLabel =>
      '$displayName · ${abbreviatedNpub(publicIdentity)}';
  final String? fipsEndpoint;
  final String? peerNpub;
  final List<NStackWorkspace> workspaces;
  final NStackBrowserSettings settings;
  final NStackCatalogueStatus? catalogueStatus;
  final NStackWorkspaceDiscoveryStatus? workspaceDiscovery;

  NStackEntry copyWith({
    String? towerNpub,
    String? name,
    String? url,
    String? fipsEndpoint,
    bool clearFipsEndpoint = false,
    String? peerNpub,
    bool clearPeerNpub = false,
    List<NStackWorkspace>? workspaces,
    NStackBrowserSettings? settings,
    NStackCatalogueStatus? catalogueStatus,
    bool clearCatalogueStatus = false,
    NStackWorkspaceDiscoveryStatus? workspaceDiscovery,
    bool clearWorkspaceDiscovery = false,
  }) {
    return NStackEntry(
      id: id,
      towerNpub: towerNpub ?? this.towerNpub,
      name: name ?? this.name,
      url: url ?? this.url,
      fipsEndpoint:
          clearFipsEndpoint ? null : fipsEndpoint ?? this.fipsEndpoint,
      peerNpub: clearPeerNpub ? null : peerNpub ?? this.peerNpub,
      workspaces: workspaces ?? this.workspaces,
      settings: settings ?? this.settings,
      catalogueStatus:
          clearCatalogueStatus ? null : catalogueStatus ?? this.catalogueStatus,
      workspaceDiscovery: clearWorkspaceDiscovery
          ? null
          : workspaceDiscovery ?? this.workspaceDiscovery,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'tower_npub': towerNpub,
        'fips_endpoint': fipsEndpoint,
        'peer_npub': peerNpub,
        'workspaces': [for (final workspace in workspaces) workspace.toJson()],
        'settings': settings.toJson(),
        'service_catalogue': catalogueStatus?.toJson(),
        'workspace_discovery': workspaceDiscovery?.toJson(),
      };

  static NStackEntry? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final id = _nonEmpty(value['id']);
    final name = _nonEmpty(value['name']);
    final url = canonicalNStackUrl(value['url']?.toString());
    if (id == null || name == null || url == null) return null;
    final towerNpub = _optionalNpub(value['tower_npub']);
    if (value['tower_npub'] != null && towerNpub == null) return null;
    final fipsEndpoint =
        canonicalFipsEndpoint(value['fips_endpoint']?.toString());
    final peerNpub = _optionalNpub(value['peer_npub']);
    if ((fipsEndpoint == null) != (peerNpub == null)) return null;
    final catalogueStatus = value['service_catalogue'] == null
        ? null
        : NStackCatalogueStatus.tryParse(value['service_catalogue']);
    if (value['service_catalogue'] != null && catalogueStatus == null) {
      return null;
    }
    final tower = catalogueStatus?.catalogue?.service('tower');
    if (tower != null && !_sameHttpOrigin(tower.endpoint, url)) return null;
    final workspaces = <NStackWorkspace>[];
    final seen = <String>{};
    final seenRemote = <String>{};
    final seenStable = <String>{};
    if (value['workspaces'] is List) {
      for (final raw in value['workspaces'] as List) {
        final workspace = NStackWorkspace.tryParse(raw);
        if (workspace == null ||
            !seen.add(workspace.id) ||
            !seenRemote.add(workspace.remoteId) ||
            !seenStable.add(
                '${workspace.stableRemoteId ?? workspace.remoteId}\u0000${workspace.workspaceOwnerNpub ?? ''}')) {
          return null;
        }
        workspaces.add(workspace);
      }
    }
    final workspaceDiscovery = value['workspace_discovery'] == null
        ? null
        : NStackWorkspaceDiscoveryStatus.tryParse(value['workspace_discovery']);
    if (value['workspace_discovery'] != null && workspaceDiscovery == null) {
      return null;
    }
    return NStackEntry(
      id: id,
      name: name,
      towerNpub: towerNpub,
      url: url,
      fipsEndpoint: fipsEndpoint,
      peerNpub: peerNpub,
      workspaces: List.unmodifiable(workspaces),
      settings: NStackBrowserSettings.tryParse(value['settings']),
      catalogueStatus: catalogueStatus,
      workspaceDiscovery: workspaceDiscovery,
    );
  }
}

class NStackRegistry {
  const NStackRegistry({
    this.version = nstackRegistryVersion,
    this.revision = 0,
    this.activeStackId,
    this.hostStackId,
    this.backupDestination,
    this.backupDestinationMigrationVersion = 0,
    this.stacks = const [],
  });

  final int version;
  final int revision;
  final String? activeStackId;
  final String? hostStackId;
  final NStackBackupDestination? backupDestination;
  final int backupDestinationMigrationVersion;
  final List<NStackEntry> stacks;

  NStackEntry? get activeStack => _byId(activeStackId);
  NStackEntry? get hostStack => _byId(hostStackId);
  NStackEntry? get backupStack => _byId(backupDestination?.stackId);

  NStackWorkspace? get backupWorkspace {
    final destination = backupDestination;
    final stack = backupStack;
    if (destination == null || stack == null) return null;
    for (final workspace in stack.workspaces) {
      if (workspace.id == destination.workspaceId &&
          workspace.remoteId == destination.workspaceRemoteId &&
          workspace.workspaceOwnerNpub == destination.workspaceOwnerNpub) {
        return workspace;
      }
    }
    return null;
  }

  bool get backupDestinationAvailable =>
      backupWorkspace?.supportsBackup == true &&
      backupStack?.workspaceDiscovery?.stale != true;

  NStackEntry? _byId(String? id) {
    if (id == null) return null;
    for (final stack in stacks) {
      if (stack.id == id) return stack;
    }
    return null;
  }

  NStackRegistry next({
    String? activeStackId,
    bool clearActive = false,
    String? hostStackId,
    bool clearHost = false,
    NStackBackupDestination? backupDestination,
    bool clearBackupDestination = false,
    int? backupDestinationMigrationVersion,
    List<NStackEntry>? stacks,
  }) {
    final nextStacks = stacks ?? this.stacks;
    String? valid(String? value) =>
        nextStacks.any((stack) => stack.id == value) ? value : null;
    return NStackRegistry(
      version: nstackRegistryVersion,
      revision: revision + 1,
      activeStackId:
          valid(clearActive ? null : activeStackId ?? this.activeStackId),
      hostStackId: valid(clearHost ? null : hostStackId ?? this.hostStackId),
      backupDestination: clearBackupDestination
          ? null
          : backupDestination ?? this.backupDestination,
      backupDestinationMigrationVersion: backupDestinationMigrationVersion ??
          this.backupDestinationMigrationVersion,
      stacks: List.unmodifiable(nextStacks),
    );
  }

  Map<String, dynamic> toJson() => {
        'schema': 'org.wingman.nbrowser.nstack-registry',
        'version': version,
        'revision': revision,
        'active_stack_id': activeStackId,
        'host_stack_id': hostStackId,
        'backup_destination': backupDestination?.toJson(),
        'backup_destination_migration_version':
            backupDestinationMigrationVersion,
        'stacks': [for (final stack in stacks) stack.toJson()],
      };

  static NStackRegistry? tryParse(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['schema'] != 'org.wingman.nbrowser.nstack-registry' ||
        (value['version'] != 1 && value['version'] != nstackRegistryVersion) ||
        value['stacks'] is! List) {
      return null;
    }
    final stacks = <NStackEntry>[];
    final seen = <String>{};
    for (final raw in value['stacks'] as List) {
      final stack = NStackEntry.tryParse(raw);
      if (stack == null || !seen.add(stack.id)) return null;
      stacks.add(stack);
    }
    final active = _nonEmpty(value['active_stack_id']);
    final host = _nonEmpty(value['host_stack_id']);
    final backupDestination = value['backup_destination'] == null
        ? null
        : NStackBackupDestination.tryParse(value['backup_destination']);
    final migrationVersion = value['backup_destination_migration_version'];
    if ((active != null && !seen.contains(active)) ||
        (host != null && !seen.contains(host)) ||
        (value['backup_destination'] != null && backupDestination == null) ||
        (migrationVersion != null && migrationVersion is! int)) {
      return null;
    }
    return NStackRegistry(
      version: nstackRegistryVersion,
      revision: value['revision'] is int ? value['revision'] as int : 0,
      activeStackId: active,
      hostStackId: host,
      backupDestination: backupDestination,
      backupDestinationMigrationVersion:
          migrationVersion is int ? migrationVersion : 0,
      stacks: List.unmodifiable(stacks),
    );
  }

  static NStackRegistry? decode(String raw) {
    try {
      return tryParse(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }
}

bool isWorkspaceUuid(String value) => RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(value);

bool _sameHttpOrigin(String left, String right) {
  final a = Uri.tryParse(left);
  final b = Uri.tryParse(right);
  if (a == null || b == null) return false;
  int port(Uri uri) =>
      uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      port(a) == port(b);
}

String? _boundedString(Object? value, int minimum, int maximum) {
  if (value is! String || value.length < minimum || value.length > maximum) {
    return null;
  }
  if (value.trim() != value || value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    return null;
  }
  return value;
}

List<String>? _boundedStringList(
    Object? value, int maximumItems, int maximumLength) {
  if (value is! List || value.length > maximumItems) return null;
  final result = <String>[];
  final seen = <String>{};
  for (final item in value) {
    final text = _boundedString(item, 1, maximumLength);
    if (text == null || !seen.add(text)) return null;
    result.add(text);
  }
  return result;
}

List<int>? _boundedIntList(Object? value, int maximumItems) {
  if (value == null) return const [];
  if (value is! List || value.length > maximumItems) return null;
  final result = <int>[];
  final seen = <int>{};
  for (final item in value) {
    if (item is! int || item < 1 || item > 65535 || !seen.add(item)) {
      return null;
    }
    result.add(item);
  }
  return result;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

Uri? _canonicalServiceOrigin(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final local = {'localhost', '127.0.0.1', '::1'}.contains(host);
  if (!{'https', 'wss'}.contains(uri.scheme) &&
      !(local && {'http', 'ws'}.contains(uri.scheme))) {
    return null;
  }
  return uri.replace(host: host, path: '');
}

String? canonicalNStackUrl(String? value) {
  final raw = value?.trim() ?? '';
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  final local = {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
  if (scheme != 'https' && !(scheme == 'http' && local)) return null;
  if (uri.fragment.isNotEmpty || uri.query.isNotEmpty) return null;
  final path = uri.path == '/' ? '' : uri.path.replaceFirst(RegExp(r'/+$'), '');
  return uri
      .replace(scheme: scheme, host: uri.host.toLowerCase(), path: path)
      .toString();
}

String? canonicalFipsEndpoint(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.host.endsWith('.fips') ||
      uri.host.length <= 5 ||
      uri.userInfo.isNotEmpty ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      !uri.hasPort) {
    return null;
  }
  return uri.replace(path: '').toString();
}

String? _nonEmpty(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

String? _optionalNpub(Object? value) {
  final text = _nonEmpty(value);
  if (text == null) return null;
  return RegExp(r'^npub1[023456789acdefghjklmnpqrstuvwxyz]{20,}$')
          .hasMatch(text)
      ? text
      : null;
}

/// Presentation only: never use abbreviated values for identity comparisons.
String abbreviatedNpub(String? value) {
  if (value == null || !value.startsWith('npub1') || value.length < 16) {
    return 'Identity unavailable';
  }
  return '${value.substring(0, 9)}…${value.substring(value.length - 4)}';
}

String safeConnectionName(String value, {required String fallback}) {
  final text = value.trim();
  if (text.isEmpty ||
      text.contains(RegExp(
          r'https?://|wss?://|npub1|[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}|[0-9a-fA-F]{64}|(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}',
          caseSensitive: false))) {
    return fallback;
  }
  return text;
}
