import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../browser/browser_bookmark_store.dart';
import 'nstack_models.dart';

class NStackRegistryStore extends ChangeNotifier {
  NStackRegistryStore({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const keyPrefix = 'wingman.nstack.registry.v2.';
  static const legacyKeyPrefix = 'wingman.nstack.registry.v1.';
  final SharedPreferencesAsync _preferences;
  final Map<String, NStackRegistry> _cache = {};

  Future<NStackRegistry> load(String signerNpub) async {
    final identity = signerNpub.trim();
    if (identity.isEmpty) return const NStackRegistry();
    final cached = _cache[identity];
    if (cached != null) return cached;
    final raw = await _preferences.getString('$keyPrefix$identity');
    var registry = raw == null ? null : NStackRegistry.decode(raw);
    if (registry == null && raw == null) {
      final legacy = await _preferences.getString('$legacyKeyPrefix$identity');
      registry = legacy == null ? null : NStackRegistry.decode(legacy);
      if (registry != null) {
        await _preferences.setString(
            '$keyPrefix$identity', jsonEncode(registry.toJson()));
      }
    }
    registry ??= const NStackRegistry();
    final migrated = _migrateLegacyBackupDestination(registry);
    if (!identical(migrated, registry)) {
      await _preferences.setString(
          '$keyPrefix$identity', jsonEncode(migrated.toJson()));
    }
    _cache[identity] = migrated;
    return migrated;
  }

  Future<void> replaceAtomic(String signerNpub, NStackRegistry registry) async {
    final identity = signerNpub.trim();
    if (identity.isEmpty || registry.version != nstackRegistryVersion) {
      throw StateError('A valid identity and registry are required.');
    }
    final encoded = jsonEncode(registry.toJson());
    if (NStackRegistry.decode(encoded) == null) {
      throw StateError('Registry failed canonical validation.');
    }
    await _preferences.setString('$keyPrefix$identity', encoded);
    _cache[identity] = registry;
    notifyListeners();
  }

  Future<NStackEntry> updateCatalogue(
    String signerNpub,
    String stackId,
    NStackCatalogueStatus status, {
    required String expectedUrl,
  }) async {
    final current = await load(signerNpub);
    final existing = current.stacks.where((stack) => stack.id == stackId);
    if (existing.isEmpty) throw StateError('NStack no longer exists.');
    if (existing.first.url != expectedUrl) {
      throw StateError('NStack origin changed during service discovery.');
    }
    final pinned = existing.first.publicIdentity;
    final reported = status.catalogue?.towerNpub;
    if (pinned != null && reported != null && pinned != reported) {
      throw StateError(
          'NStack identity changed. Add it as a separate connection.');
    }
    final updated =
        existing.first.copyWith(towerNpub: reported, catalogueStatus: status);
    await replaceAtomic(
      signerNpub,
      current.next(stacks: [
        for (final stack in current.stacks)
          if (stack.id == stackId) updated else stack,
      ]),
    );
    return updated;
  }

  Future<NStackRegistry> addOrUpdate(
    String signerNpub,
    NStackEntry entry, {
    bool makeActive = false,
    bool makeHost = false,
  }) async {
    final current = await load(signerNpub);
    final nextStacks = [
      for (final stack in current.stacks)
        if (stack.id != entry.id) stack,
      entry,
    ];
    final next = current.next(
      stacks: nextStacks,
      activeStackId: makeActive || current.activeStackId == null
          ? entry.id
          : current.activeStackId,
      hostStackId: makeHost ? entry.id : current.hostStackId,
    );
    await replaceAtomic(signerNpub, next);
    return next;
  }

  Future<NStackEntry> applyWorkspaceDiscovery(
    String signerNpub, {
    required NStackEntry candidate,
    required List<NStackWorkspace> discovered,
    required DateTime refreshedAt,
    String? expectedPreviousUrl,
  }) async {
    final current = await load(signerNpub);
    final existing =
        current.stacks.where((stack) => stack.id == candidate.id).firstOrNull;
    if (expectedPreviousUrl != null && existing == null) {
      throw StateError('NStack was removed during discovery.');
    }
    if (existing != null &&
        existing.url != (expectedPreviousUrl ?? candidate.url)) {
      throw StateError('NStack address changed during discovery.');
    }
    final identities =
        discovered.map((w) => w.serviceNpub).whereType<String>().toSet();
    if (identities.length > 1) {
      throw StateError('Discovery returned conflicting NStack identities.');
    }
    final reported = identities.firstOrNull;
    final pinned = existing?.publicIdentity;
    final changingAddress = existing != null && existing.url != candidate.url;
    if ((pinned != null && reported != null && pinned != reported) ||
        (changingAddress && (pinned == null || reported != pinned))) {
      throw StateError(
          'NStack identity could not be matched. Add it as a separate connection.');
    }
    final source = (existing?.copyWith(
              url: candidate.url,
              clearCatalogueStatus: changingAddress,
              clearFipsEndpoint: changingAddress,
              clearPeerNpub: changingAddress,
            ) ??
            candidate)
        .copyWith(towerNpub: reported);
    final oldByStableIdentity = <String, NStackWorkspace>{
      for (final workspace in source.workspaces)
        _workspaceStableIdentity(workspace): workspace,
    };
    final oldLegacyByRemoteId = <String, NStackWorkspace>{
      for (final workspace in source.workspaces)
        if (!workspace.isDiscovered) workspace.remoteId: workspace,
    };
    final merged = <NStackWorkspace>[
      for (final workspace in discovered)
        NStackWorkspace(
          id: oldByStableIdentity[_workspaceStableIdentity(workspace)]?.id ??
              oldLegacyByRemoteId[workspace.remoteId]?.id ??
              newNStackOpaqueId(),
          name: workspace.name,
          remoteId: workspace.remoteId,
          stableRemoteId: workspace.stableRemoteId,
          workspaceOwnerNpub: workspace.workspaceOwnerNpub,
          workspaceServiceNpub: workspace.workspaceServiceNpub,
          directHttpsUrl: workspace.directHttpsUrl,
          serviceNpub: workspace.serviceNpub,
          membershipRole: workspace.membershipRole,
        ),
    ];
    final nextEntry = source.copyWith(
      workspaces: List.unmodifiable(merged),
      workspaceDiscovery: NStackWorkspaceDiscoveryStatus(
        lastAttemptAt: refreshedAt.toUtc(),
        lastSuccessAt: refreshedAt.toUtc(),
        stale: false,
      ),
    );
    final next = current.next(
      stacks: [
        for (final stack in current.stacks)
          if (stack.id != nextEntry.id) stack,
        nextEntry,
      ],
      activeStackId: current.activeStackId ?? nextEntry.id,
    );
    await replaceAtomic(signerNpub, next);
    return nextEntry;
  }

  Future<NStackEntry> markWorkspaceDiscoveryFailure(
    String signerNpub, {
    required String stackId,
    required String expectedUrl,
    required DateTime attemptedAt,
    required String errorCode,
    required String errorMessage,
  }) async {
    final current = await load(signerNpub);
    final stack =
        current.stacks.where((item) => item.id == stackId).firstOrNull;
    if (stack == null || stack.url != expectedUrl) {
      throw StateError('NStack changed during discovery.');
    }
    final nextEntry = stack.copyWith(
      workspaceDiscovery: NStackWorkspaceDiscoveryStatus(
        lastAttemptAt: attemptedAt.toUtc(),
        lastSuccessAt: stack.workspaceDiscovery?.lastSuccessAt,
        stale: true,
        errorCode: errorCode,
        errorMessage: errorMessage,
      ),
    );
    await replaceAtomic(
      signerNpub,
      current.next(stacks: [
        for (final item in current.stacks)
          if (item.id == stackId) nextEntry else item,
      ]),
    );
    return nextEntry;
  }

  Future<void> rename(String signerNpub, String stackId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 128 ||
        trimmed.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw StateError('Enter a display name of 1–128 characters.');
    }
    final current = await load(signerNpub);
    if (!current.stacks.any((s) => s.id == stackId)) {
      throw StateError('NStack no longer exists.');
    }
    await replaceAtomic(
        signerNpub,
        current.next(stacks: [
          for (final stack in current.stacks)
            if (stack.id == stackId) stack.copyWith(name: trimmed) else stack,
        ]));
  }

  Future<NStackRegistry> remove(String signerNpub, String stackId) async {
    final current = await load(signerNpub);
    final nextStacks = current.stacks.where((s) => s.id != stackId).toList();
    final next = current.next(
      stacks: nextStacks,
      clearActive: current.activeStackId == stackId,
      clearHost: current.hostStackId == stackId,
    );
    await replaceAtomic(signerNpub, next);
    return next;
  }

  Future<void> selectActive(String signerNpub, String stackId) async {
    final current = await load(signerNpub);
    if (!current.stacks.any((stack) => stack.id == stackId)) {
      throw StateError('NStack no longer exists.');
    }
    await replaceAtomic(signerNpub, current.next(activeStackId: stackId));
  }

  Future<void> selectHost(String signerNpub, String? stackId) async {
    final current = await load(signerNpub);
    if (stackId != null && !current.stacks.any((s) => s.id == stackId)) {
      throw StateError('NStack no longer exists.');
    }
    await replaceAtomic(
      signerNpub,
      current.next(hostStackId: stackId, clearHost: stackId == null),
    );
  }

  Future<void> selectBackupDestination(
    String signerNpub, {
    required String stackId,
    required String workspaceId,
  }) async {
    final current = await load(signerNpub);
    final stack =
        current.stacks.where((item) => item.id == stackId).firstOrNull;
    final workspace =
        stack?.workspaces.where((item) => item.id == workspaceId).firstOrNull;
    if (stack == null ||
        workspace == null ||
        !workspace.supportsBackup ||
        stack.workspaceDiscovery?.stale == true) {
      throw StateError('Choose a currently accessible Flight Deck workspace.');
    }
    await replaceAtomic(
      signerNpub,
      current.next(
        backupDestination: NStackBackupDestination(
          stackId: stack.id,
          workspaceId: workspace.id,
          workspaceRemoteId: workspace.remoteId,
          workspaceOwnerNpub: workspace.workspaceOwnerNpub!,
        ),
        backupDestinationMigrationVersion: 1,
      ),
    );
  }

  Future<void> clearBackupDestination(String signerNpub) async {
    final current = await load(signerNpub);
    await replaceAtomic(
      signerNpub,
      current.next(
        clearBackupDestination: true,
        backupDestinationMigrationVersion: 1,
      ),
    );
  }

  Future<void> updateActiveSettings(
    String signerNpub,
    NStackBrowserSettings Function(NStackBrowserSettings) update,
  ) async {
    final current = await load(signerNpub);
    final active = current.activeStack;
    if (active == null) return;
    final stacks = [
      for (final stack in current.stacks)
        if (stack.id == active.id)
          stack.copyWith(settings: update(stack.settings))
        else
          stack,
    ];
    await replaceAtomic(signerNpub, current.next(stacks: stacks));
  }

  /// Copies legacy v1 launcher settings to the first selected NStack once.
  /// Legacy data is deliberately retained for rollback and never overwritten.
  Future<void> migrateLegacyBrowserSettings(
    String signerNpub, {
    required List<BrowserBookmark> bookmarks,
    String? background,
    String labelColour = '#ffffff',
    bool builtInStartup = false,
  }) async {
    final current = await load(signerNpub);
    final active = current.activeStack;
    if (active == null ||
        active.settings.bookmarks.isNotEmpty ||
        bookmarks.isEmpty &&
            background == null &&
            labelColour == '#ffffff' &&
            !builtInStartup) {
      return;
    }
    await updateActiveSettings(
      signerNpub,
      (_) => NStackBrowserSettings(
        bookmarks: List.unmodifiable(bookmarks),
        background: background,
        labelColour: safeLabelColour(labelColour),
        builtInStartup: builtInStartup,
      ),
    );
  }
}

NStackRegistry _migrateLegacyBackupDestination(NStackRegistry registry) {
  if (registry.backupDestinationMigrationVersion >= 1 ||
      registry.backupDestination != null) {
    return registry;
  }
  NStackBackupDestination? destination;
  final host = registry.hostStack;
  if (host == null) return registry;
  if (host.workspaceDiscovery?.stale != true) {
    final accessible = host.workspaces
        .where((workspace) => workspace.supportsBackup)
        .toList(growable: false);
    if (accessible.length == 1) {
      final workspace = accessible.single;
      destination = NStackBackupDestination(
        stackId: host.id,
        workspaceId: workspace.id,
        workspaceRemoteId: workspace.remoteId,
        workspaceOwnerNpub: workspace.workspaceOwnerNpub!,
      );
    }
  }
  return registry.next(
    backupDestination: destination,
    clearBackupDestination: destination == null,
    backupDestinationMigrationVersion: 1,
  );
}

String _workspaceStableIdentity(NStackWorkspace workspace) =>
    '${workspace.stableRemoteId ?? workspace.remoteId}\u0000${workspace.workspaceOwnerNpub ?? ''}\u0000${workspace.workspaceServiceNpub ?? ''}';

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

String newNStackOpaqueId() {
  final random = Random.secure();
  final bytes = List<int>.generate(18, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}
