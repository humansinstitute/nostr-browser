import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../browser/browser_bookmark_store.dart';
import 'nstack_models.dart';

class NStackRegistryStore extends ChangeNotifier {
  NStackRegistryStore({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const keyPrefix = 'wingman.nstack.registry.v1.';
  final SharedPreferencesAsync _preferences;
  final Map<String, NStackRegistry> _cache = {};

  Future<NStackRegistry> load(String signerNpub) async {
    final identity = signerNpub.trim();
    if (identity.isEmpty) return const NStackRegistry();
    final cached = _cache[identity];
    if (cached != null) return cached;
    final raw = await _preferences.getString('$keyPrefix$identity');
    final registry = raw == null
        ? const NStackRegistry()
        : NStackRegistry.decode(raw) ?? const NStackRegistry();
    _cache[identity] = registry;
    return registry;
  }

  Future<void> replaceAtomic(String signerNpub, NStackRegistry registry) async {
    final identity = signerNpub.trim();
    if (identity.isEmpty || registry.version != 1) {
      throw StateError('A valid identity and registry are required.');
    }
    final encoded = jsonEncode(registry.toJson());
    if (NStackRegistry.decode(encoded) == null) {
      throw StateError('Registry failed canonical validation.');
    }
    await _preferences.setString('$keyPrefix$identity', encoded);
    _cache[identity] = registry;
    notifyListeners();
  }

  Future<NStackRegistry> addOrUpdate(
    String signerNpub,
    NStackEntry entry, {
    bool makeActive = false,
    bool makeHost = false,
  }) async {
    final current = await load(signerNpub);
    final nextStacks = [
      for (final stack in current.stacks)
        if (stack.id != entry.id) stack,
      entry,
    ];
    final next = current.next(
      stacks: nextStacks,
      activeStackId: makeActive || current.activeStackId == null
          ? entry.id
          : current.activeStackId,
      hostStackId: makeHost ? entry.id : current.hostStackId,
    );
    await replaceAtomic(signerNpub, next);
    return next;
  }

  Future<NStackRegistry> remove(String signerNpub, String stackId) async {
    final current = await load(signerNpub);
    final nextStacks = current.stacks.where((s) => s.id != stackId).toList();
    final next = current.next(
      stacks: nextStacks,
      clearActive: current.activeStackId == stackId,
      clearHost: current.hostStackId == stackId,
    );
    await replaceAtomic(signerNpub, next);
    return next;
  }

  Future<void> selectActive(String signerNpub, String stackId) async {
    final current = await load(signerNpub);
    if (!current.stacks.any((stack) => stack.id == stackId)) {
      throw StateError('NStack no longer exists.');
    }
    await replaceAtomic(signerNpub, current.next(activeStackId: stackId));
  }

  Future<void> selectHost(String signerNpub, String? stackId) async {
    final current = await load(signerNpub);
    if (stackId != null && !current.stacks.any((s) => s.id == stackId)) {
      throw StateError('NStack no longer exists.');
    }
    await replaceAtomic(
      signerNpub,
      current.next(hostStackId: stackId, clearHost: stackId == null),
    );
  }

  Future<void> updateActiveSettings(
    String signerNpub,
    NStackBrowserSettings Function(NStackBrowserSettings) update,
  ) async {
    final current = await load(signerNpub);
    final active = current.activeStack;
    if (active == null) return;
    final stacks = [
      for (final stack in current.stacks)
        if (stack.id == active.id)
          stack.copyWith(settings: update(stack.settings))
        else
          stack,
    ];
    await replaceAtomic(signerNpub, current.next(stacks: stacks));
  }

  /// Copies legacy v1 launcher settings to the first selected NStack once.
  /// Legacy data is deliberately retained for rollback and never overwritten.
  Future<void> migrateLegacyBrowserSettings(
    String signerNpub, {
    required List<BrowserBookmark> bookmarks,
    String? background,
    String labelColour = '#ffffff',
    bool builtInStartup = false,
  }) async {
    final current = await load(signerNpub);
    final active = current.activeStack;
    if (active == null ||
        active.settings.bookmarks.isNotEmpty ||
        bookmarks.isEmpty &&
            background == null &&
            labelColour == '#ffffff' &&
            !builtInStartup) {
      return;
    }
    await updateActiveSettings(
      signerNpub,
      (_) => NStackBrowserSettings(
        bookmarks: List.unmodifiable(bookmarks),
        background: background,
        labelColour: safeLabelColour(labelColour),
        builtInStartup: builtInStartup,
      ),
    );
  }
}

String newNStackOpaqueId() {
  final random = Random.secure();
  final bytes = List<int>.generate(18, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}
