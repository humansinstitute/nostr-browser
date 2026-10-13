import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'flight_deck_update_models.dart';

const _otaEnabled = bool.fromEnvironment(
  'WMAPP_FLIGHTDECK_OTA_ENABLED',
  defaultValue: false,
);
const _feedUrl = String.fromEnvironment('WMAPP_FLIGHTDECK_FEED_URL');
const _archiveHosts = String.fromEnvironment('WMAPP_FLIGHTDECK_ARCHIVE_HOSTS');
const _wmappVersion = String.fromEnvironment(
  'WMAPP_VERSION',
  defaultValue: '0.1.2',
);
const _nativeBridgeVersion = int.fromEnvironment(
  'WMAPP_NATIVE_BRIDGE_VERSION',
  defaultValue: 1,
);

Future<FlightDeckUpdateController> createFlightDeckUpdateController() async {
  final supportDirectory = await getApplicationSupportDirectory();
  final feedUri = Uri.tryParse(_feedUrl.trim());
  final allowedHosts = <String>{
    if (feedUri != null) feedUri.host.toLowerCase(),
    ..._archiveHosts
        .split(',')
        .map((host) => host.trim().toLowerCase())
        .where((host) => host.isNotEmpty),
  };
  final controller = IoFlightDeckUpdateController(
    rootDirectory: Directory('${supportDirectory.path}/flightdeck-updates'),
    feedUri: feedUri,
    enabled: _otaEnabled,
    allowedHosts: allowedHosts,
    currentWmappVersion: _wmappVersion,
    nativeBridgeVersion: _nativeBridgeVersion,
    packagedVersionLoader: () async {
      final raw = await rootBundle.loadString('assets/flightdeck/version.json');
      return FlightDeckPackagedVersion.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    },
  );
  await controller.initialize();
  return controller;
}

class FlightDeckPackagedVersion {
  const FlightDeckPackagedVersion({
    required this.buildNumber,
    required this.label,
  });

  factory FlightDeckPackagedVersion.fromJson(Map<String, dynamic> json) {
    final buildNumber = json['buildNumber'];
    final buildId = json['buildId']?.toString().trim() ?? '';
    if (buildNumber is! int || buildNumber < 0) {
      throw const FormatException(
          'Packaged Flight Deck buildNumber is invalid');
    }
    return FlightDeckPackagedVersion(
      buildNumber: buildNumber,
      label: buildId.isEmpty
          ? 'Build $buildNumber'
          : 'Build $buildNumber ($buildId)',
    );
  }

  final int buildNumber;
  final String label;
}

class FlightDeckUpdateManifest {
  const FlightDeckUpdateManifest({
    required this.schemaVersion,
    required this.buildNumber,
    required this.buildId,
    required this.sourceCommit,
    required this.archiveUri,
    required this.archiveSha256,
    required this.archiveSizeBytes,
    required this.builtAt,
    required this.minimumWmappVersion,
    required this.minimumNativeBridgeVersion,
    required this.channel,
    required this.releaseNotesUri,
  });

