import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef FipsProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

enum FipsRuntimeState {
  disabled,
  notBundled,
  notInstalled,
  consentRequired,
  installRequired,
  starting,
  controlAccessPending,
  running,
  degraded,
  failed,
}

class FipsRuntimeStatus {
  const FipsRuntimeStatus({
    required this.state,
    required this.detail,
    this.nodeNpub,
  });

  final FipsRuntimeState state;
  final String detail;
  final String? nodeNpub;

  bool get isRunning => state == FipsRuntimeState.running;
  bool get canAttemptAppAccess =>
      state == FipsRuntimeState.running ||
      state == FipsRuntimeState.controlAccessPending;
}

class FipsProbeResult {
  const FipsProbeResult({
    required this.ok,
    required this.detail,
  });

  final bool ok;
  final String detail;
}

enum FipsDiagnosticsExportOutcome { success, cancelled, failed }

class FipsDiagnosticsExportResult {
  const FipsDiagnosticsExportResult(
      {required this.outcome, required this.detail});
  final FipsDiagnosticsExportOutcome outcome;
  final String detail;
}

class FipsCommand {
  const FipsCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

abstract class FipsAndroidRuntimeChannel {
  Future<Map<String, dynamic>> inspect();
  Future<Map<String, dynamic>> start({bool repair = false});
  Future<Map<String, dynamic>> stop();
  Future<Map<String, dynamic>> peerStatus();
  Future<Map<String, dynamic>> probe(String npub);
  Future<Map<String, dynamic>> exportDiagnostics();
  Future<Map<String, dynamic>> clearDiagnostics();
  Future<Map<String, dynamic>> journalEvent(String eventCode);
}

class MethodChannelFipsAndroidRuntime implements FipsAndroidRuntimeChannel {
  const MethodChannelFipsAndroidRuntime({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('com.wingmanbefree.wingman_app/fips');

  final MethodChannel _channel;

  @override
  Future<Map<String, dynamic>> inspect() => _invoke('inspect');

  @override
  Future<Map<String, dynamic>> start({bool repair = false}) =>
      _invoke(repair ? 'repair' : 'start');

  @override
  Future<Map<String, dynamic>> stop() => _invoke('stop');

  @override
  Future<Map<String, dynamic>> peerStatus() => _invoke('peerStatus');

  @override
  Future<Map<String, dynamic>> probe(String npub) =>
      _invoke('probe', {'npub': npub});

  @override
  Future<Map<String, dynamic>> exportDiagnostics() =>
      _invoke('exportDiagnostics');

  @override
  Future<Map<String, dynamic>> clearDiagnostics() =>
      _invoke('clearDiagnostics');

  @override
  Future<Map<String, dynamic>> journalEvent(String eventCode) =>
      _invoke('journalEvent', {'eventCode': eventCode});

  Future<Map<String, dynamic>> _invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      method,
      arguments,
    );
    return value ??
        const {
          'state': 'failed',
          'detail': 'The device returned no embedded FIPS status.',
        };
  }
}

class FipsRuntimeService {
  FipsRuntimeService({
    String? bundledPackagePath,
    String? fipsctlPath,
    String? attestationPath,
    FipsProcessRunner? processRunner,
    bool? isMacOS,
    bool? isLinux,
    bool? isAndroid,
    bool? isIOS,
    FipsAndroidRuntimeChannel? iosRuntime,
    FipsAndroidRuntimeChannel? androidRuntime,
    Future<bool> Function()? readEnabled,
    Future<void> Function(bool enabled)? writeEnabled,
    Future<bool> Function(String path)? fileExists,
    Future<String?> Function(String path)? readTextFile,
  })  : bundledPackagePath = bundledPackagePath ??
            defaultBundledPackagePath(isMacOS: isMacOS, isLinux: isLinux),
        fipsctlPath = fipsctlPath ?? '/usr/local/bin/fipsctl',
        attestationPath = attestationPath ??
            defaultAttestationPath(isMacOS: isMacOS, isLinux: isLinux),
        _readEnabled = readEnabled ?? _readEnabledPreference,
        _writeEnabled = writeEnabled ?? _writeEnabledPreference,
        _processRunner = processRunner ?? Process.run,
        _isMacOS = isMacOS ?? (isLinux == true ? false : Platform.isMacOS),
        _isLinux = isLinux ?? (isMacOS == true ? false : Platform.isLinux),
        _isAndroid = isAndroid ??
            (isMacOS == true || isLinux == true ? false : Platform.isAndroid),
        _isIOS = isIOS ??
            (isMacOS == true || isLinux == true || isAndroid == true
                ? false
                : Platform.isIOS),
        _androidRuntime =
            ((isIOS ?? Platform.isIOS) ? iosRuntime : androidRuntime) ??
                const MethodChannelFipsAndroidRuntime(),
        _fileExists = fileExists ?? ((path) => File(path).exists()),
        _readTextFile = readTextFile ?? _readTextFileFromDisk;

