import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/flight_deck_update_manager_io.dart';
import 'package:wingman_app/src/core/flight_deck_update_models.dart';
import 'package:wingman_app/src/core/local_flight_deck_server_io.dart';

void main() {
  final temporaryDirectories = <Directory>[];

  tearDown(() async {
    for (final directory in temporaryDirectories) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
    temporaryDirectories.clear();
  });

  Future<Directory> temporaryRoot(String name) async {
    final root = await Directory.systemTemp.createTemp('wmapp-$name-');
    temporaryDirectories.add(root);
    return root;
  }

  test('manifest parsing enforces schema, HTTPS hosts, and compatibility', () {
    final archive = _archive({'index.html': utf8.encode('ok')});
    final valid = _manifest(archive, buildNumber: 101);
    final parsed = FlightDeckUpdateManifest.parse(
      jsonEncode(valid),
      allowedHosts: {'updates.example'},
      currentWmappVersion: '0.1.2',
      nativeBridgeVersion: 1,
    );
    expect(parsed.buildNumber, 101);
    expect(parsed.archiveSha256, sha256.convert(archive).toString());

    expect(
      () => FlightDeckUpdateManifest.parse(
        '{broken',
        allowedHosts: {'updates.example'},
        currentWmappVersion: '0.1.2',
        nativeBridgeVersion: 1,
      ),
      throwsFormatException,
    );
    expect(
      () => FlightDeckUpdateManifest.parse(
        jsonEncode({...valid, 'schema_version': 2}),
        allowedHosts: {'updates.example'},
        currentWmappVersion: '0.1.2',
        nativeBridgeVersion: 1,
      ),
      throwsA(isA<FlightDeckCompatibilityException>()),
    );
    expect(
      () => FlightDeckUpdateManifest.parse(
        jsonEncode({
          ...valid,
          'compatibility': {
            'minimum_wmapp_version': '0.2.0',
            'minimum_native_bridge': 2,
          },
        }),
        allowedHosts: {'updates.example'},
        currentWmappVersion: '0.1.2',
        nativeBridgeVersion: 1,
      ),
      throwsA(isA<FlightDeckCompatibilityException>()),
    );
    expect(
      () => FlightDeckUpdateManifest.parse(
        jsonEncode({
          ...valid,
          'archive': {
            ...(valid['archive']! as Map<String, dynamic>),
            'url': 'https://evil.example/flightdeck.tar.gz',
          },
        }),
        allowedHosts: {'updates.example'},
        currentWmappVersion: '0.1.2',
        nativeBridgeVersion: 1,
      ),
      throwsFormatException,
    );
  });

  test('same or older manifest produces no update', () async {
    final root = await temporaryRoot('no-update');
    final archive = _archive({'index.html': utf8.encode('same')});
    final client = _FakeDownloadClient()
      ..putJson(_feedUri, _manifest(archive, buildNumber: 100));
    final manager = _manager(root, client, packagedBuild: 100);

    await manager.initialize();
    await manager.checkForUpdates();

    expect(manager.snapshot.phase, FlightDeckUpdatePhase.idle);
    expect(manager.snapshot.availableVersion, isEmpty);
    expect(manager.activeRootPath, isNull);
  });

  test('verified archive installs atomically and rolls back to packaged assets',
      () async {
    final root = await temporaryRoot('success');
    final archive = _archive({
      'index.html': utf8.encode('<html>downloaded</html>'),
      'assets/app.js': utf8.encode('console.log("downloaded")'),
    });
    final manifest = _manifest(archive, buildNumber: 101);
    final client = _FakeDownloadClient()
      ..putJson(_feedUri, manifest)
      ..putBytes(_archiveUri, archive);
    final manager = _manager(root, client, packagedBuild: 100);

    await manager.initialize();
    expect(manager.activeRootPath, isNull);
    await manager.checkForUpdates();
    expect(manager.snapshot.phase, FlightDeckUpdatePhase.available);
    await manager.applyAvailable();

    expect(manager.snapshot.phase, FlightDeckUpdatePhase.active);
    expect(manager.snapshot.activeVersion, contains('Build 101'));
    expect(manager.snapshot.previousVersion, contains('Build 100'));
    expect(
      await File('${manager.activeRootPath}/index.html').readAsString(),
      contains('downloaded'),
    );

    await manager.rollback();
    expect(manager.activeRootPath, isNull);
    expect(manager.snapshot.activeVersion, contains('Build 100'));
  });

  test('checksum and declared size failures retain packaged fallback',
      () async {
    for (final failure in ['checksum', 'size']) {
      final root = await temporaryRoot(failure);
      final archive = _archive({'index.html': utf8.encode('bad')});
      final manifest = _manifest(
        archive,
        buildNumber: 101,
        shaOverride: failure == 'checksum' ? List.filled(64, '0').join() : null,
        sizeOverride: failure == 'size' ? archive.length + 1 : null,
      );
      final client = _FakeDownloadClient()
        ..putJson(_feedUri, manifest)
        ..putBytes(_archiveUri, archive);
      final manager = _manager(root, client, packagedBuild: 100);

      await manager.initialize();
      await manager.checkForUpdates();
      await manager.applyAvailable();

      expect(manager.snapshot.phase, FlightDeckUpdatePhase.failed);
      expect(manager.activeRootPath, isNull);
      expect(manager.snapshot.error,
          contains(failure == 'checksum' ? 'checksum' : 'size'));
    }
  });

  test('unsafe TAR paths, links, and resource limits are rejected', () async {
    final cases = <String, ({Uint8List archive, Map<String, int> limits})>{
      'traversal': (
        archive: _archiveEntries([_TarEntry('../escape', utf8.encode('x'))]),
        limits: {},
      ),
      'absolute': (
        archive: _archiveEntries([_TarEntry('/escape', utf8.encode('x'))]),
        limits: {},
      ),
      'symlink': (
        archive: _archiveEntries([
          _TarEntry('index.html', Uint8List(0), type: 50),
        ]),
        limits: {},
      ),
      'entry-count': (
        archive: _archive({
          'index.html': utf8.encode('ok'),
          'assets/app.js': utf8.encode('ok'),
        }),
        limits: {'entries': 1},
      ),
      'per-file': (
        archive: _archive({'index.html': utf8.encode('too large')}),
        limits: {'file': 4},
      ),
      'total-size': (
        archive: _archive({
          'index.html': utf8.encode('1234'),
          'app.js': utf8.encode('5678'),
        }),
        limits: {'total': 6},
      ),
    };

    for (final entry in cases.entries) {
      final root = await temporaryRoot(entry.key);
      final client = _FakeDownloadClient()
        ..putJson(_feedUri, _manifest(entry.value.archive, buildNumber: 101))
        ..putBytes(_archiveUri, entry.value.archive);
      final manager = _manager(
        root,
        client,
        packagedBuild: 100,
        maximumEntries: entry.value.limits['entries'] ?? 20,
        maximumFileBytes: entry.value.limits['file'] ?? 1024,
        maximumExtractedBytes: entry.value.limits['total'] ?? 4096,
      );

      await manager.initialize();
      await manager.checkForUpdates();
      await manager.applyAvailable();

      expect(
        manager.snapshot.phase,
        FlightDeckUpdatePhase.failed,
        reason: entry.key,
      );
      expect(manager.activeRootPath, isNull, reason: entry.key);
      expect(
          await _directoryIsEmpty(Directory('${root.path}/staging')), isTrue);
    }
  });

  test('interrupted download removes partial staging and keeps active build',
      () async {
    final root = await temporaryRoot('interrupted');
    final archive = _archive({'index.html': utf8.encode('partial')});
    final client = _FakeDownloadClient()
      ..putJson(_feedUri, _manifest(archive, buildNumber: 101))
      ..failAfterWrite(_archiveUri, archive.sublist(0, archive.length ~/ 2));
    final manager = _manager(root, client, packagedBuild: 100);

    await manager.initialize();
    await manager.checkForUpdates();
    await manager.applyAvailable();

    expect(manager.snapshot.phase, FlightDeckUpdatePhase.failed);
    expect(manager.activeRootPath, isNull);
    expect(
        await _directoryIsEmpty(Directory('${root.path}/downloads')), isTrue);
    expect(await _directoryIsEmpty(Directory('${root.path}/staging')), isTrue);
  });

  test('activation pointer failure retains the previous downloaded build',
      () async {
    final root = await temporaryRoot('atomic-failure');
    final firstArchive = _archive({'index.html': utf8.encode('first')});
    final firstClient = _FakeDownloadClient()
      ..putJson(_feedUri, _manifest(firstArchive, buildNumber: 101))
      ..putBytes(_archiveUri, firstArchive);
    final first = _manager(root, firstClient, packagedBuild: 100);
    await first.initialize();
    await first.checkForUpdates();
    await first.applyAvailable();
    final firstRoot = first.activeRootPath;

    final secondArchive = _archive({'index.html': utf8.encode('second')});
    final secondClient = _FakeDownloadClient()
      ..putJson(_feedUri, _manifest(secondArchive, buildNumber: 102))
      ..putBytes(_archiveUri, secondArchive);
    final persistence = _FailingPersistence(
      AtomicJsonFlightDeckStatePersistence(File('${root.path}/state.json')),
      failOnWrite: 2,
    );
    final second = _manager(
      root,
      secondClient,
      packagedBuild: 100,
      persistence: persistence,
    );
    await second.initialize();
    await second.checkForUpdates();
    await second.applyAvailable();

    expect(second.snapshot.phase, FlightDeckUpdatePhase.failed);
    expect(second.activeRootPath, firstRoot);
    expect(
        await File('$firstRoot/index.html').readAsString(), contains('first'));
  });

  test(
      'next launch restores the previous verified build when active is invalid',
      () async {
    final root = await temporaryRoot('startup-recovery');
    final client = _FakeDownloadClient();
    final firstArchive = _archive({'index.html': utf8.encode('first')});
    client
      ..putJson(_feedUri, _manifest(firstArchive, buildNumber: 101))
      ..putBytes(_archiveUri, firstArchive);
    final manager = _manager(root, client, packagedBuild: 100);
    await manager.initialize();
    await manager.checkForUpdates();
    await manager.applyAvailable();
    final firstRoot = manager.activeRootPath;

    final secondArchive = _archive({'index.html': utf8.encode('second')});
    client
      ..putJson(_feedUri, _manifest(secondArchive, buildNumber: 102))
      ..putBytes(_archiveUri, secondArchive);
    await manager.checkForUpdates();
    await manager.applyAvailable();
    await File('${manager.activeRootPath}/index.html').delete();

    final relaunched = _manager(root, client, packagedBuild: 100);
    await relaunched.initialize();
    expect(relaunched.activeRootPath, firstRoot);
    expect(relaunched.snapshot.failedVersion, contains('Build 102'));
  });

  test('loopback resolver selects downloaded files and rejects symlinks',
      () async {
    final root = await temporaryRoot('server-selection');
    await Directory('${root.path}/assets').create(recursive: true);
    await File('${root.path}/index.html').writeAsString('index');
    await File('${root.path}/assets/app.js').writeAsString('app');

    expect(
      (await selectDownloadedFlightDeckFile(root.path, 'assets/app.js'))?.path,
      '${root.path}/assets/app.js',
    );
    expect(
      (await selectDownloadedFlightDeckFile(root.path, 'tasks/123'))?.path,
      '${root.path}/index.html',
    );
    await Link('${root.path}/assets/link.js')
        .create('${root.path}/assets/app.js');
    expect(
      await selectDownloadedFlightDeckFile(root.path, 'assets/link.js'),
      isNull,
    );
  });
}

