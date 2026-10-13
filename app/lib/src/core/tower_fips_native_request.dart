import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tower_fips_proxy.dart';

/// Pull-driven page adapter over the same restricted socket proxy. Each request
/// owns its connection, so cancellation also interrupts an idle SSE response.
class TowerFipsNativeRequest {
  TowerFipsNativeRequest._(this._client, this._request, this._proxy, this._id);
  final TowerFipsProxy _proxy;
  final String _id;
  final HttpClient _client;
  final HttpClientRequest _request;
  StreamIterator<List<int>>? _body;
  bool _finishedUpload = false;
  bool _closed = false;
  bool _busy = false;
  List<int> _pending = [];
  int _offset = 0;

  static Future<TowerFipsNativeRequest> open(TowerFipsProxy proxy, String url,
      String method, Map<String, dynamic> headers) async {
    if (!url.startsWith('${proxy.endpoint}/') ||
        Uri.parse(url).origin != Uri.parse(proxy.endpoint).origin ||
        Uri.parse(url).hasFragment) {
      throw const FormatException('Request must target the paired Tower.');
    }
    final client = HttpClient();
    final nativeId = proxy.registerNativeRequest();
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client.openUrl(
          method,
          Uri.parse(
              '${proxy.proxyBaseUrl}${url.substring(proxy.endpoint.length)}'));
      request.followRedirects = false;
      headers.forEach((name, value) {
        final lower = name.toLowerCase();
        if (const {
          'origin',
          'host',
          'content-length',
          'transfer-encoding',
          'connection',
          'cookie',
          'cookie2',
          'expect'
        }.contains(lower)) {
          return;
        }
        request.headers.set(name, value.toString());
      });
      request.headers.set('origin', proxy.pageOrigin);
      request.headers.set('x-wm-native-request', nativeId);
      return TowerFipsNativeRequest._(client, request, proxy, nativeId);
    } catch (_) {
      proxy.cancelNativeRequest(nativeId);
      client.close(force: true);
      rethrow;
    }
  }

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
    _body = StreamIterator(response);
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
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
    _proxy.cancelNativeRequest(_id);
    _client.close(force: true);
    _request.abort();
    unawaited(_body?.cancel());
    _pending = [];
  }
}
