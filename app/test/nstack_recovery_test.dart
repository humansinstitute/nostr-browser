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
    await registryStore.selectBackupDestination(identity.npub,
        stackId: _hostStack.id, workspaceId: 'workspace-internal');
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
    relay.events.clear();

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
    await store.selectBackupDestination(identity.npub,
        stackId: _hostStack.id, workspaceId: 'workspace-internal');
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

  test('identity and selected-workspace mismatch fail closed', () async {
    final identity = NostrCrypto.importIdentity(_secret);
    final store = NStackRegistryStore();
    await store.addOrUpdate(identity.npub, _hostStack, makeActive: true);
    await store.selectBackupDestination(identity.npub,
        stackId: _hostStack.id, workspaceId: 'workspace-internal');
    final storage = _FakeStorage();
    final service = NStackRecoveryService(
        registryStore: store, storage: storage, relay: _FakeRelay());
    await expectLater(
      service.publish(
        identityNpub: identity.npub,
        publicKeyHex: identity.publicKeyHex,
        secret: '2'.padLeft(64, '0'),
      ),
      throwsStateError,
    );
    await service.publish(
      identityNpub: identity.npub,
      publicKeyHex: identity.publicKeyHex,
      secret: _secret,
    );
    final valid = storage.pointer!;
    storage.pointer = NStackRecoveryPointer(
      hostUrl: valid.hostUrl,
      workspaceId: '33333333-3333-4333-8333-333333333333',
      workspaceOwnerNpub: valid.workspaceOwnerNpub,
      objectId: valid.objectId,
      sha256: valid.sha256,
      snapshotRevision: valid.snapshotRevision,
      updatedAt: valid.updatedAt,
      relays: valid.relays,
    );
    await expectLater(
      service.retrieve(
        identityNpub: identity.npub,
        publicKeyHex: identity.publicKeyHex,
        secret: _secret,
      ),
      throwsA(isA<NStackStorageException>()
          .having((error) => error.code, 'code', 'workspace_mismatch')),
    );
  });

  test('missing namespace and membership loss do not fall back', () async {
    final identity = NostrCrypto.importIdentity(_secret);
    final store = NStackRegistryStore();
    await store.addOrUpdate(identity.npub, _hostStack, makeActive: true);
    await store.selectBackupDestination(identity.npub,
        stackId: _hostStack.id, workspaceId: 'workspace-internal');
    final storage = _FakeStorage()
      ..failure = const NStackStorageException(
          'app_not_found', 'Workspace manager must enable NBrowser backup.',
          statusCode: 404);
    final service = NStackRecoveryService(
        registryStore: store, storage: storage, relay: _FakeRelay());
    await expectLater(
      service.publish(
          identityNpub: identity.npub,
          publicKeyHex: identity.publicKeyHex,
          secret: _secret),
      throwsA(isA<NStackStorageException>()
          .having((error) => error.code, 'code', 'app_not_found')),
    );
    storage.failure = const NStackStorageException(
        'workspace_membership_required', 'Workspace access was denied.',
        statusCode: 403);
    await expectLater(
      service.publish(
          identityNpub: identity.npub,
          publicKeyHex: identity.publicKeyHex,
          secret: _secret),
      throwsA(isA<NStackStorageException>().having(
          (error) => error.code, 'code', 'workspace_membership_required')),
    );
    expect(storage.uploadAttempts, 2);
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
    NStackWorkspace(
      id: 'workspace-internal',
      name: 'Home',
      remoteId: '11111111-1111-4111-8111-111111111111',
      stableRemoteId: '11111111-1111-4111-8111-111111111111',
      workspaceOwnerNpub:
          'npub10xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqpkge6d',
      workspaceServiceNpub:
          'npub10xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqpkge6d',
      directHttpsUrl: 'https://host.example',
      serviceNpub:
          'npub10xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqpkge6d',
      membershipRole: 'owner',
    )
  ],
  settings: NStackBrowserSettings(bookmarks: [
    BrowserBookmark(title: 'Ambulando', url: 'https://ambulando.example/app')
  ]),
);

class _FakeStorage implements NStackStorageClient {
  List<int> bytes = const [];
  String? hash;
  bool tamper = false;
  NStackRecoveryPointer? pointer;
  NStackStorageException? failure;
  int uploadAttempts = 0;

  @override
  Future<NStackBackupNamespaceState> namespaceState(
          {required NStackBackupTarget target, required String secret}) async =>
      NStackBackupNamespaceState.enabled;

  @override
  Future<void> enableNamespace(
      {required NStackBackupTarget target, required String secret}) async {}

  @override
  Future<NStackRecoveryPointer> upload({
    required NStackBackupTarget target,
    required String secret,
    required List<int> bytes,
    required String sha256,
    required int snapshotRevision,
    required DateTime updatedAt,
    required List<String> relays,
  }) async {
    uploadAttempts++;
    if (failure case final error?) throw error;
    expect(target.hostUrl, 'https://host.example');
    expect(target.workspaceId, '11111111-1111-4111-8111-111111111111');
    expect(NostrCrypto.sha256Hex(bytes), sha256);
    this.bytes = List.unmodifiable(bytes);
    hash = sha256;
    return pointer = NStackRecoveryPointer(
      hostUrl: target.hostUrl,
      workspaceId: target.workspaceId,
      workspaceOwnerNpub: target.workspaceOwnerNpub,
      objectId: '22222222-2222-4222-8222-222222222222',
      sha256: sha256,
      snapshotRevision: snapshotRevision,
      updatedAt: updatedAt,
      relays: relays,
    );
  }

  @override
  Future<NStackRecoveryPointer> readPointer({
    required NStackBackupTarget target,
    required String secret,
    required List<String> relays,
  }) async =>
      pointer!;

  @override
  Future<List<int>> fetchObject({
    required NStackBackupTarget target,
    required NStackRecoveryPointer pointer,
    required String secret,
  }) async {
    if (pointer.workspaceId != target.workspaceId ||
        pointer.workspaceOwnerNpub != target.workspaceOwnerNpub ||
        pointer.hostUrl != target.hostUrl) {
      throw const NStackStorageException('workspace_mismatch',
          'The backup pointer does not match the selected workspace.');
    }
    if (pointer.sha256 != hash) throw StateError('hash mismatch');
    final result = List<int>.from(bytes);
    if (tamper) result[10] ^= 1;
    if (NostrCrypto.sha256Hex(result) != pointer.sha256) {
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
