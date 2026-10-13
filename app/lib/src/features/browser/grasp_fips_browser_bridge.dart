import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

import '../../core/grasp_fips_transport.dart';
import '../../core/tower_fips_proxy.dart';
import 'grasp_fips_bridge_script.dart';
import 'mesh_auth_request.dart';
import 'relay_diagnostics.dart';
import '../drive/drive_native_save.dart';

/// Ephemeral endpoint-scoped transport grants for one native-verified top-level
/// document. Authentication remains a separate signer concern.
enum GraspFipsConsentResult { approved, denied, unavailable }

class FipsTransportConsentRequest {
  const FipsTransportConsentRequest({
    required this.endpoint,
    required this.peerNpub,
    required this.purpose,
  });

  final String endpoint;
  final String peerNpub;
  final String purpose;

  String get policyOperation => 'fips-policy-v1:transport:$purpose:$peerNpub';
}

class FipsAuthenticationGrant {
  const FipsAuthenticationGrant({
    required this.grantId,
    required this.endpoint,
    required this.peerNpub,
    required this.purpose,
    required this.operation,
    required this.authentication,
  });

  final String grantId;
  final String endpoint;
  final String peerNpub;
  final String purpose;
  final String operation;
  final String authentication;

  String get policyOperation =>
      'fips-policy-v1:signing:$authentication:$purpose:'
      '$peerNpub:${operation.toUpperCase()}';
}

class GraspFipsBrowserBridge {
  GraspFipsBrowserBridge(
      {required this.pageOrigin,
      required this.approve,
      required this.prepare,
      required this.reply,
      this.transportFactory,
      this.onDiagnostic});
  final String pageOrigin;
  final Future<GraspFipsConsentResult> Function(
      FipsTransportConsentRequest request) approve;
  final Future<String?> Function(String endpoint) prepare;
  final Future<void> Function(String script) reply;
  final GraspFipsTransport Function(String endpoint)? transportFactory;
  final void Function(String tab, String relay, String stage)? onDiagnostic;
  final String _token = TowerFipsProxy.capability();
  final Map<String, GraspHttpRequest> _requests = {};
  final Map<String, GraspSocket> _sockets = {};
  final Set<String> _denied = {};
  final Map<String, GraspFipsTransport> _grants = {};
  final Map<String, String> _grantPurposes = {};
  final Map<String, String> _requestGrants = {};
  final Map<String, String> _socketGrants = {};
  final Map<String, String> _socketTraces = {};
  final Map<String, String> _grantTraces = {};
  final Map<String, String> _authEventIds = {};
  final String _diagnosticTab = TowerFipsProxy.capability().substring(0, 8);
  bool get _diagnosticsEnabled =>
      onDiagnostic != null || RelayDiagnostics.enabled;
  final Map<String, DriveNativeSave> _saves = {};
  bool get hasDrive => _grantPurposes.values.contains('drive');
  bool _closed = false;
  final Set<String> _connectingEndpoints = {};
  int _epoch = 0, _opening = 0;
  String get script => graspFipsBridgeScript(_token, pageOrigin);
  int get grantEpoch => _epoch;
  String? get endpoint =>
      _grants.isEmpty ? null : _grants.values.first.endpoint;
  String get signingDocumentToken => _token;

  void _diagnose(String tab, String relay, String stage) {
    if (!_diagnosticsEnabled) return;
    try {
      (onDiagnostic ?? RelayDiagnostics.record)(tab, relay, stage);
    } catch (_) {
      // A diagnostic sink cannot change transport or signing behavior.
    }
  }

  void recordAuthentication(String? grantId, String stage) {
    final trace = grantId == null
        ? (_socketTraces.length == 1 ? _socketTraces.values.single : null)
        : _grantTraces[grantId];
    if (trace != null) _diagnose(_diagnosticTab, trace, stage);
  }

  void _recordSocket(String id, String stage) {
    final trace = _socketTraces[id];
    if (trace != null) _diagnose(_diagnosticTab, trace, stage);
  }