  factory FlightDeckUpdateManifest.parse(
    String raw, {
    required Set<String> allowedHosts,
    required String currentWmappVersion,
    required int nativeBridgeVersion,
  }) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const FormatException('Update manifest is not valid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Update manifest root must be an object');
    }
    return FlightDeckUpdateManifest.fromJson(
      decoded,
      allowedHosts: allowedHosts,
      currentWmappVersion: currentWmappVersion,
      nativeBridgeVersion: nativeBridgeVersion,
    );
  }

  factory FlightDeckUpdateManifest.fromJson(
    Map<String, dynamic> json, {
    required Set<String> allowedHosts,
    required String currentWmappVersion,
    required int nativeBridgeVersion,
  }) {
    final schemaVersion = json['schema_version'];
    if (schemaVersion != 1) {
      throw const FlightDeckCompatibilityException(
        'This update uses an unsupported manifest schema.',
      );
    }
    final buildNumber = json['build_number'];
    final buildId = _requiredString(json, 'build_id');
    final sourceCommit = _requiredString(json, 'source_commit').toLowerCase();
    final builtAtRaw = _requiredString(json, 'built_at');
    final channel = _requiredString(json, 'channel');
    final archive = json['archive'];
    final compatibility = json['compatibility'];
    if (buildNumber is! int ||
        buildNumber < 1 ||
        buildNumber > 9007199254740991) {
      throw const FormatException('Manifest build_number is invalid');
    }
    if (!RegExp(r'^[0-9a-f]{40}([0-9a-f]{24})?$').hasMatch(sourceCommit)) {
      throw const FormatException('Manifest source_commit is invalid');
    }
    final builtAt = DateTime.tryParse(builtAtRaw)?.toUtc();
    if (builtAt == null) {
      throw const FormatException('Manifest built_at is invalid');
    }
    if (archive is! Map<String, dynamic>) {
      throw const FormatException('Manifest archive is invalid');
    }
    if (compatibility is! Map<String, dynamic>) {
      throw const FormatException('Manifest compatibility is invalid');
    }
    if (_requiredString(archive, 'format') != 'tar.gz') {
      throw const FormatException(
          'Only tar.gz Flight Deck archives are supported');
    }
    final archiveUri = Uri.tryParse(_requiredString(archive, 'url'));
    _validateHttpsUri(archiveUri, allowedHosts, label: 'archive');
    if (!archiveUri!.path.endsWith('.tar.gz')) {
      throw const FormatException('Archive URL must identify a tar.gz file');
    }
    final archiveSha256 = _requiredString(archive, 'sha256').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(archiveSha256)) {
      throw const FormatException('Manifest archive SHA-256 is invalid');
    }
    final archiveSizeBytes = archive['size_bytes'];
    if (archiveSizeBytes is! int || archiveSizeBytes < 1) {
      throw const FormatException('Manifest archive size is invalid');
    }
    final minimumWmappVersion = _requiredString(
      compatibility,
      'minimum_wmapp_version',
    );
    final minimumNativeBridgeVersion = compatibility['minimum_native_bridge'];
    if (minimumNativeBridgeVersion is! int || minimumNativeBridgeVersion < 1) {
      throw const FormatException(
          'Manifest native bridge compatibility is invalid');
    }
    if (_compareVersions(currentWmappVersion, minimumWmappVersion) < 0) {
      throw FlightDeckCompatibilityException(
        'Flight Deck $buildNumber needs WMAPP $minimumWmappVersion or newer.',
        version: buildNumber.toString(),
      );
    }
    if (nativeBridgeVersion < minimumNativeBridgeVersion) {
      throw FlightDeckCompatibilityException(
        'Flight Deck $buildNumber needs native bridge $minimumNativeBridgeVersion or newer.',
        version: buildNumber.toString(),
      );
    }
    final notesRaw = json['release_notes_url']?.toString().trim() ?? '';
    final releaseNotesUri = notesRaw.isEmpty ? null : Uri.tryParse(notesRaw);
    if (releaseNotesUri != null) {
      _validateHttpsUri(releaseNotesUri, allowedHosts, label: 'release notes');
    }
    return FlightDeckUpdateManifest(
      schemaVersion: schemaVersion,
      buildNumber: buildNumber,
      buildId: buildId,
      sourceCommit: sourceCommit,
      archiveUri: archiveUri,
      archiveSha256: archiveSha256,
      archiveSizeBytes: archiveSizeBytes,
      builtAt: builtAt,
      minimumWmappVersion: minimumWmappVersion,
      minimumNativeBridgeVersion: minimumNativeBridgeVersion,
      channel: channel,
      releaseNotesUri: releaseNotesUri,
    );
  }

  final int schemaVersion;
  final int buildNumber;
  final String buildId;
  final String sourceCommit;
  final Uri archiveUri;
  final String archiveSha256;
  final int archiveSizeBytes;
  final DateTime builtAt;
  final String minimumWmappVersion;
  final int minimumNativeBridgeVersion;
  final String channel;
  final Uri? releaseNotesUri;

  String get label => 'Build $buildNumber ($buildId)';

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'build_number': buildNumber,
        'build_id': buildId,
        'source_commit': sourceCommit,
        'built_at': builtAt.toIso8601String(),
        'channel': channel,
        'archive': {
          'format': 'tar.gz',
          'url': archiveUri.toString(),
          'sha256': archiveSha256,
          'size_bytes': archiveSizeBytes,
        },
        'compatibility': {
          'minimum_wmapp_version': minimumWmappVersion,
          'minimum_native_bridge': minimumNativeBridgeVersion,
        },
        if (releaseNotesUri != null)
          'release_notes_url': releaseNotesUri.toString(),
      };
}

class FlightDeckCompatibilityException implements Exception {
  const FlightDeckCompatibilityException(this.message, {this.version = ''});

  final String message;
  final String version;

  @override
  String toString() => message;
}

class FlightDeckDownloadedFile {
  const FlightDeckDownloadedFile({
    required this.byteCount,
    required this.sha256,
  });

  final int byteCount;
  final String sha256;
}

abstract class FlightDeckDownloadClient {
  Future<FlightDeckDownloadedFile> download(
    Uri uri,
    File destination, {
    required int maximumBytes,
  });
}

class IoFlightDeckDownloadClient implements FlightDeckDownloadClient {
  IoFlightDeckDownloadClient({
    required Set<String> allowedHosts,
    HttpClient? client,
  })  : _allowedHosts = allowedHosts.map((host) => host.toLowerCase()).toSet(),
        _client = client ?? HttpClient();

  final Set<String> _allowedHosts;
  final HttpClient _client;

