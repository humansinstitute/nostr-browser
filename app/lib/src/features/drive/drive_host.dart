import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:file_selector/file_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/app_config.dart';
import '../../core/fips_app_target.dart';
import '../../core/nostr_crypto.dart';
import '../../core/signer_vault.dart';
import '../../core/tower_fips_proxy.dart';
import '../../core/fips_runtime_service.dart';
import 'drive_protocol.dart';

/// Desktop host. Keeps filesystem roots and OS grants exclusively on this machine.
class DriveHost extends ChangeNotifier {
  DriveHost(
      {this.identityLoader,
      this.endpointLoader,
      this.towerRequest,
      this.helperPath,
      this.beforeReplay,
      Future<ConnectionTask<Socket>> Function(dynamic host, int port)?
          socketConnector,
      FipsRuntimeService? fipsRuntime,
      SignerVaultSecretStore? hostSecretStore,
      this.listenAddress,
      this.listenPort = 7345,
      this.now = DateTime.now})
      : _fipsRuntime = fipsRuntime ?? FipsRuntimeService(),
        _socketConnector = socketConnector ?? Socket.startConnect,
        _hostSecretStore =
            hostSecretStore ?? _SecureStorageDriveHostSecretStore() {
    _enabledSubscription =
        _fipsRuntime.enabledChanges.listen(_onFipsEnabledChanged);
  }
  final Future<NostrIdentity> Function()? identityLoader;
  final Future<String> Function()? endpointLoader;
  final Future<Map<String, dynamic>> Function(
      String, String, String, Map<String, dynamic>?)? towerRequest;
  final String? helperPath;
  final Future<void> Function()? beforeReplay;
  final FipsRuntimeService _fipsRuntime;
  final Future<ConnectionTask<Socket>> Function(dynamic host, int port)
      _socketConnector;
  final SignerVaultSecretStore _hostSecretStore;
  int get activeRequests => _active.values.fold<int>(0, (n, x) => n + x.length);
  final InternetAddress? listenAddress;
  final int listenPort;
  final DateTime Function() now;
  int? get listeningPort => _server?.port;

  static const channel = MethodChannel('au.com.otherstuff.wingman/drive');
  static const storageKey = 'wingman.drive.shares.v1';
  static const hostIdentityStorageKey = 'wingman.drive.host-key.v1';
  static const _diagnosticsLimit = 60;
  static const _diagnosticsTextLimit = 24000;
  static const _driveDiagnosticsMarker =
      'wmapp-drive-diagnostics-v1 build=unknown revision=drive';
  final List<Map<String, dynamic>> shares = [];
  final List<String> _diagnostics = [];
  final Map<String, DrivePolicy> _policies = {};
  final Map<String, Set<HttpResponse>> _active = {};
  final DriveRequestVerifier _verifier = DriveRequestVerifier();
  HttpServer? _server;
  Timer? _timer;
  StreamSubscription<bool>? _enabledSubscription;
  final Set<HttpClient> _clients = {};
  final Set<Process> _helpers = {};
  bool _fipsEnabled = true;
  AppConfig? _config;
  NostrIdentity? _hostIdentity;
  String message = 'Choose a folder to share from this desktop.';
  String? endpoint;
  bool _refreshing = false;
  int _generation = 0;
  bool _disposed = false;
  bool get supported => !kIsWeb && (Platform.isMacOS || Platform.isLinux);
  bool get hasDiagnostics => _diagnostics.isNotEmpty;
  String get diagnosticsText => _diagnosticsText();

  void _onFipsEnabledChanged(bool enabled) {
    if (_disposed) return;
    _fipsEnabled = enabled;
    if (!enabled) {
      unawaited(_disableFipsHosting());
    } else if (_config != null) {
      unawaited(configure(_config!));
    }
  }

  Future<void> _disableFipsHosting() async {
    ++_generation;
    _fipsEnabled = false;
    await stop();
    if (_disposed || _fipsEnabled) return;
    message = 'FIPS is disabled. Enable it in Setup to host shared folders.';
    notifyListeners();
  }

