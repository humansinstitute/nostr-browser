import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/features/browser/browser_bookmark_store.dart';
import 'package:wingman_app/src/features/nstack/nstack_models.dart';
import 'package:wingman_app/src/features/nstack/nstack_store.dart';

void main() {
  setUp(() => SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty());
  final tower = NostrCrypto.importIdentity('1'.padLeft(64, '0')).npub;
  final key = NostrCrypto.importIdentity('2'.padLeft(64, '0')).npub;
  final other = NostrCrypto.importIdentity('3'.padLeft(64, '0')).npub;
  NStackWorkspace workspace(String url,
          {String? service, String? workspaceKey}) =>
      NStackWorkspace(
          id: 'private-workspace',
          name: 'Main workspace',
          remoteId: '12345678-1234-4234-8234-123456789abc',
          workspaceOwnerNpub: tower,
          workspaceServiceNpub: workspaceKey ?? key,
          serviceNpub: service ?? tower,
          directHttpsUrl: url,
          membershipRole: 'owner');
  const oldUrl = 'https://old.example';
  const newUrl = 'https://new.example';
  Future<NStackRegistryStore> saved() async {
    final store = NStackRegistryStore();
    await store.addOrUpdate(
        tower,
        NStackEntry(
            id: 'private-stack',
            name: 'Old name',
            url: oldUrl,
            towerNpub: tower,
            workspaces: [workspace(oldUrl)],
            settings: const NStackBrowserSettings(bookmarks: [
              BrowserBookmark(title: 'App', url: 'https://app.example')
            ], labelColour: '#123456', builtInStartup: true)),
        makeActive: true,
        makeHost: true);
    await store.selectBackupDestination(tower,
        stackId: 'private-stack', workspaceId: 'private-workspace');
    return store;
  }

  test(
      'rename and same-identity endpoint edit persist associations across restart',
      () async {
    final store = await saved();
    await store.rename(tower, 'private-stack', 'Home NStack');
    final original = (await store.load(tower)).activeStack!;
    await store.applyWorkspaceDiscovery(tower,
        candidate: original.copyWith(url: newUrl),
        expectedPreviousUrl: oldUrl,
        discovered: [workspace(newUrl)],
        refreshedAt: DateTime.now());
    final restarted = await NStackRegistryStore().load(tower);
    expect(restarted.stacks, hasLength(1));
    expect(restarted.activeStack?.id, 'private-stack');
    expect(restarted.hostStack?.id, 'private-stack');
    expect(restarted.activeStack?.name, 'Home NStack');
    expect(restarted.activeStack?.url, newUrl);
    expect(restarted.activeStack?.publicIdentity, tower);
    expect(restarted.activeStack?.settings.bookmarks.single.title, 'App');
    expect(restarted.activeStack?.settings.labelColour, '#123456');
    expect(restarted.activeStack?.settings.builtInStartup, isTrue);
    expect(restarted.backupDestination?.workspaceId, 'private-workspace');
    expect(restarted.backupWorkspace?.directHttpsUrl, newUrl);
    expect(restarted.backupDestinationAvailable, isTrue);
  });
  test('different or missing identity rejects endpoint edit atomically',
      () async {
    final store = await saved();
    final before = (await store.load(tower)).toJson().toString();
    final original = (await store.load(tower)).activeStack!;
    for (final discovered in [
      [workspace(newUrl, service: other)],
      <NStackWorkspace>[]
    ]) {
      await expectLater(
          store.applyWorkspaceDiscovery(tower,
              candidate: original.copyWith(url: newUrl),
              expectedPreviousUrl: oldUrl,
              discovered: discovered,
              refreshedAt: DateTime.now()),
          throwsStateError);
      expect((await NStackRegistryStore().load(tower)).toJson().toString(),
          before);
    }
  });
  test('changed workspace key never inherits old workspace association',
      () async {
    final store = await saved();
    await store.applyWorkspaceDiscovery(tower,
        candidate: (await store.load(tower)).activeStack!,
        discovered: [workspace(oldUrl, workspaceKey: other)],
        refreshedAt: DateTime.now());
    final registry = await NStackRegistryStore().load(tower);
    expect(
        registry.activeStack?.workspaces.single.id, isNot('private-workspace'));
    expect(registry.backupDestinationAvailable, isFalse);
  });
  test('presentation hides endpoint labels and full identities', () {
    expect(safeConnectionName('old.example', fallback: 'NStack'), 'NStack');
    expect(
        safeConnectionName('12345678-1234-4234-8234-123456789abc',
            fallback: 'Workspace'),
        'Workspace');
    expect(abbreviatedNpub(key), startsWith('npub1'));
    expect(abbreviatedNpub(key), isNot(contains(key)));
    expect(abbreviatedNpub(null), 'Identity unavailable');
  });
}
