import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NostrProfileStore {
  NostrProfileStore({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const _profileKeyPrefix = 'wingman.nostr.profile.v1.';

  final SharedPreferencesAsync _preferences;

  Future<NostrProfile> load(String npub) async {
    final key = _keyFor(npub);
    if (key == null) return const NostrProfile();
    final raw = await _preferences.getString(key);
    return NostrProfile.tryParse(raw) ?? const NostrProfile();
  }

  // Serialize read/modify/write operations across store instances per identity.
  static final Map<String, Future<void>> _writes = {};

  Future<NostrProfile> save(String npub, NostrProfile profile) =>
      _mutate(npub, (state) async {
        _setDraft(state, profile);
        return profile;
      });

  /// Atomically save this draft and reserve its event timestamp before signing.
  Future<ProfilePublication> preparePublication(
          String npub, NostrProfile profile, int nowSeconds) =>
      _mutate(npub, (state) async {
        final last = _timestamp(state, 'last_publish_created_at');
        final remote = _timestamp(state, 'remote_created_at');
        var createdAt = nowSeconds;
        if (createdAt <= last) createdAt = last + 1;
        if (createdAt <= remote) createdAt = remote + 1;
        _setDraft(state, profile);
        state['last_publish_created_at'] = createdAt;
        return ProfilePublication(
            revision: state['draft_revision'] as int, createdAt: createdAt);
      });

  Future<void> acknowledgePublication(
          String npub, ProfilePublication publication) =>
      _mutate(npub, (state) async {
        if (publication.createdAt > _timestamp(state, 'published_created_at')) {
          state['published_created_at'] = publication.createdAt;
        }
        // A delayed OK must never mark a subsequent edit as published.
        if (state['draft_revision'] == publication.revision &&
            state['last_publish_created_at'] == publication.createdAt) {
          state['local_edit'] = false;
        }
      });

  Future<NostrProfile> saveRemote(String npub, NostrProfile profile,
          {required int createdAt}) =>
      _mutate(npub, (state) async {
        // Legacy records without authorship metadata are unsent drafts.
        if (state.isNotEmpty && state['local_edit'] != false ||
            createdAt <= _timestamp(state, 'published_created_at') ||
            createdAt <= _timestamp(state, 'remote_created_at')) {
          return NostrProfile.tryParse(jsonEncode(state)) ??
              const NostrProfile();
        }
        final cached = await _withCachedAvatar(profile);
        state.addAll(cached.toJson());
        state['local_edit'] = false;
        state['remote_created_at'] = createdAt;
        return cached;
      });

  static int _timestamp(Map<String, dynamic> state, String key) =>
      state[key] is int ? state[key] as int : 0;

  void _setDraft(Map<String, dynamic> state, NostrProfile profile) {
    final revision = _timestamp(state, 'draft_revision') + 1;
    state.addAll(profile.toJson());
    state['local_edit'] = true;
    state['draft_revision'] = revision;
  }

  Future<T> _mutate<T>(
      String npub, Future<T> Function(Map<String, dynamic>) update) async {
    final key = _keyFor(npub);
    if (key == null) {
      throw StateError('An identity is required to save a profile.');
    }
    final previous = _writes[key] ?? Future<void>.value();
    final done = Completer<void>();
    _writes[key] = done.future;
    await previous;
    try {
      final raw = await _preferences.getString(key);
      final state = raw == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final result = await update(state);
      await _preferences.setString(key, jsonEncode(state));
      return result;
    } finally {
      done.complete();
      if (identical(_writes[key], done.future)) _writes.remove(key);
    }
  }

  String? _keyFor(String npub) {
    final normalized = npub.trim();
    if (normalized.isEmpty) return null;
    return '$_profileKeyPrefix$normalized';
  }

  Future<NostrProfile> _withCachedAvatar(NostrProfile profile) async {
    final avatarUrl = profile.avatarUrl;
    if (avatarUrl.isEmpty) {
      return profile.copyWithCachedAvatar(url: '', base64: '');
    }
    if (profile.cachedPictureUrl == avatarUrl &&
        profile.cachedPictureBase64.isNotEmpty) {
      return profile;
    }
    try {
      final data = await NetworkAssetBundle(Uri.parse(avatarUrl))
          .load(avatarUrl)
          .timeout(const Duration(seconds: 6));
      if (data.lengthInBytes > 1500000) return profile;
      final bytes = Uint8List.view(
        data.buffer,
        data.offsetInBytes,
        data.lengthInBytes,
      );
      return profile.copyWithCachedAvatar(
        url: avatarUrl,
        base64: base64Encode(bytes),
      );
    } catch (_) {
      return profile.copyWithCachedAvatar(url: '', base64: '');
    }
  }
}

class ProfilePublication {
  const ProfilePublication({required this.revision, required this.createdAt});
  final int revision;
  final int createdAt;
}

class NostrProfile {
  const NostrProfile({
    this.displayName = '',
    this.name = '',
    this.pictureUrl = '',
    this.nip05 = '',
    this.website = '',
    this.about = '',
    this.cachedPictureUrl = '',
    this.cachedPictureBase64 = '',
  });

  final String displayName;
  final String name;
  final String pictureUrl;
  final String nip05;
  final String website;
  final String about;
  final String cachedPictureUrl;
  final String cachedPictureBase64;

  String labelFor(String npub) {
    final primary = displayName.trim();
    if (primary.isNotEmpty) return primary;
    final secondary = name.trim();
    if (secondary.isNotEmpty) return secondary;
    return 'Profile';
  }

  String get avatarUrl {
    final value = pictureUrl.trim();
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    return value;
  }

  Uint8List? get cachedAvatarBytes {
    if (cachedPictureUrl.trim() != avatarUrl || cachedPictureBase64.isEmpty) {
      return null;
    }
    try {
      return base64Decode(cachedPictureBase64);
    } catch (_) {
      return null;
    }
  }

  NostrProfile copyWith({
    String? displayName,
    String? name,
    String? pictureUrl,
    String? nip05,
    String? website,
    String? about,
  }) {
    return NostrProfile(
      displayName: displayName ?? this.displayName,
      name: name ?? this.name,
      pictureUrl: pictureUrl ?? this.pictureUrl,
      nip05: nip05 ?? this.nip05,
      website: website ?? this.website,
      about: about ?? this.about,
      cachedPictureUrl: cachedPictureUrl,
      cachedPictureBase64: cachedPictureBase64,
    );
  }

  NostrProfile copyWithCachedAvatar({
    required String url,
    required String base64,
  }) {
    return NostrProfile(
      displayName: displayName,
      name: name,
      pictureUrl: pictureUrl,
      nip05: nip05,
      website: website,
      about: about,
      cachedPictureUrl: url,
      cachedPictureBase64: base64,
    );
  }

  Map<String, dynamic> toKind0Json() {
    return {
      if (name.trim().isNotEmpty) 'name': name.trim(),
      if (displayName.trim().isNotEmpty) 'display_name': displayName.trim(),
      if (pictureUrl.trim().isNotEmpty) 'picture': pictureUrl.trim(),
      if (nip05.trim().isNotEmpty) 'nip05': nip05.trim(),
      if (website.trim().isNotEmpty) 'website': website.trim(),
      if (about.trim().isNotEmpty) 'about': about.trim(),
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'version': 1,
      'display_name': displayName,
      'name': name,
      'picture_url': pictureUrl,
      'nip05': nip05,
      'website': website,
      'about': about,
      'cached_picture_url': cachedPictureUrl,
      'cached_picture_base64': cachedPictureBase64,
      'kind0_content': toKind0Json(),
    };
  }

  static NostrProfile? tryParse(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) return null;
      return NostrProfile(
        displayName: decoded['display_name']?.toString() ?? '',
        name: decoded['name']?.toString() ?? '',
        pictureUrl: decoded['picture_url']?.toString() ??
            decoded['picture']?.toString() ??
            '',
        nip05: decoded['nip05']?.toString() ?? '',
        website: decoded['website']?.toString() ?? '',
        about: decoded['about']?.toString() ?? '',
        cachedPictureUrl: decoded['cached_picture_url']?.toString() ?? '',
        cachedPictureBase64: decoded['cached_picture_base64']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  static NostrProfile? fromKind0Content(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) return null;
      final displayName = decoded['display_name']?.toString() ??
          decoded['displayName']?.toString() ??
          '';
      final pictureUrl = decoded['picture']?.toString() ??
          decoded['image']?.toString() ??
          decoded['avatar']?.toString() ??
          '';
      return NostrProfile(
        displayName: displayName,
        name: decoded['name']?.toString() ?? '',
        pictureUrl: pictureUrl,
        nip05: decoded['nip05']?.toString() ?? '',
        website: decoded['website']?.toString() ?? '',
        about: decoded['about']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}