  Future<void> configure(AppConfig config, {bool repair = false}) async {
    if (!supported || _disposed) return;
    final initialGeneration = _generation;
    final enabled = await _fipsRuntime.isEnabled;
    if (_disposed || initialGeneration != _generation) return;
    if (!enabled) {
      _config = config;
      await _disableFipsHosting();
      return;
    }
    if (_disposed) return;
    _fipsEnabled = true;
    final contextChanged = _config == null ||
        _config?.deviceNpub != config.deviceNpub ||
        _config?.towerUrl != config.towerUrl ||
        _config?.workspaceId != config.workspaceId;
    if (contextChanged) {
      clearDiagnostics(notify: false);
    }
    if (_server != null &&
        _config?.deviceNpub == config.deviceNpub &&
        _config?.deviceSecret == config.deviceSecret &&
        _config?.towerUrl == config.towerUrl &&
        _config?.workspaceId == config.workspaceId) {
      return;
    }
    final generation = ++_generation;
    await _stopResources();
    if (generation != _generation || _disposed || !_fipsEnabled) return;
    _config = config;
    final diagnosticsContext = _diagnosticsContext;
    if (config.deviceSecret.isEmpty) {
      message = 'Unlock your identity to host folders.';
      notifyListeners();
      return;
    }
    try {
      if (identityLoader != null) {
        _hostIdentity = await identityLoader!();
      } else {
        var secret = await _hostSecretStore.read(hostIdentityStorageKey);
        if (generation != _generation) return;
        if (secret == null) {
          secret = NostrCrypto.generateIdentity().nsec;
          await _hostSecretStore.write(hostIdentityStorageKey, secret);
        }
        if (generation != _generation) return;
        _hostIdentity = NostrCrypto.importIdentity(secret);
      }
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString(storageKey) ?? '[]') as List;
      if (generation != _generation) return;
      shares
        ..clear()
        ..addAll(saved.map((e) => (e as Map).cast<String, dynamic>()));
      for (final s in shares) {
        if (s['policy'] is Map && s['fetched_at'] is String) {
          _policies[s['id']] = DrivePolicy(
              (s['policy'] as Map).cast<String, dynamic>(),
              DateTime.parse(s['fetched_at']));
        }
        if (Platform.isMacOS && s['bookmark'] != null) {
          try {
            s['root'] =
                await channel.invokeMethod<String>('restore', s['bookmark']);
          } catch (_) {
            s['enabled'] = false;
          }
        }
      }
      final resolvedEndpoint = endpointLoader != null
          ? await endpointLoader!()
          : await _resolveLocalFipsEndpoint(
              repair: repair, diagnosticsContext: diagnosticsContext);
      if (generation != _generation) return;
      endpoint = resolvedEndpoint;
      final server = await HttpServer.bind(
          listenAddress ?? TowerFipsProxy.meshAddress(endpoint!), listenPort);
      if (generation != _generation) {
        await server.close(force: true);
        return;
      }
      _server = server;
      server.idleTimeout = const Duration(seconds: 30);
      server.listen(_serve);
      _timer = Timer.periodic(
          const Duration(seconds: 30), (_) => unawaited(refreshPolicies()));
      await refreshPolicies();
      message =
          'Hosting selected folders while Nostr Browser is running and unlocked.';
    } on DriveHostStartupException catch (error) {
      if (generation != _generation) return;
      await stop();
      message = error.message;
    } on SocketException catch (error) {
      if (generation != _generation) return;
      await stop();
      message =
          'Drive hosting could not bind to this machine FIPS address: ${error.osError?.message ?? error.message}. Check FIPS is running for this login session, then retry.';
    } on FormatException catch (error) {
      if (generation != _generation) return;
      await stop();
      message =
          'Drive hosting found an invalid FIPS identity: ${error.message}. Repair FIPS, then retry.';
    } catch (error) {
      if (generation != _generation) return;
      await stop();
      message =
          'Drive hosting failed during startup: ${FipsRuntimeService.redactSecrets(error.toString())}. Retry after checking FIPS and folder access.';
    }
    notifyListeners();
  }

  Future<String> _resolveLocalFipsEndpoint(
      {required bool repair, required String diagnosticsContext}) async {
    final status = repair
        ? await _fipsRuntime.ensureReadyForAppAccess()
        : await _fipsRuntime.inspect();
    _recordDiagnostic({
      'event': 'fips_readiness',
      'repair': repair,
      'state': status.state.name,
      'can_attempt_app_access': status.canAttemptAppAccess,
      'node_npub_present': status.nodeNpub?.trim().isNotEmpty == true,
    }, diagnosticsContext: diagnosticsContext);
    if (!status.canAttemptAppAccess) {
      throw DriveHostStartupException(
          'Drive hosting cannot start because FIPS is not ready: ${status.detail}');
    }
    final nodeNpub = status.nodeNpub?.trim();
    if (nodeNpub == null || nodeNpub.isEmpty) {
      if (status.state == FipsRuntimeState.controlAccessPending) {
        throw const DriveHostStartupException(
            'FIPS is running, but Drive hosting cannot read this machine FIPS identity from this login session yet. Log out and back in, then retry.');
      }
      throw DriveHostStartupException(
          'Drive hosting cannot start because FIPS did not report this machine identity (${status.detail})');
    }
    return 'http://$nodeNpub.fips:7345';
  }

  bool _owns(Map s) =>
      s['owner_npub'] == _config?.deviceNpub &&
      s['tower'] == _config?.towerUrl &&
      s['workspace_id'] == _config?.workspaceId;
  List<Map<String, dynamic>> get visible => shares.where(_owns).toList();
  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(storageKey, jsonEncode(shares));
  }

  Future<void> add(String name, String audience, String hostName) async {
    if (endpoint == null ||
        _server == null ||
        _config?.deviceSecret.isEmpty != false) {
      throw StateError('Host unavailable');
    }
    final generation = _generation;
    String? root;
    String? bookmark;
    if (Platform.isMacOS) {
      final picked = await channel.invokeMapMethod<String, dynamic>('pick');
      root = picked?['path'];
      bookmark = picked?['bookmark'];
    } else {
      root = await getDirectoryPath(confirmButtonText: 'Share folder');
    }
    if (root == null || generation != _generation) return;
    final bytes = NostrCrypto.generateIdentity().publicKeyHex.substring(0, 32);
    final id =
        '${bytes.substring(0, 8)}-${bytes.substring(8, 12)}-${bytes.substring(12, 16)}-${bytes.substring(16, 20)}-${bytes.substring(20)}';
    final s = <String, dynamic>{
      'id': id,
      'root': root,
      'bookmark': bookmark,
      'tower': _config!.towerUrl,
      'workspace_id': _config!.workspaceId,
      'owner_npub': _config!.deviceNpub,
      'name': name,
      'host_name': hostName,
      'audience': audience,
      'enabled': true,
      'published': false,
      'revision': 0
    };
    shares.add(s);
    await _persist();
    notifyListeners();
    try {
      await publish(s);
      await refreshPolicies();
    } catch (error) {
      s['last_registration_error'] = safeRegistrationError(error);
      await _persist();
      notifyListeners();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _tower(String url, String method, String secret,
      [Map<String, dynamic>? payload]) async {
    if (!_fipsEnabled || _disposed) throw StateError('FIPS disabled');
    if (towerRequest != null) {
      return towerRequest!(url, method, secret, payload);
    }
    final started = Stopwatch()..start();
    final body = payload == null ? null : jsonEncode(payload);
    final auth = NostrCrypto.signNip98(
        secret: secret, method: method, url: url, body: body);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _clients.add(client);
    client.findProxy = (_) => 'DIRECT';
    final uri = Uri.parse(url);
    final target = _diagnosticTarget(uri);
    final diagnosticsContext = _diagnosticsContext;
    var activeStage = 'connect';
    void record(String stage,
        {int? statusCode, String? code, Object? error, bool notify = true}) {
      activeStage = stage;
      _recordDiagnostic({
        'event': 'tower_request',
        'stage': stage,
        'elapsed_ms': started.elapsedMilliseconds,
        'method': method.toUpperCase(),
        'route': _safeRoute(uri),
        'configured_tower_origin': _safeOrigin(_config?.towerUrl),
        'share_tower_origin': _safeOrigin(uri.origin),
        'target_host': target.host,
        'target_port': target.port,
        if (target.meshHost != null) 'fips_mesh_host': target.meshHost,
        if (target.meshPort != null) 'fips_mesh_port': target.meshPort,
        if (statusCode != null) 'status': statusCode,
        if (code != null && code.isNotEmpty) 'code': _safeToken(code),
        if (error != null) 'error': _safeError(error),
      }, notify: notify, diagnosticsContext: diagnosticsContext);
    }

    if (uri.host.endsWith('.fips')) {
      late final FipsAppTarget fipsTarget;
      try {
        fipsTarget = FipsAppTarget.parse(uri.origin);
      } on FormatException {
        record('connect',
            error: StateError('invalid_fips_tower_url'), notify: false);
        _clients.remove(client);
        client.close(force: true);
        throw const DriveRegistrationException(
            'Invalid FIPS Tower URL. Use http://<node-npub>.fips:<port>.');
      }
      client.connectionFactory = (u, h, p) {
        record('connect', notify: false);
        return _socketConnector(
            TowerFipsProxy.meshAddress(fipsTarget.origin), fipsTarget.port);
      };
    }
    try {
      if (!uri.host.endsWith('.fips')) record('connect', notify: false);
      final req = await client.openUrl(method, uri);
      record('send', notify: false);
      req.followRedirects = false;
      req.headers.set('authorization', auth.authorization);
      req.headers.set('content-type', 'application/json');
      if (body != null) req.write(body);
      final data = <int>[];
      final response = await req.close().timeout(const Duration(seconds: 10));
      record('response', statusCode: response.statusCode, notify: false);
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        data.addAll(chunk);
        if (data.length > 1024 * 1024) throw StateError('policy_too_large');
      }
      final text = utf8.decode(data);
      Map<String, dynamic>? decoded;
      if (text.trim().isNotEmpty) {
        try {
          final value = jsonDecode(text);
          if (value is Map) decoded = value.cast<String, dynamic>();
        } catch (_) {
          decoded = null;
        }
      }
      if ({401, 403, 404}.contains(response.statusCode)) {
        record('parse',
            statusCode: response.statusCode, code: _safeBodyCode(decoded));
        throw DrivePolicyDenied(statusCode: response.statusCode, body: decoded);
      }
      if (response.statusCode != 200) {
        record('parse',
            statusCode: response.statusCode, code: _safeBodyCode(decoded));
        throw DriveTowerException(response.statusCode, decoded, text);
      }
      record('parse', statusCode: response.statusCode);
      return decoded ?? <String, dynamic>{};
    } catch (error) {
      if (error is DrivePolicyDenied || error is DriveTowerException) {
        rethrow;
      }
      record(_transportStage(error, activeStage), error: error);
      rethrow;
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  String _url(Map s) =>
      '${s['tower']}/api/v4/flightdeck-pg/workspaces/${s['workspace_id']}/drive/shares/${s['id']}';
  Map<String, dynamic> _registrationData(Map<String, dynamic> s) =>
      <String, dynamic>{
        'name': (s['name'] ?? '').toString().trim(),
        'host_name': (s['host_name'] ?? '').toString().trim(),
        'host_npub': _hostIdentity!.npub,
        'endpoint': endpoint,
        'audience': s['audience'],
        'enabled': s['enabled'],
        'previous_revision': s['revision']
      };

  Future<void> publish(Map<String, dynamic> s) async {
    try {
      if (!_owns(s) || _hostIdentity == null || endpoint == null) {
        throw StateError('owner_required');
      }
      final owner = NostrCrypto.importIdentity(_config!.deviceSecret);
      if (owner.npub != _config!.deviceNpub || owner.npub != s['owner_npub']) {
        throw const DriveRegistrationException(
            'Drive registration requires the unlocked owner identity for this workspace.');
      }
      final data = _registrationData(s);
      final proof = NostrCrypto.signEvent(secret: _hostIdentity!.nsec, event: {
        'kind': 27235,
        'content': '',
        'tags': [
          ['protocol', 'fips-drive-register-v1'],
          ['u', _url(s)],
          ['owner', s['owner_npub']],
          ['payload', sha256.convert(utf8.encode(jsonEncode(data))).toString()]
        ]
      });
      final result = await _tower(_url(s), 'PUT', _config!.deviceSecret,
          {...data, 'host_proof': proof});
      s['revision'] = int.parse(result['share']['revision'].toString());
      s['name'] = data['name'];
      s['host_name'] = data['host_name'];
      s['published'] = true;
      s.remove('last_registration_error');
      await _persist();
      notifyListeners();
    } catch (error) {
      s['published'] = false;
      s['last_registration_error'] = safeRegistrationError(error);
      await _persist();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateShare(
      Map<String, dynamic> share, String name, String audience) async {
    if (!_owns(share)) throw StateError('owner_required');
    _policies.remove(share['id']);
    share.remove('policy');
    share.remove('fetched_at');
    share['name'] = name;
    share['audience'] = audience;
    share['enabled'] = true;
    share['published'] = false;
    share.remove('last_registration_error');
    await _persist();
    notifyListeners();
    try {
      await publish(share);
      await refreshPolicies();
    } catch (error) {
      share['last_registration_error'] = safeRegistrationError(error);
      await _persist();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> disable(Map<String, dynamic> s) async {
    s['enabled'] = false;
    s['published'] = false;
    _policies.remove(s['id']);
    s.remove('policy');
    s.remove('fetched_at');
    for (final response in _active[s['id']] ?? <HttpResponse>{}) {
      unawaited(response.close());
    }
    await _persist();
    notifyListeners();
    try {
      await publish(s);
    } catch (_) {
      message = 'Stopped locally. Retry registration when Tower returns.';
      notifyListeners();
    }
  }

  String registrationStatus(Map<String, dynamic> s) {
    if (s['enabled'] != true) return 'Stopped';
    if (s['published'] == true && s['revision'] is int && s['revision'] > 0) {
      return 'Sharing';
    }
    final error = s['last_registration_error'];
    if (error is String && error.isNotEmpty) {
      return 'Registration failed: $error';
    }
    return 'Registration pending';
  }

  String safeRegistrationError(Object error) {
    if (error is DriveRegistrationException) return error.message;
    if (error is DriveTowerException) return error.safeMessage;
    if (error is DrivePolicyDenied) return error.safeMessage;
    if (error is SocketException) {
      return 'Network error reaching Tower (${error.osError?.message ?? error.message})';
    }
    if (error is TimeoutException) return 'Timed out waiting for Tower';
    if (error is FormatException) return 'Invalid Tower response';
    return FipsRuntimeService.redactSecrets(error.toString());
  }

  Future<void> refreshPolicies() async {
    if (_refreshing ||
        _hostIdentity == null ||
        !_fipsEnabled ||
        _disposed ||
        _server == null) {
      return;
    }
    _refreshing = true;
    final generation = _generation;
    try {
      for (final s in visible.where((s) => s['enabled'] == true)) {
        try {
          final value =
              await _tower('${_url(s)}/policy', 'GET', _hostIdentity!.nsec);
          if (generation != _generation) return;
          if (value['workspace_id'] != s['workspace_id'] ||
              value['share']['id'] != s['id'] ||
              value['share']['host_npub'] != _hostIdentity!.npub ||
              value['share']['endpoint'] != endpoint) {
            throw const DrivePolicyDenied();
          }
          final fetched = now();
          _policies[s['id']] = DrivePolicy(value, fetched);
          s['policy'] = value;
          s['fetched_at'] = fetched.toIso8601String();
          await _persist();
        } on DrivePolicyDenied {
          if (generation != _generation) return;
          _policies.remove(s['id']);
          s.remove('policy');
          s.remove('fetched_at');
          await _persist();
        } catch (_) {/* Outage never renews cached authorization. */}
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<Map<String, dynamic>> _fs(
      Map s, String operation, String path, int offset, String revision) async {
    final bundled = File(
        '${File(Platform.resolvedExecutable).parent.parent.path}/Resources/wmapp-drive-fs');
    final explicit = Platform.environment['WMAPP_DRIVE_FS'];
    final linux = File(
        '${File(Platform.resolvedExecutable).parent.path}/lib/wmapp-drive-fs');
    final binary = helperPath ??
        explicit ??
        (linux.existsSync()
            ? linux.path
            : bundled.existsSync()
                ? bundled.path
                : '${Directory.current.parent.path}/target/debug/wmapp-drive-fs');
    final generation = _generation;
    final process = await Process.start(binary, []);
    if (generation != _generation || _disposed || !_fipsEnabled) {
      process.kill();
      throw StateError('revoked');
    }
    _helpers.add(process);
    try {
      process.stdin.write(jsonEncode({
        'root': s['root'],
        'path': path,
        'operation': operation,
        'offset': offset,
        'revision': revision
      }));
      await process.stdin.close();
      final out = process.stdout.transform(utf8.decoder).join();
      unawaited(process.stderr.drain());
      final raw = await out.timeout(const Duration(seconds: 15), onTimeout: () {
        process.kill();
        throw StateError('filesystem_timeout');
      });
      if (await process.exitCode != 0 || raw.length > 1024 * 1024) {
        throw StateError('filesystem_unavailable');
      }
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } finally {
      _helpers.remove(process);
    }
  }

  Future<void> _replayTail = Future.value();
  Future<void> _consumeReplay(String replayId) {
    final next = _replayTail.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final replay =
          (jsonDecode(prefs.getString('wingman.drive.replay.v1') ?? '{}')
                  as Map)
              .cast<String, dynamic>();
      final currentTime = now().millisecondsSinceEpoch;
      replay.removeWhere((_, expiry) => (expiry as int) < currentTime);
      if (replay.length >= 8192 || replay.containsKey(replayId)) {
        throw StateError('replayed_request');
      }
      replay[replayId] = currentTime + 121000;
      if (!await prefs.setString(
          'wingman.drive.replay.v1', jsonEncode(replay))) {
        throw StateError('replay_unavailable');
      }
    });
    _replayTail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _serve(HttpRequest req) async {
    Map<String, dynamic>? s;
    final response = req.response;
    final serving = _server;
    final generation = _generation;
    try {
      final parts = req.uri.pathSegments;
      if (req.method != 'GET' ||
          parts.length != 4 ||
          parts[0] != 'drive' ||
          parts[1] != 'v1' ||
          !['list', 'read', 'status'].contains(parts[3])) {
        throw StateError('unsupported_request');
      }
      s = shares
          .where((s) => s['id'] == parts[2] && _owns(s) && s['enabled'] == true)
          .first;
      response.statusCode = 401;
      final identity = _verifier.verify(req.headers.value('authorization'),
          '$endpoint${req.uri}', s['workspace_id'], s['id'], now(),
          consume: false);
      response.statusCode = 200;
      bool allowed() =>
          serving != null &&
          identical(serving, _server) &&
          generation == _generation &&
          s!['enabled'] == true &&
          _owns(s) &&
          _policies[s['id']]?.allows(identity, now()) == true;
      if (!allowed()) {
        response.statusCode = 403;
        throw StateError('denied_or_policy_expired');
      }
      if (activeRequests >= 8) {
        response.statusCode = 429;
        throw StateError('busy');
      }
      // Reserve synchronously, before replay persistence can yield.
      _active.putIfAbsent(s['id'], () => {}).add(response);
      response.statusCode = 401;
      if (beforeReplay != null) await beforeReplay!();
      // Persist replay consumption before any bytes leave the host, surviving restart.
      final replayId = (jsonDecode(utf8.decode(
              base64Decode(req.headers.value('authorization')!.substring(6))))
          as Map)['id'] as String;
      await _consumeReplay(replayId);
      response.statusCode = 200;
      if (!allowed()) {
        response.statusCode = 403;
        throw StateError('revoked');
      }
      response.headers.set('cache-control', 'no-store');
      final path = req.uri.queryParameters['path'] ?? '';
      final revision = req.uri.queryParameters['revision'] ?? '';
      if (parts[3] == 'status') {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'available': true}));
      } else if (parts[3] == 'list') {
        final result = await _fs(
            s,
            'list',
            path,
            int.tryParse(req.uri.queryParameters['offset'] ?? '0') ?? 0,
            revision);
        if (!allowed()) {
          response.statusCode = 403;
          throw StateError('revoked');
        }
        if (result['error'] != null) {
          response.statusCode = result['error'] == 'changed' ? 409 : 404;
        }
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(result));
      } else {
        var offset = 0;
        while (true) {
          if (!allowed()) throw StateError('revoked');
          final result = await _fs(s, 'read', path, offset, revision);
          if (!allowed()) throw StateError('revoked');
          if (result['error'] != null) {
            if (offset == 0) {
              response.statusCode = result['error'] == 'changed' ? 409 : 404;
              response.write(jsonEncode(result));
            }
            break;
          }
          if (offset == 0) {
            response.contentLength = result['size'] as int;
            response.headers.contentType = ContentType.binary;
          }
          final bytes = base64Decode(result['chunk']);
          response.add(bytes);
          await response.flush().timeout(const Duration(seconds: 30));
          offset += bytes.length;
          if (result['done'] == true) break;
        }
      }
    } catch (_) {
      try {
        if (response.statusCode == 200) response.statusCode = 404;
      } catch (_) {}
    } finally {
      if (s != null) _active[s['id']]?.remove(response);
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    ++_generation;
    await _stopResources();
  }

  Future<void> _stopResources() async {
    _timer?.cancel();
    _timer = null;
    final server = _server;
    _server = null;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
    for (final helper in _helpers.toList()) {
      helper.kill();
    }
    _helpers.clear();
    endpoint = null;
    _policies.clear();
    _active.clear();
    await server?.close(force: true);
  }

  @override
  void dispose() {
    ++_generation;
    _disposed = true;
    unawaited(_enabledSubscription?.cancel());
    clearDiagnostics(notify: false);
    unawaited(stop());
    super.dispose();
  }

  void clearDiagnostics({bool notify = true}) {
    if (_diagnostics.isEmpty) return;
    _diagnostics.clear();
    if (notify) notifyListeners();
  }

  String _diagnosticsText() {
    final lines = <String>[
      '$_driveDiagnosticsMarker os=${Platform.operatingSystem}',
      ..._diagnostics,
    ];
    final text = lines.join('\n');
    if (text.length <= _diagnosticsTextLimit) return text;
    return text.substring(text.length - _diagnosticsTextLimit);
  }

  String get _diagnosticsContext =>
      '$_generation|${_config?.deviceNpub ?? ''}|${_config?.towerUrl ?? ''}|${_config?.workspaceId ?? ''}';

  void _recordDiagnostic(Map<String, Object?> fields,
      {bool notify = true, String? diagnosticsContext}) {
    if (_disposed) return;
    if (diagnosticsContext != null &&
        diagnosticsContext != _diagnosticsContext) {
      return;
    }
    final safe = <String, Object?>{
      'ts': now().toUtc().toIso8601String(),
      'workspace_scoped': _config?.workspaceId.trim().isNotEmpty == true,
      for (final entry in fields.entries)
        if (entry.value != null) entry.key: entry.value,
    };
    final line = safe.entries
        .map((entry) => '${entry.key}=${_diagnosticValue(entry.value)}')
        .join(' ');
    _diagnostics.add(line);
    while (_diagnostics.length > _diagnosticsLimit) {
      _diagnostics.removeAt(0);
    }
    if (notify) notifyListeners();
  }

  static String _diagnosticValue(Object? value) {
    if (value is bool || value is num) return value.toString();
    return jsonEncode(_safeText(value?.toString() ?? ''));
  }

  static String _safeText(String value) {
    final withoutControls = value
        .replaceAll(RegExp(r'[\r\n\t]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return withoutControls.length <= 220
        ? withoutControls
        : '${withoutControls.substring(0, 220)}...';
  }

  static String _safeToken(String value) {
    final match = RegExp(r'^[a-zA-Z0-9_.:-]{1,80}$').firstMatch(value);
    return match == null ? 'redacted' : value;
  }

  static String? _safeBodyCode(Map<String, dynamic>? body) {
    final code = body?['code'] ?? body?['error'];
    return code is String ? _safeTowerCode(code) : null;
  }

  static String _safeTowerCode(String value) {
    return switch (value) {
      'invalid_host_proof' ||
      'invalid_name' ||
      'invalid_request' ||
      'not_found' ||
      'unauthorized' ||
      'forbidden' =>
        value,
      _ => 'tower_error',
    };
  }

  static String _safeError(Object error) {
    if (error is SocketException) {
      final message = (error.osError?.message ?? error.message).toLowerCase();
      if (message.contains('connection refused')) return 'connection_refused';
      if (message.contains('timed out')) return 'connect_timeout';
      if (message.contains('network is unreachable')) {
        return 'network_unreachable';
      }
      if (message.contains('no route')) return 'no_route_to_host';
      if (message.contains('connection reset')) return 'connection_reset';
      return 'socket_error';
    }
    if (error is TimeoutException) return 'timeout';
    if (error is HandshakeException) return 'tls_handshake_failed';
    if (error is FormatException) return 'invalid_response';
    if (error is StateError) {
      return switch (error.message) {
        'invalid_fips_tower_url' => 'invalid_fips_tower_url',
        'policy_too_large' => 'response_too_large',
        _ => 'state_error',
      };
    }
    return error.runtimeType.toString();
  }

  static String _transportStage(Object error, String activeStage) {
    if (error is FormatException) return 'parse';
    if (error is StateError && error.message == 'policy_too_large') {
      return 'response';
    }
    return activeStage;
  }

  static String _safeOrigin(String? value) {
    final uri = Uri.tryParse((value ?? '').trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    return uri.hasPort
        ? '${uri.scheme}://${uri.host}:${uri.port}'
        : '${uri.scheme}://${uri.host}';
  }

  static String _safeRoute(Uri uri) {
    final parts = uri.pathSegments;
    const prefix = ['api', 'v4', 'flightdeck-pg', 'workspaces'];
    final driveShare = parts.length == 8 &&
        parts.take(4).toList().join('/') == prefix.join('/') &&
        parts[5] == 'drive' &&
        parts[6] == 'shares';
    if (driveShare) {
      return '/api/v4/flightdeck-pg/workspaces/<workspace>/drive/shares/<share>';
    }
    final drivePolicy = parts.length == 9 &&
        parts.take(4).toList().join('/') == prefix.join('/') &&
        parts[5] == 'drive' &&
        parts[6] == 'shares' &&
        parts[8] == 'policy';
    if (drivePolicy) {
      return '/api/v4/flightdeck-pg/workspaces/<workspace>/drive/shares/<share>/policy';
    }
    return '<unknown>';
  }

  static _TowerDiagnosticTarget _diagnosticTarget(Uri uri) {
    String? meshHost;
    int? meshPort;
    if (uri.host.endsWith('.fips')) {
      try {
        final target = FipsAppTarget.parse(uri.origin);
        meshHost = TowerFipsProxy.meshAddress(target.origin).address;
        meshPort = target.port;
      } catch (_) {
        meshHost = 'invalid_fips_target';
      }
    }
    return _TowerDiagnosticTarget(
      host: uri.host,
      port: uri.hasPort ? uri.port : _defaultPort(uri.scheme),
      meshHost: meshHost,
      meshPort: meshPort,
    );
  }

  static int _defaultPort(String scheme) {
    if (scheme == 'https') return 443;
    if (scheme == 'http') return 80;
    return 0;
  }
}

class _SecureStorageDriveHostSecretStore implements SignerVaultSecretStore {
  _SecureStorageDriveHostSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _macOsOptions = MacOsOptions(
    usesDataProtectionKeychain: false,
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) {
    return _storage.read(key: key, mOptions: _macOsOptions);
  }

  @override
  Future<void> write(String key, String value) {
    return _storage.write(key: key, value: value, mOptions: _macOsOptions);
  }

  @override
  Future<void> delete(String key) {
    return _storage.delete(key: key, mOptions: _macOsOptions);
  }
}

class DriveHostStartupException implements Exception {
  const DriveHostStartupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _TowerDiagnosticTarget {
  const _TowerDiagnosticTarget({
    required this.host,
    required this.port,
    this.meshHost,
    this.meshPort,
  });

  final String host;
  final int port;
  final String? meshHost;
  final int? meshPort;
}
