import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'flight_deck_update_models.dart';

class LocalFlightDeckServer {
  LocalFlightDeckServer._(this._server, this._assetKeys, this._updates) {
    _server.listen(_serve);
  }

  static const host = '127.0.0.1';
  static const port = 47831;
  static const origin = 'http://$host:$port';
  static const _assetPrefix = 'assets/flightdeck/';

  final HttpServer _server;
  final Set<String> _assetKeys;
  final FlightDeckUpdateController? _updates;

  static Future<LocalFlightDeckServer> start({
    FlightDeckUpdateController? updates,
  }) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assetKeys = manifest
        .listAssets()
        .where((key) => key.startsWith(_assetPrefix))
        .toSet();
    if (!assetKeys.contains('${_assetPrefix}index.html')) {
      throw StateError('The packaged Flight Deck bundle is missing index.html');
    }
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
      shared: true,
    );
    return LocalFlightDeckServer._(server, assetKeys, updates);
  }

  String get url => '$origin/';

  Future<void> _serve(HttpRequest request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    final relativePath = _safeRelativePath(request.uri.path);
    if (relativePath == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final downloadedRoot = _updates?.activeRootPath;
    if (downloadedRoot != null) {
      final served =
          await _serveDownloaded(request, downloadedRoot, relativePath);
      if (served) return;
    }
    await _servePackaged(request, relativePath);
  }

  Future<bool> _serveDownloaded(
    HttpRequest request,
    String root,
    String relativePath,
  ) async {
    final selected = await selectDownloadedFlightDeckFile(root, relativePath);
    if (selected == null) {
      if (relativePath == 'index.html' || !_hasFileExtension(relativePath)) {
        await _updates?.reportServeFailure(
          'The active downloaded Flight Deck is missing its entry point.',
        );
        return false;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return true;
    }
    try {
      final length = await selected.length();
      request.response.headers
        ..contentType = _contentType(selected.path)
        ..set(HttpHeaders.cacheControlHeader, _cacheControl(selected.path))
        ..set('X-Content-Type-Options', 'nosniff');
      request.response.contentLength = length;
      if (request.method == 'GET') {
        await request.response.addStream(selected.openRead());
      }
      await request.response.close();
      return true;
    } catch (_) {
      await _updates?.reportServeFailure(
        'The active downloaded Flight Deck could not be served.',
      );
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
      return true;
    }
  }

  Future<void> _servePackaged(HttpRequest request, String relativePath) async {
    var assetKey = '$_assetPrefix$relativePath';
    if (!_assetKeys.contains(assetKey) && !_hasFileExtension(relativePath)) {
      assetKey = '${_assetPrefix}index.html';
    }
    if (!_assetKeys.contains(assetKey)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    try {
      final data = await rootBundle.load(assetKey);
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      request.response.headers
        ..contentType = _contentType(assetKey)
        ..set(HttpHeaders.cacheControlHeader, _cacheControl(assetKey))
        ..set('X-Content-Type-Options', 'nosniff');
      request.response.contentLength = bytes.length;
      if (request.method == 'GET') {
        request.response.add(Uint8List.fromList(bytes));
      }
    } catch (_) {
      request.response.statusCode = HttpStatus.internalServerError;
    }
    await request.response.close();
  }

  static String? _safeRelativePath(String requestPath) {
    final raw = requestPath == '/' ? 'index.html' : requestPath.substring(1);
    if (raw.isEmpty || raw.contains('\\') || raw.contains('\u0000')) {
      return null;
    }
    final segments = raw.split('/');
    if (segments.any(
        (segment) => segment.isEmpty || segment == '.' || segment == '..')) {
      return null;
    }
    return segments.join('/');
  }

  static bool _hasFileExtension(String path) {
    final lastSegment = path.split('/').last;
    return lastSegment.contains('.');
  }

  static ContentType _contentType(String path) {
    final extension = path.split('.').last.toLowerCase();
    return switch (extension) {
      'html' => ContentType.html,
      'js' || 'mjs' => ContentType('text', 'javascript', charset: 'utf-8'),
      'css' => ContentType('text', 'css', charset: 'utf-8'),
      'json' || 'webmanifest' => ContentType.json,
      'png' => ContentType('image', 'png'),
      'svg' => ContentType('image', 'svg+xml'),
      'ico' => ContentType('image', 'x-icon'),
      'txt' || 'md' => ContentType.text,
      'woff' => ContentType('font', 'woff'),
      'woff2' => ContentType('font', 'woff2'),
      _ => ContentType.binary,
    };
  }

  static String _cacheControl(String path) {
    if (path.contains('/assets/')) return 'public, max-age=31536000, immutable';
    return 'no-cache';
  }
}

Future<File?> selectDownloadedFlightDeckFile(
  String rootPath,
  String relativePath,
) async {
  final root = Directory(rootPath).absolute.path;
  String candidatePath(String path) => File('$root/$path').absolute.path;
  bool isDescendant(String path) =>
      path.startsWith('$root${Platform.pathSeparator}');

  var candidate = candidatePath(relativePath);
  if (!isDescendant(candidate)) return null;
  var type = await FileSystemEntity.type(candidate, followLinks: false);
  if (type == FileSystemEntityType.notFound &&
      !LocalFlightDeckServer._hasFileExtension(relativePath)) {
    candidate = candidatePath('index.html');
    type = await FileSystemEntity.type(candidate, followLinks: false);
  }
  if (type != FileSystemEntityType.file || !isDescendant(candidate)) {
    return null;
  }
  return File(candidate);
}
