import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:bech32/bech32.dart';
import 'package:crypto/crypto.dart';

import 'fips_app_target.dart';

/// A single approved page/mesh pairing. No caller-controlled upstream authority.
class TowerFipsProxy {
  TowerFipsProxy._(this.endpoint, this.pageOrigin, this._server, this._route,
      this._clientFactory) {
    _server.listen(_serve);
  }

  final String endpoint;
  final String pageOrigin;
  final HttpServer _server;
  final String _route;
  final HttpClient Function() _clientFactory;
  final Set<HttpClient> _clients = {};
  final Set<String> _nativeRequests = {};
  final Map<String, HttpClient> _nativeClients = {};
  String registerNativeRequest() {
    final id = capability();
    _nativeRequests.add(id);
    return id;
  }

  void cancelNativeRequest(String id) {
    _nativeRequests.remove(id);
    _nativeClients.remove(id)?.close(force: true);
  }

  bool _closed = false;
  String get proxyBaseUrl => 'http://127.0.0.1:${_server.port}/$_route';

  static String capability() => base64Url
      .encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');

  // FIPS v0.5 identity/address.rs: fd + first 15 bytes of SHA256(x-only npub).
  // Dial this pinned mesh address directly: no DNS rebinding or public resolver.
  static InternetAddress meshAddress(String endpoint) {
    final npub = FipsAppTarget.parse(endpoint).nodeNpub;
    final decoded = bech32.decode(npub);
    if (decoded.hrp != 'npub') {
      throw const FormatException('Invalid node npub.');
    }
    var bits = 0, accumulator = 0;
    final bytes = <int>[];
    for (final value in decoded.data) {
      accumulator = ((accumulator << 5) | value) & 65535;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        bytes.add((accumulator >> bits) & 255);
      }
    }
    if (bytes.length != 32 ||
        bits >= 5 ||
        (accumulator & ((1 << bits) - 1)) != 0) {
      throw const FormatException('Invalid node npub padding.');
    }
    return InternetAddress.fromRawAddress(
        Uint8List.fromList([0xfd, ...sha256.convert(bytes).bytes.take(15)]));
  }

  static void validateEndpoint(String endpoint) {
    final target = FipsAppTarget.parse(endpoint);
    try {
      meshAddress(endpoint);
    } catch (_) {
      throw const FormatException('Invalid node npub.');
    }
    if (endpoint != target.origin) {
      throw const FormatException('Use an exact FIPS HTTP origin with a port.');
    }
  }

  static Future<TowerFipsProxy> bind({
    required String endpoint,
    required String pageOrigin,
    // Dependency injection is native/test-only, never exposed to a page.
    HttpClient Function()? clientFactory,
  }) async {
    validateEndpoint(endpoint);
    final origin = Uri.tryParse(pageOrigin);
    if (origin == null ||
        origin.origin != pageOrigin ||
        !(origin.scheme == 'https' ||
            (origin.scheme == 'http' &&
                (origin.host == '127.0.0.1' || origin.host == 'localhost')))) {
      throw const FormatException('A trusted Flight Deck origin is required.');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return TowerFipsProxy._(
        endpoint,
        pageOrigin,
        server,
        capability(),
        clientFactory ??
            () => HttpClient()
              ..connectionFactory = (uri, host, port) {
                if (uri.origin != Uri.parse(endpoint).origin ||
                    host != null ||
                    port != null) {
                  throw const SocketException('Unpaired Tower target.');
                }
                return Socket.startConnect(
                    meshAddress(endpoint), Uri.parse(endpoint).port);
              });
  }

  static const _hop = {
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  };
  static const _allowedMethods = {
    'GET',
    'HEAD',
    'POST',
    'PUT',
    'PATCH',
    'DELETE'
  };
  static const _allowedHeaders = {
    'authorization',
    'content-type',
    'accept',
    'range',
    'if-range',
    'if-match',
    'if-none-match',
    'if-modified-since',
    'if-unmodified-since',
    'last-event-id',
    'x-flightdeck-pg-app-npub',
    'x-request-id',
  };

  void _cors(HttpResponse response) {
    response.headers.set('access-control-allow-origin', pageOrigin);
    response.headers.set('vary', 'Origin');
    response.headers.set(
        'access-control-expose-headers',
        'Content-Type, Content-Length, Content-Disposition, Content-Range, '
            'Accept-Ranges, ETag, Last-Modified, Retry-After, X-Request-Id');
  }

  Future<void> _serve(HttpRequest incoming) async {
    final response = incoming.response;
    HttpClient? client;
    final nativeId = incoming.headers.value('x-wm-native-request');
    try {
      final raw = incoming.uri.toString();
      final prefix = '/$_route';
      if ((nativeId != null && !_nativeRequests.contains(nativeId)) ||
          _closed ||
          incoming.headers.value('origin') != pageOrigin ||
          incoming.headers.value('host') != '127.0.0.1:${_server.port}' ||
          incoming.uri.hasScheme ||
          incoming.uri.hasAuthority ||
          !(raw.startsWith('$prefix/') ||
              raw == prefix ||
              raw.startsWith('$prefix?'))) {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      _cors(response);
      if (incoming.method == 'OPTIONS') {
        final method = incoming.headers.value('access-control-request-method');
        final headers =
            (incoming.headers.value('access-control-request-headers') ?? '')
                .split(',')
                .map((h) => h.trim().toLowerCase())
                .where((h) => h.isNotEmpty);
        if (!_allowedMethods.contains(method) ||
            headers.any((h) => !_allowedHeaders.contains(h))) {
          response.statusCode = HttpStatus.forbidden;
        } else {
          response.statusCode = HttpStatus.noContent;
          response.headers
              .set('access-control-allow-methods', _allowedMethods.join(', '));
          response.headers
              .set('access-control-allow-headers', _allowedHeaders.join(', '));
          if (incoming.headers
                  .value('access-control-request-private-network') ==
              'true') {
            response.headers
                .set('access-control-allow-private-network', 'true');
          }
        }
        await response.close();
        return;
      }
      if (!_allowedMethods.contains(incoming.method)) {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      var suffix = raw.substring(prefix.length);
      if (suffix.isEmpty || suffix.startsWith('?')) suffix = '/$suffix';
      // Concatenation, never resolve(): //host and absolute URLs cannot retarget.
      final target = Uri.parse('$endpoint$suffix');
      if (target.origin != Uri.parse(endpoint).origin ||
          target.hasFragment ||
          suffix.startsWith('//') ||
          suffix.contains('\\')) {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      client = _clientFactory();
      _clients.add(client);
      if (nativeId != null) _nativeClients[nativeId] = client;
      client.autoUncompress = false;
      client.findProxy = (_) => 'DIRECT';
      client.connectionTimeout = const Duration(seconds: 15);
      final activeClient = client;
      unawaited(response.done.then((_) => activeClient.close(force: true),
          onError: (_) => activeClient.close(force: true)));
      final upstream = await client.openUrl(incoming.method, target);
      upstream.followRedirects = false;
      final nominated = (incoming.headers.value('connection') ?? '')
          .split(',')
          .map((s) => s.trim().toLowerCase())
          .toSet();
      incoming.headers.forEach((name, values) {
        if (_hop.contains(name) ||
            nominated.contains(name) ||
            name == 'x-wm-native-request' ||
            name == 'host' ||
            name == 'origin' ||
            name == 'cookie' ||
            name == 'cookie2' ||
            name == 'forwarded' ||
            name == 'referer' ||
            name.startsWith('x-forwarded-') ||
            name.startsWith('forwarded-') ||
            name.startsWith('sec-') ||
            name.startsWith('access-control-')) {
          return;
        }
        upstream.headers.set(name, values);
      });
      upstream.headers.set('host', Uri.parse(endpoint).authority);
      await upstream.addStream(incoming);
      final result = await upstream.close();
      if (result.isRedirect ||
          (result.statusCode >= 300 &&
              result.statusCode < 400 &&
              result.statusCode != 304)) {
        response.statusCode = HttpStatus.badGateway;
        response.write('Tower FIPS redirects are forbidden.');
        await response.close();
        return;
      }
      response.statusCode = result.statusCode;
      final resultNominated = (result.headers.value('connection') ?? '')
          .split(',')
          .map((s) => s.trim().toLowerCase())
          .toSet();
      result.headers.forEach((name, values) {
        if (_hop.contains(name) ||
            resultNominated.contains(name) ||
            name == 'set-cookie' ||
            name == 'set-cookie2' ||
            name == 'location' ||
            name.startsWith('access-control-')) {
          return;
        }
        response.headers.set(name, values);
      });
      _cors(response);
      response.bufferOutput = false;
      await response.addStream(result);
      await response.close();
    } catch (_) {
      // Never emit upstream exceptions: they may contain token-bearing URLs.
      try {
        response.statusCode = HttpStatus.badGateway;
        response.write('Tower FIPS transport failed.');
        await response.close();
      } catch (_) {}
    } finally {
      client?.close(force: true);
      _clients.remove(client);
      if (nativeId != null) cancelNativeRequest(nativeId);
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
    _nativeClients.clear();
    _nativeRequests.clear();
    await _server.close(force: true);
  }
}
