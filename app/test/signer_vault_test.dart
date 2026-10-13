import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/core/signer_vault.dart';

class RecordingSecureStoragePlatform extends FlutterSecureStoragePlatform {
  final _values = <String, String>{};
  final reads = <Map<String, String>>[];
  final writes = <Map<String, String>>[];

  String _storageKey(String key, Map<String, String> options) =>
      '${options['accountName'] ?? ''}:$key';

  void seed({
    required String accountName,
    required String key,
    required String value,
  }) {
    _values['$accountName:$key'] = value;
  }

  String? value({
    required String accountName,
    required String key,
  }) =>
      _values['$accountName:$key'];

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async =>
      _values.containsKey(_storageKey(key, options));

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    _values.remove(_storageKey(key, options));
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    _values.clear();
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    reads.add(options);
    return _values[_storageKey(key, options)];
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async =>
      _values;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    writes.add(options);
    _values[_storageKey(key, options)] = value;
  }
}

class CountingMemorySecretStore extends MemorySignerVaultSecretStore {
  int reads = 0;

  @override
  Future<String?> read(String key) async {
    reads += 1;
    return super.read(key);
  }
}

void main() {
  const secretHex =
      '0000000000000000000000000000000000000000000000000000000000000001';
  const deviceSecretKey = 'wingman.signer.device_secret.v1';
  const currentMacOsAccountName = 'com.wingmanbefree.wmapp.signer-vault';
  const legacyMacOsAccountName = 'flutter_secure_storage_service';

  test('encrypts nsec locally and unlocks with PIN', () async {
    final nsec = NostrCrypto.importIdentity(secretHex).nsec;
    final localStore = MemorySignerVaultLocalStore();
    final secretStore = MemorySignerVaultSecretStore();
    final vault = SignerVault(
      localStore: localStore,
      secretStore: secretStore,
    );

    final created = await vault.create(nsec: nsec, pin: '123456');
    expect(created.nsec, nsec);

    final record = await vault.loadRecord();
    expect(record, isNotNull);
    expect(record!.npub, created.npub);
    expect(record.ciphertext, isNot(contains('nsec')));

    final unlocked = await vault.unlock(pin: '123456');
    expect(unlocked.nsec, nsec);
    expect(unlocked.npub, created.npub);
  });

  test('rejects wrong PIN', () async {
    final nsec = NostrCrypto.importIdentity(secretHex).nsec;
    final vault = SignerVault(
      localStore: MemorySignerVaultLocalStore(),
      secretStore: MemorySignerVaultSecretStore(),
    );
    await vault.create(nsec: nsec, pin: '123456');

    expect(
      () => vault.unlock(pin: '654321'),
      throwsA(isA<SignerVaultException>()),
    );
  });

  test('unlock reads secure storage once and native signing does not reread',
      () async {
    final nsec = NostrCrypto.importIdentity(secretHex).nsec;
    final secretStore = CountingMemorySecretStore();
    final vault = SignerVault(
      localStore: MemorySignerVaultLocalStore(),
      secretStore: secretStore,
    );
    await vault.create(nsec: nsec, pin: '123456');
    secretStore.reads = 0;

    final unlocked = await vault.unlock(pin: '123456');

    expect(secretStore.reads, 1);
    final config = AppConfig.defaults().copyWith(
      deviceNpub: unlocked.npub,
      devicePublicKeyHex: unlocked.publicKeyHex,
      deviceSecret: unlocked.nsec,
    );
    final bridge = NativeCoreBridge();
    expect(
      (await bridge.signNip98(
        config: config,
        method: 'GET',
        url: 'https://fixture.example',
      ))
          .ok,
      isTrue,
    );
    expect(
      (await bridge.signEvent(
        config: config,
        event: {'kind': 1, 'content': 'fixture', 'tags': []},
      ))
          .ok,
      isTrue,
    );
    expect(secretStore.reads, 1);
  });

  test('creation cannot overwrite an existing or unreadable vault', () async {
    final local = MemorySignerVaultLocalStore();
    final secrets = MemorySignerVaultSecretStore();
    final vault = SignerVault(localStore: local, secretStore: secrets);
    final first = await vault.create(nsec: secretHex, pin: '1234');
    final before = await local.getString('wingman.signer.vault.v1');
    await expectLater(vault.create(nsec: '2'.padLeft(64, '0'), pin: '5678'),
        throwsA(isA<SignerVaultException>()));
    expect(await local.getString('wingman.signer.vault.v1'), before);
    expect((await vault.unlock(pin: '1234')).npub, first.npub);
    expect(before, isNot(contains(first.nsec)));
    expect(before, isNot(contains(secretHex)));
    await local.setString('wingman.signer.vault.v1', 'unreadable');
    await expectLater(vault.create(nsec: secretHex, pin: '1234'),
        throwsA(isA<SignerVaultException>()));
    expect(await local.getString('wingman.signer.vault.v1'), 'unreadable');
  });

  test('simultaneous creation cannot replace the first identity', () async {
    final local = MemorySignerVaultLocalStore();
    final secrets = MemorySignerVaultSecretStore();
    final vault = SignerVault(localStore: local, secretStore: secrets);
    final other = SignerVault(localStore: local, secretStore: secrets);
    final first = vault.create(nsec: secretHex, pin: '1234');
    await expectLater(other.create(nsec: '2'.padLeft(64, '0'), pin: '5678'),
        throwsA(isA<SignerVaultException>()));
    final created = await first;
    expect((await vault.unlock(pin: '1234')).npub, created.npub);
  });

  test('macOS secure storage reads WMAPP service and migrates legacy item',
      () async {
    final originalPlatform = FlutterSecureStoragePlatform.instance;
    final platform = RecordingSecureStoragePlatform()
      ..seed(
        accountName: legacyMacOsAccountName,
        key: deviceSecretKey,
        value: 'device-secret',
      );
    FlutterSecureStoragePlatform.instance = platform;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() {
      FlutterSecureStoragePlatform.instance = originalPlatform;
      debugDefaultTargetPlatformOverride = null;
    });

    final store = SecureStorageSignerVaultSecretStore();

    expect(await store.read(deviceSecretKey), 'device-secret');
    expect(platform.reads, hasLength(2));
    expect(platform.reads.first['accountName'], currentMacOsAccountName);
    expect(platform.reads.first['usesDataProtectionKeychain'], 'false');
    expect(platform.reads.last['accountName'], legacyMacOsAccountName);
    expect(platform.reads.last['usesDataProtectionKeychain'], 'false');
    expect(platform.writes.single['accountName'], currentMacOsAccountName);
    expect(
      platform.value(
        accountName: currentMacOsAccountName,
        key: deviceSecretKey,
      ),
      'device-secret',
    );
  });
}