const _feedUri = 'https://updates.example/stable/manifest.json';
const _archiveUri = 'https://updates.example/releases/flightdeck.tar.gz';

IoFlightDeckUpdateController _manager(
  Directory root,
  FlightDeckDownloadClient client, {
  required int packagedBuild,
  FlightDeckStatePersistence? persistence,
  int maximumEntries = 20,
  int maximumFileBytes = 1024,
  int maximumExtractedBytes = 4096,
}) {
  return IoFlightDeckUpdateController(
    rootDirectory: root,
    feedUri: Uri.parse(_feedUri),
    enabled: true,
    allowedHosts: const {'updates.example'},
    currentWmappVersion: '0.1.2',
    nativeBridgeVersion: 1,
    packagedVersionLoader: () async => FlightDeckPackagedVersion(
      buildNumber: packagedBuild,
      label: 'Build $packagedBuild (packaged)',
    ),
    downloadClient: client,
    statePersistence: persistence,
    maximumManifestBytes: 64 * 1024,
    maximumArchiveBytes: 1024 * 1024,
    maximumExpandedTarBytes: 2 * 1024 * 1024,
    maximumExtractedBytes: maximumExtractedBytes,
    maximumFileBytes: maximumFileBytes,
    maximumEntries: maximumEntries,
  );
}

