import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wingman_app/src/features/browser/browser_download.dart';

void main() {
  group('BrowserDownloadPolicy', () {
    test('detects ordinary HTTP(S) file links only', () {
      expect(
          BrowserDownloadPolicy.isDirectFileUrl(
              'https://example.test/a/report.PDF?q=1'),
          isTrue);
      expect(
          BrowserDownloadPolicy.isDirectFileUrl(
              'http://example.test/archive.zip'),
          isTrue);
      expect(BrowserDownloadPolicy.isDirectFileUrl('https://example.test/page'),
          isFalse);
      expect(BrowserDownloadPolicy.isDirectFileUrl('file:///tmp/report.pdf'),
          isFalse);
    });

    test('detects attachment, binary MIME and unshowable responses', () {
      expect(
          BrowserDownloadPolicy.isDownloadResponse(
              contentDisposition: 'attachment; filename=a.bin'),
          isTrue);
      expect(
          BrowserDownloadPolicy.isDownloadResponse(
              mimeType: 'application/octet-stream'),
          isTrue);
      expect(BrowserDownloadPolicy.isDownloadResponse(canShowMimeType: false),
          isTrue);
      expect(BrowserDownloadPolicy.isDownloadResponse(mimeType: 'text/html'),
          isFalse);
    });
  });

  group('BrowserDownloadFilename', () {
    test('prefers RFC 5987 server filename and removes traversal', () {
      expect(
        BrowserDownloadFilename.select(
          contentDisposition:
              "attachment; filename*=UTF-8''..%2F..%2Fquarterly%20report.pdf",
          suggestedFilename: 'ignored.bin',
          url: Uri.parse('https://example.test/fallback'),
        ),
        'quarterly report.pdf',
      );
    });

    test('sanitizes reserved characters and supplies a MIME fallback', () {
      expect(BrowserDownloadFilename.sanitize(r'..\evil:<name>?.txt'),
          'evil__name__.txt');
      expect(
        BrowserDownloadFilename.select(
          url: Uri.parse('https://example.test/'),
          mimeType: 'application/pdf',
        ),
        'download.pdf',
      );
    });
  });

  group('BrowserDownloadTransfer fixture', () {
    late HttpServer server;
    late Directory temporary;
    late _FakeExporter exporter;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('wmapp-download-test-');
      exporter = _FakeExporter();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        switch (request.uri.path) {
          case '/direct/report.pdf':
            request.response.headers.contentType =
                ContentType('application', 'pdf');
            request.response.add([1, 2, 3]);
          case '/attachment':
            request.response.headers.set(
                'content-disposition', 'attachment; filename="server.txt"');
            request.response.write('attachment');
          case '/duplicate':
            request.response.headers.set(
                'content-disposition', 'attachment; filename="server.txt"');
            request.response.write('duplicate');
          case '/failed':
            request.response.statusCode = 503;
            request.response.write('no');
          case '/auth':
            if (request.headers.value('authorization') != 'Bearer current') {
              request.response.statusCode = 401;
            }
            request.response.write('authenticated');
          case '/redirect-cross':
            request.response.statusCode = 302;
            request.response.headers.set(
              'location',
              'http://localhost:${server.port}/auth-cross',
            );
          case '/auth-cross':
            if (request.headers.value('authorization') != null) {
              request.response.statusCode = 400;
            }
            request.response.write('no leaked authorization');
          default:
            request.response.statusCode = 404;
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await temporary.delete(recursive: true);
    });

    BrowserDownloadTransfer transfer() => BrowserDownloadTransfer(
          cookiesFor: (_) async => const [
            WebViewCookie(
                name: 'session', value: 'active', domain: '127.0.0.1'),
          ],
          exporter: exporter,
          temporaryDirectory: () async => temporary,
        );

    String url(String path) => 'http://127.0.0.1:${server.port}$path';

    test('downloads direct and attachment responses with server filenames',
        () async {
      final direct = await transfer().start(BrowserDownloadRequest(
        url: url('/direct/report.pdf'),
        signal: BrowserDownloadSignal.directLink,
      ));
      final attachment = await transfer().start(BrowserDownloadRequest(
        url: url('/attachment'),
        signal: BrowserDownloadSignal.response,
      ));
      expect(direct.filename, 'report.pdf');
      expect(attachment.filename, 'server.txt');
      expect(exporter.payloads['report.pdf'], [1, 2, 3]);
      expect(exporter.payloads['server.txt'], 'attachment'.codeUnits);
    });

    test('reports collision-safe destination returned by platform exporter',
        () async {
      exporter.destinations['server.txt'] = 'Downloads/server (1).txt';
      final result = await transfer().start(BrowserDownloadRequest(
        url: url('/duplicate'),
        signal: BrowserDownloadSignal.htmlDownload,
      ));
      expect(result.destination, 'Downloads/server (1).txt');
    });

    test('surfaces failed responses and cancellation', () async {
      await expectLater(
        transfer().start(BrowserDownloadRequest(
          url: url('/failed'),
          signal: BrowserDownloadSignal.response,
        )),
        throwsA(isA<HttpException>()),
      );
      exporter.error = const BrowserDownloadCancelled();
      await expectLater(
        transfer().start(BrowserDownloadRequest(
          url: url('/attachment'),
          signal: BrowserDownloadSignal.response,
        )),
        throwsA(isA<BrowserDownloadCancelled>()),
      );
    });

    test('keeps authorization on the exact origin and strips it on redirect',
        () async {
      final authenticated = await transfer().start(BrowserDownloadRequest(
        url: url('/auth'),
        signal: BrowserDownloadSignal.htmlDownload,
        authenticationHeaders: const {'authorization': 'Bearer current'},
      ));
      final redirected = await transfer().start(BrowserDownloadRequest(
        url: url('/redirect-cross'),
        signal: BrowserDownloadSignal.response,
        authenticationHeaders: const {'authorization': 'Bearer current'},
      ));
      expect(
          exporter.payloads[authenticated.filename], 'authenticated'.codeUnits);
      expect(
        exporter.payloads[redirected.filename],
        'no leaked authorization'.codeUnits,
      );
    });
  });

  test('native signal map preserves HTML download channel contract', () {
    final request = BrowserDownloadRequest.fromMap({
      'url': 'https://example.test/file',
      'signal': 'htmlDownload',
      'suggestedFilename': 'from-link.txt',
      'mimeType': 'text/plain',
      'headers': {
        'Authorization': 'Bearer current',
        'Cookie': 'must-not-cross-channel=yes',
      },
    });
    expect(request.signal, BrowserDownloadSignal.htmlDownload);
    expect(request.suggestedFilename, 'from-link.txt');
    expect(request.authenticationHeaders, {'authorization': 'Bearer current'});
  });
}

class _FakeExporter implements BrowserDownloadExporter {
  final payloads = <String, List<int>>{};
  final destinations = <String, String>{};
  Object? error;

  @override
  Future<String> export(File file, String filename) async {
    if (error case final Object value) throw value;
    payloads[filename] = await file.readAsBytes();
    return destinations[filename] ?? 'Downloads/$filename';
  }
}
