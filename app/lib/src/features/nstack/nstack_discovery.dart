import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'nstack_models.dart';
import 'nstack_store.dart';

const nstackDescriptorPath = '/.well-known/nstack.json';
const nstackDescriptorMaxBytes = 128 * 1024;
const nstackDescriptorTimeout = Duration(seconds: 5);

class NStackDiscoveryException implements Exception {
  const NStackDiscoveryException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => message;
}

class NStackDiscoveryClient {
  NStackDiscoveryClient({
    http.Client? client,
    DateTime Function()? clock,
    this.timeout = nstackDescriptorTimeout,
  })  : _client = client ?? http.Client(),
        _clock = clock ?? DateTime.now;

  final http.Client _client;
  final DateTime Function() _clock;
  final Duration timeout;

  Future<NStackServiceCatalogue> fetch(String configuredUrl) async {
    final configured = canonicalNStackUrl(configuredUrl);
    if (configured == null) {
      throw const NStackDiscoveryException(
          'invalid_origin', 'The configured NStack origin is invalid.');
    }
    final origin = Uri.parse(configured).replace(path: '');
    final abortTrigger = Completer<void>();
    final request = http.AbortableRequest(
        'GET', origin.replace(path: nstackDescriptorPath),
        abortTrigger: abortTrigger.future)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    try {
      final bytes =
          await _readResponse(request).timeout(timeout, onTimeout: () {
        abortTrigger.complete();
        throw TimeoutException('Descriptor request timed out.');
      });
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } catch (_) {
        throw const NStackDiscoveryException(
            'malformed', 'Descriptor is not valid UTF-8 JSON.');
      }
      return validateNStackDescriptor(
        decoded,
        configuredOrigin: origin.toString(),
        fetchedAt: _clock().toUtc(),
      );
    } on NStackDiscoveryException {
      rethrow;
    } on TimeoutException {
      throw const NStackDiscoveryException(
          'timeout', 'Descriptor request timed out.');
    } catch (_) {
      throw const NStackDiscoveryException(
          'network_error', 'Descriptor request failed.');
    }
  }

  Future<List<int>> _readResponse(http.BaseRequest request) async {
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw NStackDiscoveryException('http_error',
          'Descriptor request returned HTTP ${response.statusCode}.');
    }
    final length = response.contentLength;
    if (length != null && length > nstackDescriptorMaxBytes) {
      throw const NStackDiscoveryException(
          'oversized', 'Descriptor exceeds the 128 KiB limit.');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      bytes.addAll(chunk);
      if (bytes.length > nstackDescriptorMaxBytes) {
        throw const NStackDiscoveryException(
            'oversized', 'Descriptor exceeds the 128 KiB limit.');
      }
    }
    return bytes;
  }
}

class NStackDiscoveryService {
  NStackDiscoveryService({
    required this.registryStore,
    NStackDiscoveryClient? client,
    DateTime Function()? clock,
  })  : client = client ?? NStackDiscoveryClient(clock: clock),
        _clock = clock ?? DateTime.now;

  final NStackRegistryStore registryStore;
  final NStackDiscoveryClient client;
  final DateTime Function() _clock;

  Future<NStackEntry> refresh(String identity, String stackId) async {
    final registry = await registryStore.load(identity);
    final stack =
        registry.stacks.where((item) => item.id == stackId).firstOrNull;
    if (stack == null) throw StateError('NStack no longer exists.');
    final now = _clock().toUtc();
    NStackCatalogueStatus status;
    try {
      final catalogue = await client.fetch(stack.url);
      status = NStackCatalogueStatus(checkedAt: now, catalogue: catalogue);
    } on NStackDiscoveryException catch (error) {
      status = NStackCatalogueStatus(
        checkedAt: now,
        catalogue: stack.catalogueStatus?.catalogue,
        errorCode: error.code,
        errorMessage: error.message,
      );
    }
    return registryStore.updateCatalogue(
      identity,
      stackId,
      status,
      expectedUrl: stack.url,
    );
  }
}

