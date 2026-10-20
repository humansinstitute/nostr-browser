import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

const browserDownloadChannelName = 'wingman/browser_download';

enum BrowserDownloadSignal { directLink, htmlDownload, response }

class BrowserDownloadRequest {
  const BrowserDownloadRequest({
    required this.url,
    required this.signal,
    this.suggestedFilename,
    this.contentDisposition,
    this.mimeType,
    this.userAgent,
    this.authenticationHeaders = const {},
  });

  factory BrowserDownloadRequest.fromMap(Map<Object?, Object?> value) {
    final signalName = value['signal'] as String?;
    return BrowserDownloadRequest(
      url: value['url'] as String? ?? '',
      signal: BrowserDownloadSignal.values.firstWhere(
        (candidate) => candidate.name == signalName,
        orElse: () => BrowserDownloadSignal.response,
      ),
      suggestedFilename: value['suggestedFilename'] as String?,
      contentDisposition: value['contentDisposition'] as String?,
      mimeType: value['mimeType'] as String?,
      userAgent: value['userAgent'] as String?,
      authenticationHeaders: _safeAuthenticationHeaders(value['headers']),
    );
  }

  final String url;
  final BrowserDownloadSignal signal;
  final String? suggestedFilename;
  final String? contentDisposition;
  final String? mimeType;
  final String? userAgent;
  final Map<String, String> authenticationHeaders;

  static Map<String, String> _safeAuthenticationHeaders(Object? value) {
    if (value is! Map) return const {};
    final authorization = value.entries
        .where((entry) => entry.key.toString().toLowerCase() == 'authorization')
        .map((entry) => entry.value.toString())
        .firstOrNull;
    return authorization == null ? const {} : {'authorization': authorization};
  }
}

class BrowserDownloadPolicy {
  static const _fileExtensions = <String>{
    '7z',
    'apk',
    'avi',
    'bin',
    'bz2',
    'csv',
    'doc',
    'docx',
    'dmg',
    'epub',
    'gz',
    'ics',
    'iso',
    'json',
    'm4a',
    'mkv',
    'mov',
    'mp3',
    'mp4',
    'odp',
    'ods',
    'odt',
    'pdf',
    'pkg',
    'ppt',
    'pptx',
    'rar',
    'rtf',
    'tar',
    'tgz',
    'txt',
    'wav',
    'webm',
    'xls',
    'xlsx',
    'xml',
    'xz',
    'zip',
  };

  static bool isDirectFileUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    final segment = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final dot = segment.lastIndexOf('.');
    if (dot <= 0 || dot == segment.length - 1) return false;
    return _fileExtensions.contains(segment.substring(dot + 1).toLowerCase());
  }

  static bool isDownloadResponse({
    String? contentDisposition,
    String? mimeType,
    bool canShowMimeType = true,
  }) {
    if (!canShowMimeType) return true;
    final disposition = contentDisposition?.toLowerCase() ?? '';
    if (disposition.split(';').first.trim() == 'attachment') return true;
    final mime = (mimeType ?? '').split(';').first.trim().toLowerCase();
    return mime == 'application/octet-stream' ||
        mime == 'application/zip' ||
        mime == 'application/x-7z-compressed' ||
        mime == 'application/x-rar-compressed';
  }
}

class BrowserDownloadFilename {
  static String select({
    String? contentDisposition,
    String? suggestedFilename,
    required Uri url,
    String? mimeType,
  }) {
    final candidates = <String?>[
      _fromDisposition(contentDisposition),
      suggestedFilename,
      url.pathSegments.isEmpty
          ? null
          : Uri.decodeComponent(url.pathSegments.last),
    ];
    for (final candidate in candidates) {
      final safe = sanitize(candidate ?? '');
      if (safe.isNotEmpty) return safe;
    }
    return 'download${_extensionForMime(mimeType)}';
  }

  static String sanitize(String value) {
    var name = value
        .replaceAll('\\', '/')
        .split('/')
        .last
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .replaceAll(RegExp(r'[:*?"<>|]'), '_')
        .trim();
    name =
        name.replaceAll(RegExp(r'^\.+'), '').replaceAll(RegExp(r'[. ]+$'), '');
    if (name.isEmpty || name == '.' || name == '..') return '';
    if (name.length > 180) {
      final dot = name.lastIndexOf('.');
      final extension =
          dot > 0 && name.length - dot <= 16 ? name.substring(dot) : '';
      name = '${name.substring(0, 180 - extension.length)}$extension';
    }
    return name;
  }