Map<String, dynamic> _manifest(
  Uint8List archive, {
  required int buildNumber,
  String? shaOverride,
  int? sizeOverride,
}) {
  return {
    'schema_version': 1,
    'build_number': buildNumber,
    'build_id': 'test-$buildNumber',
    'source_commit': List.filled(40, 'a').join(),
    'built_at': '2026-08-26T08:00:00.000Z',
    'channel': 'flightdeck-release',
    'archive': {
      'format': 'tar.gz',
      'url': _archiveUri,
      'sha256': shaOverride ?? sha256.convert(archive).toString(),
      'size_bytes': sizeOverride ?? archive.length,
    },
    'compatibility': {
      'minimum_wmapp_version': '0.1.2',
      'minimum_native_bridge': 1,
    },
  };
}

Uint8List _archive(Map<String, List<int>> files) {
  return _archiveEntries([
    for (final entry in files.entries)
      _TarEntry(entry.key, Uint8List.fromList(entry.value)),
  ]);
}

Uint8List _archiveEntries(List<_TarEntry> entries) {
  final tar = BytesBuilder(copy: false);
  for (final entry in entries) {
    tar
      ..add(_tarHeader(entry))
      ..add(entry.content);
    final padding = (512 - (entry.content.length % 512)) % 512;
    if (padding > 0) tar.add(Uint8List(padding));
  }
  tar.add(Uint8List(1024));
  return Uint8List.fromList(gzip.encode(tar.takeBytes()));
}

