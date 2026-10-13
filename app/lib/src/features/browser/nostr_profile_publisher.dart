import 'dart:convert';

import '../../core/nostr_crypto.dart';
import 'nostr_profile_relay_client.dart';
import 'nostr_profile_store.dart';

class NostrProfilePublisher {
  NostrProfilePublisher(
      {required this.store, required this.relays, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  final NostrProfileStore store;
  final NostrProfileRelayClient relays;

  Future<ProfilePublishResult> publish({
    required String npub,
    required String secret,
    required NostrProfile profile,
  }) async {
    final publication = await store.preparePublication(
        npub, profile, _clock().millisecondsSinceEpoch ~/ 1000);
    final identity = NostrCrypto.importIdentity(secret);
    if (identity.npub != npub) {
      throw StateError('Unlock the matching identity before publishing.');
    }
    final event = NostrCrypto.signEvent(secret: secret, event: {
      'kind': 0,
      'created_at': publication.createdAt,
      'tags': <List<String>>[],
      'content': jsonEncode(profile.toKind0Json()),
    });
    final result = await relays.publish(event);
    if (result.published) {
      await store.acknowledgePublication(npub, publication);
    }
    return result;
  }
}
