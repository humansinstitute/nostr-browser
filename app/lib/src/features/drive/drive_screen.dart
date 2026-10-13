import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/app_config.dart';
import '../../core/fips_runtime_service.dart';
import '../../core/native_core_bridge.dart';
import 'drive_host.dart';

class DriveScreen extends StatefulWidget {
  const DriveScreen(
      {required this.config,
      required this.bridge,
      this.host,
      this.fipsRuntime,
      super.key});
  final AppConfig config;
  final NativeCoreBridge bridge;
  final DriveHost? host;
  final FipsRuntimeService? fipsRuntime;
  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  late final DriveHost host =
      widget.host ?? DriveHost(fipsRuntime: widget.fipsRuntime);
  @override
  void initState() {
    super.initState();
    unawaited(host.configure(widget.config));
  }

  @override
  void didUpdateWidget(covariant DriveScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(host.configure(widget.config));
  }

  @override
  void dispose() {
    host.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = TextEditingController(text: 'Shared folder');
    final source = TextEditingController(text: 'Desktop');
    var audience = 'private';
    final approved = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, set) => AlertDialog(
                    title: const Text('Share a folder'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: name,
                          maxLength: 120,
                          decoration:
                              const InputDecoration(labelText: 'Share name')),
                      TextField(
                          controller: source,
                          maxLength: 120,
                          decoration:
                              const InputDecoration(labelText: 'Source name')),
                      SelectableText('Workspace: ${widget.config.workspaceId}'),
                      DropdownButton<String>(
                          value: audience,
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(
                                value: 'private',
                                child: Text('Only I can read')),
                            DropdownMenuItem(
                                value: 'workspace',
                                child: Text('Anyone in the workspace'))
                          ],
                          onChanged: (v) => set(() => audience = v!)),
                      const Text(
                          'Select the folder in the next window. Hosting stops when you lock or exit Nostr Browser.')
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Choose folder'))
                    ])));
    if (approved == true) {
      try {
        await host.add(name.text.trim(), audience, source.text.trim());
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  'Sharing could not be registered. ${host.safeRegistrationError(error)}.')));
        }
      }
    }
    name.dispose();
    source.dispose();
  }

  Future<void> _edit(Map<String, dynamic> share) async {
    final name = TextEditingController(text: share['name']);
    var audience = share['audience'] as String;
    final approved = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, set) => AlertDialog(
                    title: const Text('Edit share'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: name,
                          maxLength: 120,
                          decoration:
                              const InputDecoration(labelText: 'Share name')),
                      DropdownButton<String>(
                          value: audience,
                          items: const [
                            DropdownMenuItem(
                                value: 'private',
                                child: Text('Only I can read')),
                            DropdownMenuItem(
                                value: 'workspace',
                                child: Text('Anyone in the workspace'))
                          ],
                          onChanged: (v) => set(() => audience = v!))
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Save and share'))
                    ])));
    if (approved == true) {
      try {
        await host.updateShare(share, name.text.trim(), audience);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  'Could not update sharing. ${host.safeRegistrationError(error)}.')));
        }
      }
    }
    name.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: host,
      builder: (context, _) =>
          ListView(padding: const EdgeInsets.all(24), children: [
            Text('Shared folders',
                style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 12),
            Text(host.supported
                ? host.message
                : 'Browse shared folders in Flight Deck. Phone background hosting is not supported.'),
            const SizedBox(height: 12),
            if (host.supported)
              Wrap(spacing: 12, children: [
                FilledButton.icon(
                    onPressed:
                        widget.config.hasWorkspace && host.endpoint != null
                            ? _add
                            : null,
                    icon: const Icon(Icons.create_new_folder),
                    label: const Text('Share folder')),
                OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        await host.configure(widget.config, repair: true);
                        await host.refreshPolicies();
                        for (final s in host.visible) {
                          await host.publish(s);
                        }
                      } catch (error) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(
                                  'Registration retry failed. ${host.safeRegistrationError(error)}. Local stop sharing still applies.')));
                        }
                      }
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry registration'))
              ]),
            if (!widget.config.hasWorkspace)
              const Text('Choose a Tower workspace in Setup first.'),
            if (host.supported) ...[
              const SizedBox(height: 12),
              Material(
                type: MaterialType.transparency,
                child: ExpansionTile(
                  key: const ValueKey('drive-diagnostics-section'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Diagnostics'),
                  initiallyExpanded: false,
                  children: [
                    SizedBox(
                      height: 180,
                      width: double.infinity,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: Theme.of(context).colorScheme.outline),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(host.diagnosticsText.isEmpty
                              ? 'No Drive diagnostics captured yet.'
                              : host.diagnosticsText),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(spacing: 12, children: [
                      OutlinedButton.icon(
                        key: const ValueKey('drive-copy-diagnostics'),
                        onPressed: host.hasDiagnostics
                            ? () async {
                                await Clipboard.setData(
                                    ClipboardData(text: host.diagnosticsText));
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text(
                                              'Drive diagnostics copied.')));
                                }
                              }
                            : null,
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy diagnostics'),
                      ),
                      TextButton.icon(
                        key: const ValueKey('drive-clear-diagnostics'),
                        onPressed: host.hasDiagnostics
                            ? () => host.clearDiagnostics()
                            : null,
                        icon: const Icon(Icons.clear),
                        label: const Text('Clear'),
                      ),
                    ]),
                  ],
                ),
              ),
            ],
            for (final s in host.visible)
              ListTile(
                  leading: const Icon(Icons.folder_shared),
                  title: Text(s['name']),
                  subtitle: Text(
                      '${s['root']}\n${s['audience'] == 'private' ? 'Only I can read' : 'Anyone in the workspace'} · ${host.registrationStatus(s)}'),
                  isThreeLine: true,
                  onTap: () => _edit(s),
                  trailing: s['enabled'] == true
                      ? TextButton(
                          onPressed: () => host.disable(s),
                          child: const Text('Stop sharing'))
                      : null)
          ]));
}
