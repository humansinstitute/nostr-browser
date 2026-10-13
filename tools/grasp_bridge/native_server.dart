// Isolated validation adapter. Never imported by the product. This listener carries
// test RPC only; production transport has no HTTP listener or signing proxy.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../app/lib/src/core/grasp_fips_transport.dart';
import '../../app/lib/src/core/tower_fips_proxy.dart';
import '../../app/lib/src/features/browser/grasp_fips_browser_bridge.dart';

Future<void> main(List<String> args) async {
  final origin = args[0];
  final endpoint = args[1];
  final fixture = args.contains('--fixture');
  HttpServer? service;
  if (fixture) {
    service = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    service.listen((r) async {
      if (WebSocketTransformer.isUpgradeRequest(r)) {
        final ws = await WebSocketTransformer.upgrade(r);
        ws.add('["AUTH","fixture-challenge"]');
        ws.listen(ws.add);
        return;
      }
      if (r.uri.path == '/hang') return;
      if (r.uri.path == '/redirect') {
        r.response.statusCode = 302;
        r.response.headers.set('location', 'https://example.invalid');
      } else if (r.uri.path == '/echo') {
        r.response.statusCode = 201;
        r.response.headers.contentType = ContentType.binary;
        await r.response.addStream(r);
      } else {
        r.response.headers.contentType = ContentType.json;
        r.response.write('{"supported_grasps":["GRASP-08"]}');
      }
      await r.response.close();
    });
  }
  final rpc = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final route = TowerFipsProxy.capability();
  final replies = <String, Completer<String>>{};
  final bridge = GraspFipsBrowserBridge(
    pageOrigin: origin,
    approve: (candidate) async => candidate == endpoint,
    prepare: (_) async => null,
    transportFactory: fixture
        ? (endpoint) => GraspFipsTransport(
            endpoint,
            clientFactory: () => HttpClient()
              ..connectionFactory = (_, __, ___) => Socket.startConnect(
                InternetAddress.loopbackIPv4,
                service!.port,
              ),
          )
        : null,
    reply: (script) async {
      if (!script.contains('Reply')) return;
      final values =
          jsonDecode(
                '[${script.substring(script.indexOf('(') + 1, script.length - 1)}]',
              )
              as List;
      replies.remove(values[1])?.complete(script);
    },
  );
  rpc.listen((r) async {
    if (r.headers.value('host') != '127.0.0.1:${rpc.port}' ||
        r.headers.value('origin') != null ||
        !r.uri.path.startsWith('/$route/')) {
      r.response.statusCode = 403;
      await r.response.close();
      return;
    }
    if (r.uri.path == '/$route/script') {
      r.response.write(bridge.script);
      await r.response.close();
      return;
    }
    final message = await utf8.decoder.bind(r).join();
    final value = jsonDecode(message) as Map;
    final id = value['id'] as String;
    final completer = Completer<String>();
    replies[id] = completer;
    unawaited(bridge.receive(message));
    try {
      r.response.write(
        await completer.future.timeout(const Duration(seconds: 40)),
      );
    } catch (_) {
      r.response.statusCode = 500;
    }
    await r.response.close();
  });
  stdout.writeln('http://127.0.0.1:${rpc.port}/$route');
}
