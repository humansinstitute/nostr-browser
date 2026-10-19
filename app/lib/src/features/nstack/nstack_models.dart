import 'dart:convert';

import '../browser/browser_bookmark_store.dart';

const nstackProtocolVersion = 1;
const nstackRecoveryHintKind = 30078;
const nstackRecoveryHintDTag = 'org.wingman.nbrowser.settings.v1';

class NStackWorkspace {
  const NStackWorkspace({
    required this.id,
    required this.name,
    required this.remoteId,
  });

  final String id;
  final String name;
  final String remoteId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'remote_id': remoteId,
      };

  static NStackWorkspace? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final id = _nonEmpty(value['id']);
    final name = _nonEmpty(value['name']);
    final remoteId = _nonEmpty(value['remote_id']);
    if (id == null || name == null || remoteId == null) return null;
    return NStackWorkspace(id: id, name: name, remoteId: remoteId);
  }
}

class NStackBrowserSettings {
  const NStackBrowserSettings({
    this.bookmarks = const [],
    this.background,
    this.labelColour = '#ffffff',
    this.builtInStartup = false,
  });

  final List<BrowserBookmark> bookmarks;
  final String? background;
  final String labelColour;
  final bool builtInStartup;

  NStackBrowserSettings copyWith({
    List<BrowserBookmark>? bookmarks,
    String? background,
    bool clearBackground = false,
    String? labelColour,
    bool? builtInStartup,
  }) {
    return NStackBrowserSettings(
      bookmarks: bookmarks ?? this.bookmarks,
      background: clearBackground ? null : background ?? this.background,
      labelColour: labelColour ?? this.labelColour,
      builtInStartup: builtInStartup ?? this.builtInStartup,
    );
  }

  Map<String, dynamic> toJson() => {
        'bookmarks': [for (final bookmark in bookmarks) bookmark.toJson()],
        'background': background,
        'label_colour': safeLabelColour(labelColour),
        'built_in_startup': builtInStartup,
      };

  static NStackBrowserSettings tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return const NStackBrowserSettings();
    final seen = <String>{};
    final bookmarks = <BrowserBookmark>[];
    final rawBookmarks = value['bookmarks'];
    if (rawBookmarks is List) {
      for (final raw in rawBookmarks) {
        final bookmark = BrowserBookmark.tryParse(raw);
        if (bookmark != null && seen.add(bookmark.url)) bookmarks.add(bookmark);
      }
    }
    return NStackBrowserSettings(
      bookmarks: List.unmodifiable(bookmarks),
      background: safeBookmarkImage(value['background']?.toString()),
      labelColour: safeLabelColour(value['label_colour']?.toString()),
      builtInStartup: value['built_in_startup'] == true,
    );
  }
}

class NStackEntry {
  const NStackEntry({
    required this.id,
    required this.name,
    required this.url,
    this.fipsEndpoint,
    this.peerNpub,
    this.workspaces = const [],
    this.settings = const NStackBrowserSettings(),
  });

  final String id;
  final String name;
  final String url;
  final String? fipsEndpoint;
  final String? peerNpub;
  final List<NStackWorkspace> workspaces;
  final NStackBrowserSettings settings;

  NStackEntry copyWith({
    String? name,
    String? url,
    String? fipsEndpoint,
    bool clearFipsEndpoint = false,
    String? peerNpub,
    bool clearPeerNpub = false,
    List<NStackWorkspace>? workspaces,
    NStackBrowserSettings? settings,
  }) {
    return NStackEntry(
      id: id,
      name: name ?? this.name,
      url: url ?? this.url,
      fipsEndpoint:
          clearFipsEndpoint ? null : fipsEndpoint ?? this.fipsEndpoint,
      peerNpub: clearPeerNpub ? null : peerNpub ?? this.peerNpub,
      workspaces: workspaces ?? this.workspaces,
      settings: settings ?? this.settings,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'fips_endpoint': fipsEndpoint,
        'peer_npub': peerNpub,
        'workspaces': [for (final workspace in workspaces) workspace.toJson()],
        'settings': settings.toJson(),
      };

  static NStackEntry? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final id = _nonEmpty(value['id']);
    final name = _nonEmpty(value['name']);
    final url = canonicalNStackUrl(value['url']?.toString());
    if (id == null || name == null || url == null) return null;
    final fipsEndpoint =
        canonicalFipsEndpoint(value['fips_endpoint']?.toString());
    final peerNpub = _optionalNpub(value['peer_npub']);
    if ((fipsEndpoint == null) != (peerNpub == null)) return null;
    final workspaces = <NStackWorkspace>[];
    final seen = <String>{};
    if (value['workspaces'] is List) {
      for (final raw in value['workspaces'] as List) {
        final workspace = NStackWorkspace.tryParse(raw);
        if (workspace != null && seen.add(workspace.id)) {
          workspaces.add(workspace);
        }
      }
    }
    return NStackEntry(
      id: id,
      name: name,
      url: url,
      fipsEndpoint: fipsEndpoint,
      peerNpub: peerNpub,
      workspaces: List.unmodifiable(workspaces),
      settings: NStackBrowserSettings.tryParse(value['settings']),
    );
  }
}

