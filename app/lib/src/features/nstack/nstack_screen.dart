import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/nostr_crypto.dart';
import 'nstack_access.dart';
import 'nstack_models.dart';
import 'nstack_recovery.dart';
import 'nstack_store.dart';

class NStackScreen extends StatefulWidget {
  const NStackScreen({
    required this.config,
    required this.registryStore,
    required this.grantStore,
    required this.accessService,
    required this.recoveryService,
    required this.onRegistryChanged,
    super.key,
  });

  final AppConfig config;
  final NStackRegistryStore registryStore;
  final NStackGrantStore grantStore;
  final NStackAccessService accessService;
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
  String? _message;

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
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
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
              onPressed: _busy || widget.config.deviceNpub.isEmpty
                  ? null
                  : () => _editStack(),
              icon: const Icon(Icons.add),
              label: const Text('Add NStack'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Choose the NStacks this identity uses. Websites see nothing beyond '
          'the window.NStack version until you approve discovery.',
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
    );
  }

  Widget _stackCard(NStackEntry stack) {
    final active = _registry.activeStackId == stack.id;
    final host = _registry.hostStackId == stack.id;
    return Card(
      key: ValueKey('nstack-${stack.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            ListTile(
              leading: Icon(host ? Icons.home_work : Icons.dns_outlined),
              title: Text(stack.name),
              subtitle:
                  Text('${stack.url}\n${stack.workspaces.length} workspace(s)'),
              isThreeLine: true,
              trailing: Wrap(
                children: [
                  IconButton(
                    tooltip: 'Edit ${stack.name}',
                    onPressed: _busy ? null : () => _editStack(stack),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: 'Remove ${stack.name}',
                    onPressed: _busy ? null : () => _removeStack(stack),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
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
            CheckboxListTile(
              value: host,
              onChanged: _busy
                  ? null
                  : (value) async {
                      await widget.registryStore.selectHost(
                        widget.config.deviceNpub,
                        value == true ? stack.id : null,
                      );
                      await _load();
                    },
              title: const Text('Host encrypted NBrowser backup'),
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

  Widget _recoveryCard() {
    final published = _status?['last_published_at']?.toString();
    final restored = _status?['last_restored_at']?.toString();
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
              'The host stores only NIP-44 ciphertext. A signed, self-encrypted '
              'Nostr hint points to the exact object and hash.',
            ),
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
                          _registry.hostStack == null
                      ? null
                      : _publish,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Publish backup'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('recover-nstack-backup'),
                  onPressed:
                      _busy || !widget.config.hasDeviceSecret ? null : _recover,
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
    final handles = widget.accessService.activeHandles;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Website access',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_grants.isEmpty && handles.isEmpty)
              const Text('No website discovery or capability grants.'),
            for (final grant in _grants)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.travel_explore),
                title: Text(grant.origin),
                subtitle: Text('${grant.stackIds.length} disclosed NStack(s)'),
                trailing: TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          await widget.accessService.revokeOrigin(
                              widget.config.deviceNpub, grant.origin);
                          await _load();
                        },
                  child: const Text('Revoke'),
                ),
              ),
            for (final handle in handles)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.key_off_outlined),
                title: Text(handle.origin),
                subtitle: Text(handle.capabilities.join(', ')),
                trailing: TextButton(
                  onPressed: () =>
                      widget.accessService.revokeFromManagement(handle.handle),
                  child: const Text('Revoke handle'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editStack([NStackEntry? existing]) async {
    final result = await showDialog<NStackEntry>(
      context: context,
      builder: (context) => _NStackEditor(existing: existing),
    );
    if (result == null) return;
    await _run(() async {
      await widget.registryStore.addOrUpdate(
        widget.config.deviceNpub,
        result,
        makeActive: existing == null && _registry.stacks.isEmpty,
      );
      widget.onRegistryChanged();
      _message = '${result.name} saved.';
    });
  }

  Future<void> _removeStack(NStackEntry stack) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Remove ${stack.name}?'),
            content: const Text(
                'This removes its local metadata and revokes active handles. Existing encrypted backup objects are immutable.'),
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
      _message = '${stack.name} removed.';
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
                  'Host: ${preview.pointer.hostUrl}\n'
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
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      _message = error.toString().replaceFirst('Bad state: ', '');
    } finally {
      await _load();
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _NStackEditor extends StatefulWidget {
  const _NStackEditor({this.existing});
  final NStackEntry? existing;

  @override
  State<_NStackEditor> createState() => _NStackEditorState();
}

class _NStackEditorState extends State<_NStackEditor> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _fips;
  late final TextEditingController _peer;
  late final TextEditingController _workspaces;
  String? _error;

  @override
  void initState() {
    super.initState();
    final stack = widget.existing;
    _name = TextEditingController(text: stack?.name ?? '');
    _url = TextEditingController(text: stack?.url ?? '');
    _fips = TextEditingController(text: stack?.fipsEndpoint ?? '');
    _peer = TextEditingController(text: stack?.peerNpub ?? '');
    _workspaces = TextEditingController(
      text: stack?.workspaces
              .map((workspace) => '${workspace.name}|${workspace.remoteId}')
              .join('\n') ??
          '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _fips.dispose();
    _peer.dispose();
    _workspaces.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add NStack' : 'Edit NStack'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name')),
              TextField(
                  controller: _url,
                  decoration: const InputDecoration(labelText: 'HTTPS URL')),
              TextField(
                  controller: _fips,
                  decoration: const InputDecoration(
                      labelText: 'FIPS endpoint (optional)')),
              TextField(
                  controller: _peer,
                  decoration: const InputDecoration(
                      labelText: 'Pinned FIPS peer npub (optional)')),
              TextField(
                controller: _workspaces,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Workspaces',
                  helperText: 'One per line: Display name|remote workspace ID',
                ),
              ),
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
    final name = _name.text.trim();
    final url = canonicalNStackUrl(_url.text);
    final fips = canonicalFipsEndpoint(_fips.text);
    final peer = _peer.text.trim();
    var peerValid = peer.isEmpty;
    if (peer.isNotEmpty) {
      try {
        NostrCrypto.publicKeyHexFromNpub(peer);
        peerValid = true;
      } catch (_) {}
    }
    if (name.isEmpty || url == null) {
      setState(() => _error = 'Enter a name and valid HTTPS URL.');
      return;
    }
    if ((_fips.text.trim().isEmpty) != peer.isEmpty ||
        !peerValid ||
        (_fips.text.trim().isNotEmpty && fips == null)) {
      setState(() =>
          _error = 'FIPS endpoint and pinned peer npub must both be valid.');
      return;
    }
    final existingByRemote = {
      for (final workspace
          in widget.existing?.workspaces ?? const <NStackWorkspace>[])
        workspace.remoteId: workspace,
    };
    final workspaces = <NStackWorkspace>[];
    final seen = <String>{};
    for (final line in _workspaces.text.split('\n')) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('|');
      if (parts.length != 2 || parts.any((part) => part.trim().isEmpty)) {
        setState(() => _error = 'Each workspace must use Name|remote ID.');
        return;
      }
      final remote = parts[1].trim();
      if (!seen.add(remote)) {
        setState(() => _error = 'Workspace remote IDs must be unique.');
        return;
      }
      workspaces.add(NStackWorkspace(
        id: existingByRemote[remote]?.id ?? newNStackOpaqueId(),
        name: parts[0].trim(),
        remoteId: remote,
      ));
    }
    Navigator.pop(
      context,
      NStackEntry(
        id: widget.existing?.id ?? newNStackOpaqueId(),
        name: name,
        url: url,
        fipsEndpoint: fips,
        peerNpub: peer.isEmpty ? null : peer,
        workspaces: workspaces,
        settings: widget.existing?.settings ?? const NStackBrowserSettings(),
      ),
    );
  }
}
