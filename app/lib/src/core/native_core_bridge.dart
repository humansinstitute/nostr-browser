import 'dart:convert';
import 'dart:io';

import 'app_config.dart';
import 'nostr_crypto.dart';

class NativeCoreBridge {
  static const signerLockedError =
      'Signer is locked. Unlock your identity with your PIN and retry.';

  String debugResolveRepoRoot() => _repoRoot();

  Future<CoreStatus> status(AppConfig config) async {
    final result = await _runCore([
      'status',
      if (config.workspaceId.isNotEmpty) ...[
        '--workspace-id',
        config.workspaceId,
      ],
    ], config: config);

    return CoreStatus(
      ok: result.ok,
      towerUrl: config.towerUrl,
      appNpub: config.appNpub,
      workspaceId: config.workspaceId,
      channelId: config.channelId,
      deviceNpub: config.deviceNpub,
      deviceConfigured: config.hasDeviceSecret,
      latestSync: result.ok ? 'core reachable' : 'not synced',
      message: result.ok
          ? 'Native core status loaded.'
          : 'Native core unavailable: ${result.error}',
    );
  }

  Future<DriveListing> listDrive(AppConfig config) async {
    final result = await _runCore([
      'list-items',
      '--workspace-id',
      config.workspaceId,
    ], config: config);
    if (result.ok) {
      final json = result.json;
      final items = (json['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(
            (item) => DriveItem(
              name: _string(item['name']) ?? _string(item['id']) ?? 'Untitled',
              path: _string(item['path']) ?? _string(item['id']) ?? '',
              kind: _string(item['item_type']) == 'folder'
                  ? DriveItemKind.folder
                  : DriveItemKind.file,
              localState: _string(item['cache_state']) ?? 'online_only',
            ),
          )
          .toList();
      return DriveListing(
        items: items,
        message: 'Loaded ${items.length} local Drive items from wmapp-core.',
      );
    }

    return DriveListing(
      items: const [
        DriveItem(
          name: 'Wingman App',
          path: '/Wingman Suite/Wingman App',
          kind: DriveItemKind.folder,
          localState: 'online_only',
        ),
        DriveItem(
          name: 'wmapp-cli-test.txt',
          path: '/Wingman Suite/Wingman App/wmapp-cli-test.txt',
          kind: DriveItemKind.file,
          localState: 'online_only',
        ),
      ],
      message: config.canSync
          ? 'Local index unavailable: ${result.error}'
          : 'Configure Tower, workspace, and device key before syncing.',
    );
  }

  Future<CoreCommandResult> syncOnce(AppConfig config) {
    return _runCore([
      'sync',
      '--once',
      '--workspace-id',
      config.workspaceId,
      '--channel-id',
      config.channelId,
    ], config: config);
  }

  Future<DeviceIdentity> generateDeviceKey() async {
    final identity = NostrCrypto.generateIdentity();
    return DeviceIdentity(
      npub: identity.npub,
      publicKeyHex: identity.publicKeyHex,
      nsec: identity.nsec,
    );
  }

  Future<DeviceIdentity> importDeviceKey(String secret) async {
    final identity = NostrCrypto.importIdentity(secret);
    return DeviceIdentity(
      npub: identity.npub,
      publicKeyHex: identity.publicKeyHex,
      nsec: secret,
    );
  }

  Future<CoreCommandResult> registerDevice(AppConfig config) {
    return _runCore([
      'device',
      'register',
      '--workspace-service-npub',
      config.workspaceServiceNpub,
      '--device-npub',
      config.deviceNpub,
      '--label',
      Platform.localHostname,
      '--platform',
      Platform.operatingSystem,
    ], config: config, signingSecret: config.registrationSecret);
  }

  Future<CoreCommandResult> validateChannel(AppConfig config) {
    return _runCore([
      'channel',
      '--workspace-id',
      config.workspaceId,
      '--channel-id',
      config.channelId,
    ], config: config);
  }

  Future<CoreCommandResult> signNip98({
    required AppConfig config,
    required String method,
    required String url,
    String? body,
  }) async {
    if (!config.hasDeviceSecret) {
      return const CoreCommandResult(
        ok: false,
        json: {},
        error: signerLockedError,
      );
    }
    try {
      final signed = NostrCrypto.signNip98(
        secret: config.deviceSecret,
        method: method,
        url: url,
        body: body,
      );
      return CoreCommandResult(
        ok: true,
        json: {
          'authorization': signed.authorization,
          'event': signed.event,
        },
      );
    } catch (error) {
      return CoreCommandResult(
        ok: false,
        json: const {},
        error: error.toString(),
      );
    }
  }

  Future<CoreCommandResult> signEvent({
    required AppConfig config,
    required Map<String, dynamic> event,
  }) async {
    if (!config.hasDeviceSecret) {
      return const CoreCommandResult(
        ok: false,
        json: {},
        error: signerLockedError,
      );
    }
    try {
      return CoreCommandResult(
        ok: true,
        json: NostrCrypto.signEvent(
          secret: config.deviceSecret,
          event: event,
        ),
      );
    } catch (error) {
      return CoreCommandResult(
        ok: false,
        json: const {},
        error: error.toString(),
      );
    }
  }

  Future<CoreCommandResult> nip44Encrypt({
    required AppConfig config,
    required String peerPubkey,
    required String plaintext,
  }) {
    return _runCore([
      'nip44',
      'encrypt',
      '--secret',
      config.deviceSecret,
      '--peer-pubkey',
      peerPubkey,
      '--plaintext',
      plaintext,
    ], config: config);
  }

  Future<CoreCommandResult> nip44Decrypt({
    required AppConfig config,
    required String peerPubkey,
    required String ciphertext,
  }) {
    return _runCore([
      'nip44',
      'decrypt',
      '--secret',
      config.deviceSecret,
      '--peer-pubkey',
      peerPubkey,
      '--ciphertext',
      ciphertext,
    ], config: config);
  }

  Future<CoreCommandResult> _runCore(
    List<String> args, {
    AppConfig? config,
    String? signingSecret,
  }) async {
    if (!_canRunCoreProcess) {
      return CoreCommandResult(
        ok: false,
        json: const {},
        error:
            'wmapp-core local process is not available on ${Platform.operatingSystem} yet',
      );
    }

    final executable = Platform.environment['WMAPP_CORE_BIN'];
    final environment = <String, String>{
      if (config != null) ...{
        'TOWER_URL': config.towerUrl,
        'FLIGHTDECK_APP_NPUB': config.appNpub,
        'WINGMAN_NSEC': signingSecret?.trim().isNotEmpty == true
            ? signingSecret!.trim()
            : config.deviceSecret,
      },
    };

    final result = executable == null || executable.isEmpty
        ? await Process.run(
            'cargo',
            ['run', '--quiet', '--bin', 'wmapp-core', '--', ...args],
            workingDirectory: _repoRoot(),
            environment: environment,
          )
        : await Process.run(
            executable,
            args,
            environment: environment,
          );

    if (result.exitCode != 0) {
      return CoreCommandResult(
        ok: false,
        json: const {},
        error: _trimOutput(result.stderr) ?? _trimOutput(result.stdout),
      );
    }

    final stdout = _trimOutput(result.stdout) ?? '{}';
    try {
      final decoded = jsonDecode(stdout);
      return CoreCommandResult(
        ok: true,
        json: decoded is Map<String, dynamic> ? decoded : {'value': decoded},
      );
    } catch (error) {
      return CoreCommandResult(
        ok: false,
        json: const {},
        error: 'invalid JSON from core: $error',
      );
    }
  }

  String? _trimOutput(Object output) {
    final value = output.toString().trim();
    return value.isEmpty ? null : value;
  }

  String? _string(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  String _repoRoot() {
    final explicit = Platform.environment['WMAPP_REPO_DIR'];
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit.trim();
    }

    final candidates = <String>[
      Directory.current.path,
      '${Directory.current.path}/..',
      '${Directory.current.path}/../..',
      '${Platform.environment['HOME'] ?? ''}/code/nbrowser',
      '${Platform.environment['HOME'] ?? ''}/code/wm/wmapp',
      '${Platform.environment['HOME'] ?? ''}/code/wingmanbefree/wm-app',
      '${Platform.environment['HOME'] ?? ''}/wm-app',
    ];

    for (final candidate in candidates) {
      if (candidate.trim().isEmpty) continue;
      final directory = Directory(candidate).absolute;
      if (File('${directory.path}/Cargo.toml').existsSync() &&
          Directory('${directory.path}/crates/wmapp-core').existsSync()) {
        return directory.path;
      }
    }

    return Directory.current.path;
  }

  bool get _canRunCoreProcess {
    return Platform.isMacOS || Platform.isLinux || Platform.isWindows;
  }
}

class CoreStatus {
  const CoreStatus({
    required this.ok,
    required this.towerUrl,
    required this.appNpub,
    required this.workspaceId,
    required this.channelId,
    required this.deviceNpub,
    required this.deviceConfigured,
    required this.latestSync,
    required this.message,
  });

