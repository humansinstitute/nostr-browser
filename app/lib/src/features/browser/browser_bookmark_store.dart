import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class BrowserBookmark {
  const BrowserBookmark(
      {required this.title,
      required this.url,
      this.iconUrl,
      this.customImage,
      this.startup = false});

  final String title;
  final String url;
  final String? iconUrl;
  final String? customImage;
  final bool startup;

  String? get thumbnail => customImage ?? iconUrl ?? bookmarkFaviconUrl(url);

  BrowserBookmark renamed(String value) {
    final normalized = value.trim();
    return BrowserBookmark(
      title: normalized.isEmpty ? title : normalized,
      url: url,
      iconUrl: iconUrl,
      customImage: customImage,
      startup: startup,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        'iconUrl': iconUrl,
        'customImage': customImage,
        'startup': startup
      };

  static BrowserBookmark? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final canonicalUrl = canonicalBrowserBookmarkUrl(value['url']?.toString());
    if (canonicalUrl == null) return null;
    final rawTitle = value['title']?.toString().trim() ?? '';
    return BrowserBookmark(
      title: rawTitle.isEmpty ? Uri.parse(canonicalUrl).host : rawTitle,
      url: canonicalUrl,
      iconUrl: safeBookmarkIconUrl(value['iconUrl']?.toString()),
      customImage: safeBookmarkImage(value['customImage']?.toString()),
      startup: value['startup'] == true,
    );
  }
}

/// Returns a conservative duplicate key for an HTTP(S) page.
///
/// Only surrounding whitespace plus scheme/host casing are normalized. Paths,
/// trailing slashes, query strings, and fragments remain distinct because they
/// can identify meaningful application routes.
String? canonicalBrowserBookmarkUrl(String? value) {
  final trimmed = value?.trim() ?? '';
  final uri = Uri.tryParse(trimmed);
  final scheme = uri?.scheme.toLowerCase();
  if (uri == null ||
      (scheme != 'http' && scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      RegExp(r'\s').hasMatch(trimmed)) {
    return null;
  }
  return uri.replace(scheme: scheme, host: uri.host.toLowerCase()).toString();
}

class BrowserBookmarkStore {
  BrowserBookmarkStore({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const keyPrefix = 'wingman.browser.bookmarks.v1.';
  final SharedPreferencesAsync _preferences;

  Future<List<BrowserBookmark>> load(String signerNpub) async {
    final key = _storageKey(signerNpub);
    if (key == null) return const [];
    final raw = await _preferences.getString(key);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['bookmarks'] is! List) {
        return const [];
      }
      final seen = <String>{};
      final bookmarks = <BrowserBookmark>[];
      for (final value in decoded['bookmarks'] as List<dynamic>) {
        final bookmark = BrowserBookmark.tryParse(value);
        if (bookmark != null && seen.add(bookmark.url)) bookmarks.add(bookmark);
      }
      return bookmarks;
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(
    String signerNpub,
    List<BrowserBookmark> bookmarks,
  ) async {
    final key = _storageKey(signerNpub);
    if (key == null) return;
    await _preferences.setString(
      key,
      jsonEncode({
        'version': 1,
        'bookmarks': [for (final bookmark in bookmarks) bookmark.toJson()],
      }),
    );
  }

  Future<String?> loadBackground(String signerNpub) async {
    final key = _storageKey(signerNpub);
    return key == null
        ? null
        : safeBookmarkImage(await _preferences.getString('$key.background'));
  }

  Future<void> saveBackground(String signerNpub, String? image) async {
    final key = _storageKey(signerNpub);
    if (key == null) return;
    if (image == null) {
      await _preferences.remove('$key.background');
    } else if (safeBookmarkImage(image) != null) {
      await _preferences.setString('$key.background', image);
    }
  }

  Future<String> loadLabelColour(String signerNpub) async {
    final key = _storageKey(signerNpub);
    return safeLabelColour(
        key == null ? null : await _preferences.getString('$key.labelColour'));
  }

  Future<void> saveLabelColour(String signerNpub, String colour) async {
    final key = _storageKey(signerNpub);
    if (key != null) {
      await _preferences.setString('$key.labelColour', safeLabelColour(colour));
    }
  }

  Future<bool> loadBuiltInStartup(String signerNpub) async {
    final key = _storageKey(signerNpub);
    return key != null &&
        await _preferences.getBool('$key.builtInStartup.v1') == true;
  }

  Future<void> saveBuiltInStartup(String signerNpub, bool enabled) async {
    final key = _storageKey(signerNpub);
    if (key != null) {
      await _preferences.setBool('$key.builtInStartup.v1', enabled);
    }
  }

  String? _storageKey(String signerNpub) {
    final normalized = signerNpub.trim();
    return normalized.isEmpty ? null : '$keyPrefix$normalized';
  }
}

// Decorative metadata never supplies a navigation URL or transport grant.
String? safeBookmarkIconUrl(String? value) {
  final url = canonicalBrowserBookmarkUrl(value);
  if (url == null) return null;
  final uri = Uri.parse(url);
  if (uri.host.endsWith('.fips') || uri.host == 'fips') return null;
  if (uri.scheme == 'http' &&
      !['localhost', '127.0.0.1', '::1'].contains(uri.host)) {
    return null;
  }
  return url;
}

String? bookmarkFaviconUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri == null ? null : safeBookmarkIconUrl('${uri.origin}/favicon.ico');
}

String? safeBookmarkImage(String? value) {
  if (value == null ||
      !value.startsWith('data:image/png;base64,') ||
      value.length > 2800000) {
    return null;
  }
  try {
    final bytes = base64Decode(value.substring(22));
    if (bytes.length < 8 ||
        bytes.take(8).join(',') != '137,80,78,71,13,10,26,10') {
      return null;
    }
    return value;
  } catch (_) {
    return null;
  }
}

/// Reject conflicts instead of silently merging or dropping another saved app.
String? bookmarkEditError(List<BrowserBookmark> bookmarks,
    BrowserBookmark original, String title, String url,
    {String? reservedUrl}) {
  if (title.trim().isEmpty) return 'Enter an app name.';
  final canonical = canonicalBrowserBookmarkUrl(url);
  if (canonical == null) {
    return 'Enter a complete HTTP or HTTPS URL without credentials or spaces.';
  }
  if (canonical == reservedUrl ||
      bookmarks.any((b) => b.url != original.url && b.url == canonical)) {
    return 'An app with this launch URL is already saved.';
  }
  return null;
}

/// Only opaque six-digit RGB values may enter launcher CSS.
String safeLabelColour(String? value) =>
    value != null && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)
        ? value.toLowerCase()
        : '#ffffff';