class NStackRegistry {
  const NStackRegistry({
    this.version = 1,
    this.revision = 0,
    this.activeStackId,
    this.hostStackId,
    this.stacks = const [],
  });

  final int version;
  final int revision;
  final String? activeStackId;
  final String? hostStackId;
  final List<NStackEntry> stacks;

  NStackEntry? get activeStack => _byId(activeStackId);
  NStackEntry? get hostStack => _byId(hostStackId);

  NStackEntry? _byId(String? id) {
    if (id == null) return null;
    for (final stack in stacks) {
      if (stack.id == id) return stack;
    }
    return null;
  }

  NStackRegistry next({
    String? activeStackId,
    bool clearActive = false,
    String? hostStackId,
    bool clearHost = false,
    List<NStackEntry>? stacks,
  }) {
    final nextStacks = stacks ?? this.stacks;
    String? valid(String? value) =>
        nextStacks.any((stack) => stack.id == value) ? value : null;
    return NStackRegistry(
      version: 1,
      revision: revision + 1,
      activeStackId:
          valid(clearActive ? null : activeStackId ?? this.activeStackId),
      hostStackId: valid(clearHost ? null : hostStackId ?? this.hostStackId),
      stacks: List.unmodifiable(nextStacks),
    );
  }

  Map<String, dynamic> toJson() => {
        'schema': 'org.wingman.nbrowser.nstack-registry',
        'version': version,
        'revision': revision,
        'active_stack_id': activeStackId,
        'host_stack_id': hostStackId,
        'stacks': [for (final stack in stacks) stack.toJson()],
      };

  static NStackRegistry? tryParse(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['schema'] != 'org.wingman.nbrowser.nstack-registry' ||
        value['version'] != 1 ||
        value['stacks'] is! List) {
      return null;
    }
    final stacks = <NStackEntry>[];
    final seen = <String>{};
    for (final raw in value['stacks'] as List) {
      final stack = NStackEntry.tryParse(raw);
      if (stack == null || !seen.add(stack.id)) return null;
      stacks.add(stack);
    }
    final active = _nonEmpty(value['active_stack_id']);
    final host = _nonEmpty(value['host_stack_id']);
    if ((active != null && !seen.contains(active)) ||
        (host != null && !seen.contains(host))) {
      return null;
    }
    return NStackRegistry(
      revision: value['revision'] is int ? value['revision'] as int : 0,
      activeStackId: active,
      hostStackId: host,
      stacks: List.unmodifiable(stacks),
    );
  }

  static NStackRegistry? decode(String raw) {
    try {
      return tryParse(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }
}

String? canonicalNStackUrl(String? value) {
  final raw = value?.trim() ?? '';
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  final local = {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
  if (scheme != 'https' && !(scheme == 'http' && local)) return null;
  if (uri.fragment.isNotEmpty || uri.query.isNotEmpty) return null;
  final path = uri.path == '/' ? '' : uri.path.replaceFirst(RegExp(r'/+$'), '');
  return uri
      .replace(scheme: scheme, host: uri.host.toLowerCase(), path: path)
      .toString();
}

String? canonicalFipsEndpoint(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.host.endsWith('.fips') ||
      uri.host.length <= 5 ||
      uri.userInfo.isNotEmpty ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      !uri.hasPort) {
    return null;
  }
  return uri.replace(path: '').toString();
}

String? _nonEmpty(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

String? _optionalNpub(Object? value) {
  final text = _nonEmpty(value);
  if (text == null) return null;
  return RegExp(r'^npub1[023456789acdefghjklmnpqrstuvwxyz]{20,}$')
          .hasMatch(text)
      ? text
      : null;
}
