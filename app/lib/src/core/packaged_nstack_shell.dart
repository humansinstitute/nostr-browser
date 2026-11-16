import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// A catalogue pin is shipped with the application, never learned remotely.
class PackagedNStackShell {
  PackagedNStackShell._(this._assets, this.sourceRevision);
  final Map<String, (Uint8List, String)> _assets;
  final String sourceRevision;
  HttpServer? _server;
  String? _capability;
  Uri? get launchUri => _server == null
      ? null
      : Uri.parse('http://127.0.0.1:${_server!.port}/$_capability/index.html');
  String? get origin => launchUri?.origin;
  static bool validPath(String path) =>
      RegExp(r'^[a-zA-Z0-9_-][a-zA-Z0-9_./-]*$').hasMatch(path) &&
      path.split('/').every((s) => s.isNotEmpty && s != '.' && s != '..');

  static Future<PackagedNStackShell> load(
      {required String manifestSha256,
      required Future<Uint8List> Function(String) read}) async {
    final raw = await read('manifest.json');
    if (sha256.convert(raw).toString() != manifestSha256) {
      throw const FormatException('Packaged NStack manifest integrity failed.');
    }
    final manifest = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    if (manifest['schemaVersion'] != 1 ||
        manifest['id'] != 'nstack' ||
        manifest['entrypoint'] != 'index.html' ||
        !RegExp(r'^[a-f0-9]{40}$')
            .hasMatch(manifest['sourceRevision'] as String)) {
      throw const FormatException('Unsupported packaged NStack manifest.');
    }
    const types = {
      'text/html',
      'text/javascript',
      'application/javascript',
      'text/css',
      'image/png',
      'image/svg+xml',
      'image/jpeg',
      'image/webp',
      'font/woff2',
      'application/json',
      'font/ttf',
      'text/plain'
    };
    final assets = <String, (Uint8List, String)>{};
    final files = manifest['files'] as Map<String, dynamic>;
    if (files.isEmpty || files.length > 256) {
      throw const FormatException('Invalid packaged asset count.');
    }
    var total = 0;
    for (final entry in files.entries) {
      final metadata = entry.value as Map<String, dynamic>;
      final type = metadata['contentType'] as String;
      final mime = type.replaceFirst('; charset=utf-8', '');
      if (!validPath(entry.key) || !types.contains(mime)) {
        throw const FormatException('Invalid packaged asset path or type.');
      }
      final bytes = await read(entry.key);
      total += bytes.length;
      if (total > 32 * 1024 * 1024 ||
          sha256.convert(bytes).toString() != metadata['sha256']) {
        throw const FormatException('Packaged NStack asset integrity failed.');
      }
      assets[entry.key] = (Uint8List.fromList(bytes), type);
    }
    if (assets['index.html']?.$2.replaceFirst('; charset=utf-8', '') !=
        'text/html') {
      throw const FormatException('Missing packaged NStack entrypoint.');
    }
    return PackagedNStackShell._(assets, manifest['sourceRevision'] as String);
  }

  static Future<PackagedNStackShell> fromBundle(String pin) => load(
      manifestSha256: pin,
      read: (path) async {
        final data = await rootBundle.load('assets/nstack-shell/$path');
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      });
  bool ownsUrl(String value) {
    final uri = Uri.tryParse(value);
    return launchUri != null &&
        uri != null &&
        uri.hasAuthority &&
        uri.scheme == 'http' &&
        uri.origin == origin &&
        uri.userInfo.isEmpty &&
        uri.path.startsWith('/$_capability/') &&
        !uri.hasQuery &&
        validPath(uri.path.substring('/$_capability/'.length)) &&
        _assets.containsKey(uri.path.substring('/$_capability/'.length));
  }

  bool approvesDocument(String value) =>
      ownsUrl(value) && Uri.parse(value).path == launchUri!.path;
  bool allowsNavigation(String value, {required bool isMainFrame}) =>
      isMainFrame && approvesDocument(value);

  Future<Uri> start() async {
    if (_server != null) return launchUri!;
    final random = Random.secure();
    _capability =
        base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)))
            .replaceAll('=', '');
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_serve);
    return launchUri!;
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set('Cache-Control', 'no-store')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('Content-Security-Policy',
          "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src https:; frame-src 'none'; frame-ancestors 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'");
    final hosts = request.headers[HttpHeaders.hostHeader];
    final origins = request.headers['origin'];
    final fetchSites = request.headers['sec-fetch-site'];
    if (hosts?.length != 1 ||
        hosts!.single != '127.0.0.1:${_server?.port}' ||
        (origins != null &&
            (origins.length != 1 || origins.single != origin)) ||
        (fetchSites != null &&
            (fetchSites.length != 1 ||
                !const ['none', 'same-origin'].contains(fetchSites.single))) ||
        !['GET', 'HEAD'].contains(request.method) ||
        !ownsUrl('$origin${request.uri}') ||
        request.uri.toString().contains('%') ||
        request.uri.hasAuthority) {
      response.statusCode = HttpStatus.forbidden;
    } else {
      final asset =
          _assets[request.uri.path.substring('/$_capability/'.length)]!;
      response.headers.set(HttpHeaders.contentTypeHeader, asset.$2);
      response.contentLength = asset.$1.length;
      if (request.method == 'GET') response.add(asset.$1);
    }
    await response.close();
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    _capability = null;
    await server?.close(force: true);
  }
}