  final bool ok;
  final String towerUrl;
  final String appNpub;
  final String workspaceId;
  final String channelId;
  final String deviceNpub;
  final bool deviceConfigured;
  final String latestSync;
  final String message;
}

class DriveListing {
  const DriveListing({
    required this.items,
    required this.message,
  });

  final List<DriveItem> items;
  final String message;
}

class DriveItem {
  const DriveItem({
    required this.name,
    required this.path,
    required this.kind,
    required this.localState,
  });

  final String name;
  final String path;
  final DriveItemKind kind;
  final String localState;
}

enum DriveItemKind {
  folder,
  file,
}

class DeviceIdentity {
  const DeviceIdentity({
    required this.npub,
    required this.publicKeyHex,
    this.nsec,
  });

  factory DeviceIdentity.fromJson(Map<String, dynamic> json) {
    return DeviceIdentity(
      npub: json['npub']?.toString() ?? '',
      publicKeyHex: json['public_key_hex']?.toString() ?? '',
      nsec: json['nsec']?.toString(),
    );
  }

  final String npub;
  final String publicKeyHex;
  final String? nsec;

  DeviceIdentity copyWith({
    String? npub,
    String? publicKeyHex,
    String? nsec,
  }) {
    return DeviceIdentity(
      npub: npub ?? this.npub,
      publicKeyHex: publicKeyHex ?? this.publicKeyHex,
      nsec: nsec ?? this.nsec,
    );
  }
}

class CoreCommandResult {
  const CoreCommandResult({
    required this.ok,
    required this.json,
    this.error,
  });

  final bool ok;
  final Map<String, dynamic> json;
  final String? error;
}
