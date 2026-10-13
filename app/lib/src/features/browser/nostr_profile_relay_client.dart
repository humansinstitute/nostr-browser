import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'nostr_profile_store.dart';

class NostrProfileRelayClient {
  NostrProfileRelayClient({
    List<String> relays = defaultProfileRelays,
    this.timeout = const Duration(seconds: 5),
  }) : relays = _normalizeRelays(relays);

  static const defaultProfileRelays = [
    'wss://relay.damus.io',
    'wss://relay.primal.net',
  ];

  final List<String> relays;
  final Duration timeout;

  /// Only an OK for this exact event with accepted=true counts as publication.
  Future<ProfilePublishResult> publish(Map<String, dynamic> event) async {
    final accepted = await Future.wait(relays.map((relay) async {
      WebSocketChannel? channel;
      StreamSubscription<dynamic>? subscription;
      try {
        channel = WebSocketChannel.connect(Uri.parse(relay));
        final ack = Completer<bool>();
        subscription = channel.stream.listen((message) {
          try {
            final data = jsonDecode(message as String);
            if (data is List &&
                data.length >= 3 &&
                data[0] == 'OK' &&
                data[1] == event['id'] &&
                !ack.isCompleted) {
              ack.complete(data[2] == true);
            }
          } catch (_) {/* Ignore unrelated or malformed relay frames. */}
        }, onError: (_) {
          if (!ack.isCompleted) ack.complete(false);
        }, onDone: () {
          if (!ack.isCompleted) ack.complete(false);
        });
        await channel.ready.timeout(timeout);
        channel.sink.add(jsonEncode(['EVENT', event]));
        return await ack.future.timeout(timeout, onTimeout: () => false);
      } catch (_) {
        return false;
      } finally {
        await subscription?.cancel();
        try {
          await channel?.sink.close().timeout(timeout);
        } catch (_) {}
      }
    }));
    return ProfilePublishResult(
      acceptedRelays: [
        for (var i = 0; i < relays.length; i++)
          if (accepted[i]) relays[i]
      ],
      totalRelays: relays.length,
    );
  }

  Future<NostrProfileRelayResult?> fetchProfile(String publicKeyHex) async {
    final trimmed = publicKeyHex.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(trimmed) || relays.isEmpty) {
      return null;
    }
    final results = await Future.wait(
      relays.map((relay) => _fetchFromRelay(relay, trimmed)),
    );
    NostrProfileRelayResult? latest;
    for (final result in results.whereType<NostrProfileRelayResult>()) {
      if (latest == null || result.createdAt > latest.createdAt) {
        latest = result;
      }
    }
    return latest;
  }

  Future<NostrProfileRelayResult?> _fetchFromRelay(
    String relay,
    String publicKeyHex,
  ) async {
    WebSocketChannel? channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(relay));
      final subId = 'wmapp-profile-${DateTime.now().microsecondsSinceEpoch}';
      final completer = Completer<NostrProfileRelayResult?>();
      Timer? timer;
      StreamSubscription<dynamic>? subscription;

      void complete(NostrProfileRelayResult? result) {
        if (completer.isCompleted) return;
        timer?.cancel();
        unawaited(subscription?.cancel());
        try {
          channel?.sink.add(jsonEncode(['CLOSE', subId]));
        } catch (_) {}
        unawaited(channel?.sink.close());
        completer.complete(result);
      }

      timer = Timer(timeout, () => complete(null));
      subscription = channel.stream.listen(
        (message) {
          final result = _parseRelayMessage(
            message,
            subId: subId,
            publicKeyHex: publicKeyHex,
          );
          if (result != null) complete(result);
        },
        onError: (_) => complete(null),
        onDone: () => complete(null),
        cancelOnError: true,
      );

      channel.sink.add(
        jsonEncode([
          'REQ',
          subId,
          {
            'kinds': [0],
            'authors': [publicKeyHex],
            'limit': 1,
          },
        ]),
      );

      return await completer.future;
    } catch (_) {
      try {
        await channel?.sink.close().timeout(timeout);
      } catch (_) {}
      return null;
    }
  }

  NostrProfileRelayResult? _parseRelayMessage(
    dynamic message, {
    required String subId,
    required String publicKeyHex,
  }) {
    if (message is! String) return null;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! List || decoded.length < 3) return null;
      if (decoded[0] != 'EVENT' || decoded[1] != subId) return null;
      final event = decoded[2];
      if (event is! Map<String, dynamic>) return null;
      if (event['kind'] != 0) return null;
      if (event['pubkey']?.toString().toLowerCase() != publicKeyHex) {
        return null;
      }
      final createdAt = event['created_at'] is int
          ? event['created_at'] as int
          : int.tryParse(event['created_at']?.toString() ?? '') ?? 0;
      final profile = NostrProfile.fromKind0Content(
        event['content']?.toString() ?? '',
      );
      if (profile == null) return null;
      return NostrProfileRelayResult(
        profile: profile,
        createdAt: createdAt,
      );
    } catch (_) {
      return null;
    }
  }

  static List<String> _normalizeRelays(List<String> values) {
    return {
      for (final value in values)
        if (_isRelayUrl(value)) value.trim(),
    }.toList(growable: false);
  }

  static bool _isRelayUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        (uri.scheme == 'wss' || uri.scheme == 'ws') &&
        uri.host.isNotEmpty;
  }
}

class NostrProfileRelayResult {
  const NostrProfileRelayResult({
    required this.profile,
    required this.createdAt,
  });

  final NostrProfile profile;
  final int createdAt;
}

class ProfilePublishResult {
  const ProfilePublishResult(
      {required this.acceptedRelays, required this.totalRelays});
  final List<String> acceptedRelays;
  final int totalRelays;
  bool get published => acceptedRelays.isNotEmpty;
  String get message => published
      ? 'Published: ${acceptedRelays.length}/$totalRelays relays accepted your profile. '
          '${acceptedRelays.join(', ')}'
      : 'Draft saved on this device. No relay confirmed publication. Check your connection and retry.';
}