  String? _relayStage(String data, {required bool outbound}) {
    try {
      final frame = jsonDecode(data);
      if (frame is! List || frame.isEmpty || frame.first is! String) {
        return null;
      }
      switch (frame.first) {
        case 'AUTH':
          return outbound ? 'auth_sent' : 'auth_challenge';
        case 'OK':
          return null;
        case 'REQ':
          return outbound ? 'req_sent' : null;
        case 'EVENT':
          return 'event_received';
        case 'EOSE':
          return 'eose_received';
        case 'CLOSED':
          return 'subscription_closed';
      }
    } catch (_) {}
    return null;
  }

  bool permitsMeshSigning(String? documentToken, String targetUrl) {
    if (_closed || documentToken != _token) return false;
    return _grants.entries.any((entry) =>
        _grantPurposes[entry.key] == 'tower' && entry.value.accepts(targetUrl));
  }

  bool permitsAuthentication(String method, Map<String, dynamic> params) {
    if (_closed) return false;
    if (permitsDriveAuthentication(params)) return true;
    return authenticationGrant(method, params) != null;
  }

  FipsAuthenticationGrant? authenticationGrant(
      String method, Map<String, dynamic> params) {
    if (_closed) return null;
    final auth = MeshAuthRequest.parse(method, params);
    if (auth == null) return null;
    if (method == 'signEvent' &&
        (DateTime.now().millisecondsSinceEpoch ~/ 1000 -
                    (params['created_at'] as int))
                .abs() >
            60) {
      return null;
    }
    bool narrowGit = false;
    var gitTarget = false;
    if (method == 'signEvent' && params['kind'] == 27235) {
      final tags = params['tags'] as List;
      final uri = Uri.parse(auth.target);
      gitTarget = RegExp(r'^/[^/]+/[^/]+\.git$').hasMatch(uri.path);
      narrowGit = auth.operation == 'GET' &&
          tags.length == 2 &&
          !uri.hasQuery &&
          gitTarget;
    }
    final matches = _grants.entries.where((entry) {
      final purpose = _grantPurposes[entry.key];
      if (!entry.value
          .accepts(auth.target, websocket: params['kind'] == 22242)) {
        return false;
      }
      if (method == 'signNip98') {
        return {'service', 'tower', 'autopilot'}.contains(purpose);
      }
      if (params['kind'] == 27235) {
        if (gitTarget && !narrowGit) return false;
        return narrowGit
            ? {'service', 'git'}.contains(purpose)
            : {'service', 'tower', 'autopilot'}.contains(purpose);
      }
      return params['kind'] == 22242;
    }).toList();
    if (matches.length != 1) return null;
    final match = matches.single;
    if (params['kind'] == 22242) {
      final tags = params['tags'] as List;
      final challenge =
          tags.firstWhere((t) => t[0] == 'challenge')[1] as String;
      if (!match.value.hasChallenge(auth.target, challenge)) return null;
    }
    final endpoint = match.value.endpoint;
    return FipsAuthenticationGrant(
      grantId: match.key,
      endpoint: endpoint,
      peerNpub: Uri.parse(endpoint).host.replaceFirst(RegExp(r'\.fips$'), ''),
      purpose: _grantPurposes[match.key]!,
      operation: auth.operation,
      authentication: method == 'signNip98'
          ? 'nip98'
          : params['kind'] == 22242
              ? 'nip42'
              : 'nip98-event',
    );
  }

  bool permitsDriveAuthentication(Map<String, dynamic> p) {
    try {
      final tags = p['tags'] as List;
      if (_closed ||
          p['kind'] != 27235 ||
          p['content'] != '' ||
          tags.length != 5 ||
          (DateTime.now().millisecondsSinceEpoch ~/ 1000 -
                      (p['created_at'] as int))
                  .abs() >
              60) {
        return false;
      }
      if (tags[0][0] != 'u' ||
          tags[1][0] != 'method' ||
          tags[1][1] != 'GET' ||
          tags[2][0] != 'workspace' ||
          tags[3][0] != 'share' ||
          tags[4][0] != 'nonce') {
        return false;
      }
      if (tags.any((t) => t is! List || t.length != 2 || t[1] is! String)) {
        return false;
      }
      final url = tags[0][1] as String;
      final u = Uri.parse(url);
      return _grants.entries.any((entry) =>
              _grantPurposes[entry.key] == 'drive' &&
              entry.value.accepts(url)) &&
          u.path == '/drive/v1/${tags[3][1]}/${u.pathSegments.last}' &&
          ['list', 'read', 'status'].contains(u.pathSegments.last) &&
          RegExp(r'^[a-zA-Z0-9_-]{32,128}$').hasMatch(tags[4][1]);
    } catch (_) {
      return false;
    }
  }

