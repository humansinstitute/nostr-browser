import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import 'tower_fips_proxy.dart';

/// An explicitly approved mesh node + port. No DNS, proxy listener, redirect,
/// cookies, service identity lookup, or signing authority is involved.
class GraspFipsTransport {
  GraspFipsTransport(this.endpoint, {this.clientFactory}) {
    TowerFipsProxy.validateEndpoint(endpoint);
  }
  final String endpoint;
  final HttpClient Function()? clientFactory;
  final Set<HttpClient> _clients = {};
  final Set<GraspHttpRequest> _requests = {};
  final Set<GraspSocket> _sockets = {};
  bool _closed = false;

  bool accepts(String value, {bool websocket = false}) {
    final uri = Uri.tryParse(value);
    final base = Uri.parse(endpoint);
    return uri != null &&
        uri.scheme == (websocket ? 'ws' : 'http') &&
        uri.host == base.host &&
        uri.port == base.port &&
        uri.hasPort &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment &&
        value.startsWith(
            '${websocket ? endpoint.replaceFirst('http:', 'ws:') : endpoint}/') &&
        !RegExp(r'[\\\x00-\x20\x7f]').hasMatch(value);
  }

  HttpClient _client() {
    if (_closed) throw StateError('Transport revoked.');
    final client = clientFactory?.call() ?? HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 15);
    if (clientFactory == null) {
      client.connectionFactory = (uri, host, port) {
        if (uri.host != Uri.parse(endpoint).host ||
            uri.port != Uri.parse(endpoint).port ||
            host != null ||
            port != null) {
          throw const SocketException('Unapproved target.');
        }
        return Socket.startConnect(
            TowerFipsProxy.meshAddress(endpoint), uri.port);
      };
    }
    _clients.add(client);
    return client;
  }

  Future<GraspHttpRequest> open(
      String url, String method, Map<String, dynamic> headers) async {
    if (!accepts(url) ||
        !{'GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE'}.contains(method)) {
      throw const FormatException('Unapproved FIPS request.');
    }
    final client = _client();
    try {
      final request = await client
          .openUrl(method, Uri.parse(url))
          .timeout(const Duration(seconds: 15), onTimeout: () {
        client.close(force: true);
        throw TimeoutException('Open timed out.');
      });
      if (_closed) throw StateError('Transport revoked.');
      request.followRedirects = false;
      for (final entry in headers.entries) {
        if (!{
          'accept',
          'authorization',
          'content-type',
          'git-protocol',
          'range',
          'if-range',
          'if-match',
          'if-none-match',
          'if-modified-since',
          'if-unmodified-since',
          'last-event-id',
          'x-flightdeck-pg-app-npub',
          'x-request-id'
        }.contains(entry.key.toLowerCase())) {
          continue;
        }
        request.headers.set(entry.key, entry.value.toString());
      }
      late final GraspHttpRequest result;
      result = GraspHttpRequest(client, request, () {
        _clients.remove(client);
        _requests.remove(result);
      });
      _requests.add(result);
      return result;
    } catch (_) {
      _clients.remove(client);
      client.close(force: true);
      rethrow;
    }
  }

  Future<GraspSocket> socket(String url) async {
    if (!accepts(url, websocket: true)) {
      throw const FormatException('Unapproved relay.');
    }
    final client = _client();
    try {
      // WebSocket.connect may follow redirects internally. Pin every connection
      // AND reject any redirect response before the library can follow it.
      final request = await client
          .getUrl(Uri.parse(url.replaceFirst('ws:', 'http:')))
          .timeout(const Duration(seconds: 10), onTimeout: () {
        client.close(force: true);
        throw TimeoutException('Relay open timed out.');
      });
      request.followRedirects = false;
      request.headers.set('connection', 'Upgrade');
      request.headers.set('upgrade', 'websocket');
      request.headers.set('sec-websocket-version', '13');
      final key = base64Encode(base64Url
          .decode('${TowerFipsProxy.capability()}=')
          .take(16)
          .toList());
      request.headers.set('sec-websocket-key', key);
      final response = await request
          .close()
          .timeout(const Duration(seconds: 10), onTimeout: () {
        client.close(force: true);
        throw TimeoutException('Relay upgrade timed out.');
      });
      if (_closed || response.statusCode != 101) {
        throw StateError('Relay upgrade failed.');
      }
      final expected = GraspSocket.acceptKey(key);
      if (response.headers.value('sec-websocket-accept') != expected ||
          response.headers.value('upgrade')?.toLowerCase() != 'websocket' ||
          !(response.headers.value('connection') ?? '')
              .toLowerCase()
              .split(',')
              .map((s) => s.trim())
              .contains('upgrade') ||
          response.headers.value('sec-websocket-extensions') != null ||
          response.headers.value('sec-websocket-protocol') != null) {
        throw StateError('Invalid relay upgrade.');
      }
      final raw = await response.detachSocket();
      if (_closed) {
        raw.destroy();
        throw StateError('Transport revoked.');
      }
      final ws = WebSocket.fromUpgradedSocket(raw, serverSide: false);
      late final GraspSocket result;
      result = GraspSocket(url, ws, raw, client, () {
        _sockets.remove(result);
        _clients.remove(client);
      });
      _sockets.add(result);
      return result;
    } catch (_) {
      _clients.remove(client);
      client.close(force: true);
      rethrow;
    }
  }

  bool hasChallenge(String url, String challenge) =>
      !_closed &&
      _sockets
          .any((s) => s.url == url && !s.closed && s.challenge == challenge);

  void close() {
    if (_closed) return;
    _closed = true;
    for (final request in _requests.toList()) {
      request.close();
    }
    for (final socket in _sockets.toList()) {
      socket.close();
    }
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }
}