  static String? _fromDisposition(String? value) {
    if (value == null) return null;
    final encoded = RegExp(r'''filename\*\s*=\s*(?:UTF-8'')?([^;]+)''',
            caseSensitive: false)
        .firstMatch(value)
        ?.group(1)
        ?.trim();
    if (encoded != null) {
      try {
        return Uri.decodeComponent(_unquote(encoded));
      } catch (_) {}
    }
    final plain = RegExp(r'''filename\s*=\s*("[^"]*"|'[^']*'|[^;]+)''',
            caseSensitive: false)
        .firstMatch(value)
        ?.group(1)
        ?.trim();
    return plain == null ? null : _unquote(plain);
  }

  static String _unquote(String value) {
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  static String _extensionForMime(String? value) =>
      switch (value?.split(';').first.trim()) {
        'application/pdf' => '.pdf',
        'application/zip' => '.zip',
        'text/plain' => '.txt',
        'text/csv' => '.csv',
        'application/json' => '.json',
        _ => '',
      };
}

class BrowserDownloadProgress {
  const BrowserDownloadProgress(this.received, this.total);
  final int received;
  final int? total;
  double? get fraction =>
      total == null || total! <= 0 ? null : received / total!;
}

class BrowserDownloadResult {
  const BrowserDownloadResult(
      {required this.filename, required this.destination});
  final String filename;
  final String destination;
}

class BrowserDownloadCancelled implements Exception {
  const BrowserDownloadCancelled();
}

abstract class BrowserDownloadExporter {
  Future<String> export(File file, String filename);
}

class PlatformBrowserDownloadExporter implements BrowserDownloadExporter {
  PlatformBrowserDownloadExporter([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(browserDownloadChannelName);
  final MethodChannel _channel;

  @override
  Future<String> export(File file, String filename) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('export', {
        'path': file.path,
        'filename': filename,
      });
      final outcome = result?['outcome'];
      if (outcome == 'cancelled') throw const BrowserDownloadCancelled();
      if (outcome != 'success') {
        throw StateError(
            result?['detail'] as String? ?? 'The file could not be saved.');
      }
      return result?['destination'] as String? ?? 'Downloads';
    } on MissingPluginException {
      final location = await getSaveLocation(suggestedName: filename);
      if (location == null) throw const BrowserDownloadCancelled();
      await file.copy(location.path);
      return location.path;
    }
  }
}

typedef BrowserCookieProvider = Future<List<WebViewCookie>> Function(Uri uri);
typedef BrowserDownloadProgressCallback = void Function(
    BrowserDownloadProgress progress);

class BrowserDownloadTransfer {
  BrowserDownloadTransfer({
    required BrowserCookieProvider cookiesFor,
    BrowserDownloadExporter? exporter,
    HttpClient Function()? clientFactory,
    Future<Directory> Function()? temporaryDirectory,
  })  : _cookiesFor = cookiesFor,
        _exporter = exporter ?? PlatformBrowserDownloadExporter(),
        _clientFactory = clientFactory ?? HttpClient.new,
        _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final BrowserCookieProvider _cookiesFor;
  final BrowserDownloadExporter _exporter;
  final HttpClient Function() _clientFactory;
  final Future<Directory> Function() _temporaryDirectory;
  bool _cancelled = false;
  HttpClient? _client;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<BrowserDownloadResult> start(
    BrowserDownloadRequest request, {
    BrowserDownloadProgressCallback? onProgress,
  }) async {
    var uri = Uri.parse(request.url);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException('Only HTTP(S) files can be downloaded.');
    }
    final client = _client = _clientFactory();
    final authenticationOrigin = uri.origin;
    File? partial;
    try {
      HttpClientResponse? response;
      for (var redirects = 0; redirects <= 10; redirects++) {
        _checkCancelled();
        final httpRequest = await client.getUrl(uri);
        httpRequest.followRedirects = false;
        httpRequest.headers.set(HttpHeaders.acceptHeader, '*/*');
        if (uri.origin == authenticationOrigin) {
          for (final header in request.authenticationHeaders.entries) {
            httpRequest.headers.set(header.key, header.value);
          }
        }
        final agent = request.userAgent?.trim();
        if (agent != null && agent.isNotEmpty) {
          httpRequest.headers.set(HttpHeaders.userAgentHeader, agent);
        }
        final cookies = await _cookiesFor(uri);
        for (final cookie in cookies) {
          if (_cookieApplies(cookie, uri)) {
            httpRequest.cookies.add(Cookie(cookie.name, cookie.value));
          }
        }
        response = await httpRequest.close();
        if (!response.isRedirect) break;
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) {
          throw const HttpException('Redirect had no location.');
        }
        uri = uri.resolve(location);
        if (uri.scheme != 'http' && uri.scheme != 'https') {
          throw const HttpException('Download redirect was rejected.');
        }
        response = null;
      }
      if (response == null) {
        throw const HttpException('Too many download redirects.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw HttpException('Download returned HTTP ${response.statusCode}.');
      }
      final filename = BrowserDownloadFilename.select(
        contentDisposition: response.headers.value('content-disposition') ??
            request.contentDisposition,
        suggestedFilename: request.suggestedFilename,
        url: uri,
        mimeType: response.headers.contentType?.mimeType ?? request.mimeType,
      );
      final directory = await _temporaryDirectory();
      await directory.create(recursive: true);
      partial = File(
          '${directory.path}/wmapp-download-${DateTime.now().microsecondsSinceEpoch}.part');
      final sink = partial.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          _checkCancelled();
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(BrowserDownloadProgress(
            received,
            response.contentLength >= 0 ? response.contentLength : null,
          ));
        }
        await sink.close();
      } catch (_) {
        await sink.close();
        rethrow;
      }
      _checkCancelled();
      final destination = await _exporter.export(partial, filename);
      return BrowserDownloadResult(
          filename: filename, destination: destination);
    } finally {
      client.close(force: true);
      if (partial != null && await partial.exists()) await partial.delete();
    }
  }

  void _checkCancelled() {
    if (_cancelled) throw const BrowserDownloadCancelled();
  }

  static bool _cookieApplies(WebViewCookie cookie, Uri uri) {
    var domain = cookie.domain.toLowerCase();
    if (domain.startsWith('.')) domain = domain.substring(1);
    final host = uri.host.toLowerCase();
    if (host != domain && !host.endsWith('.$domain')) return false;
    final path = cookie.path.isEmpty ? '/' : cookie.path;
    return uri.path.isEmpty ? path == '/' : uri.path.startsWith(path);
  }
}

