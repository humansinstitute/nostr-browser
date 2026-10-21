import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/fips_app_target.dart';
import '../../core/fips_runtime_service.dart';
import '../browser/relay_diagnostics.dart';
import '../browser/signer_policy.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    required this.config,
    this.relayDiagnosticsSaved = false,
    this.relayDiagnosticsAtLaunch = false,
    this.onRelayDiagnosticsChanged,
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
  final FipsRuntimeService fipsRuntime;
  final ValueChanged<AppConfig> onConfigChanged;
  final Future<void> Function() onClearBrowserData;
  final ValueChanged<String> onOpenFipsApp;
  final String localFlightDeckUrl;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _flightDeckController;
  late List<String> _trustedOrigins;
  String? _message;
  String? _fipsMessage;
  bool _busy = false;
  bool _exportBusy = false;
  bool _relayBusy = false;
  FipsRuntimeStatus? _fipsStatus;

  @override
  void initState() {
    super.initState();
    _flightDeckController =
        TextEditingController(text: widget.config.flightDeckUrl);
    _trustedOrigins = List.of(widget.config.trustedOrigins);
    _refreshFipsStatus();
  }

  @override
  void dispose() {
    _flightDeckController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 6),
        const Text(
            'Browser connections, permissions, privacy, and diagnostics.'),
        const SizedBox(height: 24),
        _sectionTitle('FIPS status'),
        const SizedBox(height: 8),
        _fipsCard(),
        const SizedBox(height: 24),
        _sectionTitle('Site permissions'),
        const SizedBox(height: 8),
        _sitePermissionsCard(),
        const SizedBox(height: 24),
        _sectionTitle('Privacy & browser data'),
        const SizedBox(height: 8),
        _privacyCard(),
        const SizedBox(height: 24),
        _sectionTitle('Advanced diagnostics'),
        const SizedBox(height: 8),
        _advancedCard(),
        if (_message != null) ...[
          const SizedBox(height: 16),
          Text(_message!, key: const ValueKey('settings-message')),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _sectionTitle(String title) => Text(
        title,
        style: Theme.of(context).textTheme.titleLarge,
      );

  Widget _sitePermissionsCard() {
    final builtIn = SignerPolicy.normalizeOrigin(widget.localFlightDeckUrl);
    final external = SignerPolicy.normalizeOrigin(widget.config.flightDeckUrl);
    final legacyTower = SignerPolicy.normalizeOrigin(widget.config.towerUrl);
    final origins = <String>{
      if (builtIn.isNotEmpty) builtIn,
      if (external.isNotEmpty) external,
      if (legacyTower.isNotEmpty) legacyTower,
      for (final value in _trustedOrigins)
        if (SignerPolicy.normalizeOrigin(value).isNotEmpty)
          SignerPolicy.normalizeOrigin(value),
    }.toList(growable: false);

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'Only these exact origins may ask Nostr Browser for protected capabilities. Signing still requires its own request approval.',
              ),
            ),
            if (origins.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Text('No sites have permission yet.'),
              ),
            for (final origin in origins)
              ListTile(
                key: ValueKey('site-permission-$origin'),
                leading: Icon(
                  origin == builtIn
                      ? Icons.home_outlined
                      : Icons.language_outlined,
                ),
                title: SelectableText(origin),
                subtitle: Text(
                  origin == builtIn
                      ? 'Built-in Flight Deck · included with Nostr Browser'
                      : origin == external
                          ? 'External Flight Deck · exact origin only'
                          : origin == legacyTower
                              ? 'Legacy site permission · exact origin only'
                              : 'Site permission · exact origin only',
                ),
                trailing: origin == builtIn
                    ? const Tooltip(
                        message: 'Built-in permission',
                        child: Icon(Icons.lock_outline),
                      )
                    : IconButton(
                        key: ValueKey('revoke-site-permission-$origin'),
                        tooltip: 'Revoke $origin',
                        onPressed:
                            _busy ? null : () => _revokeSitePermission(origin),
                        icon: const Icon(Icons.delete_outline),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _privacyCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final action = OutlinedButton.icon(
              key: const ValueKey('reset-browser-data'),
              onPressed: _busy ? null : _resetBrowserData,
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('Reset browser data'),
            );
            const details = ListTile(
              leading: Icon(Icons.shield_outlined),
              title: Text('Data stored by websites'),
              subtitle: Text(
                'Clear cookies, cache, local storage, and service worker data. Sites may sign out.',
              ),
            );
            if (constraints.maxWidth >= 520) {
              return ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('Data stored by websites'),
                subtitle: const Text(
                  'Clear cookies, cache, local storage, and service worker data. Sites may sign out.',
                ),
                trailing: action,
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [details, action],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _advancedCard() {
    return Card(
      child: ExpansionTile(
        key: const ValueKey('advanced-diagnostics'),
        title: const Text('Technical controls and compatibility'),
        subtitle: const Text(
            'FIPS details, external Flight Deck, and private relay traces'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          Text('FIPS diagnostics',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_fipsStatus?.nodeNpub != null)
            SelectableText('Node: ${_fipsStatus!.nodeNpub}'),
          if (_fipsStatus?.nodeNpub != null) const SizedBox(height: 8),
          _fipsDiagnosticControls(),
          if (_fipsMessage != null) ...[
            const SizedBox(height: 8),
            Text(_fipsMessage!),
          ],
          const SizedBox(height: 20),
          Text('External Flight Deck',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'Optional compatibility setting. Built-in Flight Deck works automatically. Only the exact external origin is allowed.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('external-flight-deck-url'),
            controller: _flightDeckController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'External Flight Deck URL',
              hintText: 'https://flight-deck.example',
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: const ValueKey('save-external-flight-deck'),
              onPressed: _busy ? null : _saveExternalFlightDeck,
              child: const Text('Save external Flight Deck'),
            ),
          ),
          const SizedBox(height: 20),
          SwitchListTile(
            key: const ValueKey('private-relay-diagnostics'),
            contentPadding: EdgeInsets.zero,
            value: widget.relayDiagnosticsSaved,
            onChanged: _relayBusy || widget.onRelayDiagnosticsChanged == null
                ? null
                : _setRelayDiagnostics,
            title: const Text('Private relay diagnostics'),
            subtitle: const Text(
              'Off by default. Saves a bounded local trace with random IDs—never URLs, content, keys, or identities.',
            ),
          ),
          if (widget.relayDiagnosticsSaved != widget.relayDiagnosticsAtLaunch)
            const Text('Restart WMapp to apply'),
          const Text(
            'Turning this off stops new records after restart. Existing traces remain until cleared.',
          ),
          TextButton(
            key: const ValueKey('clear-relay-diagnostics'),
            onPressed: _relayBusy ? null : _clearRelayDiagnostics,
            child: const Text('Clear relay diagnostics'),
          ),
        ],
      ),
    );
  }

  Widget _fipsDiagnosticControls() {
    final state = _fipsStatus?.state;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('fips-refresh'),
          onPressed: _busy ? null : _refreshFipsStatus,
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh'),
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
            label: Text(_exportBusy ? 'Exporting…' : 'Export diagnostics'),
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
            if (canInstall)
              FilledButton.icon(
                key: const ValueKey('fips-install-repair'),
                onPressed: _busy ? null : _installOrRepairFips,
                icon: const Icon(Icons.build_circle_outlined),
                label: const Text('Install or repair'),
              ),
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
      final alreadyTrusted = [
        ...widget.config.effectiveTrustedOrigins(),
        ..._trustedOrigins,
      ].any(
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
        final trustedOrigins = <String>{
          ..._trustedOrigins,
          origin,
        }.toList(growable: false);
        if (mounted) setState(() => _trustedOrigins = trustedOrigins);
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

  Future<void> _revokeSitePermission(String origin) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Revoke site permission?'),
            content: Text(
              '$origin will no longer be able to request protected browser capabilities. Any active pairing is revoked when the browser configuration updates.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Revoke'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    final external = SignerPolicy.normalizeOrigin(widget.config.flightDeckUrl);
    final legacyTower = SignerPolicy.normalizeOrigin(widget.config.towerUrl);
    final trustedOrigins = _trustedOrigins
        .where((value) => SignerPolicy.normalizeOrigin(value) != origin)
        .toList(growable: false);
    final next = widget.config.copyWith(
      trustedOrigins: trustedOrigins,
      flightDeckUrl: origin == external ? '' : widget.config.flightDeckUrl,
      towerUrl: origin == legacyTower ? '' : widget.config.towerUrl,
    );
    if (origin == external) _flightDeckController.clear();
    setState(() {
      _trustedOrigins = trustedOrigins;
      _message = 'Permission revoked for $origin.';
    });
    widget.onConfigChanged(next);
  }

  void _saveExternalFlightDeck() {
    final value = _flightDeckController.text.trim();
    final nextOrigin = SignerPolicy.normalizeOrigin(value);
    if (value.isNotEmpty && nextOrigin.isEmpty) {
      setState(() {
        _message = 'Enter a complete http:// or https:// Flight Deck URL.';
      });
      return;
    }

    final previousOrigin =
        SignerPolicy.normalizeOrigin(widget.config.flightDeckUrl);
    final changed = value != widget.config.flightDeckUrl;
    final trustedOrigins = changed && previousOrigin.isNotEmpty
        ? _trustedOrigins
            .where(
              (entry) => SignerPolicy.normalizeOrigin(entry) != previousOrigin,
            )
            .toList(growable: false)
        : List<String>.of(_trustedOrigins);
    setState(() {
      _trustedOrigins = trustedOrigins;
      _message = changed
          ? 'External Flight Deck updated. Previous pairings were revoked.'
          : 'External Flight Deck is unchanged.';
    });
    widget.onConfigChanged(
      widget.config.copyWith(
        flightDeckUrl: value,
        trustedOrigins: trustedOrigins,
      ),
    );
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