  @override
  Future<FlightDeckDownloadedFile> download(
    Uri uri,
    File destination, {
    required int maximumBytes,
  }) async {
    var current = uri;
    for (var redirects = 0; redirects <= 3; redirects++) {
      _validateHttpsUri(
        current,
        _allowedHosts,
        label: 'download',
        allowQuery: redirects > 0,
      );
      final request =
          await _client.getUrl(current).timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || redirects == 3) {
          throw const HttpException('Update download redirect was rejected');
        }
        await response.drain<void>();
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
            'Update download returned HTTP ${response.statusCode}');
      }
      final declaredLength = response.contentLength;
      if (declaredLength > maximumBytes) {
        throw const FileSystemException(
            'Update download exceeds its size limit');
      }
      await destination.parent.create(recursive: true);
      final output = destination.openWrite(mode: FileMode.writeOnly);
      final digestCollector = _DigestCollector();
      final digestInput = sha256.startChunkedConversion(digestCollector);
      var received = 0;
      try {
        await for (final chunk
            in response.timeout(const Duration(seconds: 30))) {
          received += chunk.length;
          if (received > maximumBytes) {
            throw const FileSystemException(
                'Update download exceeds its size limit');
          }
          digestInput.add(chunk);
          output.add(chunk);
        }
        digestInput.close();
        await output.flush();
        await output.close();
      } catch (_) {
        await output.close();
        if (await destination.exists()) await destination.delete();
        rethrow;
      }
      final digest = digestCollector.value;
      if (digest == null) {
        throw const FormatException('Update digest was not produced');
      }
      return FlightDeckDownloadedFile(
        byteCount: received,
        sha256: digest.toString(),
      );
    }
    throw const HttpException('Update download exceeded its redirect limit');
  }
}

abstract class FlightDeckStatePersistence {
  Future<Map<String, dynamic>?> read();

  Future<void> write(Map<String, dynamic> state);
}

