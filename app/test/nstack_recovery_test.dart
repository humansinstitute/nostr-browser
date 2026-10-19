import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/features/browser/browser_bookmark_store.dart';
import 'package:wingman_app/src/features/nstack/nstack_models.dart';
import 'package:wingman_app/src/features/nstack/nstack_recovery.dart';
import 'package:wingman_app/src/features/nstack/nstack_store.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('encrypted publish, verified preview and confirmed atomic restore',
      () async {
    final identity = NostrCrypto.importIdentity(_secret);
    final registryStore = NStackRegistryStore();
    await registryStore.addOrUpdate(
      identity.npub,
      _hostStack,
      makeActive: true,
      makeHost: true,
    );
    final storage = _FakeStorage();
    final relay = _FakeRelay();
    final service = NStackRecoveryService(
      registryStore: registryStore,
      storage: storage,
      relay: relay,
      clock: () => DateTime.utc(2026, 10, 19, 11),
    );

    final published = await service.publish(
      identityNpub: identity.npub,
      publicKeyHex: identity.publicKeyHex,
      secret: _secret,
    );
    expect(published.acceptedRelays, ['wss://one.example']);
    expect(utf8.decode(storage.bytes), isNot(contains('Ambulando')));
    final event = relay.events.single;
    expect(NostrCrypto.verifyEvent(event), isTrue);
    expect(event['kind'], nstackRecoveryHintKind);
    expect(event['content'], isNot(contains('host.example')));

    final preview = await service.retrieve(
      identityNpub: identity.npub,
      publicKeyHex: identity.publicKeyHex,
      secret: _secret,
    );
    expect(preview.pointer.hostUrl, 'https://host.example');
    expect(preview.snapshot.registry.stacks.single.name, 'Personal');
    expect(
        preview.snapshot.registry.stacks.single.settings.bookmarks.single.title,
        'Ambulando');

    await registryStore.replaceAtomic(identity.npub, const NStackRegistry());
    await service.restoreConfirmed(identity.npub, preview);
    final restored = await registryStore.load(identity.npub);
    expect(restored.stacks.single.name, 'Personal');
    expect(restored.activeStack?.settings.bookmarks.single.url,
        'https://ambulando.example/app');
    expect((await service.statusStore.load(identity.npub))?['success'], isTrue);
  });

  test('tampered object is rejected without changing local settings', () async {
    final identity = NostrCrypto.importIdentity(_secret);
    final store = NStackRegistryStore();
    await store.addOrUpdate(identity.npub, _hostStack,
        makeActive: true, makeHost: true);
    final storage = _FakeStorage();
    final relay = _FakeRelay();
    final service = NStackRecoveryService(
      registryStore: store,
      storage: storage,
      relay: relay,
    );
    await service.publish(
      identityNpub: identity.npub,
      publicKeyHex: identity.publicKeyHex,
      secret: _secret,
    );
    storage.tamper = true;
    final before = (await store.load(identity.npub)).toJson();
    expect(
      () => service.retrieve(
        identityNpub: identity.npub,
        publicKeyHex: identity.publicKeyHex,
        secret: _secret,
      ),
      throwsStateError,
    );
    expect((await store.load(identity.npub)).toJson(), before);
  });

  test('latest-event selection verifies author, signature, kind and d tag', () {
    final identity = NostrCrypto.importIdentity(_secret);
    Map<String, dynamic> sign(int createdAt, String content) =>
        NostrCrypto.signEvent(secret: _secret, event: {
          'kind': nstackRecoveryHintKind,
          'created_at': createdAt,
          'tags': [
            ['d', nstackRecoveryHintDTag]
          ],
          'content': content,
        });
    final older = sign(10, 'old');
    final newer = sign(20, 'new');
    final tampered = Map<String, dynamic>.from(newer)..['content'] = 'changed';
    final wrongTag = NostrCrypto.signEvent(secret: _secret, event: {
      'kind': nstackRecoveryHintKind,
      'created_at': 30,
      'tags': [
        ['d', 'other']
      ],
      'content': 'wrong',
    });
    expect(
      selectLatestValidHint(
          [older, tampered, wrongTag, newer], identity.publicKeyHex)?['id'],
      newer['id'],
    );
  });

  test('snapshot allowlist excludes grants, handles, secrets and vault values',
      () {
    final identity = NostrCrypto.importIdentity(_secret);
    final json = NStackSettingsSnapshot(
      identityNpub: identity.npub,
      createdAt: DateTime.utc(2026, 10, 19),
      registry: NStackRegistry(
        revision: 1,
        activeStackId: _hostStack.id,
        hostStackId: _hostStack.id,
        stacks: const [_hostStack],
      ),
    ).canonicalJson();
    for (final forbidden in [
      'nsec',
      'device_secret',
      'vault',
      'origin_grant',
      'capability_handle',
      'signature',
    ]) {
      expect(json.toLowerCase(), isNot(contains(forbidden)));
    }
  });
}

const _secret =
    '0000000000000000000000000000000000000000000000000000000000000001';
const _hostStack = NStackEntry(
  id: 'host-internal',
  name: 'Personal',
  url: 'https://host.example',
  workspaces: [
    NStackWorkspace(id: 'workspace-internal', name: 'Home', remoteId: 'ws-1')
  ],
  settings: NStackBrowserSettings(bookmarks: [
    BrowserBookmark(title: 'Ambulando', url: 'https://ambulando.example/app')
  ]),
);

class _FakeStorage implements NStackStorageClient {
  List<int> bytes = const [];
  String? hash;
  bool tamper = false;

  @override
  Future<String> upload({
    required String hostUrl,
    required String ownerNpub,
    required String secret,
    required List<int> bytes,
    required String sha256,
  }) async {
    expect(hostUrl, 'https://host.example');
    expect(NostrCrypto.sha256Hex(bytes), sha256);
    this.bytes = List.unmodifiable(bytes);
    hash = sha256;
    return '11111111-1111-4111-8111-111111111111';
  }

  @override
  Future<List<int>> fetch({
    required String hostUrl,
    required String objectId,
    required String secret,
    required String expectedSha256,
  }) async {
    if (expectedSha256 != hash) throw StateError('hash mismatch');
    final result = List<int>.from(bytes);
    if (tamper) result[10] ^= 1;
    if (NostrCrypto.sha256Hex(result) != expectedSha256) {
      throw StateError('Recovery object bytes failed hash verification.');
    }
    return result;
  }
}

class _FakeRelay implements NStackRecoveryRelay {
  final List<Map<String, dynamic>> events = [];
  @override
  List<String> get relays => const ['wss://one.example', 'wss://two.example'];

  @override
  Future<List<Map<String, dynamic>>> fetchHints(String publicKeyHex) async =>
      List.unmodifiable(events);

  @override
  Future<NStackRelayPublishResult> publish(Map<String, dynamic> event) async {
    events.add(Map<String, dynamic>.from(event));
    return const NStackRelayPublishResult(['wss://one.example'], 2);
  }
}
