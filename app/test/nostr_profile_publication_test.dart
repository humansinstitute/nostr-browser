import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bip340/bip340.dart' as bip340;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/features/browser/nostr_profile_publisher.dart';
import 'package:wingman_app/src/features/browser/nostr_profile_relay_client.dart';
import 'package:wingman_app/src/features/browser/nostr_profile_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final identity = NostrCrypto.importIdentity('1'.padLeft(64, '0'));
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  Future<String> relay(
      void Function(WebSocket, Map<String, dynamic>) onEvent) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((message) {
        final frame = jsonDecode(message as String) as List;
        if (frame[0] == 'EVENT') {
          onEvent(socket, frame[1] as Map<String, dynamic>);
        }
      });
    });
    addTearDown(() async {
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    return 'ws://127.0.0.1:${server.port}';
  }

  test('success permits only newer remote profiles across restarts', () async {
    final url = await relay((socket, event) {
      socket.add(jsonEncode(['OK', event['id'], true]));
    });
    await NostrProfilePublisher(
            store: NostrProfileStore(),
            relays: NostrProfileRelayClient(relays: [url]),
            clock: () => DateTime.fromMillisecondsSinceEpoch(100000))
        .publish(
            npub: identity.npub,
            secret: identity.nsec,
            profile: const NostrProfile(name: 'published'));
    for (final timestamp in [99, 100]) {
      expect(
          (await NostrProfileStore().saveRemote(
                  identity.npub, const NostrProfile(name: 'stale'),
                  createdAt: timestamp))
              .name,
          'published');
    }
    expect(
        (await NostrProfileStore().saveRemote(
                identity.npub, const NostrProfile(name: 'newer'),
                createdAt: 101))
            .name,
        'newer');
    expect(
        (await NostrProfileStore().saveRemote(
                identity.npub, const NostrProfile(name: 'older'),
                createdAt: 100))
            .name,
        'newer');
  });

  test('unsent cleared draft survives a newer remote event after restart',
      () async {
    await NostrProfileStore().saveRemote(
        identity.npub, const NostrProfile(name: 'remote'),
        createdAt: 100);
    await NostrProfileStore().save(identity.npub, const NostrProfile());
    expect(
        (await NostrProfileStore().saveRemote(
                identity.npub, const NostrProfile(name: 'new remote'),
                createdAt: 200))
            .name,
        '');
  });

  test('stale relay acknowledgement cannot clear a newer identical draft',
      () async {
    final received = Completer<void>();
    late WebSocket connection;
    late String eventId;
    final url = await relay((socket, event) {
      connection = socket;
      eventId = event['id'] as String;
      received.complete();
    });
    const profile = NostrProfile(name: 'same content');
    final pending = NostrProfilePublisher(
            store: NostrProfileStore(),
            relays: NostrProfileRelayClient(relays: [url]),
            clock: () => DateTime.fromMillisecondsSinceEpoch(100000))
        .publish(npub: identity.npub, secret: identity.nsec, profile: profile);
    await received.future;
    await NostrProfileStore().save(identity.npub, profile);
    connection.add(jsonEncode(['OK', eventId, true]));
    expect((await pending).published, isTrue);
    expect(
        (await NostrProfileStore().saveRemote(
                identity.npub, const NostrProfile(name: 'new remote'),
                createdAt: 200))
            .name,
        'same content');
  });

  test('same-second concurrent publishes and restart use increasing timestamps',
      () async {
    final events = <int>[];
    final url = await relay((socket, event) {
      events.add(event['created_at'] as int);
      socket.add(jsonEncode(['OK', event['id'], true]));
    });
    Future<ProfilePublishResult> publish() => NostrProfilePublisher(
            store: NostrProfileStore(),
            relays: NostrProfileRelayClient(relays: [url]),
            clock: () => DateTime.fromMillisecondsSinceEpoch(100000))
        .publish(
            npub: identity.npub,
            secret: identity.nsec,
            profile: const NostrProfile(name: 'published'));
    await Future.wait([publish(), publish()]);
    expect(events.toSet(), {100, 101});
    await publish();
    expect(events.last, 102);
    await NostrProfileStore().saveRemote(
        identity.npub, const NostrProfile(name: 'future remote'),
        createdAt: 200);
    await publish();
    expect(events.last, 201);
  });

  test('out-of-order acknowledgements preserve latest publication ordering',
      () async {
    final store = NostrProfileStore();
    final first = await store.preparePublication(
        identity.npub, const NostrProfile(name: 'first'), 100);
    final second = await store.preparePublication(
        identity.npub, const NostrProfile(name: 'second'), 100);
    await store.acknowledgePublication(identity.npub, second);
    await NostrProfileStore().acknowledgePublication(identity.npub, first);
    expect(
        (await store.saveRemote(
                identity.npub, const NostrProfile(name: 'stale'),
                createdAt: 101))
            .name,
        'second');
    expect(
        (await store.saveRemote(
                identity.npub, const NostrProfile(name: 'newer'),
                createdAt: 102))
            .name,
        'newer');
  });

  test('legacy local data remains a draft until explicitly published',
      () async {
    await SharedPreferencesAsync().setString(
        'wingman.nostr.profile.v1.${identity.npub}',
        jsonEncode(const NostrProfile(name: 'legacy').toJson()));
    final store = NostrProfileStore();
    expect(
        (await store.saveRemote(
                identity.npub, const NostrProfile(name: 'remote'),
                createdAt: 100))
            .name,
        'legacy');
    final publication = await store.preparePublication(
        identity.npub, await store.load(identity.npub), 101);
    await store.acknowledgePublication(identity.npub, publication);
    expect(
        (await NostrProfileStore().saveRemote(
                identity.npub, const NostrProfile(name: 'newer'),
                createdAt: 102))
            .name,
        'newer');
  });

  test('relay fetch carries event timestamp through to storage', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((message) {
        final frame = jsonDecode(message as String) as List;
        if (frame[0] == 'REQ') {
          socket.add(jsonEncode([
            'EVENT',
            frame[1],
            {
              'kind': 0,
              'pubkey': identity.publicKeyHex,
              'created_at': 123,
              'content': '{"name":"fetched"}',
            }
          ]));
        }
      });
    });
    final result =
        await NostrProfileRelayClient(relays: ['ws://127.0.0.1:${server.port}'])
            .fetchProfile(identity.publicKeyHex);
    expect(result!.createdAt, 123);
    await NostrProfileStore()
        .saveRemote(identity.npub, result.profile, createdAt: result.createdAt);
    expect(
        (await NostrProfileStore().saveRemote(
                identity.npub, const NostrProfile(name: 'stale'),
                createdAt: 122))
            .name,
        'fetched');
  });

  test('publishes a valid signed kind-0 and reports exact acknowledged relays',
      () async {
    Map<String, dynamic>? captured;
    final accepted = await relay((socket, event) {
      captured = event;
      socket.add(jsonEncode(['OK', 'unrelated', true, 'ignored']));
      socket.add(jsonEncode(['OK', event['id'], true, 'saved']));
    });
    final rejected = await relay((socket, event) {
      socket.add(jsonEncode(['OK', event['id'], false, 'blocked']));
    });
    final store = NostrProfileStore();
    final result = await NostrProfilePublisher(
      store: store,
      relays: NostrProfileRelayClient(relays: [accepted, rejected]),
    ).publish(
        npub: identity.npub,
        secret: identity.nsec,
        profile: const NostrProfile(
          name: 'test',
          displayName: 'Test User',
          pictureUrl: 'https://example.test/avatar.png',
          nip05: 'test@example.test',
          website: 'https://example.test',
          about: 'Local fake relay test',
          cachedPictureBase64: 'private-cache-only',
        ));
    expect(result.acceptedRelays, [accepted]);
    expect(result.totalRelays, 2);
    expect(result.published, isTrue);
    final event = captured!;
    expect(event.keys.toSet(),
        {'id', 'pubkey', 'created_at', 'kind', 'tags', 'content', 'sig'});
    expect(event['kind'], 0);
    expect(event['pubkey'], identity.publicKeyHex);
    expect(
        bip340.verify(event['pubkey'] as String, event['id'] as String,
            event['sig'] as String),
        isTrue);
    final payload = jsonDecode(event['content'] as String) as Map;
    expect(payload.keys.toSet(),
        {'name', 'display_name', 'picture', 'nip05', 'website', 'about'});
    expect(jsonEncode(event), isNot(contains(identity.nsec)));
    expect(jsonEncode(event), isNot(contains(identity.secretHex)));
    expect(jsonEncode(event), isNot(contains('private-cache-only')));
    expect((await NostrProfileStore().load(identity.npub)).displayName,
        'Test User');
  });

  for (final mode in ['reject', 'unrelated', 'disconnect', 'malformed']) {
    test(
        '$mode never counts as publication and draft survives restart and refresh',
        () async {
      final url = await relay((socket, event) {
        switch (mode) {
          case 'reject':
            socket.add(jsonEncode(['OK', event['id'], false, 'denied']));
          case 'unrelated':
            socket.add(jsonEncode(['OK', 'wrong-id', true]));
          case 'disconnect':
            socket.close();
          case 'malformed':
            socket.add('not json');
        }
      });
      final store = NostrProfileStore();
      final result = await NostrProfilePublisher(
        store: store,
        relays: NostrProfileRelayClient(
            relays: [url], timeout: const Duration(milliseconds: 150)),
      ).publish(
          npub: identity.npub,
          secret: identity.nsec,
          profile: const NostrProfile(displayName: 'Keep my draft'));
      expect(result.published, isFalse);
      expect(result.message, contains('No relay confirmed'));
      await NostrProfileStore().saveRemote(
          identity.npub, const NostrProfile(displayName: 'Stale remote'),
          createdAt: 9999999999);
      expect((await NostrProfileStore().load(identity.npub)).displayName,
          'Keep my draft');
    });
  }

  test(
      'missing relays and mismatched signing identity keep drafts without publication',
      () async {
    final store = NostrProfileStore();
    final publisher = NostrProfilePublisher(
        store: store, relays: NostrProfileRelayClient(relays: []));
    final result = await publisher.publish(
        npub: identity.npub,
        secret: identity.nsec,
        profile: const NostrProfile(name: 'offline'));
    expect(result.published, isFalse);
    await expectLater(
        publisher.publish(
            npub: identity.npub,
            secret: NostrCrypto.importIdentity('2'.padLeft(64, '0')).nsec,
            profile: const NostrProfile(name: 'retained')),
        throwsStateError);
    expect((await store.load(identity.npub)).name, 'retained');
  });

  test(
      'concurrent remote writes cannot replace a local edit, even when clearing fields',
      () async {
    final store = NostrProfileStore();
    await Future.wait([
      store.saveRemote(identity.npub, const NostrProfile(name: 'old remote'),
          createdAt: 100),
      NostrProfileStore().save(identity.npub, const NostrProfile()),
      NostrProfileStore().saveRemote(
          identity.npub, const NostrProfile(name: 'late remote'),
          createdAt: 100),
      store.saveRemote('another-identity', const NostrProfile(name: 'other'),
          createdAt: 100),
    ]);
    expect((await store.load(identity.npub)).name, '');
    expect((await store.load('another-identity')).name, 'other');
    final raw = await SharedPreferencesAsync()
        .getString('wingman.nostr.profile.v1.${identity.npub}');
    expect(jsonDecode(raw!)['local_edit'], isTrue);
  });
}
