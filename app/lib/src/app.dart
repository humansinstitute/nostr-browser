import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme/browser_theme.dart';
import 'core/app_config.dart';
import 'core/flight_deck_update_manager.dart';
import 'core/native_core_bridge.dart';
import 'core/signer_vault.dart';
import 'features/browser/nostr_profile_relay_client.dart';
import 'features/browser/relay_diagnostic_settings.dart';
import 'features/browser/relay_diagnostics.dart';
import 'features/browser/signer_store.dart';
import 'features/shell/shell_home.dart';
import 'features/onboarding/signer_onboarding_screen.dart';
import 'features/onboarding/welcome_surface.dart';

class WingmanApp extends StatefulWidget {
  const WingmanApp({
    this.useSignerVault = true,
    this.signerVault,
    this.localFlightDeckUrl = '',
    this.flightDeckUpdates,
    this.profileRelayClient,
    super.key,
  });

  final bool useSignerVault;
  final SignerVault? signerVault;
  final String localFlightDeckUrl;
  final FlightDeckUpdateController? flightDeckUpdates;
  final NostrProfileRelayClient? profileRelayClient;

  @override
  State<WingmanApp> createState() => _WingmanAppState();
}

class _WingmanAppState extends State<WingmanApp> {
  static const _appConfigKey = 'wingman.app.config.v1';

  AppConfig _config = AppConfig.defaults();
  late final NativeCoreBridge _bridge = NativeCoreBridge();
  late final SignerStore _signerStore = SignerStore();
  late final SignerVault _signerVault = widget.signerVault ?? SignerVault();
  bool _checkingVault = true;
  bool _launchRelayDiagnostics = false;
  bool _savedRelayDiagnostics = false;
  SignerVaultRecord? _startupVault;

  @override
  void initState() {
    super.initState();
    _loadInitialState();
  }

  void _updateConfig(AppConfig config) {
    setState(() {
      _config = config;
    });
    unawaited(_saveAppConfig(config));
  }

  Future<void> _loadInitialState() async {
    final relayDiagnosticsLoad = RelayDiagnosticSettings().load();
    final savedConfig = await _loadAppConfig();
    final relayDiagnostics = await relayDiagnosticsLoad;
    RelayDiagnostics.enabled = relayDiagnostics;
    SignerVaultRecord? record;
    if (widget.useSignerVault) {
      record = await _signerVault.loadRecord();
    }
    if (!mounted) return;
    setState(() {
      _config = savedConfig.copyWith(
        deviceSecret: _config.deviceSecret,
        deviceNpub: record?.npub ?? _config.deviceNpub,
        devicePublicKeyHex: record?.publicKeyHex ?? _config.devicePublicKeyHex,
      );
      _startupVault = record;
      _launchRelayDiagnostics = relayDiagnostics;
      _savedRelayDiagnostics = relayDiagnostics;
      _checkingVault = false;
    });
  }

  Future<void> _setRelayDiagnostics(bool enabled) async {
    await RelayDiagnosticSettings().save(enabled);
    if (!mounted) return;
    setState(() => _savedRelayDiagnostics = enabled);
  }

  Future<AppConfig> _loadAppConfig() async {
    final defaults = AppConfig.defaults();
    final raw = await SharedPreferencesAsync().getString(_appConfigKey);
    if (raw == null || raw.trim().isEmpty) return defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return defaults;
      return defaults.copyWith(
        towerUrl: _stringValue(decoded, 'tower_url') ?? defaults.towerUrl,
        appNpub: _stringValue(decoded, 'app_npub') ?? defaults.appNpub,
        flightDeckUrl:
            _stringValue(decoded, 'flight_deck_url') ?? defaults.flightDeckUrl,
        workspaceId:
            _stringValue(decoded, 'workspace_id') ?? defaults.workspaceId,
        workspaceServiceNpub: _stringValue(decoded, 'workspace_service_npub') ??
            defaults.workspaceServiceNpub,
        channelId: _stringValue(decoded, 'channel_id') ?? defaults.channelId,
        trustedOrigins: _stringListValue(decoded, 'trusted_origins') ??
            defaults.trustedOrigins,
        rememberNip98Approvals: decoded['remember_nip98_approvals'] is bool
            ? decoded['remember_nip98_approvals'] as bool
            : defaults.rememberNip98Approvals,
        displayExperimentalFlightDeckDriveSync:
            decoded['display_experimental_flight_deck_drive_sync'] is bool
                ? decoded['display_experimental_flight_deck_drive_sync'] as bool
                : defaults.displayExperimentalFlightDeckDriveSync,
      );
    } catch (_) {
      return defaults;
    }
  }

  Future<void> _saveAppConfig(AppConfig config) async {
    final payload = {
      'version': 1,
      'tower_url': config.towerUrl,
      'app_npub': config.appNpub,
      'flight_deck_url': config.flightDeckUrl,
      'workspace_id': config.workspaceId,
      'workspace_service_npub': config.workspaceServiceNpub,
      'channel_id': config.channelId,
      'trusted_origins': config.trustedOrigins,
      'remember_nip98_approvals': config.rememberNip98Approvals,
      'display_experimental_flight_deck_drive_sync':
          config.displayExperimentalFlightDeckDriveSync,
    };
    await SharedPreferencesAsync()
        .setString(_appConfigKey, jsonEncode(payload));
  }

  String? _stringValue(Map<String, dynamic> map, String key) {
    final value = map[key]?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  List<String>? _stringListValue(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! List) return null;
    final items = value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    return items.isEmpty ? null : items;
  }

  void _unlockSigner(SignerVaultUnlock unlocked) {
    setState(() {
      _startupVault = null;
      _config = _config.copyWith(
        deviceSecret: unlocked.nsec,
        deviceNpub: unlocked.npub,
        devicePublicKeyHex: unlocked.publicKeyHex,
      );
    });
  }

  void _logOutSigner() {
    setState(() {
      _config = _config.copyWith(deviceSecret: '');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nostr Browser',
      debugShowCheckedModeBanner: false,
      theme: BrowserTheme.light(),
      home: _home(),
    );
  }

  Widget _home() {
    if (_checkingVault) {
      return const WelcomeLoadingScreen();
    }
    if (_startupVault != null) {
      return SignerOnboardingScreen(
        vault: _signerVault,
        record: _startupVault,
        onUnlocked: _unlockSigner,
      );
    }
    return ShellHome(
      config: _config,
      relayDiagnosticsSaved: _savedRelayDiagnostics,
      relayDiagnosticsAtLaunch: _launchRelayDiagnostics,
      onRelayDiagnosticsChanged: _setRelayDiagnostics,
      localFlightDeckUrl: widget.localFlightDeckUrl,
      flightDeckUpdates: widget.flightDeckUpdates,
      profileRelayClient: widget.profileRelayClient,
      bridge: _bridge,
      signerStore: _signerStore,
      onConfigChanged: _updateConfig,
      onLogOut: _config.hasDeviceSecret ? _logOutSigner : null,
      signerVault: widget.useSignerVault ? _signerVault : null,
      onUnlocked: _unlockSigner,
    );
  }
}