class AtomicJsonFlightDeckStatePersistence
    implements FlightDeckStatePersistence {
  AtomicJsonFlightDeckStatePersistence(this.file);

  final File file;

  File get _backup => File('${file.path}.previous');

  @override
  Future<Map<String, dynamic>?> read() async {
    for (final candidate in [file, _backup]) {
      if (!await candidate.exists()) continue;
      try {
        final decoded = jsonDecode(await candidate.readAsString());
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        // Try the recoverable previous pointer below.
      }
    }
    return null;
  }

  @override
  Future<void> write(Map<String, dynamic> state) async {
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.new-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    await temporary.writeAsString('${jsonEncode(state)}\n', flush: true);
    try {
      await temporary.rename(file.path);
      if (await _backup.exists()) await _backup.delete();
      return;
    } on FileSystemException {
      if (!await file.exists()) rethrow;
    }

    if (await _backup.exists()) await _backup.delete();
    await file.rename(_backup.path);
    try {
      await temporary.rename(file.path);
      await _backup.delete();
    } catch (_) {
      if (await file.exists()) await file.delete();
      await _backup.rename(file.path);
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }
}

class IoFlightDeckUpdateController extends FlightDeckUpdateController {
  IoFlightDeckUpdateController({
    required this.rootDirectory,
    required this.feedUri,
    required this.enabled,
    required Set<String> allowedHosts,
    required this.currentWmappVersion,
    required this.nativeBridgeVersion,
    required this.packagedVersionLoader,
    FlightDeckDownloadClient? downloadClient,
    FlightDeckStatePersistence? statePersistence,
    this.maximumManifestBytes = 64 * 1024,
    this.maximumArchiveBytes = 25 * 1024 * 1024,
    this.maximumExpandedTarBytes = 80 * 1024 * 1024,
    this.maximumExtractedBytes = 75 * 1024 * 1024,
    this.maximumFileBytes = 15 * 1024 * 1024,
    this.maximumEntries = 2000,
  })  : allowedHosts = allowedHosts.map((host) => host.toLowerCase()).toSet(),
        _downloadClient = downloadClient ??
            IoFlightDeckDownloadClient(allowedHosts: allowedHosts),
        _statePersistence = statePersistence ??
            AtomicJsonFlightDeckStatePersistence(
              File('${rootDirectory.path}/state.json'),
            ),
        _snapshot = FlightDeckUpdateSnapshot.disabled();

  final Directory rootDirectory;
  final Uri? feedUri;
  final bool enabled;
  final Set<String> allowedHosts;
  final String currentWmappVersion;
  final int nativeBridgeVersion;
  final Future<FlightDeckPackagedVersion> Function() packagedVersionLoader;
  final int maximumManifestBytes;
  final int maximumArchiveBytes;
  final int maximumExpandedTarBytes;
  final int maximumExtractedBytes;
  final int maximumFileBytes;
  final int maximumEntries;
  final FlightDeckDownloadClient _downloadClient;
  final FlightDeckStatePersistence _statePersistence;

  late FlightDeckPackagedVersion _packagedVersion;
  FlightDeckUpdateSnapshot _snapshot;
  _InstalledBuild? _active;
  _InstalledBuild? _previous;
  bool _previousIsPackaged = false;
  FlightDeckUpdateManifest? _available;
  String _failedVersion = '';
  DateTime? _lastCheckAt;
  DateTime? _lastSuccessAt;
  DateTime? _lastFailureAt;
  String _lastError = '';
  bool _busy = false;
  bool _initialized = false;

  Directory get _downloadsDirectory =>
      Directory('${rootDirectory.path}/downloads');
  Directory get _stagingDirectory => Directory('${rootDirectory.path}/staging');
  Directory get _versionsDirectory =>
      Directory('${rootDirectory.path}/versions');

  @override
  FlightDeckUpdateSnapshot get snapshot => _snapshot;

  @override
  String? get activeRootPath => _active == null
      ? null
      : '${_versionsDirectory.path}/${_active!.directoryName}';

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      _packagedVersion = await packagedVersionLoader();
    } catch (_) {
      _packagedVersion = const FlightDeckPackagedVersion(
        buildNumber: 0,
        label: 'packaged',
      );
    }
    await rootDirectory.create(recursive: true);
    await _downloadsDirectory.create(recursive: true);
    await _versionsDirectory.create(recursive: true);
    await _cleanDirectory(_stagingDirectory);
    await _cleanDirectory(_downloadsDirectory);
    final state = await _statePersistence.read();
    if (state != null) _loadState(state);
    final activeValid = await _isInstallValid(_active);
    final previousValid = await _isInstallValid(_previous);
    if (_active != null && !activeValid) {
      _failedVersion = _active!.label;
      _lastFailureAt = DateTime.now().toUtc();
      _lastError =
          'The active downloaded build was invalid and was rolled back.';
      _active = previousValid ? _previous : null;
      _previous = null;
      _previousIsPackaged = _active != null;
      await _persistState();
    } else if (_previous != null && !previousValid) {
      _previous = null;
      _previousIsPackaged = true;
      await _persistState();
    }
    _initialized = true;
    _publish(
      enabled && _validFeedConfiguration
          ? FlightDeckUpdatePhase.idle
          : FlightDeckUpdatePhase.disabled,
      enabled && _validFeedConfiguration
          ? 'Ready to check the verified Flight Deck feed.'
          : 'Packaged Flight Deck only. OTA is disabled or its HTTPS feed is not configured.',
    );
  }

  bool get _validFeedConfiguration {
    final uri = feedUri;
    if (uri == null) return false;
    try {
      _validateHttpsUri(uri, {uri.host.toLowerCase()}, label: 'feed');
      return allowedHosts.contains(uri.host.toLowerCase());
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> checkForUpdates({bool applyAutomatically = false}) async {
    await initialize();
    if (!enabled || !_validFeedConfiguration || _busy) return;
    _busy = true;
    _lastCheckAt = DateTime.now().toUtc();
    _publish(FlightDeckUpdatePhase.checking,
        'Checking for a newer verified build...');
    File? manifestFile;
    FlightDeckUpdateManifest? manifest;
    try {
      manifestFile =
          File('${_downloadsDirectory.path}/${_uniqueName('manifest')}.json');
      await _downloadClient.download(
        feedUri!,
        manifestFile,
        maximumBytes: maximumManifestBytes,
      );
      manifest = FlightDeckUpdateManifest.parse(
        await manifestFile.readAsString(),
        allowedHosts: allowedHosts,
        currentWmappVersion: currentWmappVersion,
        nativeBridgeVersion: nativeBridgeVersion,
      );
      if (manifest.archiveSizeBytes > maximumArchiveBytes) {
        throw const FormatException(
            'Declared archive size exceeds the WMAPP limit');
      }
      if (manifest.buildNumber <= _activeBuildNumber) {
        _available = null;
        _lastError = '';
        await _persistState();
        _publish(
          FlightDeckUpdatePhase.idle,
          'Flight Deck is current. No newer compatible build is available.',
        );
        return;
      }
      _available = manifest;
      _lastError = '';
      await _persistState();
      _publish(
        FlightDeckUpdatePhase.available,
        '${manifest.label} is available and passed compatibility checks.',
      );
      if (applyAutomatically) await _apply(manifest);
    } on FlightDeckCompatibilityException catch (error) {
      _recordFailure(error.version, error.message);
      await _persistState();
      _publish(FlightDeckUpdatePhase.incompatible, error.message);
    } catch (error) {
      _recordFailure(manifest?.label ?? '', _safeError(error));
      await _bestEffortPersist();
      _publish(FlightDeckUpdatePhase.failed,
          'The update check failed. Retry when online.');
    } finally {
      _busy = false;
      if (manifestFile != null && await manifestFile.exists()) {
        await manifestFile.delete();
      }
      _republishBusyState();
    }
  }

  @override
  Future<void> applyAvailable() async {
    await initialize();
    if (_busy || _available == null) return;
    _busy = true;
    try {
      await _apply(_available!);
    } finally {
      _busy = false;
      _republishBusyState();
    }
  }

  Future<void> _apply(FlightDeckUpdateManifest manifest) async {
    File? archiveFile;
    Directory? operationDirectory;
    try {
      _publish(FlightDeckUpdatePhase.downloading,
          'Downloading ${manifest.label}...');
      operationDirectory =
          Directory('${_stagingDirectory.path}/${_uniqueName('install')}');
      await operationDirectory.create(recursive: true);
      archiveFile = File(
          '${_downloadsDirectory.path}/${_uniqueName('flightdeck')}.tar.gz');
      final downloaded = await _downloadClient.download(
        manifest.archiveUri,
        archiveFile,
        maximumBytes: maximumArchiveBytes,
      );
      if (downloaded.byteCount != manifest.archiveSizeBytes) {
        throw const FormatException(
            'Downloaded archive size does not match the manifest');
      }
      if (downloaded.sha256.toLowerCase() != manifest.archiveSha256) {
        throw const FormatException(
            'Downloaded archive checksum does not match the manifest');
      }
      _publish(FlightDeckUpdatePhase.verifying,
          'Verifying and safely extracting ${manifest.label}...');
      final tarFile = File('${operationDirectory.path}/payload.tar');
      await _gunzipBounded(archiveFile, tarFile, maximumExpandedTarBytes);
      final extractedRoot = Directory('${operationDirectory.path}/root');
      await extractedRoot.create();
      await _extractTarSafely(tarFile, extractedRoot);
      final index = File('${extractedRoot.path}/index.html');
      if (!await index.exists() || await index.length() == 0) {
        throw const FormatException(
            'Downloaded Flight Deck is missing index.html');
      }
      await File('${extractedRoot.path}/wmapp-install.json')
          .writeAsString('${jsonEncode(manifest.toJson())}\n', flush: true);
      _publish(FlightDeckUpdatePhase.activating,
          'Activating ${manifest.label} atomically...');
      final installed = _InstalledBuild(
        buildNumber: manifest.buildNumber,
        buildId: manifest.buildId,
        directoryName:
            'build-${manifest.buildNumber}-${manifest.archiveSha256.substring(0, 12)}',
        archiveSha256: manifest.archiveSha256,
      );
      final destination =
          Directory('${_versionsDirectory.path}/${installed.directoryName}');
      if (await destination.exists()) {
        if (!await _isInstallValid(installed)) {
          throw const FileSystemException(
              'An existing install for this version is invalid');
        }
        await extractedRoot.delete(recursive: true);
      } else {
        await extractedRoot.rename(destination.path);
      }
      final oldActive = _active;
      final newPrevious = oldActive;
      final newPreviousIsPackaged = oldActive == null;
      final activatedAt = DateTime.now().toUtc();
      await _writeState(
        active: installed,
        previous: newPrevious,
        previousIsPackaged: newPreviousIsPackaged,
        available: null,
        failedVersion: _failedVersion,
        lastError: '',
        lastCheckAt: _lastCheckAt,
        lastSuccessAt: activatedAt,
        lastFailureAt: _lastFailureAt,
      );
      _active = installed;
      _previous = newPrevious;
      _previousIsPackaged = newPreviousIsPackaged;
      _available = null;
      _lastSuccessAt = activatedAt;
      _lastError = '';
      await _pruneVersions();
      _publish(
        FlightDeckUpdatePhase.active,
        '${manifest.label} is active. Reload the Flight Deck tab to use it.',
      );
    } catch (error) {
      _recordFailure(manifest.label, _safeError(error));
      await _bestEffortPersist();
      _publish(
        FlightDeckUpdatePhase.failed,
        'The downloaded build was not activated. The current Flight Deck remains in use.',
      );
    } finally {
      if (archiveFile != null && await archiveFile.exists()) {
        await archiveFile.delete();
      }
      if (operationDirectory != null && await operationDirectory.exists()) {
        await operationDirectory.delete(recursive: true);
      }
    }
  }

  @override
  Future<void> rollback() async {
    await initialize();
    if (_busy || (_previous == null && !_previousIsPackaged)) return;
    _busy = true;
    _publish(FlightDeckUpdatePhase.rollingBack, 'Rolling back Flight Deck...');
    final oldActive = _active;
    final oldPrevious = _previous;
    final oldPreviousPackaged = _previousIsPackaged;
    try {
      final newActive = oldPreviousPackaged ? null : oldPrevious;
      final rolledBackAt = DateTime.now().toUtc();
      await _writeState(
        active: newActive,
        previous: oldActive,
        previousIsPackaged: false,
        available: _available,
        failedVersion: _failedVersion,
        lastError: '',
        lastCheckAt: _lastCheckAt,
        lastSuccessAt: rolledBackAt,
        lastFailureAt: _lastFailureAt,
      );
      _active = newActive;
      _previous = oldActive;
      _previousIsPackaged = false;
      _lastSuccessAt = rolledBackAt;
      _lastError = '';
      _publish(
        FlightDeckUpdatePhase.active,
        'Rollback complete. Reload the Flight Deck tab to use $_activeLabel.',
      );
    } catch (error) {
      _active = oldActive;
      _previous = oldPrevious;
      _previousIsPackaged = oldPreviousPackaged;
      _recordFailure(oldPrevious?.label ?? 'packaged', _safeError(error));
      await _bestEffortPersist();
      _publish(FlightDeckUpdatePhase.failed,
          'Rollback failed; the current build remains active.');
    } finally {
      _busy = false;
      _republishBusyState();
    }
  }

  @override
  Future<void> reportServeFailure(String message) async {
    if (_active == null || _busy) return;
    final failedVersion = _active!.label;
    final failureAt = DateTime.now().toUtc();
    final error = _safeError(message);
    final oldActive = _active;
    await rollback();
    if (_active != oldActive) {
      _lastError = error;
      _lastFailureAt = failureAt;
      _failedVersion = failedVersion;
      await _bestEffortPersist();
      _publish(
        FlightDeckUpdatePhase.active,
        'The downloaded build could not be served and was rolled back safely.',
      );
    }
  }

  int get _activeBuildNumber =>
      _active?.buildNumber ?? _packagedVersion.buildNumber;

  String get _activeLabel => _active?.label ?? _packagedVersion.label;

  String get _previousLabel {
    if (_previousIsPackaged) return _packagedVersion.label;
    return _previous?.label ?? '';
  }

  void _recordFailure(String version, String error) {
    _failedVersion = version;
    _lastFailureAt = DateTime.now().toUtc();
    _lastError = error;
  }

  void _publish(FlightDeckUpdatePhase phase, String message) {
    _snapshot = FlightDeckUpdateSnapshot(
      phase: phase,
      packagedVersion: _packagedVersion.label,
      activeVersion: _activeLabel,
      previousVersion: _previousLabel,
      availableVersion: _available?.label ?? '',
      failedVersion: _failedVersion,
      message: message,
      error: _lastError,
      lastCheckAt: _lastCheckAt,
      lastSuccessAt: _lastSuccessAt,
      lastFailureAt: _lastFailureAt,
      enabled: enabled && _validFeedConfiguration,
      busy: _busy,
    );
    notifyListeners();
  }

  void _republishBusyState() {
    _snapshot = FlightDeckUpdateSnapshot(
      phase: _snapshot.phase,
      packagedVersion: _snapshot.packagedVersion,
      activeVersion: _snapshot.activeVersion,
      previousVersion: _snapshot.previousVersion,
      availableVersion: _snapshot.availableVersion,
      failedVersion: _snapshot.failedVersion,
      message: _snapshot.message,
      error: _snapshot.error,
      lastCheckAt: _snapshot.lastCheckAt,
      lastSuccessAt: _snapshot.lastSuccessAt,
      lastFailureAt: _snapshot.lastFailureAt,
      enabled: _snapshot.enabled,
      busy: _busy,
    );
    notifyListeners();
  }

  void _loadState(Map<String, dynamic> state) {
    _active = _InstalledBuild.fromJson(state['active']);
    _previous = _InstalledBuild.fromJson(state['previous']);
    _previousIsPackaged = state['previous_is_packaged'] == true;
    _failedVersion = state['failed_version']?.toString() ?? '';
    _lastError = state['last_error']?.toString() ?? '';
    _lastCheckAt = _date(state['last_check_at']);
    _lastSuccessAt = _date(state['last_success_at']);
    _lastFailureAt = _date(state['last_failure_at']);
    final available = state['available_manifest'];
    if (available is Map<String, dynamic>) {
      try {
        _available = FlightDeckUpdateManifest.fromJson(
          available,
          allowedHosts: allowedHosts,
          currentWmappVersion: currentWmappVersion,
          nativeBridgeVersion: nativeBridgeVersion,
        );
      } catch (_) {
        _available = null;
      }
    }
  }

  Future<void> _persistState() {
    return _writeState(
      active: _active,
      previous: _previous,
      previousIsPackaged: _previousIsPackaged,
      available: _available,
      failedVersion: _failedVersion,
      lastError: _lastError,
      lastCheckAt: _lastCheckAt,
      lastSuccessAt: _lastSuccessAt,
      lastFailureAt: _lastFailureAt,
    );
  }

  Future<void> _writeState({
    required _InstalledBuild? active,
    required _InstalledBuild? previous,
    required bool previousIsPackaged,
    required FlightDeckUpdateManifest? available,
    required String failedVersion,
    required String lastError,
    required DateTime? lastCheckAt,
    required DateTime? lastSuccessAt,
    required DateTime? lastFailureAt,
  }) {
    return _statePersistence.write({
      'schema_version': 1,
      'active': active?.toJson(),
      'previous': previous?.toJson(),
      'previous_is_packaged': previousIsPackaged,
      'available_manifest': available?.toJson(),
      'failed_version': failedVersion,
      'last_error': lastError,
      'last_check_at': lastCheckAt?.toIso8601String(),
      'last_success_at': lastSuccessAt?.toIso8601String(),
      'last_failure_at': lastFailureAt?.toIso8601String(),
    });
  }

  Future<void> _bestEffortPersist() async {
    try {
      await _persistState();
    } catch (_) {
      // The in-memory active pointer is deliberately unchanged on failures.
    }
  }

  Future<bool> _isInstallValid(_InstalledBuild? build) async {
    if (build == null) return true;
    final root = Directory('${_versionsDirectory.path}/${build.directoryName}');
    final index = File('${root.path}/index.html');
    final receipt = File('${root.path}/wmapp-install.json');
    if (!await index.exists() ||
        await index.length() == 0 ||
        !await receipt.exists()) {
      return false;
    }
    try {
      final decoded = jsonDecode(await receipt.readAsString());
      return decoded is Map<String, dynamic> &&
          decoded['build_number'] == build.buildNumber &&
          (decoded['archive'] as Map<String, dynamic>?)?['sha256'] ==
              build.archiveSha256;
    } catch (_) {
      return false;
    }
  }

  Future<void> _gunzipBounded(File source, File target, int limit) async {
    final output =
        _BoundedFileByteSink(target.openWrite(mode: FileMode.writeOnly), limit);
    final decoder = gzip.decoder.startChunkedConversion(output);
    try {
      await for (final chunk in source.openRead()) {
        decoder.add(chunk);
      }
      decoder.close();
      await output.done;
    } catch (_) {
      await output.abort();
      if (await target.exists()) await target.delete();
      rethrow;
    }
  }

  Future<void> _extractTarSafely(File tarFile, Directory destination) async {
    final length = await tarFile.length();
    if (length == 0 || length % 512 != 0) {
      throw const FormatException('Archive TAR payload is truncated');
    }
    final input = await tarFile.open();
    final seen = <String>{};
    var entries = 0;
    var extractedBytes = 0;
    var foundTerminator = false;
    try {
      while (await input.position() < length) {
        final header = await input.read(512);
        if (header.length != 512) {
          throw const FormatException('Archive TAR header is truncated');
        }
        if (header.every((byte) => byte == 0)) {
          foundTerminator = true;
          break;
        }
        _verifyTarChecksum(header);
        entries++;
        if (entries > maximumEntries) {
          throw const FormatException('Archive contains too many entries');
        }
        final name = _tarPath(header);
        final normalized = _safeArchivePath(name);
        if (!seen.add(normalized.toLowerCase())) {
          throw const FormatException('Archive contains duplicate paths');
        }
        final type = header[156];
        final size = _tarOctal(header, 124, 12);
        if (type != 0 && type != 48 && type != 53) {
          throw const FormatException(
              'Archive contains a link or unsupported entry');
        }
        if (type == 53 && size != 0) {
          throw const FormatException('Archive directory entry has content');
        }
        if (size > maximumFileBytes) {
          throw const FormatException('Archive contains an oversized file');
        }
        extractedBytes += size;
        if (extractedBytes > maximumExtractedBytes) {
          throw const FormatException(
              'Archive extracted size exceeds the limit');
        }
        final target = _descendant(destination, normalized);
        if (type == 53) {
          await Directory(target).create(recursive: true);
        } else {
          final file = File(target);
          await file.parent.create(recursive: true);
          final output = file.openWrite(mode: FileMode.writeOnly);
          var remaining = size;
          try {
            while (remaining > 0) {
              final chunk = await input.read(min(remaining, 64 * 1024));
              if (chunk.isEmpty) {
                throw const FormatException(
                    'Archive file content is truncated');
              }
              output.add(chunk);
              remaining -= chunk.length;
            }
            await output.flush();
            await output.close();
          } catch (_) {
            await output.close();
            rethrow;
          }
          final padding = (512 - (size % 512)) % 512;
          if (padding > 0) {
            final skipped = await input.read(padding);
            if (skipped.length != padding || skipped.any((byte) => byte != 0)) {
              throw const FormatException('Archive file padding is invalid');
            }
          }
        }
      }
      if (!foundTerminator) {
        throw const FormatException('Archive TAR terminator is missing');
      }
      final remainder = await input.read(length - await input.position());
      if (remainder.any((byte) => byte != 0)) {
        throw const FormatException(
            'Archive contains data after its terminator');
      }
    } finally {
      await input.close();
    }
  }

  Future<void> _pruneVersions() async {
    final keep = <String>{
      if (_active != null) _active!.directoryName,
      if (_previous != null) _previous!.directoryName,
    };
    await for (final entity in _versionsDirectory.list(followLinks: false)) {
      final name =
          entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
      if (entity is Directory && !keep.contains(name)) {
        await entity.delete(recursive: true);
      }
    }
  }

  Future<void> _cleanDirectory(Directory directory) async {
    if (await directory.exists()) await directory.delete(recursive: true);
    await directory.create(recursive: true);
  }

  String _safeError(Object error) {
    var value = error.toString().replaceAll(rootDirectory.path, '[storage]');
    value = value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    if (value.length > 240) value = '${value.substring(0, 237)}...';
    return value;
  }
}

class _InstalledBuild {
  const _InstalledBuild({
    required this.buildNumber,
    required this.buildId,
    required this.directoryName,
    required this.archiveSha256,
  });

  static _InstalledBuild? fromJson(dynamic value) {
    if (value is! Map<String, dynamic>) return null;
    final number = value['build_number'];
    final id = value['build_id']?.toString() ?? '';
    final directory = value['directory']?.toString() ?? '';
    final digest = value['archive_sha256']?.toString() ?? '';
    if (number is! int ||
        number < 1 ||
        id.isEmpty ||
        !RegExp(r'^build-[0-9]+-[0-9a-f]{12}$').hasMatch(directory) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      return null;
    }
    return _InstalledBuild(
      buildNumber: number,
      buildId: id,
      directoryName: directory,
      archiveSha256: digest,
    );
  }

  final int buildNumber;
  final String buildId;
  final String directoryName;
  final String archiveSha256;

  String get label => 'Build $buildNumber ($buildId)';

  Map<String, dynamic> toJson() => {
        'build_number': buildNumber,
        'build_id': buildId,
        'directory': directoryName,
        'archive_sha256': archiveSha256,
      };
}

class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class _BoundedFileByteSink extends ByteConversionSinkBase {
  _BoundedFileByteSink(this._sink, this.maximumBytes);

  final IOSink _sink;
  final int maximumBytes;
  final Completer<void> _done = Completer<void>();
  var _length = 0;
  var _closed = false;

  Future<void> get done => _done.future;

  @override
  void add(List<int> chunk) {
    if (_closed) throw StateError('Decompression output is closed');
    _length += chunk.length;
    if (_length > maximumBytes) {
      throw const FormatException('Expanded archive exceeds the size limit');
    }
    _sink.add(chunk);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_finish());
  }

  Future<void> _finish() async {
    try {
      await _sink.flush();
      await _sink.close();
      if (!_done.isCompleted) _done.complete();
    } catch (error, stackTrace) {
      if (!_done.isCompleted) _done.completeError(error, stackTrace);
    }
  }

  Future<void> abort() async {
    if (!_closed) {
      _closed = true;
      await _sink.close();
    } else {
      try {
        await done;
      } catch (_) {}
    }
  }
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key]?.toString().trim() ?? '';
  if (value.isEmpty) throw FormatException('Manifest $key is missing');
  return value;
}