class GraspHttpRequest {
  GraspHttpRequest(this._client, this._request, this._onClose);
  final void Function() _onClose;
  final HttpClient _client;
  final HttpClientRequest _request;
  StreamIterator<List<int>>? _body;
  bool _finishedUpload = false;
  bool _closed = false;
  bool _busy = false;
  List<int> _pending = [];
  int _offset = 0;

  Future<void> write(String chunk) async {
    if (_closed || _finishedUpload || _busy || chunk.length > 87384) {
      throw StateError('Invalid upload state.');
    }
    _busy = true;
    try {
      final bytes = base64Decode(chunk);
      if (bytes.length > 65536) throw StateError('Upload chunk too large.');
      _request.add(bytes);
      await _request.flush();
    } finally {
      _busy = false;
    }
  }

  Future<Map<String, dynamic>> finish() async {
    if (_closed || _finishedUpload || _busy) {
      throw StateError('Invalid request state.');
    }
    _finishedUpload = true;
    final response = await _request.close();
    if (_closed) throw StateError('Request cancelled.');
    if (response.isRedirect ||
        (response.statusCode >= 300 &&
            response.statusCode < 400 &&
            response.statusCode != 304)) {
      close();
      throw StateError('Redirects forbidden.');
    }
    _body = StreamIterator(response);
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      if ({
        'set-cookie',
        'set-cookie2',
        'connection',
        'transfer-encoding',
        'location'
      }.contains(name)) {
        return;
      }
      if (response.compressionState ==
              HttpClientResponseCompressionState.decompressed &&
          (name == 'content-encoding' || name == 'content-length')) {
        return;
      }
      headers[name] = values.join(', ');
    });
    return {
      'status': response.statusCode,
      'statusText': response.reasonPhrase,
      'headers': headers
    };
  }

  Future<Map<String, dynamic>> pull() async {
    if (_closed || _body == null || _busy) {
      throw StateError('Invalid stream state.');
    }
    _busy = true;
    try {
      if (_offset == _pending.length) {
        if (!await _body!.moveNext()) {
          close();
          return {'done': true};
        }
        _pending = _body!.current;
        _offset = 0;
      }
      final end = (_offset + 65536).clamp(0, _pending.length);
      final chunk = base64Encode(_pending.sublist(_offset, end));
      _offset = end;
      return {'done': false, 'chunk': chunk};
    } finally {
      _busy = false;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _onClose();
    _client.close(force: true);
    _request.abort();
    unawaited(_body?.cancel());
    _pending = [];
  }
}

class GraspSocket {
  GraspSocket(this.url, this._socket, this._raw, this._client, this._onClose)
      : _messages = StreamIterator(_socket);
  final String url;
  final WebSocket _socket;
  final Socket _raw;
  final HttpClient _client;
  final void Function() _onClose;
  final StreamIterator<dynamic> _messages;
  bool closed = false;
  bool _reading = false;
  String? challenge;
  static String acceptKey(String key) => base64Encode(sha1
      .convert(utf8.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
      .bytes);

  Future<Map<String, dynamic>> next() async {
    if (closed || _reading) throw StateError('Relay closed or reading.');
    _reading = true;
    try {
      if (!await _messages.moveNext()) {
        final result = {
          'done': true,
          'code': _socket.closeCode ?? 1006,
          'reason': _socket.closeReason ?? ''
        };
        close();
        return result;
      }
      final data = _messages.current;
      final bytes = data is String ? utf8.encode(data) : data as List<int>;
      if (bytes.length > 1024 * 1024) {
        throw StateError('Relay frame too large.');
      }
      if (data is String) {
        try {
          final frame = jsonDecode(data);
          if (frame is List &&
              frame.length == 2 &&
              frame[0] == 'AUTH' &&
              frame[1] is String &&
              (frame[1] as String).length <= 4096) {
            challenge = frame[1] as String;
          }
        } catch (_) {}
      }
      return {
        'done': false,
        'text': data is String,
        'data': data is String ? data : base64Encode(bytes)
      };
    } catch (_) {
      close();
      rethrow;
    } finally {
      _reading = false;
    }
  }

  int _sendingBytes = 0;
  Future<void> _sendTail = Future<void>.value();
  Future<void> send(String data, bool text) async {
    if (closed || data.length > 1398104) {
      throw StateError('Relay closed or frame too large.');
    }
    final bytes = text ? utf8.encode(data) : base64Decode(data);
    if (bytes.length > 1024 * 1024) throw StateError('Relay frame too large.');
    if (_sendingBytes + bytes.length > 4 * 1024 * 1024) {
      throw StateError('Relay queue full.');
    }
    _sendingBytes += bytes.length;
    final previous = _sendTail;
    final sent = Completer<void>();
    _sendTail = sent.future;
    try {
      await previous;
      if (closed) throw StateError('Relay closed.');
      await _socket
          .addStream(Stream<dynamic>.value(text ? data : bytes))
          .timeout(const Duration(seconds: 15), onTimeout: () {
        close();
        throw TimeoutException('Relay send timed out.');
      });
    } finally {
      _sendingBytes -= bytes.length;
      sent.complete();
    }
  }

  void close([int code = 1000, String reason = '']) {
    if (closed) return;
    closed = true;
    challenge = null;
    _onClose();
    try {
      // StreamSink.close can throw synchronously while addStream is bound.
      unawaited(_socket.close(code, reason).catchError((Object _) {}));
    } catch (_) {
      // Revocation must still destroy the detached socket during a blocked send.
    } finally {
      unawaited(_messages.cancel());
      _raw.destroy();
      _client.close(force: true);
    }
  }
}
