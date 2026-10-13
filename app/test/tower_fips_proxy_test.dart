import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/tower_fips_proxy.dart';
import 'package:wingman_app/src/core/tower_fips_native_request.dart';

const endpoint =
    'http://npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98.fips:8787';
const origin = 'https://flightdeck.example';
void main() {
  late HttpServer tower;
  late TowerFipsProxy proxy;
  late HttpClient browser;
  late StreamController<HttpRequest> arrivals;
  setUp(() async {
    tower = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    arrivals = StreamController<HttpRequest>();
    tower.listen(arrivals.add);
    proxy = await TowerFipsProxy.bind(
        endpoint: endpoint,
        pageOrigin: origin,
        clientFactory: () => HttpClient()
          ..connectionFactory = (url, host, port) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, tower.port));
    browser = HttpClient()..autoUncompress = false;
  });
  tearDown(() async {
    browser.close(force: true);
    await proxy.close();
    await tower.close(force: true);
    // An unlistened controller has no drain obligation.
    unawaited(arrivals.close());
  });
  Future<HttpClientResponse> fetch(String path,
      {String method = 'GET',
      String? requestingOrigin = origin,
      Map<String, String> headers = const {},
      List<int>? body}) async {
    final req =
        await browser.openUrl(method, Uri.parse('${proxy.proxyBaseUrl}$path'));
    req.followRedirects = false;
    if (requestingOrigin != null) req.headers.set('origin', requestingOrigin);
    headers.forEach(req.headers.set);
    if (body != null) req.add(body);
    return req.close();
  }

  test('exact origin rejects arbitrary and ambiguous targets', () {
    for (final bad in [
      'https://example.com',
      '$endpoint/',
      '$endpoint?x=1',
      '$endpoint#x',
      '$endpoint/path',
      'http://localhost:80',
      'http://user@${Uri.parse(endpoint).authority}',
      endpoint.toUpperCase()
    ]) {
      expect(() => TowerFipsProxy.validateEndpoint(bad), throwsFormatException);
    }
  });
  test(
      'real socket preserves path/query, auth, binary body and status; strips unsafe headers',
      () async {
    final observed = arrivals.stream.first;
    final bytes = List<int>.generate(180000, (i) => i % 256);
    final result = fetch('/api/files/a%2Fb?token=not-logged&x=%2F',
        method: 'POST',
        headers: {
          'authorization': 'Nostr exact-signed-event',
          'content-type': 'application/octet-stream',
          'cookie': 'secret=drop',
          'x-forwarded-host': 'evil.example',
          'forwarded': 'host=evil',
          'x-forwarded-proto': 'https',
          'connection': 'x-remove',
          'x-remove': 'drop'
        },
        body: bytes);
    final req = await observed;
    expect(req.method, 'POST');
    expect(req.uri.toString(), '/api/files/a%2Fb?token=not-logged&x=%2F');
    expect(req.headers.value('host'), Uri.parse(endpoint).authority);
    expect(req.headers.value('authorization'), 'Nostr exact-signed-event');
    for (final h in [
      'cookie',
      'origin',
      'forwarded',
      'x-forwarded-host',
      'x-forwarded-proto',
      'x-remove'
    ]) {
      expect(req.headers.value(h), isNull, reason: h);
    }
    expect(await req.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
        bytes);
    req.response.statusCode = 422;
    req.response.headers.set('content-type', 'application/octet-stream');
    req.response.headers
        .set('content-disposition', 'attachment; filename=data.bin');
    req.response.headers.set('set-cookie', 'must=drop');
    req.response.headers.set('access-control-allow-origin', '*');
    req.response.add(bytes);
    await req.response.close();
    final response = await result;
    expect(response.statusCode, 422);
    expect(response.headers.value('set-cookie'), isNull);
    expect(response.headers.value('access-control-allow-origin'), origin);
    expect(response.headers.value('access-control-expose-headers'),
        contains('Content-Disposition'));
    expect(
        await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
        bytes);
  });
  test(
      'rejects missing/null/foreign Origin, unknown route, Host and retargeting',
      () async {
    for (final badOrigin in [null, 'null', 'https://evil.example']) {
      expect(
          (await fetch('/api', requestingOrigin: badOrigin)).statusCode, 403);
    }
    expect((await fetch('/api', headers: {'host': 'evil.example'})).statusCode,
        403);
    expect((await fetch('//evil.example/api')).statusCode, 403);
    final req = await browser.getUrl(Uri.parse(
        'http://127.0.0.1:${Uri.parse(proxy.proxyBaseUrl).port}/unknown/api'));
    req.headers.set('origin', origin);
    expect((await req.close()).statusCode, 403);
    expect((await fetch('/api', method: 'CONNECT')).statusCode, 405);
  });
  test('preflight is origin/header/method restricted and permits PNA',
      () async {
    final result = await fetch('/api', method: 'OPTIONS', headers: {
      'access-control-request-method': 'POST',
      'access-control-request-headers':
          'authorization, content-type, x-flightdeck-pg-app-npub',
      'access-control-request-private-network': 'true'
    });
    expect(result.statusCode, 204);
    expect(result.headers.value('access-control-allow-origin'), origin);
    expect(
        result.headers.value('access-control-allow-private-network'), 'true');
    expect(
        (await fetch('/api', method: 'OPTIONS', headers: {
          'access-control-request-method': 'GET',
          'access-control-request-headers': 'x-forwarded-host'
        }))
            .statusCode,
        403);
  });
  test('forbids public, local and same-target redirects', () async {
    final requests = StreamIterator(arrivals.stream);
    for (final destination in [
      'https://public.example',
      'http://127.0.0.1:9',
      '$endpoint/other'
    ]) {
      final result = fetch('/redirect');
      await requests.moveNext();
      requests.current.response.statusCode = 302;
      requests.current.response.headers.set('location', destination);
      await requests.current.response.close();
      final response = await result;
      expect(response.statusCode, 502);
      expect(response.headers.value('location'), isNull);
      await response.drain<void>();
    }
    await requests.cancel();
  });
  test('failure returns CORS error without tokens or fallback', () async {
    await tower.close(force: true);
    final response = await fetch('/api?token=sensitive');
    expect(response.statusCode, 502);
    expect(response.headers.value('access-control-allow-origin'), origin);
    expect(await utf8.decoder.bind(response).join(),
        'Tower FIPS transport failed.');
  });
  test(
      'native SSE first chunk arrives before close and idle cancel closes raw upstream',
      () async {
    final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final disconnected = Completer<void>();
    raw.listen((socket) {
      var sent = false;
      socket.listen((bytes) {
        if (sent) return;
        sent = true;
        socket.add(utf8.encode(
            'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\nd\r\ndata: first\n\n\r\n'));
      }, onDone: () {
        if (!disconnected.isCompleted) disconnected.complete();
        socket.destroy();
      });
    });
    final streamProxy = await TowerFipsProxy.bind(
        endpoint: endpoint,
        pageOrigin: origin,
        clientFactory: () => HttpClient()
          ..connectionFactory = (url, host, port) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, raw.port));
    final request = await TowerFipsNativeRequest.open(
        streamProxy, '$endpoint/events?token=secret', 'GET', {});
    expect(
        (await request.finish().timeout(const Duration(seconds: 2)))['status'],
        200);
    expect(utf8.decode(base64Decode((await request.pull())['chunk'] as String)),
        'data: first\n\n');
    request.close();
    await disconnected.future.timeout(const Duration(seconds: 2));
    await streamProxy.close();
    await raw.close();
  });
  test('native adapter streams upload and binary response via real sockets',
      () async {
    final observed = arrivals.stream.first;
    final request = await TowerFipsNativeRequest.open(
        proxy, '$endpoint/storage', 'PUT', {
      'authorization': 'Nostr signed',
      'content-type': 'application/octet-stream'
    });
    await request.write(base64Encode([0, 1, 255]));
    final result = request.finish();
    final req = await observed;
    expect(await req.fold<List<int>>([], (a, b) => a..addAll(b)), [0, 1, 255]);
    req.response.statusCode = 201;
    req.response.add([255, 0, 3]);
    await req.response.close();
    expect((await result)['status'], 201);
    expect(
        base64Decode((await request.pull())['chunk'] as String), [255, 0, 3]);
    expect((await request.pull())['done'], true);
    request.close();
  });
}