  static const expectedVersion = '0.5.0';
  static const configurationScriptName = 'configure-fips-wingman-poc.sh';
  static const linuxConfigurationScriptName = 'configure_fips_wingman_linux.sh';
  static const linuxInstallScriptName = 'install_fips_wingman_linux.sh';
  static const bootstrapPeerNpub =
      'npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98';
  static const bootstrapPeerAddress = '217.77.8.91:2121';

  final String bundledPackagePath;
  final String fipsctlPath;
  final String attestationPath;
  final FipsProcessRunner _processRunner;
  final bool _isMacOS;
  final bool _isLinux;
  final bool _isAndroid;
  final bool _isIOS;
  bool get _isMobile => _isAndroid || _isIOS;
  final FipsAndroidRuntimeChannel _androidRuntime;
  final Future<bool> Function(String path) _fileExists;
  final Future<String?> Function(String path) _readTextFile;
  bool _operationInProgress = false;
  Completer<void>? _mobileStartup;
  bool _diagnosticsExportInProgress = false;
  Future<FipsRuntimeStatus>? _ensureReadyOperation;

  static const enabledPreferenceKey = 'wmapp.fips.enabled.v1';
  final Future<bool> Function() _readEnabled;
  final Future<void> Function(bool) _writeEnabled;
  final _enabledChanges = StreamController<bool>.broadcast(sync: true);
  bool? _enabled;
  int _generation = 0;
  final Set<Completer<void>> _retryWaits = {};
  DateTime? _bootstrapRetryAfter;
  FipsRuntimeStatus? _lastBootstrapFailure;

  bool? get enabledSnapshot => _enabled;

  Stream<bool> get enabledChanges => _enabledChanges.stream;
  Future<bool> get isEnabled async {
    if (_enabled != null) return _enabled!;
    final generation = _generation;
    try {
      final stored = await _readEnabled();
      if (_generation == generation && _enabled == null) _enabled = stored;
    } catch (_) {
      if (_generation == generation && _enabled == null) _enabled = false;
    }
    return _enabled ?? false;
  }

  Future<void> _settingOperation = Future<void>.value();

  static Future<bool> _readEnabledPreference() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(enabledPreferenceKey) ?? true;
  }

