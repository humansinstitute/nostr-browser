import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/packaged_nstack_shell.dart';

void main() {
  late Map<String, Uint8List> files;
  late String pin;
  void fixture({String path = 'index.html'}) {
    files = {path: Uint8List.fromList(utf8.encode('<html>known</html>'))};
    final m = {
      'schemaVersion': 1,
      'id': 'nstack',
      'sourceRevision': 'a' * 40,
      'entrypoint': 'index.html',
      'files': {
        path: {
          'sha256': sha256.convert(files[path]!).toString(),
          'contentType': 'text/html'
        }
      }
    };
    files['manifest.json'] = Uint8List.fromList(utf8.encode(jsonEncode(m)));
    pin = sha256.convert(files['manifest.json']!).toString();
  }

  Future<PackagedNStackShell> load() => PackagedNStackShell.load(
      manifestSha256: pin, read: (p) async => files[p]!);
  setUp(fixture);
  test('manifest and assets pinned; traversal fails closed', () async {
    pin = '0' * 64;
    await expectLater(load(), throwsFormatException);
    fixture();
    files['index.html'] = Uint8List(0);
    await expectLater(load(), throwsFormatException);
    for (final path in [
      '../index.html',
      '/index.html',
      'a//b',
      'a/./b',
      'a%2fb',
      'a\\b'
    ]) {
      fixture(path: path);
      await expectLater(load(), throwsFormatException);
    }
  });
  test(
      'live loopback Host Origin capability method navigation and revocation boundaries',
      () async {
    final shell = await load();
    final uri = await shell.start();
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await shell.close();
    });
    Future<int> request(Uri u,
        {String method = 'GET',
        String? host,
        String? origin,
        String? site}) async {
      final r = await client.openUrl(method, u);
      if (host != null) r.headers.set('Host', host);
      if (origin != null) r.headers.set('Origin', origin);
      if (site != null) r.headers.set('Sec-Fetch-Site', site);
      final res = await r.close();
      final status = res.statusCode;
      await res.drain<void>();
      return status;
    }

    expect(await request(uri), 200);
    final policyResponse = await client.getUrl(uri).then((r) => r.close());
    final csp = policyResponse.headers.value('content-security-policy')!;
    expect(csp, contains('connect-src https:;'));
    expect(csp, isNot(contains('connect-src http:')));
    expect(csp, contains("script-src 'self';"));
    expect(csp, contains("worker-src 'none';"));
    await policyResponse.drain<void>();
    expect(await request(uri, host: 'attacker.example'), 403);
    expect(await request(uri, origin: 'https://attacker.example'), 403);
    expect(await request(uri, origin: 'null'), 403);
    expect(await request(uri, method: 'POST'), 403);
    expect(await request(uri, site: 'cross-site'), 403);
    expect(await request(uri.resolve('missing.js')), 403);
    expect(await request(uri.replace(path: '/index.html')), 403);
    expect(await request(uri.replace(query: 'remote=https://attacker.example')),
        403);
    expect(await request(uri.resolve('../index.html')), 403);
    expect(
        await request(Uri.parse(uri
            .toString()
            .replaceFirst('index.html', '%252e%252e/index.html'))),
        403);
    expect(shell.approvesDocument('$uri#connect'), isTrue);
    expect(shell.allowsNavigation(uri.toString(), isMainFrame: false), isFalse);
    expect(
        shell.allowsNavigation('https://attacker.example', isMainFrame: true),
        isFalse);
    expect(shell.allowsNavigation(uri.toString(), isMainFrame: true), isTrue);
    expect(
        shell.approvesDocument('https://attacker.example/index.html'), isFalse);
    await shell.close();
    expect(shell.approvesDocument(uri.toString()), isFalse);
  });
}
