import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_config.dart';
import 'nstack_access.dart';
import 'nstack_discovery.dart';
import 'nstack_workspace_discovery.dart';
import 'nstack_models.dart';
import 'nstack_recovery.dart';
import 'nstack_store.dart';

class NStackScreen extends StatefulWidget {
  const NStackScreen({
    required this.config,
    required this.registryStore,
    required this.grantStore,
    required this.accessService,
    required this.discoveryService,
    this.catalogueDiscoveryService,
    required this.recoveryService,
    required this.onRegistryChanged,
    super.key,
  });

  final AppConfig config;
  final NStackRegistryStore registryStore;
  final NStackGrantStore grantStore;
  final NStackAccessService accessService;
  final NStackWorkspaceDiscoveryService discoveryService;
  final NStackDiscoveryService? catalogueDiscoveryService;
  final NStackRecoveryService recoveryService;
  final VoidCallback onRegistryChanged;

  @override
  State<NStackScreen> createState() => _NStackScreenState();
}

class _NStackScreenState extends State<NStackScreen> {
  NStackRegistry _registry = const NStackRegistry();
  List<NStackDiscoveryGrant> _grants = const [];
  Map<String, dynamic>? _status;
  bool _busy = false;
  String? _refreshingStackId;
  String? _message;
  NStackBackupNamespaceState? _namespaceState;
  String? _namespaceDestinationKey;
  int _identityEpoch = 0;

  @override
  void initState() {
    super.initState();
    widget.accessService.addListener(_refreshView);
    widget.grantStore.addListener(_refreshView);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant NStackScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accessService != widget.accessService) {
      oldWidget.accessService.removeListener(_refreshView);
      widget.accessService.addListener(_refreshView);
    }
    if (oldWidget.grantStore != widget.grantStore) {
      oldWidget.grantStore.removeListener(_refreshView);
      widget.grantStore.addListener(_refreshView);
    }
    if (oldWidget.config.deviceNpub != widget.config.deviceNpub) {
      _identityEpoch++;
      setState(() {
        _registry = const NStackRegistry();
        _grants = const [];
        _status = null;
        _busy = false;
        _refreshingStackId = null;
        _message = null;
        _namespaceState = null;
        _namespaceDestinationKey = null;
      });
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    widget.accessService.removeListener(_refreshView);
    widget.grantStore.removeListener(_refreshView);
    super.dispose();
  }