NStackServiceCatalogue validateNStackDescriptor(
  Object? value, {
  required String configuredOrigin,
  required DateTime fetchedAt,
}) {
  const rootKeys = {
    'schema',
    'schema_version',
    'generated_at',
    'cache_ttl_seconds',
    'stack',
    'services'
  };
  if (value is! Map<String, dynamic> ||
      !_onlyKeys(value, rootKeys) ||
      value['schema'] != 'org.wingman.nstack.services' ||
      value['schema_version'] != 1 ||
      value['stack'] is! Map<String, dynamic> ||
      value['services'] is! List) {
    throw const NStackDiscoveryException(
        'malformed', 'Descriptor schema v1 is invalid.');
  }
  final generatedAt =
      DateTime.tryParse(value['generated_at']?.toString() ?? '')?.toUtc();
  final ttlRaw = value['cache_ttl_seconds'];
  final servicesRaw = value['services'] as List;
  final stackRaw = value['stack'] as Map<String, dynamic>;
  if (generatedAt == null ||
      generatedAt.isAfter(fetchedAt.toUtc().add(const Duration(minutes: 5))) ||
      ttlRaw is! int ||
      ttlRaw < 1 ||
      ttlRaw > 86400 ||
      servicesRaw.length > 32 ||
      !_onlyKeys(stackRaw, const {'tower_npub', 'name'})) {
    throw const NStackDiscoveryException(
        'malformed', 'Descriptor metadata is invalid.');
  }
  final towerNpub = stackRaw['tower_npub'];
  final stackName = stackRaw['name'];
  if ((towerNpub != null && !_validNpub(towerNpub)) ||
      (stackName != null && !_validString(stackName, 1, 128))) {
    throw const NStackDiscoveryException(
        'malformed', 'Descriptor stack metadata is invalid.');
  }

  final configured = Uri.parse(configuredOrigin);
  final services = <NStackService>[];
  final seen = <String>{};
  for (final raw in servicesRaw) {
    if (raw is! Map<String, dynamic> ||
        !_onlyKeys(raw, const {
          'id',
          'kind',
          'endpoint',
          'version',
          'protocols',
          'capabilities',
          'features',
          'availability'
        })) {
      throw const NStackDiscoveryException(
          'malformed', 'A service entry is invalid.');
    }
    final id = raw['id'];
    final kind = raw['kind'];
    final endpointText = raw['endpoint'];
    final version = raw['version'];
    if (!_validString(id, 1, 64) ||
        !_validString(kind, 1, 64) ||
        !_validString(endpointText, 1, 2048) ||
        !_validString(version, 1, 128) ||
        !seen.add(id as String)) {
      throw const NStackDiscoveryException(
          'malformed', 'Service identity fields are invalid or duplicated.');
    }
    final protocols = _stringList(raw['protocols'], 32, 64);
    final capabilities = _stringList(raw['capabilities'], 64, 128);
    final features = raw['features'];
    final availability = raw['availability'];
    if (protocols == null ||
        capabilities == null ||
        features is! Map<String, dynamic> ||
        !_onlyKeys(features, const {'nips', 'buds'}) ||
        availability is! Map<String, dynamic> ||
        !_onlyKeys(availability, const {'status', 'checked_at'})) {
      throw const NStackDiscoveryException(
          'malformed', 'Service metadata is invalid.');
    }
    final nips = _intList(features['nips'], 64);
    final buds = _intList(features['buds'], 64);
    final status = NStackServiceAvailability.values
        .where((item) => item.name == availability['status'])
        .firstOrNull;
    final checkedAt = availability['checked_at'] == null
        ? null
        : DateTime.tryParse(availability['checked_at'].toString())?.toUtc();
    if (nips == null ||
        buds == null ||
        status == null ||
        (availability['checked_at'] != null && checkedAt == null) ||
        (checkedAt != null &&
            checkedAt
                .isAfter(fetchedAt.toUtc().add(const Duration(minutes: 5))))) {
      throw const NStackDiscoveryException(
          'malformed', 'Service features or availability are invalid.');
    }
    final endpoint = _serviceOrigin(endpointText as String);
    if (endpoint == null) {
      throw const NStackDiscoveryException(
          'invalid_origin', 'A service endpoint is not a safe root origin.');
    }
    final known = switch (id) {
      'tower' => kind == 'tower' &&
          _isHttpOrigin(endpoint) &&
          _sameOrigin(endpoint, configured),
      'relay' => kind == 'nostr_relay' && _isWebSocketOrigin(endpoint),
      'blossom' => kind == 'blossom' && _isHttpOrigin(endpoint),
      _ => false,
    };
    if ({'tower', 'relay', 'blossom'}.contains(id) && !known) {
      throw const NStackDiscoveryException(
          'invalid_origin', 'A known service kind or origin is inconsistent.');
    }
    services.add(NStackService(
      id: id,
      kind: kind as String,
      endpoint: endpoint.toString(),
      version: version as String,
      protocols: List.unmodifiable(protocols),
      capabilities: List.unmodifiable(capabilities),
      nips: List.unmodifiable(nips),
      buds: List.unmodifiable(buds),
      availability: status,
      checkedAt: checkedAt,
      actionable: known,
    ));
  }
  return NStackServiceCatalogue(
    generatedAt: generatedAt,
    fetchedAt: fetchedAt.toUtc(),
    cacheTtlSeconds: ttlRaw.clamp(5, 3600),
    towerNpub: towerNpub as String?,
    stackName: stackName as String?,
    services: List.unmodifiable(services),
  );
}

bool _onlyKeys(Map<String, dynamic> map, Set<String> allowed) =>
    map.keys.every(allowed.contains);

bool _validString(Object? value, int minimum, int maximum) =>
    value is String &&
    value.length >= minimum &&
    value.length <= maximum &&
    value.trim() == value &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

bool _validNpub(Object? value) =>
    value is String &&
    RegExp(r'^npub1[023456789acdefghjklmnpqrstuvwxyz]{20,}$').hasMatch(value) &&
    value.length <= 128;

List<String>? _stringList(Object? value, int maximumItems, int maximumLength) {
  if (value is! List || value.length > maximumItems) return null;
  final result = <String>[];
  final seen = <String>{};
  for (final item in value) {
    if (!_validString(item, 1, maximumLength) || !seen.add(item as String)) {
      return null;
    }
    result.add(item);
  }
  return result;
}

List<int>? _intList(Object? value, int maximumItems) {
  if (value == null) return const [];
  if (value is! List || value.length > maximumItems) return null;
  final result = <int>[];
  final seen = <int>{};
  for (final item in value) {
    if (item is! int || item < 1 || item > 65535 || !seen.add(item)) {
      return null;
    }
    result.add(item);
  }
  return result;
}

Uri? _serviceOrigin(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final local = {'localhost', '127.0.0.1', '::1'}.contains(host);
  final allowed = uri.scheme == 'https' ||
      uri.scheme == 'wss' ||
      (local && (uri.scheme == 'http' || uri.scheme == 'ws'));
  if (!allowed) return null;
  return uri.replace(host: host, path: '');
}

bool _isHttpOrigin(Uri uri) => uri.scheme == 'https' || uri.scheme == 'http';
bool _isWebSocketOrigin(Uri uri) => uri.scheme == 'wss' || uri.scheme == 'ws';

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme == right.scheme &&
    left.host == right.host &&
    left.port == right.port;

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
