import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/features/browser/browser_bookmark_store.dart';
import 'package:wingman_app/src/features/nstack/nstack_models.dart';
import 'package:wingman_app/src/features/nstack/nstack_store.dart';
import 'package:wingman_app/src/features/nstack/nstack_workspace_discovery.dart';

class _Discovery implements NStackWorkspaceDiscovery {
  @override
  Future<List<NStackWorkspace>> discover(
          {required String address,
          required String identityNpub,
          required String secret}) async =>
      [
        NStackWorkspace(
            id: '',
            name: 'Workspace',
            remoteId: '12345678-1234-4234-8234-123456789abc',
            workspaceOwnerNpub: identityNpub,
            workspaceServiceNpub: identityNpub,
            serviceNpub: identityNpub,
            directHttpsUrl: address,
            membershipRole: 'owner')
      ];
}

void main() {
  final identity = NostrCrypto.importIdentity('1'.padLeft(64, '0')).npub;
  setUp(() => SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty());
  test(
      'add, re-add, select, edit and reopen preserve all connections and settings',
      () async {
    final store = NStackRegistryStore();
    final service = NStackWorkspaceDiscoveryService(
        registryStore: store, discovery: _Discovery());
    Future<NStackEntry> add(String address) => service.add(
        identityNpub: identity, secret: 'test-only', address: address);
    final first = await add('https://first.example');
    await store.rename(identity, first.id, 'First stack');
    await store.selectHost(identity, first.id);
    await store.selectBackupDestination(identity,
        stackId: first.id, workspaceId: first.workspaces.single.id);
    await store.updateActiveSettings(
        identity,
        (_) => const NStackBrowserSettings(
                bookmarks: [
                  BrowserBookmark(
                      title: 'Saved app', url: 'https://app.example')
                ],
                background: 'data:image/png;base64,iVBORw0KGgo=',
                labelColour: '#123456',
                builtInStartup: true));
    final savedJson =
        jsonEncode((await store.load(identity)).stacks.first.toJson());
    final second = await add('https://second.example');
    final third = await add('https://third.example');
    expect(second.id, isNot(first.id));
    expect(jsonEncode((await store.load(identity)).stacks.first.toJson()),
        savedJson);
    expect((await add('https://SECOND.example/')).id, second.id);
    expect((await store.load(identity)).stacks.map((s) => s.id),
        [first.id, second.id, third.id]);
    await store.selectActive(identity, second.id);
    await store.rename(identity, second.id, 'Second stack');
    await service.changeAddress(
        identityNpub: identity,
        secret: 'test-only',
        stackId: second.id,
        address: 'https://moved.example');
    final reopened = await NStackRegistryStore().load(identity);
    expect(reopened.stacks.map((s) => s.id), [first.id, second.id, third.id]);
    expect(jsonEncode(reopened.stacks.first.toJson()), savedJson);
    expect(reopened.activeStackId, second.id);
    expect(reopened.activeStack!.name, 'Second stack');
    expect(reopened.activeStack!.url, 'https://moved.example');
    expect(reopened.hostStackId, first.id);
    expect(reopened.backupStack!.id, first.id);
    expect(reopened.backupWorkspace!.id, first.workspaces.single.id);
    expect(reopened.backupDestinationAvailable, isTrue);
    final before = jsonEncode(reopened.toJson());
    await expectLater(
        service.changeAddress(
            identityNpub: identity,
            secret: 'test-only',
            stackId: second.id,
            address: 'https://first.example'),
        throwsA(isA<NStackWorkspaceDiscoveryException>()));
    expect(jsonEncode((await NStackRegistryStore().load(identity)).toJson()),
        before);
  });
  test('overlapping additions and selection retain every saved entry',
      () async {
    final store = NStackRegistryStore();
    final service = NStackWorkspaceDiscoveryService(
        registryStore: store, discovery: _Discovery());
    Future<NStackEntry> add(String host) => service.add(
        identityNpub: identity,
        secret: 'test-only',
        address: 'https://$host.example');
    final first = await add('first');
    final added =
        await Future.wait([add('second'), add('third'), add('second')]);
    expect(added[0].id, added[2].id);
    await Future.wait([
      store.selectActive(identity, added[0].id),
      store.rename(identity, first.id, 'Retained name'),
      add('fourth'),
      store.selectHost(identity, first.id)
    ]);
    final reopened = await NStackRegistryStore().load(identity);
    expect(reopened.stacks, hasLength(4));
    expect(reopened.stacks.first.name, 'Retained name');
    expect(reopened.activeStackId, added[0].id);
    expect(reopened.hostStackId, first.id);
    await expectLater(
        store.selectActive(identity, 'missing'), throwsStateError);
    await store.rename(identity, first.id, 'Still writable');
    expect((await NStackRegistryStore().load(identity)).stacks.first.name,
        'Still writable');
  });
}