  void _refreshView() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final identity = widget.config.deviceNpub;
    final registry = await widget.registryStore.load(identity);
    final grants = await widget.grantStore.list(identity);
    final status = await widget.recoveryService.statusStore.load(identity);
    if (!mounted || identity != widget.config.deviceNpub) return;
    setState(() {
      _registry = registry;
      _grants = grants;
      _status = status;
    });
    final destination = registry.backupDestination;
    final destinationKey = destination == null
        ? null
        : '${destination.stackId}:${destination.workspaceId}';
    if (destinationKey != null &&
        registry.backupDestinationAvailable &&
        widget.config.hasDeviceSecret &&
        _namespaceDestinationKey != destinationKey) {
      _namespaceDestinationKey = destinationKey;
      unawaited(_checkNamespace());
    } else if (destinationKey == null || !registry.backupDestinationAvailable) {
      _namespaceDestinationKey = destinationKey;
      _namespaceState = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return RadioGroup<String>(
      groupValue: _registry.backupDestination == null
          ? null
          : '${_registry.backupDestination!.stackId}:${_registry.backupDestination!.workspaceId}',
      onChanged: _selectBackupValue,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text('NStacks',
                    style: Theme.of(context).textTheme.headlineMedium),
              ),
              FilledButton.icon(
                key: const ValueKey('add-nstack'),
                onPressed: _busy || !widget.config.hasDeviceSecret
                    ? null
                    : () => _editStack(),
                icon: const Icon(Icons.add),
                label: const Text('Add NStack'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            widget.config.hasDeviceSecret
                ? 'Workspace discovery is signed by NBrowser’s active, unlocked '
                    'identity (${abbreviatedNpub(widget.config.deviceNpub)}). A website login inside '
                    'a tab does not change this identity. Websites see nothing '
                    'beyond the window.NStack version until you approve discovery.'
                : 'Unlock NBrowser’s active Nostr identity to add or refresh an '
                    'NStack. A website login inside a tab does not select the '
                    'discovery identity.',
            key: const ValueKey('nstack-discovery-identity'),
          ),
          const SizedBox(height: 18),
          if (_registry.stacks.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.dns_outlined),
                title: Text('No NStacks yet'),
                subtitle:
                    Text('Add one to enable discovery and encrypted backup.'),
              ),
            ),
          if (_busy) const LinearProgressIndicator(),
          for (final stack in _registry.stacks) _stackCard(stack),
          const SizedBox(height: 18),
          _recoveryCard(),
          const SizedBox(height: 18),
          _accessCard(),
          if (_message != null) ...[
            const SizedBox(height: 14),
            Text(_message!, key: const ValueKey('nstack-message')),
          ],
        ],
      ),
    );
  }

  Widget _stackCard(NStackEntry stack) {
    final active = _registry.activeStackId == stack.id;
    return Card(
      key: ValueKey('nstack-${stack.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(stack.displayName),
              subtitle: Text(
                  '${abbreviatedNpub(stack.publicIdentity)}\n${stack.workspaces.length} workspace(s)'),
              isThreeLine: true,
              trailing: Wrap(
                children: [
                  IconButton(
                    tooltip: 'Refresh workspaces',
                    onPressed: _busy || !widget.config.hasDeviceSecret
                        ? null
                        : () => _refreshStack(stack),
                    icon: _refreshingStackId == stack.id
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: 'Rename NStack',
                    onPressed: _busy ? null : () => _renameStack(stack),
                    icon: const Icon(Icons.drive_file_rename_outline),
                  ),
                  IconButton(
                    tooltip: 'Reveal connection details',
                    onPressed: _busy ? null : () => _showDetails(stack),
                    icon: const Icon(Icons.info_outline),
                  ),
                  IconButton(
                    tooltip: 'Connection details and address',
                    onPressed: _busy || !widget.config.hasDeviceSecret
                        ? null
                        : () => _editStack(stack),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: 'Remove NStack',
                    onPressed: _busy ? null : () => _removeStack(stack),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
            _serviceCatalogue(stack),
            if (stack.workspaceDiscovery == null)
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('Authenticated refresh required'),
                subtitle: Text(
                    'Previously entered workspace rows are retained until refresh replaces them with server discovery.'),
              )
            else if (stack.workspaceDiscovery!.hasError)
              ListTile(
                leading: const Icon(Icons.warning_amber),
                title: const Text('Workspace refresh failed'),
                subtitle: Text(
                  'Could not refresh workspaces. Try again from connection details.\n'
                  '${stack.workspaces.isEmpty ? 'No workspace was saved.' : 'Showing last-known-good workspaces; they may be stale.'}',
                ),
              )
            else if (stack.workspaces.isEmpty)
              const ListTile(
                leading: Icon(Icons.workspaces_outline),
                title: Text('No accessible workspaces'),
                subtitle: Text(
                    'The active identity authenticated successfully but this NStack returned no workspaces.'),
              )
            else
              for (final workspace in stack.workspaces)
                ListTile(
                  key: ValueKey('backup-workspace-${stack.id}-${workspace.id}'),
                  dense: true,
                  leading: Radio<String>(
                    value: '${stack.id}:${workspace.id}',
                    enabled: !_busy &&
                        workspace.supportsBackup &&
                        stack.workspaceDiscovery?.stale != true,
                  ),
                  title: Text(workspace.displayName),
                  subtitle: Text(
                    workspace.supportsBackup
                        ? '${stack.displayName} · ${abbreviatedNpub(workspace.workspaceServiceNpub)}'
                        : '${stack.displayName} · unavailable for workspace backup',
                  ),
                  onTap: _busy ||
                          !workspace.supportsBackup ||
                          stack.workspaceDiscovery?.stale == true
                      ? null
                      : () => _selectBackupDestination(stack, workspace),
                ),
            ListTile(
              leading: Icon(active
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              onTap: _busy
                  ? null
                  : () async {
                      await widget.registryStore
                          .selectActive(widget.config.deviceNpub, stack.id);
                      widget.onRegistryChanged();
                      await _load();
                    },
              title: const Text('Use browser links and preferences'),
            ),
            if (active)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 8),
                  child: Text(
                      '${stack.settings.bookmarks.length} browser link(s) stored for this NStack.'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _serviceCatalogue(NStackEntry stack) {
    final status = stack.catalogueStatus;
    final catalogue = status?.catalogue;
    final stale = catalogue == null || catalogue.isStaleAt(DateTime.now());
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              catalogue == null
                  ? 'Services not verified'
                  : 'Services checked ${status!.checkedAt.toLocal()}${stale ? ' — stale' : ''}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            if (status?.hasError == true)
              Text('Last service refresh failed. Try refreshing again.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            for (final service
                in catalogue?.services ?? const <NStackService>[])
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${_serviceLabel(service)} — ${service.availability.name}',
                  key: ValueKey('nstack-service-${stack.id}-${service.id}'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _serviceLabel(NStackService service) => switch (service.id) {
        'tower' => 'Tower',
        'relay' => 'Relay',
        'blossom' => 'Blossom',
        _ => 'Service',
      };

  Widget _recoveryCard() {
    final published = _status?['last_published_at']?.toString();
    final restored = _status?['last_restored_at']?.toString();
    final destination = _registry.backupDestination;
    final backupStack = _registry.backupStack;
    final backupWorkspace = _registry.backupWorkspace;
    final destinationAvailable = _registry.backupDestinationAvailable;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Encrypted backup and recovery',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'The selected workspace stores only NIP-44 ciphertext and a private '
              'NBrowser pointer row. A self-encrypted Nostr hint is supplementary.',
            ),
            const SizedBox(height: 8),
            if (destination == null)
              const Text(
                  'Choose one workspace above as the backup destination.',
                  key: ValueKey('backup-destination-missing'))
            else if (!destinationAvailable)
              Text(
                'Selected destination unavailable: ${backupStack?.displayName ?? 'removed NStack'} · '
                '${backupWorkspace?.displayName ?? 'removed workspace'}. Refresh access or choose another workspace.',
                key: const ValueKey('backup-destination-unavailable'),
              )
            else
              Text(
                'Backup destination: ${backupStack!.displayLabel} · ${backupWorkspace!.displayLabel}',
                key: const ValueKey('backup-destination-selected'),
              ),
            if (_namespaceState ==
                NStackBackupNamespaceState.managerRequired) ...[
              const SizedBox(height: 8),
              const Text(
                'A workspace manager must enable NBrowser backup for this workspace.',
                key: ValueKey('backup-namespace-manager-required'),
              ),
              if (backupWorkspace?.canManageBackupNamespace == true)
                TextButton.icon(
                  key: const ValueKey('enable-nbrowser-backup-namespace'),
                  onPressed: _busy ? null : _enableNamespace,
                  icon: const Icon(Icons.admin_panel_settings_outlined),
                  label: const Text('Enable NBrowser backup'),
                ),
            ],
            if (published != null) Text('Last published: $published'),
            if (restored != null) Text('Last restored: $restored'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  key: const ValueKey('publish-nstack-backup'),
                  onPressed: _busy ||
                          !widget.config.hasDeviceSecret ||
                          !destinationAvailable ||
                          _namespaceState ==
                              NStackBackupNamespaceState.managerRequired
                      ? null
                      : _publish,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Publish backup'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('recover-nstack-backup'),
                  onPressed: _busy ||
                          !widget.config.hasDeviceSecret ||
                          !destinationAvailable ||
                          _namespaceState ==
                              NStackBackupNamespaceState.managerRequired
                      ? null
                      : _recover,
                  icon: const Icon(Icons.restore),
                  label: const Text('Find recovery'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _accessCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Website access',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_grants.isEmpty)
              const Text('No websites can discover saved connections.'),
            for (final grant in _grants)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.travel_explore),
                title: const Text('Approved website'),
                onTap: () => _showWebsiteDetails(grant.origin),
                subtitle: Text('${grant.stackIds.length} disclosed NStack(s)'),
                trailing: Wrap(children: [
                  IconButton(
                      tooltip: 'Reveal website origin',
                      icon: const Icon(Icons.info_outline),
                      onPressed: _busy
                          ? null
                          : () => _showWebsiteDetails(grant.origin)),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            await widget.accessService.revokeOrigin(
                                widget.config.deviceNpub, grant.origin);
                            await _load();
                          },
                    child: const Text('Revoke'),
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showWebsiteDetails(String origin) async {
    final identity = widget.config.deviceNpub;
    await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: const Text('Website access details'),
              content: _detail('Website origin', origin),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Close')),
                TextButton(
                    onPressed: () async {
                      if (identity != widget.config.deviceNpub) return;
                      await widget.accessService.revokeOrigin(identity, origin);
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      await _load();
                    },
                    child: const Text('Revoke this website')),
              ],
            ));
  }

  Future<void> _selectBackupDestination(
      NStackEntry stack, NStackWorkspace workspace) async {
    await _run(() async {
      await widget.registryStore.selectBackupDestination(
        widget.config.deviceNpub,
        stackId: stack.id,
        workspaceId: workspace.id,
      );
      _namespaceDestinationKey = null;
      _namespaceState = null;
      _message =
          'Backup destination selected: ${stack.displayName} · ${workspace.displayName}.';
    });
  }

  void _selectBackupValue(String? value) {
    if (value == null || _busy) return;
    for (final stack in _registry.stacks) {
      for (final workspace in stack.workspaces) {
        if (value == '${stack.id}:${workspace.id}' &&
            workspace.supportsBackup &&
            stack.workspaceDiscovery?.stale != true) {
          unawaited(_selectBackupDestination(stack, workspace));
          return;
        }
      }
    }
  }

  Future<void> _checkNamespace() async {
    final identityEpoch = _identityEpoch;
    try {
      final state = await widget.recoveryService.namespaceState(
        identityNpub: widget.config.deviceNpub,
        secret: widget.config.deviceSecret,
      );
      if (mounted && identityEpoch == _identityEpoch) {
        setState(() => _namespaceState = state);
      }
    } catch (error) {
      if (mounted && identityEpoch == _identityEpoch) {
        setState(() {
          _namespaceState = null;
          _message = _safeError(error);
        });
      }
    }
  }

  Future<void> _enableNamespace() => _run(() async {
        await widget.recoveryService.enableNamespace(
          identityNpub: widget.config.deviceNpub,
          secret: widget.config.deviceSecret,
        );
        _namespaceState = NStackBackupNamespaceState.enabled;
        _message = 'NBrowser backup enabled for the selected workspace.';
      });

  String _safeError(Object error) {
    if (error is StateError &&
        (error.message ==
                'NStack identity could not be matched. Add it as a separate connection.' ||
            error.message ==
                'NStack identity changed. Add it as a separate connection.')) {
      return error.message.toString();
    }
    return 'The operation could not be completed. Check the connection details and try again.';
  }

  Future<void> _renameStack(NStackEntry stack) async {
    final identity = widget.config.deviceNpub;
    var draftName = stack.displayName;
    final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Rename NStack'),
              content: TextFormField(
                  initialValue: draftName,
                  onChanged: (value) => draftName = value,
                  autofocus: true,
                  maxLength: 128,
                  decoration: const InputDecoration(labelText: 'Display name')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, draftName),
                    child: const Text('Save')),
              ],
            ));
    if (name == null || !mounted || identity != widget.config.deviceNpub) {
      return;
    }
    await _run(() async {
      await widget.registryStore.rename(identity, stack.id, name);
      widget.onRegistryChanged();
      _message = 'NStack display name saved.';
    });
  }

  Future<void> _showDetails(NStackEntry stack) async {
    final identity = widget.config.deviceNpub;
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Connection details'),
              content: SizedBox(
                  width: 520,
                  child: SingleChildScrollView(
                      child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _detail('Connection address', stack.url),
                      if (stack.publicIdentity != null)
                        _detail('NStack identity', stack.publicIdentity!),
                      _detail('Active identity', identity),
                      for (final service
                          in stack.catalogueStatus?.catalogue?.services ??
                              <NStackService>[])
                        _detail(_serviceLabel(service), service.endpoint),
                      for (final workspace in stack.workspaces) ...[
                        Text(workspace.displayName),
                        _detail('Workspace ID', workspace.remoteId),
                        if (workspace.workspaceServiceNpub != null)
                          _detail('Workspace identity',
                              workspace.workspaceServiceNpub!),
                      ],
                    ],
                  ))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'))
              ],
            ));
  }

  Widget _detail(String label, String value) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: SelectableText(value),
        trailing: IconButton(
            tooltip: 'Copy $label',
            icon: const Icon(Icons.copy),
            onPressed: () => Clipboard.setData(ClipboardData(text: value))),
      );

  Future<void> _editStack([NStackEntry? existing]) async {
    final address = await showDialog<String>(
      context: context,
      builder: (context) => _NStackEditor(existingAddress: existing?.url),
    );
    if (address == null) return;
    final identity = widget.config.deviceNpub;
    final secret = widget.config.deviceSecret;
    await _run(() async {
      _message = 'Authenticating and discovering workspaces…';
      if (mounted) setState(() {});
      final result = existing == null
          ? await widget.discoveryService.add(
              identityNpub: identity,
              secret: secret,
              address: address,
            )
          : await widget.discoveryService.changeAddress(
              identityNpub: identity,
              secret: secret,
              stackId: existing.id,
              address: address,
            );
      if (identity != widget.config.deviceNpub ||
          secret != widget.config.deviceSecret) {
        return;
      }
      final checked =
          await widget.catalogueDiscoveryService?.refresh(identity, result.id);
      widget.onRegistryChanged();
      final serviceSuffix = checked?.catalogueStatus?.hasError == true
          ? ' Service catalogue refresh failed; the last verified catalogue was retained.'
          : ' Services verified.';
      _message = result.workspaces.isEmpty
          ? '${result.displayName} saved; this identity has no accessible workspaces.'
              '$serviceSuffix'
          : '${result.displayName} saved with ${result.workspaces.length} workspace(s).'
              '$serviceSuffix';
    });
  }

  Future<void> _refreshStack(NStackEntry stack) async {
    final identity = widget.config.deviceNpub;
    final secret = widget.config.deviceSecret;
    setState(() => _refreshingStackId = stack.id);
    await _run(() async {
      final refreshed = await widget.discoveryService.refresh(
        identityNpub: identity,
        secret: secret,
        stackId: stack.id,
      );
      if (identity != widget.config.deviceNpub ||
          secret != widget.config.deviceSecret) {
        return;
      }
      final checked =
          await widget.catalogueDiscoveryService?.refresh(identity, stack.id);
      widget.onRegistryChanged();
      final serviceSuffix = checked?.catalogueStatus?.hasError == true
          ? ' Service catalogue refresh failed; the last verified catalogue was retained.'
          : ' Services verified.';
      _message = refreshed.workspaces.isEmpty
          ? 'Refresh complete; no accessible workspaces were returned.$serviceSuffix'
          : 'Refreshed ${refreshed.workspaces.length} workspace(s).$serviceSuffix';
    });
    if (mounted &&
        identity == widget.config.deviceNpub &&
        secret == widget.config.deviceSecret) {
      setState(() => _refreshingStackId = null);
    }
  }

  Future<void> _removeStack(NStackEntry stack) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Remove ${stack.displayName}?'),
            content: const Text(
                'This removes its local metadata and website discovery aliases. Existing encrypted backup objects are immutable.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Remove')),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _run(() async {
      widget.accessService.revokeStack(stack.id);
      await widget.registryStore.remove(widget.config.deviceNpub, stack.id);
      widget.onRegistryChanged();
      _message = '${stack.displayName} removed.';
    });
  }

  Future<void> _publish() => _run(() async {
        final result = await widget.recoveryService.publish(
          identityNpub: widget.config.deviceNpub,
          publicKeyHex: widget.config.devicePublicKeyHex,
          secret: widget.config.deviceSecret,
        );
        _message = result.published
            ? 'Backup published to ${result.acceptedRelays.length}/${result.totalRelays} relays.'
            : 'Encrypted object uploaded, but no relay accepted the recovery hint.';
      });

  Future<void> _recover() => _run(() async {
        final preview = await widget.recoveryService.retrieve(
          identityNpub: widget.config.deviceNpub,
          publicKeyHex: widget.config.devicePublicKeyHex,
          secret: widget.config.deviceSecret,
        );
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Restore NBrowser settings?'),
                content: Text(
                  'Snapshot: ${preview.snapshot.createdAt.toLocal()}\n'
                  'NStacks: ${preview.snapshot.registry.stacks.length}\n'
                  'Browser links: ${preview.snapshot.registry.stacks.fold<int>(0, (sum, stack) => sum + stack.settings.bookmarks.length)}\n\n'
                  'The current local registry changes only after you confirm.',
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Restore')),
                ],
              ),
            ) ??
            false;
        if (!confirmed) {
          _message = 'Recovery preview checked; nothing was changed.';
          return;
        }
        await widget.recoveryService
            .restoreConfirmed(widget.config.deviceNpub, preview);
        widget.onRegistryChanged();
        _message = 'NStacks and browser links restored.';
      });

  Future<void> _run(Future<void> Function() action) async {
    final identityEpoch = _identityEpoch;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (identityEpoch == _identityEpoch) {
        _message = _safeError(error);
      }
    } finally {
      if (identityEpoch == _identityEpoch) {
        await _load();
        if (mounted && identityEpoch == _identityEpoch) {
          setState(() => _busy = false);
        }
      }
    }
  }
}

class _NStackEditor extends StatefulWidget {
  const _NStackEditor({this.existingAddress});
  final String? existingAddress;

  @override
  State<_NStackEditor> createState() => _NStackEditorState();
}

class _NStackEditorState extends State<_NStackEditor> {
  late final TextEditingController _url;
  String? _error;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.existingAddress ?? '');
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existingAddress == null
          ? 'Add NStack'
          : 'Change NStack address'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: _url,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'NStack HTTPS address',
                    helperText:
                        'NBrowser will authenticate and discover every workspace available to the active identity.',
                  )),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  void _save() {
    final url = canonicalNStackUrl(_url.text);
    if (url == null) {
      setState(() => _error = 'Enter a valid HTTPS NStack address.');
      return;
    }
    Navigator.pop(context, url);
  }
}