  Future<void> receive(String message) async {
    String? id;
    String? operation;
    final epoch = _epoch;
    try {
      if (_closed || message.length > 1500000) return;
      final value = jsonDecode(message) as Map<String, dynamic>;
      if (value['token'] != _token) return;
      id = value['id'] as String;
      operation = value['method'] as String?;
      if (id.length > 128) return;
      final result = await _call(value['method'] as String,
          (value['params'] as Map).cast<String, dynamic>());
      if (!_closed &&
          (epoch == _epoch ||
              value['method'] == 'connect' ||
              value['method'] == 'disconnect')) {
        await reply(
            'window.__wingmanGraspReply?.(${jsonEncode(_token)},${jsonEncode(id)},${jsonEncode(result)},null)');
      }
    } catch (error) {
      if (!_closed && id != null) {
        final errorText = error.toString().toLowerCase();
        final errorMessage = operation == 'connectDrive'
            ? (errorText.contains('denied')
                ? 'consent-denied'
                : errorText.contains('unavailable')
                    ? 'unavailable'
                    : 'offline')
            : operation?.startsWith('save') == true
                ? (error is StateError && error.message == 'cancelled'
                    ? 'save-cancelled'
                    : operation == 'saveBegin'
                        ? 'save-dialog-failed'
                        : operation == 'saveWrite'
                            ? 'save-write-failed'
                            : 'save-finish-failed')
                : _safeFailure(operation, error);
        await reply(
            'window.__wingmanGraspReply?.(${jsonEncode(_token)},${jsonEncode(id)},null,${jsonEncode(errorMessage)})');
      }
    }
  }

  String _safeFailure(String? method, Object error) {
    final text = error.toString().toLowerCase();
    String stage(String suffix) {
      switch (method) {
        case 'connect':
          return 'wmapp_grasp_connect_$suffix';
        case 'open':
          return 'wmapp_grasp_open_$suffix';
        case 'write':
          return 'wmapp_grasp_upload_$suffix';
        case 'finish':
          return 'wmapp_grasp_response_$suffix';
        case 'pull':
          return 'wmapp_grasp_stream_$suffix';
        case 'wsOpen':
          return 'wmapp_grasp_relay_open_$suffix';
        case 'wsNext':
          return 'wmapp_grasp_relay_stream_$suffix';
        case 'wsSend':
          return 'wmapp_grasp_relay_send_$suffix';
        case 'wsClose':
        case 'cancel':
        case 'disconnect':
          return 'wmapp_grasp_revoked';
        default:
          return 'wmapp_grasp_request_$suffix';
      }
    }

    if (text.contains('denied')) return 'wmapp_grasp_consent_denied';
    if (text.contains('revoked') || text.contains('closed')) {
      return 'wmapp_grasp_revoked';
    }
    if (error is TimeoutException || text.contains('timed out')) {
      return stage('timeout');
    }
    if (error is SocketException) return stage('socket_failed');
    if (text.contains('unavailable')) return 'wmapp_grasp_unavailable';
    if (text.contains('redirect')) return 'wmapp_grasp_redirect_rejected';
    if (error is FormatException || text.contains('unapproved')) {
      return stage('rejected');
    }
    if (text.contains('too many') || text.contains('busy')) {
      return 'wmapp_grasp_busy';
    }
    if (text.contains('invalid')) return stage('invalid_state');
    return stage('failed');
  }

