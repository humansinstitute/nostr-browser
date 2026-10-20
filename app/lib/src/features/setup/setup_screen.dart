import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/fips_app_target.dart';
import '../../core/fips_runtime_service.dart';
import '../../core/native_core_bridge.dart';
import '../browser/signer_policy.dart';
import '../browser/relay_diagnostics.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    required this.config,
    this.relayDiagnosticsSaved = false,
    this.relayDiagnosticsAtLaunch = false,
    this.onRelayDiagnosticsChanged,
    required this.bridge,
    required this.fipsRuntime,
    required this.onConfigChanged,
    required this.onClearBrowserData,
    required this.onOpenFipsApp,
    this.localFlightDeckUrl = '',
    super.key,
  });

  final AppConfig config;
  final bool relayDiagnosticsSaved;
  final bool relayDiagnosticsAtLaunch;
  final Future<void> Function(bool)? onRelayDiagnosticsChanged;
  final NativeCoreBridge bridge;
  final FipsRuntimeService fipsRuntime;
  final ValueChanged<AppConfig> onConfigChanged;
  final Future<void> Function() onClearBrowserData;
  final ValueChanged<String> onOpenFipsApp;
  final String localFlightDeckUrl;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _towerController;
  late final TextEditingController _appNpubController;
  late final TextEditingController _flightDeckController;
  late final TextEditingController _workspaceController;
  late final TextEditingController _workspaceServiceController;
  late final TextEditingController _channelController;
  late final TextEditingController _registrationSecretController;
  late final TextEditingController _deviceNpubController;
  late final TextEditingController _devicePublicKeyHexController;
  late final TextEditingController _trustedOriginsController;
  late bool _rememberNip98Approvals;
  late bool _displayExperimentalFlightDeckDriveSync;
  String? _message;
  String? _fipsMessage;
  bool _busy = false;
  bool _exportBusy = false;
  bool _relayBusy = false;
  FipsRuntimeStatus? _fipsStatus;

  @override
  void initState() {
    super.initState();
    _towerController = TextEditingController(text: widget.config.towerUrl);
    _appNpubController = TextEditingController(text: widget.config.appNpub);
    _flightDeckController =
        TextEditingController(text: widget.config.flightDeckUrl);
    _workspaceController =
        TextEditingController(text: widget.config.workspaceId);
    _workspaceServiceController =
        TextEditingController(text: widget.config.workspaceServiceNpub);
    _channelController = TextEditingController(text: widget.config.channelId);
    _registrationSecretController =
        TextEditingController(text: widget.config.registrationSecret);
    _deviceNpubController =
        TextEditingController(text: widget.config.deviceNpub);
    _devicePublicKeyHexController =
        TextEditingController(text: widget.config.devicePublicKeyHex);
    _trustedOriginsController = TextEditingController(
      text: widget.config.trustedOrigins.join('\n'),
    );
    _rememberNip98Approvals = widget.config.rememberNip98Approvals;
    _displayExperimentalFlightDeckDriveSync =
        widget.config.displayExperimentalFlightDeckDriveSync;
    _refreshFipsStatus();
  }

  @override
  void dispose() {
    _towerController.dispose();
    _appNpubController.dispose();
    _flightDeckController.dispose();
    _workspaceController.dispose();
    _workspaceServiceController.dispose();
    _channelController.dispose();
    _registrationSecretController.dispose();
    _deviceNpubController.dispose();
    _devicePublicKeyHexController.dispose();
    _trustedOriginsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Setup', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 20),
        LayoutBuilder(builder: (context, constraints) {
          final action = OutlinedButton(
            onPressed: _busy ? null : _resetBrowserData,
            child: const Text('Reset browser data'),
          );
          final narrow = constraints.maxWidth < 500;
          final description = ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Browser data'),
            subtitle: const Text('Clear cookies, cache, and local storage.'),
            trailing: narrow ? null : action,
          );
          return narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [description, action],
                )
              : description;
        }),
        const SizedBox(height: 14),
        _fipsCard(),
        const SizedBox(height: 14),
        _towerSyncCard(),
        const SizedBox(height: 14),
        if (_displayExperimentalFlightDeckDriveSync) ...[
          _field(
            controller: _appNpubController,
            label: 'Flight Deck App npub',
            icon: Icons.apps,
          ),
          _field(
            controller: _workspaceController,
            label: 'Workspace ID',
            icon: Icons.workspaces_outline,
          ),
          _field(
            controller: _workspaceServiceController,
            label: 'Workspace service npub',
            icon: Icons.badge_outlined,
          ),
          _field(
            controller: _channelController,
            label: 'Default Channel ID',
            icon: Icons.tag,
          ),
        ],
        _field(
          controller: _deviceNpubController,
          label: 'Device npub',
          readOnly: true,
          icon: Icons.fingerprint,
        ),
        _field(
          controller: _devicePublicKeyHexController,
          label: 'Device public key hex',
          readOnly: true,
          icon: Icons.tag,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            widget.config.hasDeviceSecret
                ? Icons.lock_open_outlined
                : Icons.lock_outline,
          ),
          title: const Text('Signer key'),
          subtitle: Text(
            widget.config.hasDeviceSecret
                ? 'Unlocked for this app session. The nsec is not shown or saved in settings.'
                : 'Locked. Open the browser avatar menu to create, import or unlock your identity.',
          ),
        ),
        if (widget.config.canRegisterDevice)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
                'Optional Tower device registration: ${widget.config.towerUrl}. '
                'This uses the desktop native core and is separate from publishing your public Nostr profile.'),
          ),
        if (_displayExperimentalFlightDeckDriveSync ||
            widget.config.canRegisterDevice)
          _field(
            controller: _registrationSecretController,
            label: 'Registration signer key',
            icon: Icons.admin_panel_settings_outlined,
            obscureText: true,
          ),
        _field(
          controller: _trustedOriginsController,
          label: 'Trusted origins',
          icon: Icons.verified_user_outlined,
          maxLines: 3,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _rememberNip98Approvals,
          onChanged: (value) {
            setState(() {
              _rememberNip98Approvals = value;
            });
          },
          title: const Text('Remember NIP-98 approvals'),
          secondary: const Icon(Icons.verified_outlined),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save'),
            ),
            if (_displayExperimentalFlightDeckDriveSync ||
                widget.config.canRegisterDevice) ...[
              OutlinedButton.icon(
                onPressed: _busy ? null : _registerDevice,
                icon: const Icon(Icons.how_to_reg_outlined),
                label: const Text('Register device'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _validateChannel,
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Validate channel'),
              ),
            ],
          ],
        ),
        if (_message != null) ...[
          const SizedBox(height: 16),
          Text(_message!),
        ],
        const SizedBox(height: 16),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _displayExperimentalFlightDeckDriveSync,
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _displayExperimentalFlightDeckDriveSync = value;
            });
            widget.onConfigChanged(
              _currentConfig().copyWith(
                displayExperimentalFlightDeckDriveSync: value,
              ),
            );
          },
          title: const Text(
            'Display experimental future Flight Deck Drive sync',
          ),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  key: const ValueKey('private-relay-diagnostics'),
                  contentPadding: EdgeInsets.zero,
                  value: widget.relayDiagnosticsSaved,
                  onChanged:
                      _relayBusy || widget.onRelayDiagnosticsChanged == null
                          ? null
                          : _setRelayDiagnostics,
                  title: const Text('Private relay diagnostics'),
                  subtitle: const Text(
                    'Off by default. Saves a local, bounded trace of relay stages with random IDs. No URLs, content, keys, or identities are recorded.',
                  ),
                ),
                if (widget.relayDiagnosticsSaved !=
                    widget.relayDiagnosticsAtLaunch)
                  const Text('Restart WMapp to apply'),
                const Text(
                  'Turning this off stops new records after restart. Existing trace files remain until cleared.',
                ),
                TextButton(
                  key: const ValueKey('clear-relay-diagnostics'),
                  onPressed: _relayBusy ? null : _clearRelayDiagnostics,
                  child: const Text('Clear relay diagnostics'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _towerSyncCard() {
    final local = SignerPolicy.normalizeOrigin(widget.localFlightDeckUrl);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Flight Deck browser',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Choose FIPS in your existing Flight Deck workspace and approve '
              'its mesh endpoint. No native Tower URL is needed.',
            ),
            const SizedBox(height: 14),
            if (_displayExperimentalFlightDeckDriveSync)
              _field(
                controller: _towerController,
                label: 'Tower URL',
                icon: Icons.dns_outlined,
                helperText: 'Optional native Drive sync configuration.',
              ),
            _field(
              controller: _flightDeckController,
              label: 'Flight Deck URL',
              icon: Icons.public,
              helperText:
                  'Your existing external Flight Deck URL. Only this exact '
                  'origin can pair, plus built-in Flight Deck. Leave blank '
                  'for built-in only.',
              onChanged: (_) => setState(() {}),
            ),
            Text(local.isEmpty
                ? 'Built-in Flight Deck is not currently available.'
                : 'Built-in Flight Deck: $local'),
            const SizedBox(height: 8),
            const Text(
              'Save, reload your existing Flight Deck tab, then select FIPS '
              'and approve pairing. Changing the Flight Deck URL revokes previous '
              'pairings. Keep the same page URL to retain browser data.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _fipsCard() {
    final status = _fipsStatus;
    final state = status?.state;
    final canInstall = state == FipsRuntimeState.notInstalled ||
        state == FipsRuntimeState.consentRequired ||
        state == FipsRuntimeState.installRequired ||
        state == FipsRuntimeState.degraded ||
        state == FipsRuntimeState.failed;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(state == FipsRuntimeState.running
                    ? Icons.hub
                    : Icons.hub_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'FIPS transport',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(_fipsStateLabel(state)),
              ],
            ),
            const SizedBox(height: 8),
            Text(status?.detail ?? 'Checking bundled FIPS runtime…'),
            if (status?.nodeNpub != null) ...[
              const SizedBox(height: 6),
              SelectableText('Node: ${status!.nodeNpub}'),
            ],
            const SizedBox(height: 12),
            SwitchListTile(
              key: const ValueKey('fips-enabled'),
              title: const Text('Enable FIPS in Nostr Browser'),
              subtitle: const Text(
                  'FIPS-only services require this. HTTPS browsing works when disabled.'),
              value: widget.fipsRuntime.enabledSnapshot ?? false,
              onChanged: _busy || widget.fipsRuntime.enabledSnapshot == null
                  ? null
                  : (enabled) async {
                      await _run(enabled ? 'Enabling FIPS…' : 'Disabling FIPS…',
                          () async {
                        final status =
                            await widget.fipsRuntime.setEnabled(enabled);
                        if (mounted) setState(() => _fipsStatus = status);
                        return status.detail;
                      });
                    },
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _refreshFipsStatus,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
                if (canInstall)
                  FilledButton.icon(
                    onPressed: _busy ? null : _installOrRepairFips,
                    icon: const Icon(Icons.admin_panel_settings_outlined),
                    label: const Text('Install or repair'),
                  ),
                if (widget.fipsRuntime.supportsStop &&
                    (state == FipsRuntimeState.running ||
                        state == FipsRuntimeState.starting ||
                        state == FipsRuntimeState.degraded))
                  OutlinedButton.icon(
                    key: const ValueKey('fips-stop'),
                    onPressed: _busy ? null : _stopFips,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Stop FIPS'),
                  ),
                if (widget.fipsRuntime.supportsDiagnosticsExport)
                  OutlinedButton.icon(
                    key: const ValueKey('fips-export-diagnostics'),
                    onPressed: _exportBusy ? null : _exportFipsDiagnostics,
                    icon: _exportBusy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.ios_share_outlined),
                    label:
                        Text(_exportBusy ? 'Exporting…' : 'Export diagnostics'),
                  ),
                if (widget.fipsRuntime.supportsDiagnosticsExport)
                  TextButton.icon(
                    key: const ValueKey('fips-clear-diagnostics'),
                    onPressed: _exportBusy ? null : _clearFipsDiagnostics,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Clear diagnostics'),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _openFipsApp,
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('Open FIPS app'),
                ),
              ],
            ),
            if (_fipsMessage != null) ...[
              const SizedBox(height: 10),
              Text(_fipsMessage!),
            ],
          ],
        ),
      ),
    );
  }

  String _fipsStateLabel(FipsRuntimeState? state) {
    return switch (state) {
      null => 'checking',
      FipsRuntimeState.disabled => 'disabled',
      FipsRuntimeState.notBundled => 'not bundled',
      FipsRuntimeState.notInstalled => 'not installed',
      FipsRuntimeState.consentRequired => 'VPN consent required',
      FipsRuntimeState.installRequired => 'install required',
      FipsRuntimeState.starting => 'starting',
      FipsRuntimeState.controlAccessPending => 'diagnostics pending',
      FipsRuntimeState.running => 'running',
      FipsRuntimeState.degraded => 'degraded',
      FipsRuntimeState.failed => 'failed',
    };
  }

  Future<void> _refreshFipsStatus() async {
    final status = await widget.fipsRuntime.inspect();
    if (!mounted) return;
    setState(() {
      _fipsStatus = status;
    });
  }

  Future<void> _installOrRepairFips() async {
    if (_fipsStatus?.state == FipsRuntimeState.failed) {
      await widget.fipsRuntime.recordUiRetry();
      if (!mounted) return;
    }
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Install bundled FIPS?'),
            content: Text(widget.fipsRuntime.authorizationDescription),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Continue'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _run(widget.fipsRuntime.authorizationWaitingMessage, () async {
      final status = await widget.fipsRuntime.installOrRepair();
      if (mounted) {
        setState(() {
          _fipsStatus = status;
        });
      }
      return status.detail;
    });
  }

  Future<void> _stopFips() async {
    await _run('Stopping FIPS VPN…', () async {
      final status = await widget.fipsRuntime.stop();
      if (mounted) setState(() => _fipsStatus = status);
      return status.detail;
    });
  }

  Future<void> _exportFipsDiagnostics() async {
    if (_exportBusy) return;
    setState(() {
      _exportBusy = true;
      _fipsMessage = 'Choose where to save FIPS diagnostics…';
    });
    final result = await widget.fipsRuntime.exportDiagnostics();
    if (!mounted) return;
    setState(() {
      _exportBusy = false;
      _fipsMessage = switch (result.outcome) {
        FipsDiagnosticsExportOutcome.success => result.detail,
        FipsDiagnosticsExportOutcome.cancelled =>
          'Diagnostics export cancelled.',
        FipsDiagnosticsExportOutcome.failed => result.detail,
      };
    });
  }

  Future<void> _clearFipsDiagnostics() async {
    final detail = await widget.fipsRuntime.clearDiagnostics();
    if (!mounted) return;
    setState(() {
      _fipsMessage = detail;
    });
  }

  Future<void> _openFipsApp() async {
    final input = TextEditingController();
    var shouldProbe = false;
    final submission = await _showSettledDialog<({String value, bool probe})>(
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Open FIPS app'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('fips-app-target-field'),
                  controller: input,
                  autofocus: true,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'FIPS URL or descriptor',
                    hintText: 'http://npub1….fips:41024/',
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: shouldProbe,
                  onChanged: (value) => setDialogState(
                    () => shouldProbe = value ?? true,
                  ),
                  title: const Text('Probe node before opening'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                (value: input.text, probe: shouldProbe),
              ),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
    input.dispose();
    if (submission == null) return;

    String? appUrlToOpen;
    AppConfig? configToPersist;
    await _run('Checking FIPS transport…', () async {
      final target = FipsAppTarget.parse(submission.value);
      final status = await _ensureFipsReadyForAppAccess();
      if (!status.canAttemptAppAccess) throw StateError(status.detail);
      if (submission.probe) {
        if (!status.isRunning) {
          throw StateError(
            'The optional probe needs refreshed FIPS control permission. '
            'Open without probing, or log out and back in first.',
          );
        }
        final probe = await widget.fipsRuntime.probe(target.nodeNpub);
        if (!probe.ok) {
          if (!mounted) throw StateError('The setup screen closed.');
          final continueWithoutProbe = await _showSettledDialog<bool>(
                builder: (context) => AlertDialog(
                  title: const Text('Node not confirmed yet'),
                  content: const Text(
                    'The optional probe could not confirm an existing mesh '
                    'route. Opening the exact URL will let FIPS attempt normal '
                    'discovery. If it still fails, inspect the transport '
                    'diagnostics. Open it through the encrypted mesh anyway?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Open anyway'),
                    ),
                  ],
                ),
              ) ??
              false;
          if (!continueWithoutProbe) {
            return 'FIPS app opening cancelled after the optional probe.';
          }
        }
      }

      final origin = target.origin;
      final alreadyTrusted = widget.config.effectiveTrustedOrigins().any(
            (value) => SignerPolicy.normalizeOrigin(value) == origin,
          );
      if (!alreadyTrusted) {
        if (!mounted) throw StateError('The setup screen closed.');
        final trust = await _showSettledDialog<bool>(
              builder: (context) => AlertDialog(
                title: const Text('Trust this exact FIPS origin?'),
                content: Text(
                  '$origin may request NIP-98 signatures after the normal per-request approval. No other .fips origin will be trusted.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Trust and open'),
                  ),
                ],
              ),
            ) ??
            false;
        if (!trust) return 'FIPS app opening cancelled.';
        final trustedOrigins = {
          ..._trustedOriginsController.text
              .split('\n')
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty),
          origin,
        }.toList(growable: false);
        _trustedOriginsController.text = trustedOrigins.join('\n');
        configToPersist = widget.config.copyWith(
          trustedOrigins: trustedOrigins,
        );
      }
      appUrlToOpen = target.uri.toString();
      return 'Opened ${target.uri} through FIPS.';
    });

    if (appUrlToOpen == null || !mounted) return;

    // `_showSettledDialog` waits for the route's reverse transition and overlay
    // removal, so root configuration and IndexedStack navigation cannot race
    // inherited-dialog teardown on a repeated Open FIPS app attempt.
    final config = configToPersist;
    if (config != null) {
      widget.onConfigChanged(config);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    widget.onOpenFipsApp(appUrlToOpen!);
  }

  Future<T?> _showSettledDialog<T>({required WidgetBuilder builder}) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<T>(
      context: context,
      builder: builder,
      themes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      barrierDismissible: true,
    );
    final result = await navigator.push<T>(route);
    await route.completed;
    return result;
  }

  Future<FipsRuntimeStatus> _ensureFipsReadyForAppAccess() async {
    var status = await widget.fipsRuntime.inspect();
    if (mounted) {
      setState(() {
        _fipsStatus = status;
      });
    }
    if (status.canAttemptAppAccess) return status;

    if (mounted) {
      setState(() {
        _message = 'Enabling the bundled FIPS transport…';
      });
    }
    status = await widget.fipsRuntime.ensureReadyForAppAccess();
    if (mounted) {
      setState(() {
        _fipsStatus = status;
      });
    }
    return status;
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscureText = false,
    bool readOnly = false,
    int maxLines = 1,
    String? helperText,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        obscureText: obscureText,
        readOnly: readOnly,
        maxLines: obscureText ? 1 : maxLines,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          prefixIcon: Icon(icon),
          labelText: label,
          helperText: helperText,
          helperMaxLines: 6,
        ),
      ),
    );
  }

  void _save() {
    final origins = _trustedOriginsController.text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    widget.onConfigChanged(_currentConfig().copyWith(trustedOrigins: origins));
    setState(() {
      _message = 'Configuration saved. For Tower FIPS sync, reload your '
          'existing Flight Deck tab, then select FIPS and approve pairing.';
    });
  }

  Future<void> _setRelayDiagnostics(bool enabled) async {
    setState(() => _relayBusy = true);
    try {
      await widget.onRelayDiagnosticsChanged!(enabled);
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Could not save relay diagnostics setting.');
      }
    } finally {
      if (mounted) setState(() => _relayBusy = false);
    }
  }

  Future<void> _clearRelayDiagnostics() async {
    setState(() => _relayBusy = true);
    try {
      await RelayDiagnostics.clear();
      if (mounted) setState(() => _message = 'Relay diagnostics cleared.');
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Could not clear relay diagnostics.');
      }
    } finally {
      if (mounted) setState(() => _relayBusy = false);
    }
  }

  AppConfig _currentConfig() {
    return widget.config.copyWith(
      towerUrl: _towerController.text.trim(),
      appNpub: _appNpubController.text.trim(),
      flightDeckUrl: _flightDeckController.text.trim(),
      workspaceId: _workspaceController.text.trim(),
      workspaceServiceNpub: _workspaceServiceController.text.trim(),
      channelId: _channelController.text.trim(),
      deviceNpub: widget.config.deviceNpub,
      deviceSecret: widget.config.deviceSecret,
      registrationSecret: _registrationSecretController.text.trim(),
      rememberNip98Approvals: _rememberNip98Approvals,
      devicePublicKeyHex: widget.config.devicePublicKeyHex,
      displayExperimentalFlightDeckDriveSync:
          _displayExperimentalFlightDeckDriveSync,
    );
  }

  Future<void> _registerDevice() async {
    _save();
    await _run('Registering device...', () async {
      final result = await widget.bridge.registerDevice(_currentConfig());
      if (!result.ok) return 'Device registration failed: ${result.error}';
      return 'Device registered with Tower.';
    });
  }

  Future<void> _validateChannel() async {
    _save();
    await _run('Validating channel...', () async {
      final result = await widget.bridge.validateChannel(_currentConfig());
      if (!result.ok) return 'Channel validation failed: ${result.error}';
      return 'Channel validated.';
    });
  }

  Future<void> _resetBrowserData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset browser data?'),
        content: const Text(
          'This clears WebView cookies, cache, local storage, and service worker cache. Open tabs remain listed, but sites may sign out.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.cleaning_services_outlined),
            label: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run('Resetting browser data...', () async {
      await widget.onClearBrowserData();
      return 'Browser cookies, cache, and local storage reset.';
    });
  }

  Future<void> _run(
    String progress,
    Future<String> Function() action,
  ) async {
    setState(() {
      _busy = true;
      _message = progress;
    });
    try {
      final message = await action();
      if (!mounted) return;
      setState(() {
        _message = message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _message = 'The operation failed unexpectedly. Please retry.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }
}