  static Future<void> _writeEnabledPreference(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(enabledPreferenceKey, enabled)) {
      throw StateError('FIPS preference could not be saved.');
    }
  }

  FipsRuntimeStatus get disabledStatus => FipsRuntimeStatus(
        state: FipsRuntimeState.disabled,
        detail:
            'FIPS is disabled in WMAPP. Enable it in Setup to use FIPS-only '
            'services. Ordinary HTTPS browsing remains available.'
            '${_isMobile ? '' : ' An independently installed system FIPS service '
                'is managed separately and is not stopped by this control.'}',
      );

  Future<FipsRuntimeStatus> setEnabled(bool enabled) {
    final generation = ++_generation;
    // Fail closed immediately, including while an enable waits for persistence.
    _enabled = false;
    for (final wait in _retryWaits) {
      if (!wait.isCompleted) wait.complete();
    }
    _retryWaits.clear();
    _ensureReadyOperation = null;
    _bootstrapRetryAfter = null;
    _lastBootstrapFailure = null;
    _enabledChanges.add(false);
    final result = _settingOperation.then((_) async {
      var saved = true;
      try {
        await _writeEnabled(enabled);
      } catch (_) {
        saved = false;
      }
      // Stop remains required even if saving the preference failed.
      if (_isMobile && (!enabled || !saved)) {
        try {
          await _androidRuntime.stop();
        } catch (_) {
          return const FipsRuntimeStatus(
              state: FipsRuntimeState.failed,
              detail:
                  'FIPS access is disabled, but the mobile runtime could not stop. Retry disabling it in Setup.');
        }
      }
      if (!saved) {
        return const FipsRuntimeStatus(
            state: FipsRuntimeState.failed,
            detail:
                'FIPS access is disabled, but its setting could not be saved. Retry in Setup before relaunching.');
      }
      if (enabled) await _mobileStartup?.future;
      if (_generation != generation || !enabled) return disabledStatus;
      _enabled = true;
      _enabledChanges.add(true);
      return inspect();
    });
    _settingOperation = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _waitForRetry(int generation) async {
    if (_generation != generation || _enabled == false) return;
    final wait = Completer<void>();
    _retryWaits.add(wait);
    final timer = Timer(const Duration(milliseconds: 500), () {
      if (!wait.isCompleted) wait.complete();
    });
    await wait.future;
    timer.cancel();
    _retryWaits.remove(wait);
  }

  bool get supportsStop => _isMobile || _isMacOS || _isLinux;

  bool get supportsDiagnosticsExport => _isMobile;

  Future<FipsDiagnosticsExportResult> exportDiagnostics() async {
    if (!_isMobile) {
      return const FipsDiagnosticsExportResult(
        outcome: FipsDiagnosticsExportOutcome.failed,
        detail: 'FIPS diagnostics export is available on Android and iPhone.',
      );
    }
    if (_diagnosticsExportInProgress) {
      return const FipsDiagnosticsExportResult(
        outcome: FipsDiagnosticsExportOutcome.failed,
        detail: 'A diagnostics export is already in progress.',
      );
    }
    _diagnosticsExportInProgress = true;
    try {
      await _recordAndroidEvent('dart_export_requested');
      final value = await _androidRuntime.exportDiagnostics();
      final outcome = switch (value['outcome']) {
        'success' => FipsDiagnosticsExportOutcome.success,
        'cancelled' => FipsDiagnosticsExportOutcome.cancelled,
        _ => FipsDiagnosticsExportOutcome.failed,
      };
      return FipsDiagnosticsExportResult(
        outcome: outcome,
        detail: value['detail']?.toString() ??
            'Diagnostics export failed. Please retry.',
      );
    } catch (_) {
      await _recordAndroidEvent('dart_export_failed');
      return const FipsDiagnosticsExportResult(
        outcome: FipsDiagnosticsExportOutcome.failed,
        detail: 'Diagnostics export failed unexpectedly. Please retry.',
      );
    } finally {
      _diagnosticsExportInProgress = false;
    }
  }

  Future<String> clearDiagnostics() async {
    if (!_isMobile) {
      return 'FIPS diagnostics are only retained on Android and iPhone.';
    }
    try {
      final value = await _androidRuntime.clearDiagnostics();
      return value['detail']?.toString() ?? 'FIPS diagnostics cleared.';
    } catch (_) {
      return 'FIPS diagnostics could not be cleared. Please retry.';
    }
  }

  Future<void> recordUiRetry() => _recordAndroidEvent('dart_ui_retry');

  Future<void> _recordAndroidEvent(String eventCode) async {
    if (!_isMobile) return;
    try {
      await _androidRuntime.journalEvent(eventCode);
    } catch (_) {}
  }

  static String defaultBundledPackagePath({bool? isMacOS, bool? isLinux}) {
    final resolvedIsLinux =
        isLinux ?? (isMacOS == true ? false : Platform.isLinux);
    if (resolvedIsLinux) {
      return '${File(Platform.resolvedExecutable).parent.path}/data/fips/install.sh';
    }
    final executable = File(Platform.resolvedExecutable);
    final contents = executable.parent.parent;
    final packageName = switch (Abi.current()) {
      Abi.macosArm64 => 'fips-0.5.0-macos-arm64.pkg',
      Abi.macosX64 => 'fips-0.5.0-macos-x86_64.pkg',
      _ => 'fips-0.5.0-macos-unsupported.pkg',
    };
    return '${contents.path}/Resources/FIPS/$packageName';
  }

  static String defaultAttestationPath({bool? isMacOS, bool? isLinux}) {
    final resolvedIsLinux =
        isLinux ?? (isMacOS == true ? false : Platform.isLinux);
    return resolvedIsLinux
        ? '/etc/fips/wingman-poc-runtime.json'
        : '/usr/local/etc/fips/wingman-poc-runtime.json';
  }

  static FipsCommand installCommand(String packagePath) {
    final configurationScriptPath = File(packagePath)
        .parent
        .uri
        .resolve(configurationScriptName)
        .toFilePath();
    const script = '''
on run argv
  set packagePath to item 1 of argv
  set configurationScriptPath to item 2 of argv
  do shell script ("/usr/sbin/installer -pkg " & quoted form of packagePath & " -target / && /bin/sh " & quoted form of configurationScriptPath) with administrator privileges
end run
''';
    return FipsCommand(
      '/usr/bin/osascript',
      ['-e', script, packagePath, configurationScriptPath],
    );
  }

  static FipsCommand linuxInstallCommand(String upstreamInstallPath) {
    final activationPath = File(upstreamInstallPath)
        .parent
        .uri
        .resolve(linuxInstallScriptName)
        .toFilePath();
    return FipsCommand('/usr/bin/pkexec', ['/bin/sh', activationPath]);
  }

  String get authorizationDescription => _isIOS
      ? 'iPhone will request VPN consent. Only FIPS mesh and .fips DNS use '
          'the VPN; normal internet keeps its existing route. iOS may '
          'disconnect another active VPN when you enable FIPS.'
      : _isAndroid
          ? 'Android will request VPN consent once. WM-App keeps normal internet '
              'routing outside the VPN and routes only FIPS mesh and .fips DNS '
              'traffic through its embedded runtime.'
          : _isLinux
              ? 'Linux will request administrator authorization. The pinned FIPS '
                  'systemd bundle installs the mesh daemon, TUN support, and the '
                  '.fips resolver. Existing FIPS configuration and machine identity '
                  'are preserved.'
              : 'macOS will request administrator authorization. The pinned FIPS '
                  'system package installs a launch daemon, TUN support, and the '
                  '.fips resolver. Existing FIPS configuration and machine identity '
                  'are preserved.';

  String get authorizationWaitingMessage => _isIOS
      ? 'Waiting for iPhone VPN consent…'
      : _isAndroid
          ? 'Waiting for Android VPN consent…'
          : _isLinux
              ? 'Waiting for Linux administrator authorization…'
              : 'Waiting for macOS authorization…';

  Future<FipsRuntimeStatus> inspect() async {
    if (!await isEnabled) return disabledStatus;
    if (_operationInProgress) {
      return const FipsRuntimeStatus(
        state: FipsRuntimeState.starting,
        detail: 'FIPS installation or repair is in progress.',
      );
    }
    final generation = _generation;
    final status = await _inspectRuntime();
    return _generation == generation && await isEnabled
        ? status
        : disabledStatus;
  }

  Future<FipsRuntimeStatus> ensureReadyForAppAccess() {
    final activeOperation = _ensureReadyOperation;
    if (activeOperation != null) return activeOperation;

    final operation = _ensureReadyForAppAccess();
    late final Future<FipsRuntimeStatus> trackedOperation;
    trackedOperation = operation.whenComplete(() {
      if (identical(_ensureReadyOperation, trackedOperation)) {
        _ensureReadyOperation = null;
      }
    });
    _ensureReadyOperation = trackedOperation;
    return trackedOperation;
  }

  Future<FipsRuntimeStatus> _ensureReadyForAppAccess() async {
    try {
      final generation = _generation;
      if (!await isEnabled) return disabledStatus;
      final retryAfter = _bootstrapRetryAfter;
      if (retryAfter != null && DateTime.now().isBefore(retryAfter)) {
        return _lastBootstrapFailure!;
      }
      var status = await inspect();
      if (_generation != generation || !await isEnabled) return disabledStatus;

      if (!status.canAttemptAppAccess) {
        final canActivateBundledRuntime = switch (status.state) {
          FipsRuntimeState.notInstalled ||
          FipsRuntimeState.consentRequired ||
          FipsRuntimeState.installRequired ||
          FipsRuntimeState.degraded ||
          FipsRuntimeState.failed =>
            true,
          _ => false,
        };
        if (!canActivateBundledRuntime) return status;
        status = await installOrRepair();
      }
      if (!status.canAttemptAppAccess) return status;
      if (_generation != generation || !await isEnabled) return disabledStatus;
      return _ensureBootstrapConnected(status);
    } catch (_) {
      return const FipsRuntimeStatus(
        state: FipsRuntimeState.failed,
        detail: 'Mobile embedded FIPS failed unexpectedly. Please retry.',
      );
    }
  }

  Future<FipsRuntimeStatus> _ensureBootstrapConnected(
    FipsRuntimeStatus readyStatus,
  ) async {
    final generation = _generation;
    if (!await isEnabled) return disabledStatus;
    final retryAfter = _bootstrapRetryAfter;
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) {
      return _lastBootstrapFailure!;
    }
    if (readyStatus.state == FipsRuntimeState.controlAccessPending) {
      return readyStatus;
    }

    if (_isMobile) {
      for (var attempt = 0; attempt < 20; attempt += 1) {
        if (_generation != generation || !await isEnabled) {
          return disabledStatus;
        }
        final peers = await _androidRuntime.peerStatus();
        if (_generation != generation || !await isEnabled) {
          return disabledStatus;
        }
        if (peers['connected'] == true) return readyStatus;
        await _waitForRetry(generation);
      }
      if (_generation != generation || !await isEnabled) return disabledStatus;
      return _rememberBootstrapFailure(FipsRuntimeStatus(
        state: FipsRuntimeState.degraded,
        detail: 'FIPS is running, but the authenticated bootstrap peer did not '
            'connect. Its cause is unknown; check peer availability, network '
            'reachability (UDP port 2121) and the active mobile VPN.',
        nodeNpub: readyStatus.nodeNpub,
      ));
    }

    for (var attempt = 0; attempt < 12; attempt += 1) {
      if (_generation != generation || !await isEnabled) return disabledStatus;
      final peers = await _run(fipsctlPath, const ['show', 'peers']);
      if (_generation != generation || !await isEnabled) return disabledStatus;
      if (peers.exitCode == 0 && _bootstrapIsConnected(peers.stdout)) {
        return readyStatus;
      }
      if (attempt == 0) {
        final connect = await _run(fipsctlPath, const [
          'connect',
          bootstrapPeerNpub,
          bootstrapPeerAddress,
          'udp',
        ]);
        if (_generation != generation || !await isEnabled) {
          return disabledStatus;
        }
        if (connect.exitCode != 0) {
          return _rememberBootstrapFailure(FipsRuntimeStatus(
            state: FipsRuntimeState.degraded,
            detail: 'FIPS is running, but its authenticated bootstrap link '
                'could not start: ${_resultDetail(connect)}',
            nodeNpub: readyStatus.nodeNpub,
          ));
        }
      }
      await _waitForRetry(generation);
    }
    if (_generation != generation || !await isEnabled) return disabledStatus;
    return _rememberBootstrapFailure(FipsRuntimeStatus(
      state: FipsRuntimeState.degraded,
      detail: 'FIPS is running, but its authenticated bootstrap peer did not '
          'connect. The cause is unknown; check peer availability and network '
          'reachability (UDP port 2121).',
      nodeNpub: readyStatus.nodeNpub,
    ));
  }

  FipsRuntimeStatus _rememberBootstrapFailure(FipsRuntimeStatus status) {
    _bootstrapRetryAfter = DateTime.now().add(const Duration(seconds: 30));
    _lastBootstrapFailure = status;
    return status;
  }

  static bool _bootstrapIsConnected(Object output) {
    try {
      final decoded = jsonDecode(output.toString());
      final data = decoded is Map<String, dynamic> &&
              decoded['data'] is Map<String, dynamic>
          ? decoded['data'] as Map<String, dynamic>
          : decoded;
      if (data is! Map<String, dynamic> || data['peers'] is! List) {
        return false;
      }
      return (data['peers'] as List).any((peer) =>
          peer is Map<String, dynamic> &&
          peer['npub'] == bootstrapPeerNpub &&
          peer['connectivity']?.toString().toLowerCase() == 'connected');
    } catch (_) {
      return false;
    }
  }

  Future<FipsRuntimeStatus> _inspectRuntime() async {
    if (_isMobile) {
      try {
        return _androidStatus(await _androidRuntime.inspect());
      } catch (error) {
        await _recordAndroidEvent('dart_inspect_failed');
        return FipsRuntimeStatus(
          state: FipsRuntimeState.failed,
          detail: _androidBoundaryDetail(
            error,
            'Mobile embedded FIPS inspection failed. Please retry.',
          ),
        );
      }
    }
    if (!_isMacOS && !_isLinux) {
      return const FipsRuntimeStatus(
        state: FipsRuntimeState.notBundled,
        detail: 'Bundled desktop FIPS is supported on macOS and Linux WMapp.',
      );
    }
    if (!await _fileExists(bundledPackagePath)) {
      return const FipsRuntimeStatus(
        state: FipsRuntimeState.notBundled,
        detail: 'The pinned FIPS installer is missing from this app bundle.',
      );
    }
    if (!await _fileExists(fipsctlPath)) {
      return const FipsRuntimeStatus(
        state: FipsRuntimeState.notInstalled,
        detail: 'Bundled FIPS is ready to enable. It will activate '
            'automatically when you open a FIPS app.',
      );
    }

    final version = await _run(fipsctlPath, const ['--version']);
    if (version.exitCode != 0) {
      return FipsRuntimeStatus(
        state: FipsRuntimeState.failed,
        detail: 'Could not inspect fipsctl: ${_resultDetail(version)}',
      );
    }
    if (!version.stdout.toString().contains(expectedVersion)) {
      return FipsRuntimeStatus(
        state: FipsRuntimeState.installRequired,
        detail: 'FIPS $expectedVersion is required; installed: '
            '${redactSecrets(version.stdout.toString().trim())}.',
      );
    }

    if (!await _hasCompatibleWingmanAttestation()) {
      return const FipsRuntimeStatus(
        state: FipsRuntimeState.installRequired,
        detail: 'FIPS is installed, but its bundled Wingman mesh setup is '
            'missing or outdated. Opening a FIPS app will repair it while '
            'preserving this machine identity.',
      );
    }

    final status = await _run(fipsctlPath, const ['show', 'status']);
    if (status.exitCode != 0) {
      final service = _isLinux
          ? await _run(
              '/usr/bin/systemctl', const ['is-active', 'fips.service'])
          : await _run(
              '/bin/launchctl',
              const ['print', 'system/com.fips.daemon'],
            );
      if (service.exitCode == 0) {
        if (_looksLikePermissionDenied(status)) {
          return FipsRuntimeStatus(
            state: FipsRuntimeState.controlAccessPending,
            detail: 'FIPS is installed and its system service is loaded, but '
                'this ${_isLinux ? 'Linux' : 'macOS'} login session has not refreshed its FIPS control '
                'permission yet. You can open a FIPS app without the optional '
                'probe now; log out and back in to enable diagnostics.',
          );
        }
        return FipsRuntimeStatus(
          state: FipsRuntimeState.starting,
          detail:
              'The FIPS daemon is loaded but its control socket is not ready: '
              '${_resultDetail(status)}',
        );
      }
      return FipsRuntimeStatus(
        state: FipsRuntimeState.failed,
        detail: 'FIPS is installed but the daemon is unavailable: '
            '${_resultDetail(status)}',
      );
    }

    try {
      final decoded = jsonDecode(status.stdout.toString());
      final data = decoded is Map<String, dynamic> &&
              decoded['data'] is Map<String, dynamic>
          ? decoded['data'] as Map<String, dynamic>
          : decoded as Map<String, dynamic>;
      final state = data['state']?.toString().toLowerCase() ?? '';
      final tunState = data['tun_state']?.toString().toLowerCase() ?? '';
      final persistent = data['persistent'] == true;
      final nodeNpub =
          _findString(data, const ['npub', 'node_npub', 'identity']);
      if (state == 'failed') {
        return FipsRuntimeStatus(
          state: FipsRuntimeState.failed,
          detail: 'The FIPS daemon reports a failed state.',
          nodeNpub: nodeNpub,
        );
      }
      if (state == 'created' || state == 'starting') {
        return FipsRuntimeStatus(
          state: FipsRuntimeState.starting,
          detail: 'The FIPS daemon is starting.',
          nodeNpub: nodeNpub,
        );
      }
      if (state != 'running' || tunState != 'active' || !persistent) {
        return FipsRuntimeStatus(
          state: FipsRuntimeState.degraded,
          detail: 'FIPS is reachable but not ready for stable WApp access '
              '(state: ${state.isEmpty ? 'unknown' : state}, '
              'TUN: ${tunState.isEmpty ? 'unknown' : tunState}, '
              'persistent identity: $persistent).',
          nodeNpub: nodeNpub,
        );
      }
      return FipsRuntimeStatus(
        state: FipsRuntimeState.running,
        detail: 'FIPS $expectedVersion is running.',
        nodeNpub: nodeNpub,
      );
    } catch (error) {
      return FipsRuntimeStatus(
        state: FipsRuntimeState.degraded,
        detail: 'FIPS responded, but its status was not understood: '
            '${redactSecrets(error.toString())}',
      );
    }
  }

  Future<FipsRuntimeStatus> installOrRepair() async {
    if (!await isEnabled) return disabledStatus;
    final generation = _generation;
    _bootstrapRetryAfter = null;
    _lastBootstrapFailure = null;
    if (_isMobile) {
      if (_operationInProgress) {
        return const FipsRuntimeStatus(
          state: FipsRuntimeState.starting,
          detail: 'VPN consent or embedded FIPS startup is in progress.',
        );
      }
      _operationInProgress = true;
      final startup = Completer<void>();
      _mobileStartup = startup;
      try {
        await _recordAndroidEvent('dart_start_requested');
        final current = await _androidRuntime.inspect();
        final repair = current['state'] == 'degraded' ||
            current['state'] == 'failed' ||
            current['state'] == 'running';
        if (_generation != generation || !await isEnabled) {
          return disabledStatus;
        }
        final result = await _androidRuntime.start(repair: repair);
        if (_generation != generation || !await isEnabled) {
          // A start already inside native code can finish after stop.
          await _androidRuntime.stop();
          return disabledStatus;
        }
        return _androidStatus(result);
      } catch (error) {
        if (_generation != generation || !await isEnabled) {
          return disabledStatus;
        }
        await _recordAndroidEvent('dart_start_failed');
        return FipsRuntimeStatus(
          state: FipsRuntimeState.failed,
          detail: _androidBoundaryDetail(
            error,
            'VPN consent or FIPS startup failed. Please retry.',
          ),
        );
      } finally {
        _operationInProgress = false;
        startup.complete();
        if (identical(_mobileStartup, startup)) _mobileStartup = null;
      }
    }
    if ((!_isMacOS && !_isLinux) || !await _fileExists(bundledPackagePath)) {
      return _inspectRuntime();
    }
    final helperName =
        _isLinux ? linuxInstallScriptName : configurationScriptName;
    final helperPath =
        File(bundledPackagePath).parent.uri.resolve(helperName).toFilePath();
    if (!await _fileExists(helperPath)) {
      return const FipsRuntimeStatus(
        state: FipsRuntimeState.notBundled,
        detail: 'The bundled FIPS activation helper is missing.',
      );
    }
    _operationInProgress = true;
    try {
      final command = _isLinux
          ? linuxInstallCommand(bundledPackagePath)
          : installCommand(bundledPackagePath);
      if (_generation != generation || !await isEnabled) return disabledStatus;
      final result = await _run(command.executable, command.arguments);
      if (_generation != generation || !await isEnabled) return disabledStatus;
      if (result.exitCode != 0) {
        return FipsRuntimeStatus(
          state: FipsRuntimeState.failed,
          detail: 'FIPS installation was cancelled or failed: '
              '${_resultDetail(result)}',
        );
      }
      for (var attempt = 0; attempt < 10; attempt += 1) {
        if (_generation != generation || !await isEnabled) {
          return disabledStatus;
        }
        final status = await _inspectRuntime();
        if (_generation != generation || !await isEnabled) {
          return disabledStatus;
        }
        if (status.state != FipsRuntimeState.starting) return status;
        await _waitForRetry(generation);
      }
      return const FipsRuntimeStatus(
        state: FipsRuntimeState.starting,
        detail: 'FIPS was installed and is still starting.',
      );
    } finally {
      _operationInProgress = false;
    }
  }

  Future<FipsProbeResult> probe(String npub) async {
    final generation = _generation;
    if (!RegExp(r'^npub1[023456789acdefghjklmnpqrstuvwxyz]{58}$')
        .hasMatch(npub)) {
      return const FipsProbeResult(
          ok: false, detail: 'Invalid FIPS node npub.');
    }
    final status = await inspect();
    if (!status.isRunning) {
      return FipsProbeResult(ok: false, detail: status.detail);
    }
    if (!await isEnabled) {
      return FipsProbeResult(ok: false, detail: disabledStatus.detail);
    }
    if (_isMobile) {
      try {
        final result = await _androidRuntime.probe(npub);
        if (_generation != generation || !await isEnabled) {
          return FipsProbeResult(ok: false, detail: disabledStatus.detail);
        }
        return FipsProbeResult(
          ok: result['ok'] == true,
          detail: redactSecrets(
            result['detail']?.toString() ?? 'Mobile FIPS probe failed.',
          ),
        );
      } catch (error) {
        return FipsProbeResult(
          ok: false,
          detail: _androidBoundaryDetail(
            error,
            'Mobile FIPS probe failed. Please retry.',
          ),
        );
      }
    }
    final result = await _run(
      fipsctlPath,
      ['probe', npub, '--json', '--timeout', '15'],
    );
    if (_generation != generation || !await isEnabled) {
      return FipsProbeResult(ok: false, detail: disabledStatus.detail);
    }
    return FipsProbeResult(
      ok: result.exitCode == 0,
      detail: _resultDetail(result),
    );
  }

  Future<FipsRuntimeStatus> stop() => setEnabled(false);

  static FipsRuntimeStatus _androidStatus(Map<String, dynamic> value) {
    final state = switch (value['state']?.toString()) {
      'notBundled' => FipsRuntimeState.notBundled,
      'notInstalled' => FipsRuntimeState.notInstalled,
      'consentRequired' => FipsRuntimeState.consentRequired,
      'installRequired' => FipsRuntimeState.installRequired,
      'starting' => FipsRuntimeState.starting,
      'running' => FipsRuntimeState.running,
      'degraded' => FipsRuntimeState.degraded,
      _ => FipsRuntimeState.failed,
    };
    return FipsRuntimeStatus(
      state: state,
      detail: redactSecrets(
        value['detail']?.toString() ?? 'Mobile embedded FIPS state is unknown.',
      ),
      nodeNpub: value['nodeNpub']?.toString(),
    );
  }

  static String _androidBoundaryDetail(Object error, String fallback) {
    if (error is PlatformException) {
      return redactSecrets(error.message ?? fallback);
    }
    return fallback;
  }

  Future<ProcessResult> _run(String executable, List<String> arguments) async {
    try {
      if (!await isEnabled) {
        return ProcessResult(0, 1, '', 'FIPS is disabled in WMAPP.');
      }
      return await _processRunner(executable, arguments);
    } catch (error) {
      return ProcessResult(0, 127, '', redactSecrets(error.toString()));
    }
  }

  Future<bool> _hasCompatibleWingmanAttestation() async {
    final raw = await _readTextFile(attestationPath);
    if (raw == null) return false;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return false;
      return decoded['schema'] == 2 &&
          decoded['fipsVersion'] == expectedVersion &&
          decoded['rendezvousApp'] == 'wingman-fips-poc-v1' &&
          decoded['nostrShareLocalCandidates'] == true &&
          decoded['lanEnabled'] == true &&
          decoded['lanScope'] == 'wingman-fips-poc-v1' &&
          decoded['tunEnabled'] == true &&
          decoded['dnsEnabled'] == true &&
          decoded['udpAdvertiseOnNostr'] == true &&
          decoded['udpAcceptConnections'] == true &&
          decoded['udpOutboundOnly'] == false &&
          decoded['bootstrapPeerNpub'] == bootstrapPeerNpub &&
          decoded['bootstrapPeerAddress'] == bootstrapPeerAddress;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _readTextFileFromDisk(String path) async {
    try {
      return await File(path).readAsString();
    } catch (_) {
      return null;
    }
  }

  static String _resultDetail(ProcessResult result) {
    final stderr = redactSecrets(result.stderr.toString().trim());
    final stdout = redactSecrets(result.stdout.toString().trim());
    if (stderr.isNotEmpty) return stderr;
    if (stdout.isNotEmpty) return stdout;
    return 'command exited ${result.exitCode}';
  }

  static bool _looksLikePermissionDenied(ProcessResult result) {
    final detail = '${result.stderr}\n${result.stdout}'.toLowerCase();
    return detail.contains('permission denied') ||
        detail.contains('operation not permitted') ||
        detail.contains('eacces');
  }

  static String? _findString(Map<String, dynamic> value, List<String> keys) {
    for (final key in keys) {
      final found = value[key]?.toString().trim();
      if (found != null && found.startsWith('npub1')) return found;
    }
    for (final child in value.values) {
      if (child is Map<String, dynamic>) {
        final found = _findString(child, keys);
        if (found != null) return found;
      }
    }
    return null;
  }

  static String redactSecrets(String value) {
    return value
        .replaceAll(
          RegExp(r'nsec1[023456789acdefghjklmnpqrstuvwxyz]+'),
          '[redacted-nsec]',
        )
        .replaceAll(
          RegExp(
            r'("?(?:private[_ -]?key|secret|nsec)"?\s*[:=]\s*)[^\s,}]+',
            caseSensitive: false,
          ),
          r'$1[redacted]',
        );
  }
}