  Future<dynamic> _call(String method, Map<String, dynamic> p) async {
    if (method == 'connectDrive') {
      return _connect({...p, 'purpose': 'drive'});
    }
    if (method == 'saveBegin') {
      if (_saves.length >= 4 || !hasDrive) {
        throw StateError('save_unavailable');
      }
      final epoch = _epoch;
      final name =
          (p['name'] as String).replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'), '_');
      if (name.isEmpty || name == '.' || name == '..' || name.length > 240) {
        throw StateError('invalid_filename');
      }
      String? target;
      if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
        target = (await getSaveLocation(suggestedName: name))?.path;
      } else {
        final root = Platform.isAndroid
            ? await getApplicationSupportDirectory()
            : await getApplicationDocumentsDirectory();
        final directory =
            await Directory('${root.path}/drive/${TowerFipsProxy.capability()}')
                .create(recursive: true);
        target = '${directory.path}/$name';
      }
      if (target == null || _closed || epoch != _epoch) {
        throw StateError('cancelled');
      }
      final id = TowerFipsProxy.capability();
      final file = File('$target.$id.partial');
      _saves[id] = DriveNativeSave(file, target);
      return id;
    }
    if (method.startsWith('save')) {
      final id = p['saveId'] as String;
      final save = _saves[id];
      if (save == null) throw StateError('save_closed');
      if (method == 'saveWrite') {
        final chunk = p['chunk'] as String;
        if (chunk.length > 87384) throw StateError('chunk_too_large');
        final bytes = base64Decode(chunk);
        if (bytes.length > 65536) throw StateError('chunk_too_large');
        if (save.cancelled) throw StateError('cancelled');
        save.sink.add(bytes);
        await save.sink.flush();
        return null;
      }
      final epoch = _epoch;
      try {
        if (method == 'saveFinish') {
          Map<String, dynamic> exportResult = {};
          await save.finish(
              revoked: () => _closed || epoch != _epoch,
              export: p['open'] == true || Platform.isIOS || Platform.isAndroid
                  ? () async {
                      final result = await const MethodChannel(
                              'au.com.otherstuff.wingman/drive')
                          .invokeMethod('open', save.target);
                      if (result is Map) {
                        exportResult = result.cast<String, dynamic>();
                      }
                    }
                  : null);
          return {
            'saved': true,
            'committed': save.committed,
            'location': 'local',
            ...exportResult
          };
        }
        await save.cancel();
        return null;
      } finally {
        _saves.remove(id);
      }
    }
    if (method == 'connect') {
      return _connect(p);
    }
    if (method == 'disconnect') {
      final grantId = p['grantId'] as String?;
      if (grantId == null) {
        _disconnect();
      } else {
        _revokeGrant(grantId);
      }
      return null;
    }
    final requestedUrl = p['url'] as String?;
    var grantId = p['grantId'] as String?;
    if (grantId == null && requestedUrl != null) {
      final matches = _grants.entries
          .where((entry) =>
              entry.value.accepts(requestedUrl, websocket: method == 'wsOpen'))
          .toList();
      if (matches.length == 1) grantId = matches.single.key;
    }
    final transport = grantId == null ? null : _grants[grantId];
    if (transport != null &&
        _grantPurposes[grantId] == 'drive' &&
        (method != 'open' ||
            p['method'] != 'GET' ||
            !RegExp(r'^/drive/v1/[^/]+/(list|read|status)$')
                .hasMatch(Uri.parse(requestedUrl!).path))) {
      throw StateError('Read-only Drive request required.');
    }
    if (transport == null &&
        !{'pull', 'finish', 'write', 'cancel', 'wsClose', 'wsNext', 'wsSend'}
            .contains(method)) {
      throw StateError('Connect first.');
    }
    final epoch = _epoch;
    if (method == 'open' || method == 'wsOpen') {
      if (_opening + _requests.length + _sockets.length >= 32) {
        throw StateError('Too many requests.');
      }
      _opening++;
      try {
        final id = TowerFipsProxy.capability();
        if (method == 'open') {
          final request = await transport!.open(
              p['url'] as String,
              p['method'] as String,
              (p['headers'] as Map).cast<String, dynamic>());
          if (_closed || epoch != _epoch) {
            request.close();
            throw StateError('Revoked.');
          }
          _requests[id] = request;
          _requestGrants[id] = grantId!;
        } else {
          final trace = _diagnosticsEnabled
              ? TowerFipsProxy.capability().substring(0, 8)
              : null;
          if (trace != null) _diagnose(_diagnosticTab, trace, 'ws_open_start');
          late final GraspSocket socket;
          try {
            socket = await transport!.socket(p['url'] as String);
          } catch (_) {
            if (trace != null) {
              _diagnose(_diagnosticTab, trace, 'ws_open_failed');
            }
            rethrow;
          }
          if (_closed || epoch != _epoch) {
            socket.close();
            if (trace != null) {
              _diagnose(_diagnosticTab, trace, 'bridge_revoked');
            }
            throw StateError('Revoked.');
          }
          _sockets[id] = socket;
          _socketGrants[id] = grantId!;
          if (trace != null) {
            _socketTraces[id] = trace;
            _grantTraces[grantId] = trace;
            _diagnose(_diagnosticTab, trace, 'ws_open_ok');
          }
        }
        return id;
      } finally {
        _opening--;
      }
    }
    final id = p['requestId'] as String;
    if (method == 'cancel') {
      _requests.remove(id)?.close();
      _requestGrants.remove(id);
      return null;
    }
    if (method == 'wsClose') {
      _recordSocket(id, 'ws_close_requested');
      final code = p['code'] as int? ?? 1000;
      final reason = p['reason'] as String? ?? '';
      if ((code != 1000 && (code < 3000 || code > 4999)) ||
          utf8.encode(reason).length > 123) {
        throw StateError('Invalid close.');
      }
      _sockets.remove(id)?.close(code, reason);
      _socketGrants.remove(id);
      _socketTraces.remove(id);
      _authEventIds.remove(id);
      return null;
    }
    if (method == 'wsNext' || method == 'wsSend') {
      final socket = _sockets[id];
      if (socket == null) throw StateError('Relay closed.');
      try {
        if (method == 'wsSend') {
          await socket.send(p['data'] as String, p['text'] as bool);
          if (_diagnosticsEnabled && p['text'] == true) {
            final stage = _relayStage(p['data'] as String, outbound: true);
            if (stage == 'auth_sent') {
              try {
                final frame = jsonDecode(p['data'] as String) as List;
                final event = frame[1] as Map;
                if (event['id'] is String) {
                  _authEventIds[id] = event['id'] as String;
                }
              } catch (_) {}
            }
            if (stage != null) _recordSocket(id, stage);
          }
          return null;
        }
        final result = await socket.next();
        if (_diagnosticsEnabled &&
            result['done'] != true &&
            result['text'] == true) {
          final stage = _relayStage(result['data'] as String, outbound: false);
          if (stage != null) _recordSocket(id, stage);
          try {
            final frame = jsonDecode(result['data'] as String) as List;
            if (frame.length >= 3 &&
                frame[0] == 'OK' &&
                frame[1] == _authEventIds[id]) {
              _recordSocket(id, frame[2] == true ? 'auth_ok' : 'auth_rejected');
              _authEventIds.remove(id);
            }
          } catch (_) {}
        }
        if (result['done'] == true) {
          _recordSocket(id, 'ws_next_closed');
          _sockets.remove(id);
          _socketGrants.remove(id);
          _socketTraces.remove(id);
          _authEventIds.remove(id);
        }
        return result;
      } catch (_) {
        _recordSocket(id, 'ws_next_or_send_failed');
        _sockets.remove(id)?.close();
        _socketGrants.remove(id);
        _socketTraces.remove(id);
        _authEventIds.remove(id);
        rethrow;
      }
    }
    final request = _requests[id];
    if (request == null) throw StateError('Request closed.');
    try {
      switch (method) {
        case 'write':
          await request.write(p['chunk'] as String);
          return null;
        case 'finish':
          return await request.finish();
        case 'pull':
          final result = await request.pull();
          if (result['done'] == true) {
            _requests.remove(id);
            _requestGrants.remove(id);
          }
          return result;
        default:
          throw StateError('Unknown operation.');
      }
    } catch (_) {
      _requests.remove(id)?.close();
      _requestGrants.remove(id);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _connect(Map<String, dynamic> p) async {
    final endpoint = p['endpoint'] as String;
    TowerFipsProxy.validateEndpoint(endpoint);
    final nodeNpub =
        Uri.parse(endpoint).host.replaceFirst(RegExp(r'\.fips$'), '');
    final peerNpub = p['peerNpub'] as String? ?? p['serviceNpub'] as String?;
    if (peerNpub != null && peerNpub != nodeNpub) {
      throw const FormatException('Pinned peer does not match endpoint.');
    }
    final purpose = p['purpose'] is String ? p['purpose'] as String : 'service';
    if (!{'service', 'tower', 'drive', 'git', 'autopilot'}.contains(purpose)) {
      throw const FormatException('Unsupported transport purpose.');
    }
    final consentRequest = FipsTransportConsentRequest(
      endpoint: endpoint,
      peerNpub: nodeNpub,
      purpose: purpose,
    );
    final denialKey = '${consentRequest.policyOperation}|$endpoint';
    if (_denied.contains(denialKey)) throw StateError('Connection denied.');
    if (_connectingEndpoints.contains(endpoint) ||
        _grants.length + _connectingEndpoints.length >= 8) {
      throw StateError('Connection unavailable.');
    }
    _connectingEndpoints.add(endpoint);
    final epoch = _epoch;
    try {
      final consent = await approve(consentRequest);
      if (consent == GraspFipsConsentResult.denied) {
        _denied.add(denialKey);
        throw StateError('Denied.');
      }
      if (consent != GraspFipsConsentResult.approved) {
        throw StateError('Connection unavailable.');
      }
      if (_closed || epoch != _epoch) throw StateError('Revoked.');
      final failure = await prepare('$endpoint/');
      if (failure != null || _closed || epoch != _epoch) {
        throw StateError('FIPS unavailable.');
      }
      final grantId = TowerFipsProxy.capability();
      _grants[grantId] =
          transportFactory?.call(endpoint) ?? GraspFipsTransport(endpoint);
      _grantPurposes[grantId] = purpose;
      return {
        'version': 2,
        'grantId': grantId,
        'endpoint': endpoint,
        'peerNpub': nodeNpub,
        'purpose': purpose,
      };
    } finally {
      _connectingEndpoints.remove(endpoint);
    }
  }

  void _revokeGrant(String grantId) {
    recordAuthentication(grantId, 'bridge_revoked');
    _grants.remove(grantId)?.close();
    _grantPurposes.remove(grantId);
    for (final id in _requestGrants.entries
        .where((entry) => entry.value == grantId)
        .map((entry) => entry.key)
        .toList()) {
      _requests.remove(id)?.close();
      _requestGrants.remove(id);
    }
    for (final id in _socketGrants.entries
        .where((entry) => entry.value == grantId)
        .map((entry) => entry.key)
        .toList()) {
      _sockets.remove(id)?.close();
      _socketGrants.remove(id);
      _socketTraces.remove(id);
      _authEventIds.remove(id);
    }
    _grantTraces.remove(grantId);
  }

  void _disconnect() {
    for (final trace in _socketTraces.values) {
      _diagnose(_diagnosticTab, trace, 'bridge_revoked');
    }
    _epoch++;
    for (final t in _grants.values) {
      t.close();
    }
    _grants.clear();
    _grantPurposes.clear();
    _connectingEndpoints.clear();
    for (final s in _saves.values) {
      unawaited(s.cancel().catchError((Object _) {}));
    }
    _saves.clear();
    _requests.clear();
    _requestGrants.clear();
    _sockets.clear();
    _socketGrants.clear();
    _socketTraces.clear();
    _grantTraces.clear();
    _authEventIds.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _disconnect();
    unawaited(reply('window.__wingmanGraspRevoke?.(${jsonEncode(_token)})')
        .catchError((Object _) {}));
  }
}