class BrowserDownloadCoordinator {
  BrowserDownloadCoordinator({
    required WebViewCookieManager cookieManager,
    required this.onStarted,
    required this.onProgress,
    required this.onCompleted,
    required this.onCancelled,
    required this.onFailed,
    BrowserDownloadExporter? exporter,
    MethodChannel? channel,
  })  : _cookieManager = cookieManager,
        _exporter = exporter,
        _channel = channel ?? const MethodChannel(browserDownloadChannelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  final WebViewCookieManager _cookieManager;
  final BrowserDownloadExporter? _exporter;
  final MethodChannel _channel;
  final void Function(String filename) onStarted;
  final void Function(String filename, BrowserDownloadProgress progress)
      onProgress;
  final void Function(BrowserDownloadResult result) onCompleted;
  final void Function(String filename) onCancelled;
  final void Function(String filename, Object error) onFailed;
  final Map<int, BrowserDownloadTransfer> _active = {};
  int _nextId = 1;
  bool _disposed = false;

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'request' || _disposed) return false;
    final value = Map<Object?, Object?>.from(call.arguments as Map);
    return start(BrowserDownloadRequest.fromMap(value));
  }

  Future<bool> start(BrowserDownloadRequest request) async {
    final uri = Uri.tryParse(request.url);
    if (_disposed ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    final provisional = BrowserDownloadFilename.select(
      contentDisposition: request.contentDisposition,
      suggestedFilename: request.suggestedFilename,
      url: uri,
      mimeType: request.mimeType,
    );
    final id = _nextId++;
    final transfer = BrowserDownloadTransfer(
      cookiesFor: (uri) => _cookieManager.getCookies(domain: uri),
      exporter: _exporter,
    );
    _active[id] = transfer;
    onStarted(provisional);
    unawaited(transfer
        .start(request, onProgress: (progress) {
          if (_active[id] == transfer) onProgress(provisional, progress);
        })
        .then(onCompleted)
        .onError((Object error, StackTrace stack) {
          if (error is BrowserDownloadCancelled) {
            onCancelled(provisional);
          } else {
            onFailed(provisional, error);
          }
        })
        .whenComplete(() => _active.remove(id)));
    return true;
  }

  Future<bool> installAndroid(int webViewIdentifier) async {
    if (_disposed || !Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('install', {
          'webViewIdentifier': webViewIdentifier,
        }) ??
        false;
  }

  void cancelAll() {
    for (final transfer in _active.values) {
      transfer.cancel();
    }
  }

  void dispose() {
    _disposed = true;
    cancelAll();
    _channel.setMethodCallHandler(null);
  }
}