Uint8List _tarHeader(_TarEntry entry) {
  final header = Uint8List(512);
  void string(int offset, int length, String value) {
    final bytes = utf8.encode(value);
    if (bytes.length > length) throw StateError('test TAR field is too long');
    header.setRange(offset, offset + bytes.length, bytes);
  }

  void octal(int offset, int length, int value) {
    string(offset, length,
        '${value.toRadixString(8).padLeft(length - 1, '0')}\u0000');
  }

  string(0, 100, entry.name);
  octal(100, 8, 420);
  octal(108, 8, 0);
  octal(116, 8, 0);
  octal(124, 12, entry.content.length);
  octal(136, 12, 0);
  header.fillRange(148, 156, 32);
  header[156] = entry.type;
  string(257, 6, 'ustar\u0000');
  string(263, 2, '00');
  final checksum = header.fold<int>(0, (sum, byte) => sum + byte);
  string(148, 8, '${checksum.toRadixString(8).padLeft(6, '0')}\u0000 ');
  return header;
}

class _TarEntry {
  const _TarEntry(this.name, this.content, {this.type = 48});

  final String name;
  final Uint8List content;
  final int type;
}

class _FakeDownloadClient implements FlightDeckDownloadClient {
  final Map<String, Uint8List> _responses = {};
  final Map<String, Uint8List> _partialFailures = {};

  void putJson(String uri, Map<String, dynamic> value) {
    putBytes(uri, Uint8List.fromList(utf8.encode(jsonEncode(value))));
  }

  void putBytes(String uri, Uint8List value) => _responses[uri] = value;

  void failAfterWrite(String uri, Uint8List partial) =>
      _partialFailures[uri] = partial;

  @override
  Future<FlightDeckDownloadedFile> download(
    Uri uri,
    File destination, {
    required int maximumBytes,
  }) async {
    final partial = _partialFailures[uri.toString()];
    if (partial != null) {
      await destination.parent.create(recursive: true);
      await destination.writeAsBytes(partial, flush: true);
      throw const HttpException('interrupted test download');
    }
    final bytes = _responses[uri.toString()];
    if (bytes == null) throw StateError('No fake response for $uri');
    if (bytes.length > maximumBytes) {
      throw const FileSystemException('too large');
    }
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(bytes, flush: true);
    return FlightDeckDownloadedFile(
      byteCount: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
  }
}

class _FailingPersistence implements FlightDeckStatePersistence {
  _FailingPersistence(this.delegate, {required this.failOnWrite});

  final FlightDeckStatePersistence delegate;
  final int failOnWrite;
  int writes = 0;

  @override
  Future<Map<String, dynamic>?> read() => delegate.read();

  @override
  Future<void> write(Map<String, dynamic> state) {
    writes++;
    if (writes == failOnWrite) {
      throw const FileSystemException('simulated atomic pointer failure');
    }
    return delegate.write(state);
  }
}

Future<bool> _directoryIsEmpty(Directory directory) async {
  if (!await directory.exists()) return true;
  return directory.list().isEmpty;
}