void _validateHttpsUri(Uri? uri, Set<String> allowedHosts,
    {required String label, bool allowQuery = false}) {
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (!allowQuery && uri.query.isNotEmpty) ||
      !allowedHosts.contains(uri.host.toLowerCase())) {
    throw FormatException('The $label URL is not on an allowed HTTPS host');
  }
}

int _compareVersions(String left, String right) {
  List<int>? parts(String value) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(value.trim());
    if (match == null) return null;
    return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
  }

  final a = parts(left);
  final b = parts(right);
  if (a == null || b == null) {
    throw const FormatException('WMAPP compatibility version is invalid');
  }
  for (var index = 0; index < 3; index++) {
    final comparison = a[index].compareTo(b[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

DateTime? _date(dynamic value) =>
    value == null ? null : DateTime.tryParse(value.toString())?.toUtc();

String _uniqueName(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';

void _verifyTarChecksum(Uint8List header) {
  final declared = _tarOctal(header, 148, 8);
  var actual = 0;
  for (var index = 0; index < header.length; index++) {
    actual += index >= 148 && index < 156 ? 32 : header[index];
  }
  if (declared != actual) {
    throw const FormatException('Archive TAR checksum is invalid');
  }
}

String _tarPath(Uint8List header) {
  final name = _tarString(header, 0, 100);
  final prefix = _tarString(header, 345, 155);
  final path = prefix.isEmpty ? name : '$prefix/$name';
  if (path.isEmpty) throw const FormatException('Archive entry path is empty');
  return path;
}

String _tarString(Uint8List bytes, int offset, int length) {
  final end = bytes.indexOf(0, offset);
  final limit = end < 0 || end > offset + length ? offset + length : end;
  try {
    return utf8.decode(bytes.sublist(offset, limit), allowMalformed: false);
  } catch (_) {
    throw const FormatException('Archive header text is invalid');
  }
}

int _tarOctal(Uint8List bytes, int offset, int length) {
  final value = ascii
      .decode(bytes.sublist(offset, offset + length), allowInvalid: false)
      .replaceAll('\u0000', '')
      .trim();
  if (value.isEmpty || !RegExp(r'^[0-7]+$').hasMatch(value)) {
    throw const FormatException('Archive TAR numeric field is invalid');
  }
  return int.parse(value, radix: 8);
}

String _safeArchivePath(String value) {
  if (value.startsWith('/') || value.startsWith('\\') || value.contains('\\')) {
    throw const FormatException(
        'Archive contains an absolute or backslash path');
  }
  if (RegExp(r'^[A-Za-z]:').hasMatch(value)) {
    throw const FormatException('Archive contains a drive-qualified path');
  }
  final segments = value.split('/');
  if (segments
      .any((segment) => segment.isEmpty || segment == '.' || segment == '..')) {
    throw const FormatException('Archive contains path traversal');
  }
  return segments.join('/');
}

String _descendant(Directory root, String relative) {
  final rootPath = root.absolute.path;
  final target = File('$rootPath/$relative').absolute.path;
  if (!target.startsWith('$rootPath${Platform.pathSeparator}')) {
    throw const FormatException('Archive entry escapes the staging directory');
  }
  return target;
}
