import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../core/app_config.dart';
import '../../core/tower_fips_proxy.dart';
import '../../core/fips_app_target.dart';
import '../../core/fips_runtime_service.dart';
import '../../core/native_core_bridge.dart';
import '../../core/nostr_crypto.dart';
import '../../core/signer_vault.dart';
import 'embedded_content_focus.dart';
import 'focus_edge_gestures.dart';
import 'diagnostics_store.dart';
import 'relay_diagnostics.dart';
import 'profile_avatar_upload.dart';
import 'profile_key_export_dialog.dart';
import 'browser_bookmark_store.dart';
import 'bookmark_editor.dart';
import 'browser_app_selector.dart';
import 'nostr_profile_publisher.dart';
import 'nostr_profile_relay_client.dart';
import 'nostr_profile_store.dart';
import 'signer_policy.dart';
import 'mesh_auth_request.dart';
import 'signer_store.dart';
import 'webview_file_picker.dart';
import 'grasp_fips_browser_bridge.dart';
import 'grasp_android_channel.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({
    required this.config,
    required this.bridge,
    required this.signerStore,
    required this.onOpenDrawer,
    required this.onOpenSetup,
    required this.onOpenSigner,
    required this.onOpenStatus,
    this.localFlightDeckUrl = '',
    this.onBookmarkMenuStateChanged,
    this.onFocusModeChanged,
    this.onPrepareFipsNavigation,
    this.fipsRuntime,
    this.onLogOut,
    this.onOpenIdentity,
    this.profileRelayClient,
    this.signerVault,
    this.towerProxyFactory,
    super.key,
  });

  final AppConfig config;
  final NativeCoreBridge bridge;
  final SignerStore signerStore;
  final VoidCallback onOpenDrawer;
  final VoidCallback onOpenSetup;
  final VoidCallback onOpenSigner;
  final VoidCallback onOpenStatus;
  final String localFlightDeckUrl;
  final ValueChanged<BrowserBookmarkMenuState>? onBookmarkMenuStateChanged;
  final ValueChanged<bool>? onFocusModeChanged;
  final Future<String?> Function(String url)? onPrepareFipsNavigation;
  final FipsRuntimeService? fipsRuntime;
  final VoidCallback? onLogOut;
  final VoidCallback? onOpenIdentity;
  final NostrProfileRelayClient? profileRelayClient;
  final SignerVault? signerVault;
  // Native dependency injection for socket-backed integration tests, never JS.
  @visibleForTesting
  final Future<TowerFipsProxy> Function(String endpoint, String pageOrigin)?
      towerProxyFactory;

  @override
  State<BrowserScreen> createState() => BrowserScreenState();
}

class BrowserScreenState extends State<BrowserScreen>
    with WidgetsBindingObserver {
  static final Set<Factory<OneSequenceGestureRecognizer>>
      _androidWebViewGestureRecognizers = {
    const Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
  };
  final List<BrowserTab> _tabs = [];
  final ScrollController _tabStripController = ScrollController();
  double _tabItemExtent = 194;
  int _activeTabId = 0;
  int _nextTabId = 1;
  Timer? _addressBarHideTimer;
  int _addressBarHideGeneration = 0;
  bool _addressBarVisible = false;
  bool _focusMode = false;
  static const _nip44PolicyTarget = '*';
  static const _tabClickAddressReveal = Duration(seconds: 3);
  static const _homeTitle = 'New Tab';
  static const _flightDeckTitle = 'Flight Deck';
  static const _browserSignerKey = 'wingman.browser.last_signer_npub.v1';
  static const _browserTabsKeyPrefix = 'wingman.browser.tabs.v3.';
  final WebViewCookieManager _cookieManager = WebViewCookieManager();
  final NostrProfileStore _profileStore = NostrProfileStore();
  late final NostrProfileRelayClient _profileRelayClient =
      widget.profileRelayClient ?? NostrProfileRelayClient();
  int _profileEpoch = 0;
  final BrowserBookmarkStore _bookmarkStore = BrowserBookmarkStore();
  List<BrowserBookmark> _bookmarks = const [];
  String? _selectorBackground;
  String? _defaultSelectorBackground;
  bool _bookmarkEditorOpen = false;
  String _labelColour = '#ffffff';
  bool _builtInStartup = false;
  int _signerSyncEpoch = 0;
  Future<void> _launcherSettingsQueue = Future<void>.value();
  final Map<String, _BrowserTabsSnapshot> _sessionTabs = {};

  String? _lastWebStateSignerNpub;
  NostrProfile _profile = const NostrProfile();
  final DiagnosticsStore _diagnosticsStore = DiagnosticsStore();
  Timer? _diagnosticsMaintenance;
  Timer? _persistTabsTimer;
  bool _clearingWebState = false;
  Completer<void>? _webStateClear;
  bool _restoringTabs = false;
  StreamSubscription<bool>? _fipsEnabledSubscription;
  bool _fipsEnabled = true;
  int _fipsEnabledEpoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleKeyboardEvent);
    unawaited(_diagnosticsStore.prune().catchError((Object _) {}));
    _diagnosticsMaintenance = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_diagnosticsStore.prune().catchError((Object _) {}));
    });
    _fipsEnabledSubscription =
        widget.fipsRuntime?.enabledChanges.listen(_onFipsEnabledChanged);
    unawaited(_loadFipsEnabled());
    _restoringTabs = true;
    _createHomeTab(activate: true, persistState: false);
    unawaited(_loadSelectorBackgroundAsset());
    unawaited(_loadProfile());
    unawaited(_syncWebStateToSigner());
  }

  @override
  void didUpdateWidget(covariant BrowserScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.deviceNpub != widget.config.deviceNpub ||
        (oldWidget.config.hasDeviceSecret && !widget.config.hasDeviceSecret) ||
        oldWidget.config.towerUrl != widget.config.towerUrl ||
        oldWidget.config.flightDeckUrl != widget.config.flightDeckUrl) {
      for (final tab in _tabs) {
        tab.clearDiagnosticsTransition();
        tab.revokeSigningDocument();
      }
    }
    if (oldWidget.config.deviceNpub != widget.config.deviceNpub) {
      _bookmarks = const [];
      _selectorBackground = null;
      _labelColour = '#ffffff';
      _builtInStartup = false;
      _profileEpoch++;
      _profile = const NostrProfile();
      unawaited(_loadProfile().then((_) {
        if (mounted &&
            oldWidget.config.deviceNpub.isEmpty &&
            widget.config.hasDeviceSecret) {
          _editProfile();
        }
      }));
      unawaited(_switchSignerTabs(oldWidget.config.deviceNpub));
    } else if (!oldWidget.config.hasDeviceSecret &&
        widget.config.hasDeviceSecret) {
      // Keep the same controllers, tabs and storage; retry authentication now
      // that the existing identity can actually sign.
      for (final tab in _tabs) {
        if (!tab.isHome) unawaited(tab.controller.reload());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_fipsEnabledSubscription?.cancel());
    HardwareKeyboard.instance.removeHandler(_handleKeyboardEvent);
    unawaited(_persistTabsNow());
    _persistTabsTimer?.cancel();
    _addressBarHideTimer?.cancel();
    _diagnosticsMaintenance?.cancel();
    _tabStripController.dispose();
    for (final tab in _tabs) {
      tab.dispose();
    }
    super.dispose();
  }

  Future<void> _loadFipsEnabled() async {
    final epoch = _fipsEnabledEpoch;
    final enabled = await widget.fipsRuntime?.isEnabled;
    if (epoch != _fipsEnabledEpoch) return;
    if (mounted && enabled != null && enabled != _fipsEnabled) {
      _onFipsEnabledChanged(enabled);
    }
  }

  void _onFipsEnabledChanged(bool enabled) {
    if (!mounted) return;
    _fipsEnabledEpoch++;
    _fipsEnabled = enabled;
    for (final tab in _tabs) {
      // Revoke epochs synchronously before any asynchronous document work.
      tab.revokeSigningDocument();
      if (!enabled && tab.isFips) {
        tab.fipsDisabledUrl ??= tab.currentUrl ?? tab.addressController.text;
        tab.message =
            'FIPS is disabled. Enable it in Setup to open this service.';
        unawaited(tab.controller.loadHtmlString(
          '<html><body><h1>FIPS disabled</h1><p>Enable FIPS in Setup to open this service.</p></body></html>',
          baseUrl: 'https://wingman.local/',
        ));
      } else if (enabled && tab.fipsDisabledUrl != null) {
        final destination = tab.fipsDisabledUrl!;
        tab.fipsDisabledUrl = null;
        _loadAddressForTab(tab, destination);
      } else if (!tab.isHome) {
        // HTTPS signing remains usable with a fresh document token.
        unawaited(_refreshDocumentProviders(tab, enabled));
      }
    }
    setState(() {});
  }

  Future<void> _refreshDocumentProviders(BrowserTab tab, bool enabled) async {
    final epoch = tab.signerDocumentEpoch;
    if (enabled) await _injectGraspBridge(tab);
    if (!mounted || tab.disposed || tab.signerDocumentEpoch != epoch) return;
    await _injectIfTrusted(tab);
  }

  @override
  Widget build(BuildContext context) {
    return FocusEdgeGestures(
      enabled: _focusMode &&
          !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS),
      onShowControls: exitFocusMode,
      onNextTab: () => _activateAdjacentTab(1),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_focusMode) _buildTabBar(context),
              Expanded(
                child: Stack(
                  key: const ValueKey('browser-content-viewport'),
                  fit: StackFit.expand,
                  children: [
                    _buildWebViewStack(),
                    if (!_focusMode && _addressBarVisible)
                      Positioned(
                        key: const ValueKey('browser-address-bar-overlay'),
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _buildAddressBar(context),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWebViewStack() {
    final stack = IndexedStack(
      index: _activeTabIndex,
      children: [
        for (final tab in _tabs)
          WebViewWidget(
            key: ValueKey(tab.id),
            controller: tab.controller,
            gestureRecognizers: defaultTargetPlatform == TargetPlatform.android
                ? _androidWebViewGestureRecognizers
                : const <Factory<OneSequenceGestureRecognizer>>{},
          ),
      ],
    );
    final content = EmbeddedContentFocus(child: stack);
    if (!_focusMode) return content;
    return SafeArea(bottom: false, child: content);
  }

  Widget _buildTabBar(BuildContext context) {
    final theme = Theme.of(context);
    final availableWidth = MediaQuery.sizeOf(context).width -
        MediaQuery.paddingOf(context).horizontal;
    // Keep every tab in one viewport while allowing the strip to scroll.
    final tabWidth = (availableWidth - 200).clamp(96.0, 190.0);
    _tabItemExtent = tabWidth + 4;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 42,
          child: Row(
            children: [
              IconButton(
                tooltip: 'Open menu',
                onPressed: widget.onOpenDrawer,
                icon: const Icon(Icons.menu),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  key: const ValueKey('browser-tab-strip'),
                  scrollController: _tabStripController,
                  padding: const EdgeInsets.only(left: 4, right: 12),
                  scrollDirection: Axis.horizontal,
                  itemExtent: _tabItemExtent,
                  buildDefaultDragHandles: false,
                  itemCount: _tabs.length,
                  onReorderItem: _reorderTabs,
                  proxyDecorator: (child, index, animation) {
                    return FadeTransition(
                      opacity: animation.drive(
                        Tween<double>(begin: 0.82, end: 1),
                      ),
                      child: child,
                    );
                  },
                  itemBuilder: (context, index) {
                    final tab = _tabs[index];
                    final active = tab.id == _activeTabId;
                    final button = _BrowserTabButton(
                      title: tab.label,
                      active: active,
                      tabColour: _tabColours[tab.colour],
                      onSecondaryTapUp: (details) =>
                          _showTabMenu(tab, details.globalPosition),
                      fipsTransport: tab.isFips,
                      closeable: true,
                      width: tabWidth,
                      onPressed: () => _activateTab(tab.id),
                      onClose: () => _closeTab(tab.id),
                    );
                    return Padding(
                      key: ValueKey('tab-${tab.id}'),
                      padding: const EdgeInsets.only(right: 4),
                      child: _TabReorderHandle(index: index, child: button),
                    );
                  },
                ),
              ),
              IconButton(
                tooltip: 'New tab',
                onPressed: () => _createHomeTab(),
                icon: const Icon(Icons.add),
              ),
              Semantics(
                label: 'Enter Focus Mode',
                button: true,
                excludeSemantics: true,
                child: IconButton(
                  key: const ValueKey('enter-focus-mode-button'),
                  tooltip: 'Enter Focus Mode',
                  onPressed: _enterFocusMode,
                  icon: const Icon(Icons.fullscreen),
                ),
              ),
              _BrowserAvatarMenu(
                deviceNpub: widget.config.deviceNpub,
                profile: _profile,
                onEditProfile: widget.config.hasDeviceSecret
                    ? _editProfile
                    : widget.onOpenIdentity ?? widget.onOpenSigner,
                identityActionLabel: widget.config.hasDeviceSecret
                    ? 'Edit profile'
                    : widget.config.hasDeviceNpub
                        ? 'Unlock identity'
                        : 'Create identity / Import key',
                onOpenSetup: widget.onOpenSetup,
                onOpenSigner: widget.onOpenSigner,
                onOpenStatus: widget.onOpenStatus,
                onLogOut: widget.onLogOut,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAddressBar(BuildContext context) {
    final tab = _activeTab;
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 6,
      shadowColor: theme.colorScheme.shadow,
      shape: Border(
        bottom: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Back',
              onPressed: tab.canGoBack ? _goBack : null,
              icon: const Icon(Icons.arrow_back),
            ),
            IconButton(
              tooltip: 'Forward',
              onPressed: tab.canGoForward ? _goForward : null,
              icon: const Icon(Icons.arrow_forward),
            ),
            IconButton(
              tooltip: 'Reload',
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
            ),
            Expanded(
              child: TextField(
                controller: tab.addressController,
                focusNode: tab.addressFocusNode,
                onSubmitted: _loadAddress,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.public),
                  hintText: 'Search or enter URL',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              tooltip: 'Go',
              onPressed: () => _loadAddress(tab.addressController.text),
              icon: const Icon(Icons.arrow_forward),
            ),
          ],
        ),
      ),
    );
  }

  BrowserTab get _activeTab {
    return _tabs.firstWhere((tab) => tab.id == _activeTabId);
  }

  int get _activeTabIndex {
    final index = _tabs.indexWhere((tab) => tab.id == _activeTabId);
    return index < 0 ? 0 : index;
  }

  BrowserTab? _tabById(int id) {
    for (final tab in _tabs) {
      if (tab.id == id) return tab;
    }
    return null;
  }

  BrowserBookmarkMenuState get _bookmarkMenuState {
    if (_tabs.isEmpty) return const BrowserBookmarkMenuState.unavailable();
    final tab = _activeTab;
    final url = canonicalBrowserBookmarkUrl(
      tab.isHome ? null : tab.currentUrl ?? tab.addressController.text,
    );
    if (url == null) return const BrowserBookmarkMenuState.unavailable();
    return BrowserBookmarkMenuState(
      available: true,
      bookmarked: _isLocalFlightDeckUrl(url) ||
          _bookmarks.any((bookmark) => bookmark.url == url),
    );
  }

  bool get _hasLocalFlightDeck =>
      canonicalBrowserBookmarkUrl(widget.localFlightDeckUrl) != null;

  BrowserBookmark? get _localFlightDeckBookmark {
    final url = canonicalBrowserBookmarkUrl(widget.localFlightDeckUrl);
    if (url == null) return null;
    return BrowserBookmark(
        title: _flightDeckTitle, url: url, startup: _builtInStartup);
  }

  List<BrowserBookmark> get _visibleBookmarks {
    final flightDeck = _localFlightDeckBookmark;
    if (flightDeck == null) return _bookmarks;
    return [
      flightDeck,
      for (final bookmark in _bookmarks)
        if (!_isLocalFlightDeckUrl(bookmark.url)) bookmark,
    ];
  }

  bool _isLocalFlightDeckUrl(String? value) {
    final localOrigin = SignerPolicy.normalizeOrigin(widget.localFlightDeckUrl);
    return localOrigin.isNotEmpty &&
        SignerPolicy.normalizeOrigin(value ?? '') == localOrigin;
  }

  SignerPolicy get _signerPolicy => SignerPolicy(
        trustedOrigins: [
          ...widget.config.effectiveTrustedOrigins(),
          if (_hasLocalFlightDeck) widget.localFlightDeckUrl,
        ],
      );

  void _notifyBookmarkMenuState() {
    widget.onBookmarkMenuStateChanged?.call(_bookmarkMenuState);
  }

  Future<void> toggleActivePageBookmark() async {
    final tab = _activeTab;
    final url = canonicalBrowserBookmarkUrl(
      tab.isHome ? null : tab.currentUrl ?? tab.addressController.text,
    );
    if (url == null) return;
    if (_isLocalFlightDeckUrl(url)) return;
    final existing = _bookmarks.indexWhere((bookmark) => bookmark.url == url);
    if (existing >= 0) {
      _bookmarks = List<BrowserBookmark>.from(_bookmarks)..removeAt(existing);
    } else {
      _bookmarks = [
        ..._bookmarks,
        BrowserBookmark(title: tab.pageLabel, url: url),
      ];
    }
    await _persistBookmarks();
    if (!mounted) return;
    _reloadHomeTabs();
    _notifyBookmarkMenuState();
    if (existing < 0) {
      unawaited(tab.controller.runJavaScript(bookmarkDiscoveryScript));
    }
  }

  Future<void> _removeBookmark(String url) async {
    final canonicalUrl = canonicalBrowserBookmarkUrl(url);
    if (_isLocalFlightDeckUrl(canonicalUrl)) return;
    if (canonicalUrl == null ||
        !_bookmarks.any((bookmark) => bookmark.url == canonicalUrl)) {
      return;
    }
    _bookmarks = [
      for (final bookmark in _bookmarks)
        if (bookmark.url != canonicalUrl) bookmark,
    ];
    await _persistBookmarks();
    if (!mounted) return;
    _reloadHomeTabs();
    _notifyBookmarkMenuState();
  }

  Future<void> _editBookmark(BrowserTab tab, String url) async {
    if (!tab.isHome || _isLocalFlightDeckUrl(url) || _bookmarkEditorOpen) {
      return;
    }
    final index = _bookmarks.indexWhere((b) => b.url == url);
    if (index < 0) return;
    final original = _bookmarks[index];
    final identity = widget.config.deviceNpub;
    final epoch = tab.signerDocumentEpoch;
    _bookmarkEditorOpen = true;
    BrowserBookmark? edited;
    try {
      edited = await showDialog<BrowserBookmark>(
          context: context,
          builder: (_) => BookmarkEditor(
              bookmark: original,
              bookmarks: List.of(_bookmarks),
              reservedUrl: _localFlightDeckBookmark?.url));
    } finally {
      _bookmarkEditorOpen = false;
    }
    if (!mounted ||
        edited == null ||
        widget.config.deviceNpub != identity ||
        tab.disposed ||
        !tab.isHome ||
        tab.signerDocumentEpoch != epoch) {
      return;
    }
    final current = _bookmarks.indexWhere((b) => identical(b, original));
    final error = bookmarkEditError(
        _bookmarks, original, edited.title, edited.url,
        reservedUrl: _localFlightDeckBookmark?.url);
    if (current < 0 || error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              error ?? 'Saved apps changed. Reopen the editor to retry.')));
      return;
    }
    final updated = List<BrowserBookmark>.of(_bookmarks)..[current] = edited;
    try {
      await _bookmarkStore.save(identity, updated);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not save the app. Please retry.')));
      }
      return;
    }
    if (!mounted ||
        identity != widget.config.deviceNpub ||
        tab.disposed ||
        tab.signerDocumentEpoch != epoch) {
      return;
    }
    _bookmarks = updated;
    _reloadHomeTabs();
    _notifyBookmarkMenuState();
  }

  Future<void> _loadBookmarksForSigner(String signerNpub) async {
    final epoch = _signerSyncEpoch;
    final bookmarks = await _bookmarkStore.load(signerNpub);
    final background = await _bookmarkStore.loadBackground(signerNpub);
    final colour = await _bookmarkStore.loadLabelColour(signerNpub);
    final builtInStartup = await _bookmarkStore.loadBuiltInStartup(signerNpub);
    if (!mounted ||
        epoch != _signerSyncEpoch ||
        widget.config.deviceNpub.trim() != signerNpub.trim()) {
      return;
    }
    _bookmarks = bookmarks;
    _selectorBackground = background;
    _labelColour = colour;
    _builtInStartup = builtInStartup;
    _reloadHomeTabs();
    _notifyBookmarkMenuState();
  }

  Future<void> _persistBookmarks() {
    return _bookmarkStore.save(widget.config.deviceNpub, _bookmarks);
  }

  void _reloadHomeTabs() {
    for (final tab in _tabs.where((tab) => tab.isHome)) {
      _loadHomeForTab(tab);
    }
  }

  void _enterFocusMode() {
    setState(() {
      _focusMode = true;
    });
    widget.onFocusModeChanged?.call(true);
  }

  void exitFocusMode() {
    if (!_focusMode) return;
    setState(() {
      _focusMode = false;
    });
    widget.onFocusModeChanged?.call(false);
  }

  void reloadFlightDeck() {
    for (final tab in _tabs) {
      if (_isLocalFlightDeckUrl(tab.currentUrl ?? tab.addressController.text)) {
        tab.controller.reload();
      }
    }
  }

  Future<void> _loadProfile() async {
    final deviceNpub = widget.config.deviceNpub;
    final epoch = _profileEpoch;
    final profile = await _profileStore.load(deviceNpub);
    if (!mounted ||
        widget.config.deviceNpub != deviceNpub ||
        epoch != _profileEpoch) {
      return;
    }
    setState(() {
      _profile = profile;
    });
    unawaited(_refreshProfileFromRelays(deviceNpub));
  }

  Future<void> _refreshProfileFromRelays(String deviceNpub) async {
    late final String publicKeyHex;
    try {
      publicKeyHex = NostrCrypto.publicKeyHexFromNpub(deviceNpub);
    } catch (_) {
      return;
    }
    final epoch = _profileEpoch;
    final fetched = await _profileRelayClient.fetchProfile(publicKeyHex);
    if (fetched == null ||
        !mounted ||
        widget.config.deviceNpub != deviceNpub ||
        epoch != _profileEpoch) {
      return;
    }
    final cached = await _profileStore.saveRemote(deviceNpub, fetched.profile,
        createdAt: fetched.createdAt);
    if (!mounted ||
        widget.config.deviceNpub != deviceNpub ||
        epoch != _profileEpoch) {
      return;
    }
    setState(() {
      _profile = cached;
    });
  }

  Future<void> _editProfile() async {
    final deviceNpub = widget.config.deviceNpub;
    if (!widget.config.hasDeviceSecret) {
      widget.onOpenIdentity?.call();
      return;
    }
    _profileEpoch++;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _EditNostrProfileDialog(
        deviceNpub: deviceNpub,
        profile: _profile,
        onUploadAvatar: () async {
          final uploader = ProfileAvatarUpload();
          final bytes = await uploader.pick();
          if (bytes == null) return null;
          if (!mounted ||
              widget.config.deviceNpub != deviceNpub ||
              !widget.config.hasDeviceSecret) {
            throw const AvatarUploadException(
                'Identity changed. Reopen the profile editor.');
          }
          final url = await uploader.upload(bytes,
              secret: widget.config.deviceSecret, npub: deviceNpub);
          if (!mounted ||
              widget.config.deviceNpub != deviceNpub ||
              !widget.config.hasDeviceSecret) {
            throw const AvatarUploadException(
                'Identity changed. Image uploaded for the original identity; profile not changed.');
          }
          return url;
        },
        onExportKey: widget.signerVault == null
            ? null
            : (pin) async {
                final unlocked = await widget.signerVault!.unlock(pin: pin);
                if (!mounted ||
                    widget.config.deviceNpub != deviceNpub ||
                    !widget.config.hasDeviceSecret ||
                    unlocked.npub != deviceNpub) {
                  throw StateError('Identity changed.');
                }
                return unlocked.nsec;
              },
        onSave: (profile) async {
          if (!mounted ||
              widget.config.deviceNpub != deviceNpub ||
              !widget.config.hasDeviceSecret) {
            throw StateError('Identity changed. Reopen the profile editor.');
          }
          _profileEpoch++;
          final cached = await _profileStore.save(deviceNpub, profile);
          if (!mounted ||
              widget.config.deviceNpub != deviceNpub ||
              !widget.config.hasDeviceSecret) {
            throw StateError(
                'Identity changed. Draft retained for its original identity.');
          }
          setState(() => _profile = cached);
          final result = await NostrProfilePublisher(
                  store: _profileStore, relays: _profileRelayClient)
              .publish(
                  npub: deviceNpub,
                  secret: widget.config.deviceSecret,
                  profile: cached);
          return result;
        },
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Profile saved.')));
    }
  }

  bool _handleKeyboardEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.tab) return false;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed) return false;
    _activateAdjacentTab(keyboard.isShiftPressed ? -1 : 1);
    return true;
  }

  void _activateAdjacentTab(int delta) {
    if (_tabs.length < 2) return;
    _hideAddressBar();
    final nextIndex = (_activeTabIndex + delta) % _tabs.length;
    final normalizedIndex =
        nextIndex < 0 ? nextIndex + _tabs.length : nextIndex;
    setState(() {
      _activeTabId = _tabs[normalizedIndex].id;
    });
    _revealTab(_activeTabId);
    _refreshNavigationState(_activeTab);
    _schedulePersistTabs();
    _notifyBookmarkMenuState();
  }

  WebViewController _createWebViewController(int id) {
    final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const {
          PlaybackMediaTypes.audio,
          PlaybackMediaTypes.video,
        },
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }
    final controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'WingmanTitle',
        onMessageReceived: (message) => _onTitleMessage(id, message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) => _onNavigationRequest(id, request),
          onUrlChange: (change) => _onUrlChanged(id, change.url),
          onPageStarted: (url) {
            final tab = _tabById(id);
            if (tab != null) {
              _captureDiagnosticsTransition(tab, url);
              tab.revokeSigningDocument();
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) {
              final tab = _tabById(id);
              if (tab != null) {
                _recordWebViewDiagnostic(tab, error);
              }
            }
          },
          onPageFinished: (url) => _onPageFinished(id, url),
        ),
      );
    if (!Platform.isAndroid) {
      controller
        ..addJavaScriptChannel(
          'WingmanSigner',
          onMessageReceived: (message) => _onSignerMessage(id, message),
        )
        ..addJavaScriptChannel(
          'WingmanGrasp',
          onMessageReceived: (message) =>
              _tabById(id)?.graspBridge?.receive(message.message),
        );
    }
    unawaited(configureWebViewFilePicker(controller));
    return controller;
  }

  Future<bool> _configureNativeChannels(BrowserTab tab) async {
    if (!Platform.isAndroid) return Platform.isIOS || Platform.isMacOS;
    final controller = tab.controller.platform;
    if (controller is! AndroidWebViewController) return false;
    final id = controller.webViewIdentifier;
    tab.androidWebViewIdentifier = id;
    final installed = await GraspAndroidChannel.install(
      webViewIdentifier: id,
      onMessage: (channel, message) {
        if (!mounted || _tabById(tab.id) != tab) return;
        switch (channel) {
          case 'WingmanGrasp':
            unawaited(tab.graspBridge?.receive(message));
          case 'WingmanSigner':
            unawaited(
                _onSignerMessage(tab.id, JavaScriptMessage(message: message)));
        }
      },
    );
    if (tab.disposed) {
      await GraspAndroidChannel.remove(id);
      return false;
    }
    return installed;
  }

  void _createTab(
    String url, {
    bool activate = true,
    bool persistState = true,
    String? title,
  }) {
    if (activate && _tabs.isNotEmpty) _hideAddressBar();
    final id = _nextTabId++;
    late final BrowserTab tab;
    final controller = _createWebViewController(id);
    tab = BrowserTab(
      id: id,
      controller: controller,
      addressController: TextEditingController(text: url),
      addressFocusNode: FocusNode(),
      title: title ?? 'New tab',
    );
    tab.nativeChannelsReady = _configureNativeChannels(tab);
    tab.addressFocusNode.addListener(() => _onAddressFocusChanged(tab.id));
    setState(() {
      _tabs.add(tab);
      if (activate) {
        _activeTabId = id;
      }
    });
    if (activate) {
      _revealTab(id);
    }
    _loadAddressForTab(tab, url);
    if (persistState) _schedulePersistTabs();
  }

  void _createHomeTab({
    bool activate = true,
    bool persistState = true,
  }) {
    if (activate && _tabs.isNotEmpty) _hideAddressBar();
    final id = _nextTabId++;
    late final BrowserTab tab;
    final controller = _createWebViewController(id);
    tab = BrowserTab(
      id: id,
      controller: controller,
      addressController: TextEditingController(),
      addressFocusNode: FocusNode(),
      title: _homeTitle,
      isHome: true,
    );
    tab.nativeChannelsReady = _configureNativeChannels(tab);
    tab.addressFocusNode.addListener(() => _onAddressFocusChanged(tab.id));
    setState(() {
      _tabs.add(tab);
      if (activate) {
        _activeTabId = id;
      }
    });
    if (activate) {
      _revealTab(id);
    }
    _loadHomeForTab(tab);
    if (persistState) _schedulePersistTabs();
  }

  void openTab(String url) {
    _createTab(url);
  }

  Future<void> _showTabMenu(BrowserTab tab, Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(
          overlay.globalToLocal(position).dx,
          overlay.globalToLocal(position).dy,
          0,
          0,
        ),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(value: 'prefix', child: Text('Set tab prefix…')),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: 'default',
          checked: tab.colour == null,
          child: const Text('Default colour'),
        ),
        for (final entry in _tabColours.entries)
          CheckedPopupMenuItem(
            value: entry.key,
            checked: tab.colour == entry.key,
            child: Row(
              children: [
                Icon(Icons.circle, color: entry.value, size: 16),
                const SizedBox(width: 12),
                Text(entry.key),
              ],
            ),
          ),
      ],
    );
    if (!mounted || !_tabs.contains(tab) || action == null) return;
    if (action == 'prefix') {
      var prefix = tab.prefix;
      final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Tab prefix'),
          content: TextFormField(
            initialValue: prefix,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Prefix',
              hintText: 'WORK',
              helperText: 'Shown as WORK: Page title. Leave blank to remove.',
              helperMaxLines: 2,
            ),
            onChanged: (value) => prefix = value,
            onFieldSubmitted: (value) => Navigator.pop(context, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, prefix),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (!mounted || !_tabs.contains(tab) || result == null) return;
      setState(() {
        tab.prefix = result.trim().replaceFirst(RegExp(r'[:\s]+$'), '');
      });
    } else {
      setState(() => tab.colour = action == 'default' ? null : action);
    }
    _schedulePersistTabs();
  }

  void _activateTab(int id) {
    if (_activeTabId == id) {
      _revealTab(id);
      if (_addressBarVisible) {
        _hideAddressBar();
      } else {
        _revealAddressBar(_tabClickAddressReveal);
      }
      _notifyBookmarkMenuState();
      return;
    }
    _hideAddressBar();
    setState(() {
      _activeTabId = id;
    });
    _revealTab(id);
    _refreshNavigationState(_activeTab);
    _schedulePersistTabs();
    _notifyBookmarkMenuState();
  }

  void _revealTab(int id) {
    final index = _tabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tabStripController.hasClients) return;
      final position = _tabStripController.position;
      final centeredOffset = index * _tabItemExtent -
          (position.viewportDimension - _tabItemExtent)
                  .clamp(0.0, double.infinity) /
              2;
      _tabStripController.animateTo(
        centeredOffset.clamp(0.0, position.maxScrollExtent),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _closeTab(int id) {
    final target = _tabById(id);
    if (target == null) return;
    if (id == _activeTabId) _hideAddressBar();
    if (_tabs.length == 1) {
      setState(() {
        _tabs.clear();
        _activeTabId = 0;
      });
      target.dispose();
      _createHomeTab();
      return;
    }
    final index = _tabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return;
    final removed = _tabs[index];
    final nextActiveId = id == _activeTabId
        ? _tabs[index == 0 ? 1 : index - 1].id
        : _activeTabId;
    setState(() {
      _tabs.removeAt(index);
      _activeTabId = nextActiveId;
    });
    _revealTab(nextActiveId);
    removed.dispose();
    _schedulePersistTabs();
  }

  Future<void> clearBrowserData() {
    return _clearWebState(resetTabs: false);
  }

  Future<void> _switchSignerTabs(String previousSignerNpub) async {
    // Capture before yielding; hide the old identity's documents immediately.
    final saving = _persistTabsForSigner(previousSignerNpub);
    // Capture the departing controllers for storage clearing before hiding them.
    final clearing = _clearWebState(resetTabs: false);
    _persistTabsTimer?.cancel();
    _restoringTabs = true;
    _resetTabsToDefault(persistState: false);
    unawaited(saving);
    unawaited(clearing);
    await _syncWebStateToSigner();
  }

  Future<void> _syncWebStateToSigner() async {
    final signerNpub = widget.config.deviceNpub.trim();
    if (_lastWebStateSignerNpub == signerNpub) return;
    _lastWebStateSignerNpub = signerNpub;
    final epoch = ++_signerSyncEpoch;
    bool current() =>
        mounted &&
        epoch == _signerSyncEpoch &&
        widget.config.deviceNpub.trim() == signerNpub;
    _restoringTabs = true;
    final preferences = SharedPreferencesAsync();
    final previousSignerNpub = await preferences.getString(_browserSignerKey);
    if (!current()) return;
    if (previousSignerNpub != signerNpub &&
        (signerNpub.isNotEmpty || (previousSignerNpub?.isNotEmpty ?? false))) {
      await _clearWebState(resetTabs: false);
      if (!current()) return;
      await preferences.setString(_browserSignerKey, signerNpub);
    }
    if (!current()) return;
    await _loadBookmarksForSigner(signerNpub);
    if (!current()) return;
    await _restoreTabsForSigner(signerNpub);
  }

  Future<void> _clearWebState({required bool resetTabs}) async {
    if (_clearingWebState) {
      await _webStateClear?.future;
      return;
    }
    _clearingWebState = true;
    final completion = _webStateClear = Completer<void>();
    final tabs = List<BrowserTab>.from(_tabs);
    // Revoke synchronously, before clearing platform storage can yield.
    for (final tab in tabs) {
      tab.revokeSigningDocument();
    }
    try {
      try {
        await _cookieManager.clearCookies();
      } catch (_) {}
      for (final tab in tabs) {
        tab.revokeSigningDocument();
        try {
          await tab.controller.clearCache();
        } catch (_) {}
        try {
          await tab.controller.clearLocalStorage();
        } catch (_) {}
      }
    } finally {
      _clearingWebState = false;
      completion.complete();
    }
    if (!mounted || !resetTabs) return;
    _resetTabsToDefault(persistState: false);
  }

  void _resetTabsToDefault({required bool persistState}) {
    final tabs = List<BrowserTab>.from(_tabs);
    for (final tab in tabs) {
      tab.dispose();
    }
    setState(() {
      _tabs.clear();
      _activeTabId = 0;
      _nextTabId = 1;
      _addressBarVisible = false;
      _addressBarHideTimer?.cancel();
    });
    final wasRestoringTabs = _restoringTabs;
    if (!persistState) _restoringTabs = true;
    _createHomeTab(activate: true, persistState: persistState);
    _restoringTabs = wasRestoringTabs;
  }

  Future<void> _restoreTabsForSigner(String signerNpub) async {
    // Disk restore records never override explicit startup selection. Only
    // identities already visited in this BrowserScreen restore session state.
    final snapshot = _sessionTabs[signerNpub];
    if (snapshot == null) {
      if (_tabs.length != 1 || !_tabs.single.isHome) {
        _resetTabsToDefault(persistState: false);
      }
      final selected = _visibleBookmarks.where((app) => app.startup).toList();
      if (selected.isNotEmpty) {
        final seen = <String>{};
        for (final app in selected) {
          if (!seen.add(app.url)) continue;
          if (seen.length == 1) {
            _loadAddressForTab(_tabs.single, app.url);
            _tabs.single.title = app.title;
          } else {
            _createTab(app.url,
                activate: false, persistState: false, title: app.title);
          }
        }
      }
      _restoringTabs = false;
      return;
    }

    _restoringTabs = true;
    final oldTabs = List<BrowserTab>.from(_tabs);
    for (final tab in oldTabs) {
      tab.dispose();
    }
    setState(() {
      _tabs.clear();
      _activeTabId = 0;
      _nextTabId = 1;
      _addressBarVisible = false;
      _addressBarHideTimer?.cancel();
    });

    for (final tab in snapshot.tabs) {
      if (tab.isHome || tab.url == null || tab.url!.isEmpty) {
        _createHomeTab(activate: false, persistState: false);
      } else {
        _createTab(tab.url!, activate: false, persistState: false);
      }
      final restored = _tabs.last;
      if (tab.diagnosticsTabKey != null) {
        restored.diagnosticsTabKey = tab.diagnosticsTabKey!;
      }
      restored.prefix = tab.prefix;
      restored.colour = tab.colour;
      if (tab.title != null && tab.title!.trim().isNotEmpty) {
        restored.title = tab.title!.trim();
      }
    }

    final activeIndex = snapshot.activeIndex.clamp(0, _tabs.length - 1).toInt();
    setState(() {
      _activeTabId = _tabs[activeIndex].id;
    });
    _restoringTabs = false;
  }

  void _schedulePersistTabs() {
    if (_restoringTabs) return;
    _persistTabsTimer?.cancel();
    _persistTabsTimer = Timer(const Duration(milliseconds: 100), () {
      unawaited(_persistTabsNow());
    });
  }

  Future<void> _persistTabsNow() {
    return _persistTabsForSigner(widget.config.deviceNpub);
  }

  Future<void> _persistTabsForSigner(String signerNpub) async {
    if (_restoringTabs) return;
    final key = _tabsStorageKey(signerNpub);
    if (key == null || _tabs.isEmpty) return;
    final snapshot = _BrowserTabsSnapshot(
      version: 3,
      activeIndex: _activeTabIndex,
      tabs: [
        for (final tab in _tabs)
          _BrowserTabSnapshot(
            title: tab.title,
            diagnosticsTabKey: tab.diagnosticsTabKey,
            prefix: tab.prefix,
            colour: tab.colour,
            url: tab.isHome
                ? null
                : (tab.fipsDisabledUrl ??
                        tab.currentUrl ??
                        tab.addressController.text)
                    .trim(),
            isHome: tab.isHome,
          ),
      ],
    );
    _sessionTabs[signerNpub.trim()] = snapshot;
    await SharedPreferencesAsync().setString(
      key,
      jsonEncode(snapshot.toJson()),
    );
  }

  String? _tabsStorageKey(String signerNpub) {
    final normalized = signerNpub.trim();
    if (normalized.isEmpty) return null;
    return '$_browserTabsKeyPrefix$normalized';
  }

  void _reload() {
    final tab = _activeTab;
    if (tab.isHome) {
      _loadHomeForTab(tab);
      return;
    }
    final uri = Uri.tryParse(tab.currentUrl ?? tab.addressController.text);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      tab.controller.reload();
    } else {
      _loadAddress(tab.addressController.text);
    }
  }

  Future<void> _goBack() async {
    final tab = _activeTab;
    if (!await tab.controller.canGoBack()) return;
    await tab.controller.goBack();
    await _refreshNavigationState(tab);
  }

  Future<void> _goForward() async {
    final tab = _activeTab;
    if (!await tab.controller.canGoForward()) return;
    await tab.controller.goForward();
    await _refreshNavigationState(tab);
  }

  void _loadAddress(String value) {
    final tab = _activeTab;
    _loadAddressForTab(tab, value, hideAddressBarAfterLoad: true);
  }

  void _loadAddressForTab(
    BrowserTab tab,
    String value, {
    bool hideAddressBarAfterLoad = false,
  }) {
    final normalized = _normalizeAddress(value);
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() {
        tab.message = 'Enter a valid website URL.';
      });
      return;
    }
    _captureDiagnosticsTransition(tab, normalized);
    tab.revokeSigningDocument();
    tab.fipsDisabledUrl = null;
    setState(() {
      tab.isHome = false;
      tab.currentUrl = uri.toString();
      tab.addressController.text = tab.currentUrl!;
      tab.title = _resolvedPageTitle(null, tab.currentUrl!);
      tab.message = null;
      if (hideAddressBarAfterLoad) {
        _addressBarHideTimer?.cancel();
        _addressBarVisible = false;
        tab.addressFocusNode.unfocus();
      }
    });
    final epoch = tab.signerDocumentEpoch;
    unawaited(tab.nativeChannelsReady.then<void>((_) async {
      if (!mounted || tab.disposed || tab.signerDocumentEpoch != epoch) return;
      if (_isFipsAppUrl(uri.toString())) {
        final enabled =
            widget.fipsRuntime == null || await widget.fipsRuntime!.isEnabled;
        if (!mounted || tab.disposed || tab.signerDocumentEpoch != epoch) {
          return;
        }
        if (!enabled || !_fipsEnabled) {
          tab.fipsDisabledUrl = uri.toString();
          tab.message =
              'FIPS is disabled. Enable it in Setup to open this service.';
          setState(() {});
          return;
        }
        final failure =
            await widget.onPrepareFipsNavigation?.call(uri.toString());
        if (!mounted ||
            tab.disposed ||
            tab.signerDocumentEpoch != epoch ||
            !_fipsEnabled) {
          return;
        }
        if (failure != null) {
          setState(() {
            tab.message = failure;
          });
          return;
        }
      }
      await tab.controller.loadRequest(uri);
    }));
    _schedulePersistTabs();
    if (tab.id == _activeTabId) _notifyBookmarkMenuState();
  }

  void _loadHomeForTab(BrowserTab tab) {
    setState(() {
      tab.isHome = true;
      tab.currentUrl = null;
      tab.addressController.clear();
      tab.title = _homeTitle;
      tab.message = null;
    });
    tab.revokeSigningDocument();
    final epoch = tab.signerDocumentEpoch;
    unawaited(tab.nativeChannelsReady.then<void>((_) async {
      if (!mounted || tab.disposed || tab.signerDocumentEpoch != epoch) return;
      final html = _homePageHtml(savedBookmarks: _visibleBookmarks);
      final nativeId = tab.androidWebViewIdentifier;
      if (nativeId != null) {
        // Keep Android's native current URL and document origin aligned for
        // local home actions, without weakening frame checks for web pages.
        await GraspAndroidChannel.loadHomeHtml(
            webViewIdentifier: nativeId, html: html);
      } else {
        await tab.controller
            .loadHtmlString(html, baseUrl: 'https://wingman.local/');
      }
    }));
    _schedulePersistTabs();
    if (tab.id == _activeTabId) _notifyBookmarkMenuState();
  }

  void _reorderTabs(int oldIndex, int newIndex) {
    if (_tabs.length <= 1) return;
    if (oldIndex < 0 || oldIndex >= _tabs.length) {
      return;
    }
    var destination = newIndex;
    if (oldIndex < destination) destination -= 1;
    destination = destination.clamp(0, _tabs.length - 1);
    if (oldIndex == destination) return;
    setState(() {
      final tab = _tabs.removeAt(oldIndex);
      _tabs.insert(destination, tab);
    });
    _schedulePersistTabs();
  }

  void _onAddressFocusChanged(int tabId) {
    final tab = _tabById(tabId);
    if (tab == null || tab.id != _activeTabId) return;
    if (tab.addressFocusNode.hasFocus) {
      _addressBarHideTimer?.cancel();
      if (!_addressBarVisible && mounted) {
        setState(() {
          _addressBarVisible = true;
        });
      }
      return;
    }
    if (_addressBarVisible) {
      _scheduleAddressBarHide(Duration.zero);
    }
  }

  void _revealAddressBar(Duration duration) {
    _cancelAddressBarHide();
    if (mounted) {
      setState(() {
        _addressBarVisible = true;
      });
    } else {
      _addressBarVisible = true;
    }
    _scheduleAddressBarHide(duration);
  }

  void _hideAddressBar() {
    _cancelAddressBarHide();
    final tab = _activeTab;
    if (tab.addressFocusNode.hasFocus) {
      tab.addressFocusNode.unfocus();
      _cancelAddressBarHide();
    }
    if (!_addressBarVisible) return;
    if (mounted) {
      setState(() {
        _addressBarVisible = false;
      });
    } else {
      _addressBarVisible = false;
    }
  }

  void _cancelAddressBarHide() {
    _addressBarHideTimer?.cancel();
    _addressBarHideTimer = null;
    _addressBarHideGeneration += 1;
  }

  void _scheduleAddressBarHide(Duration duration) {
    _addressBarHideTimer?.cancel();
    final generation = ++_addressBarHideGeneration;
    _addressBarHideTimer = Timer(duration, () {
      if (!mounted || generation != _addressBarHideGeneration) return;
      _addressBarHideTimer = null;
      final tab = _activeTab;
      if (tab.addressFocusNode.hasFocus) return;
      setState(() {
        _addressBarVisible = false;
      });
    });
  }

  String _normalizeAddress(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme) return trimmed;
    if (trimmed.contains('.') && !trimmed.contains(' ')) {
      return 'https://$trimmed';
    }
    return Uri.https('njump.me', '/', {'q': trimmed}).toString();
  }

  String? _normalizeOpenTabUrl(String value, String baseUrl) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      return parsed.toString();
    }
    final base = Uri.tryParse(baseUrl);
    if (base == null || !base.hasScheme || base.host.isEmpty) return null;
    return base.resolve(trimmed).toString();
  }

  String _titleForUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return 'New tab';
    return uri.host;
  }

  Future<void> _refreshNavigationState(BrowserTab tab) async {
    final canGoBack = await tab.controller.canGoBack();
    final canGoForward = await tab.controller.canGoForward();
    if (!mounted || _tabById(tab.id) == null) return;
    setState(() {
      tab.canGoBack = canGoBack;
      tab.canGoForward = canGoForward;
    });
  }

  Future<NavigationDecision> _onNavigationRequest(
    int tabId,
    NavigationRequest request,
  ) async {
    if (request.isMainFrame) {
      final tab = _tabById(tabId);
      if (tab != null) {
        _captureDiagnosticsTransition(tab, request.url);
        tab.revokeSigningDocument();
      }
    }
    final prepare = widget.onPrepareFipsNavigation;
    if (prepare == null || !_isFipsAppUrl(request.url)) {
      return NavigationDecision.navigate;
    }

    final tabAtStart = _tabById(tabId);
    final epoch = tabAtStart?.signerDocumentEpoch;
    if (!_fipsEnabled) return NavigationDecision.prevent;
    final failure = await prepare(request.url);
    if (!_fipsEnabled ||
        !mounted ||
        _tabById(tabId) != tabAtStart ||
        tabAtStart?.signerDocumentEpoch != epoch) {
      return NavigationDecision.prevent;
    }
    if (failure == null) return NavigationDecision.navigate;
    if (mounted) {
      final tab = _tabById(tabId);
      if (tab != null) {
        setState(() {
          tab.title = 'FIPS unavailable';
          tab.message = failure;
        });
      }
    }
    return NavigationDecision.prevent;
  }

  bool _isFipsAppUrl(String url) {
    try {
      FipsAppTarget.parse(url);
      return true;
    } on FormatException {
      return false;
    }
  }

  void _onUrlChanged(int tabId, String? url) {
    if (!mounted) return;
    final tab = _tabById(tabId);
    if (tab == null || url == null || url.isEmpty) return;
    if (tab.isHome &&
        (url == 'about:blank' || url == 'https://wingman.local/')) {
      return;
    }
    if (tab.currentUrl == url && tab.addressController.text == url) return;
    final previousOrigin = SignerPolicy.normalizeOrigin(
        tab.currentUrl ?? tab.addressController.text);
    final nextOrigin = SignerPolicy.normalizeOrigin(url);
    if (previousOrigin.isNotEmpty &&
        nextOrigin.isNotEmpty &&
        previousOrigin != nextOrigin) {
      tab.clearDiagnosticsTransition();
      tab.revokeSigningDocument();
    }
    setState(() {
      tab.isHome = false;
      tab.currentUrl = url;
      tab.addressController.text = url;
    });
    _schedulePersistTabs();
    if (tab.id == _activeTabId) _notifyBookmarkMenuState();
  }

  Future<void> _onPageFinished(int tabId, String url) async {
    final tab = _tabById(tabId);
    if (tab == null) return;
    tab.clearDiagnosticsTransition();
    if (tab.isHome &&
        (url == 'about:blank' || url == 'https://wingman.local/')) {
      await _injectTabCapture(tab);
      return;
    }
    final epoch = tab.signerDocumentEpoch;
    bool currentDocument() =>
        mounted && _tabById(tabId) == tab && tab.signerDocumentEpoch == epoch;
    String? title;
    try {
      title = await tab.controller.getTitle();
    } catch (_) {}
    if (!currentDocument()) return;
    setState(() {
      tab.isHome = false;
      tab.currentUrl = url;
      tab.addressController.text = url;
      tab.title = _resolvedPageTitle(title, url);
    });
    await _refreshNavigationState(tab);
    if (!currentDocument()) return;
    await _applyFlightDeckDisplayDefaults(tab, url);
    if (!currentDocument()) return;
    await _injectTabCapture(tab);
    if (!currentDocument()) return;
    await _injectTitleObserver(tab);
    if (!currentDocument()) return;
    await _injectGraspBridge(tab);
    if (!currentDocument()) return;
    await _injectIfTrusted(tab);
    if (currentDocument() &&
        _bookmarks.any((b) => b.url == canonicalBrowserBookmarkUrl(url))) {
      unawaited(tab.controller.runJavaScript(bookmarkDiscoveryScript));
    }
    _schedulePersistTabs();
    if (tab.id == _activeTabId) _notifyBookmarkMenuState();
  }

  String _resolvedPageTitle(String? title, String url) {
    final normalized = title?.trim() ?? '';
    if (normalized.isNotEmpty) return normalized;
    if (_isLocalFlightDeckUrl(url)) return _flightDeckTitle;
    return _titleForUrl(url);
  }

  void _onTitleMessage(int tabId, JavaScriptMessage message) {
    if (!mounted) return;
    final tab = _tabById(tabId);
    if (tab == null || tab.isHome) return;
    final url = tab.currentUrl ?? tab.addressController.text;
    final title = _resolvedPageTitle(message.message, url);
    if (tab.title == title) return;
    setState(() {
      tab.title = title;
    });
    _schedulePersistTabs();
  }

  Future<void> _injectTitleObserver(BrowserTab tab) async {
    try {
      await tab.controller.runJavaScript(_titleObserverScript());
    } catch (_) {}
  }

  String _titleObserverScript() {
    return '''
(() => {
  const target = document.head || document.documentElement;
  if (window.__wingmanTitleObserver || !target) return;
  let lastTitle = null;
  let publishQueued = false;
  const publish = () => {
    publishQueued = false;
    const title = String(document.title || '');
    if (title === lastTitle) return;
    lastTitle = title;
    if (window.WingmanTitle) WingmanTitle.postMessage(title);
  };
  const schedulePublish = () => {
    if (publishQueued) return;
    publishQueued = true;
    Promise.resolve().then(publish);
  };
  window.__wingmanTitleObserver = new MutationObserver(schedulePublish);
  window.__wingmanTitleObserver.observe(target, {
    childList: true,
    characterData: true,
    subtree: true,
  });
  schedulePublish();
})();
''';
  }

  Future<void> _applyFlightDeckDisplayDefaults(
    BrowserTab tab,
    String url,
  ) async {
    final pageOrigin = SignerPolicy.normalizeOrigin(url);
    final flightDeckOrigin =
        SignerPolicy.normalizeOrigin(widget.config.flightDeckUrl);
    final localFlightDeckOrigin =
        SignerPolicy.normalizeOrigin(widget.localFlightDeckUrl);
    if (pageOrigin.isEmpty ||
        (pageOrigin != flightDeckOrigin &&
            pageOrigin != localFlightDeckOrigin)) {
      return;
    }
    await tab.controller.runJavaScript('''
(() => {
  const root = document.documentElement;
  if (!root) return;
  root.style.setProperty('-webkit-text-size-adjust', 'none');
  root.style.setProperty('text-size-adjust', 'none');
})();
''');
  }

  Future<void> _loadSelectorBackgroundAsset() async {
    final bytes = await rootBundle.load('assets/app-selector/voxel-beach.png');
    if (!mounted) return;
    _defaultSelectorBackground =
        'data:image/png;base64,${base64Encode(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes))}';
    _reloadHomeTabs();
  }

  String _homePageHtml({required List<BrowserBookmark> savedBookmarks}) =>
      browserAppSelectorHtml(
          savedBookmarks: savedBookmarks,
          builtInUrl: _localFlightDeckBookmark?.url,
          backgroundImage: _selectorBackground ?? _defaultSelectorBackground,
          labelColour: _labelColour);

  Future<void> _injectGraspBridge(BrowserTab tab) async {
    // WKWebView (iOS/macOS) and Android's WebMessageListener validate
    // main-frame origin natively. A platform name alone is not authority.
    if (!await tab.nativeChannelsReady ||
        tab.disposed ||
        tab.graspBridge != null ||
        widget.onPrepareFipsNavigation == null ||
        !_fipsEnabled) {
      return;
    }
    final epoch = tab.signerDocumentEpoch;
    if (widget.fipsRuntime != null && !await widget.fipsRuntime!.isEnabled) {
      return;
    }
    if (!_fipsEnabled || tab.signerDocumentEpoch != epoch) return;
    final identity = widget.config.deviceNpub;
    final url = await tab.controller.currentUrl();
    if (!mounted ||
        _tabById(tab.id) != tab ||
        tab.signerDocumentEpoch != epoch ||
        url == null) {
      return;
    }
    final origin = SignerPolicy.normalizeOrigin(url);
    final local = SignerPolicy.normalizeOrigin(widget.localFlightDeckUrl);
    if (Uri.tryParse(origin)?.scheme != 'https' && origin != local) {
      return;
    }
    late final GraspFipsBrowserBridge bridge;
    bool current() =>
        _fipsEnabled &&
        mounted &&
        _tabById(tab.id) == tab &&
        tab.signerDocumentEpoch == epoch &&
        identical(tab.graspBridge, bridge) &&
        widget.config.deviceNpub == identity;
    bridge = GraspFipsBrowserBridge(
      onDiagnostic: (tabTrace, relayTrace, stage) {
        RelayDiagnostics.record(tabTrace, relayTrace, stage);
        const allowed = {
          'ws_open_start',
          'ws_open_failed',
          'ws_open_ok',
          'ws_close_requested',
          'auth_ok',
          'auth_rejected',
          'ws_next_closed',
          'ws_next_or_send_failed',
          'bridge_revoked',
          'signer_request',
          'signer_scope_denied',
          'signer_policy_denied',
          'signer_approved',
          'signer_denied',
          'subscription_closed'
        };
        if (allowed.contains(stage)) {
          _recordHostDiagnostic(tab, 'transport',
              level: stage.contains('failed') ||
                      stage.contains('denied') ||
                      stage.contains('rejected')
                  ? 'warn'
                  : 'info');
        }
      },
      pageOrigin: origin,
      reply: tab.controller.runJavaScript,
      prepare: (endpoint) async => current()
          ? widget.onPrepareFipsNavigation!(endpoint)
          : 'Document revoked.',
      approve: (request) async {
        if (!mounted || !current() || _activeTabId != tab.id) {
          return GraspFipsConsentResult.unavailable;
        }
        final remembered = await widget.signerStore.findPolicyRule(
          pageOrigin: origin,
          operation: request.policyOperation,
          target: request.endpoint,
          deviceNpub: identity,
        );
        if (!mounted || !current() || _activeTabId != tab.id) {
          return GraspFipsConsentResult.unavailable;
        }
        if (remembered?.allows == true) {
          return GraspFipsConsentResult.approved;
        }
        if (remembered != null) return GraspFipsConsentResult.denied;
        final target = Uri.parse(request.endpoint);
        final approval = await showDialog<SignerPromptResult>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Connect to private FIPS service?'),
            content: SelectableText(
                'Allow this page to read and send HTTP and relay data '
                'to the announced service for this tab? The announcement is supplied by '
                'the site. Approve only a service you recognise. Signing requests are '
                'approved separately. Reload, close the tab, lock, or disconnect to revoke.\n\n'
                'Page: $origin\nFIPS node: ${target.host.replaceFirst('.fips', '')}\n'
                'Port: ${target.port}\nPurpose: ${request.purpose}'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(
                      context, const SignerPromptResult(approved: false)),
                  child: const Text('Deny')),
              FilledButton(
                  onPressed: () => Navigator.pop(
                      context, const SignerPromptResult(approved: true)),
                  child: const Text('Once')),
              FilledButton(
                  onPressed: () => Navigator.pop(context,
                      const SignerPromptResult(approved: true, remember: true)),
                  child: const Text('Always allow')),
            ],
          ),
        );
        if (!current() || _activeTabId != tab.id) {
          return GraspFipsConsentResult.unavailable;
        }
        if (approval == null) return GraspFipsConsentResult.unavailable;
        if (!approval.approved) return GraspFipsConsentResult.denied;
        if (approval.remember) {
          await _rememberSignerPolicy(
            pageOrigin: origin,
            operation: request.policyOperation,
            target: request.endpoint,
            decision: SignerPolicyRuleDecision.allow,
            label: 'FIPS ${request.purpose} transport via '
                '${request.peerNpub}',
          );
          if (!current() || _activeTabId != tab.id) {
            return GraspFipsConsentResult.unavailable;
          }
        }
        return GraspFipsConsentResult.approved;
      },
    );
    tab.graspBridge = bridge;
    try {
      await tab.controller.runJavaScript(bridge.script);
    } catch (_) {
      bridge.close();
      if (identical(tab.graspBridge, bridge)) tab.graspBridge = null;
    }
  }

  Future<void> _injectIfTrusted(BrowserTab tab) async {
    if (Platform.isAndroid && !await tab.nativeChannelsReady) return;
    if (!mounted || tab.disposed) return;
    final url = tab.currentUrl ?? widget.config.flightDeckUrl;
    final origin = SignerPolicy.normalizeOrigin(url);
    final policy = _signerPolicy;
    if (!policy.canInject(url)) {
      setState(() {
        tab.message = 'Signer withheld for unsupported page: $url';
      });
      return;
    }
    final documentToken =
        tab.signerDocumentToken ??= TowerFipsProxy.capability();
    await tab.controller.runJavaScript(
      _bridgeScript(widget.config.devicePublicKeyHex,
          tab.graspBridge?.signingDocumentToken, documentToken, origin),
    );
    setState(() {
      tab.message = 'window.nostr injected for $origin';
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    for (final tab in _tabs) {
      _recordHostDiagnostic(tab, 'lifecycle');
      // Background/OS lock cannot retain a diagnostics retrieval grant.
      if (state != AppLifecycleState.resumed) {
        tab.clearDiagnosticsTransition();
        tab.revokeDiagnostics();
      }
    }
  }

  void _captureDiagnosticsTransition(BrowserTab tab, String targetUrl) {
    final origin = SignerPolicy.normalizeOrigin(tab.currentUrl ?? '');
    final target = SignerPolicy.normalizeOrigin(targetUrl);
    if (!widget.config.hasDeviceSecret || origin.isEmpty || target != origin) {
      tab.clearDiagnosticsTransition();
      return;
    }
    final scope = tab.diagnosticsScope;
    if (scope != null &&
        tab.diagnosticsWorkspace != null &&
        tab.signerDocumentToken != null) {
      tab._setDiagnosticsTransition(_DiagnosticsTransition(
          scope: scope,
          origin: origin,
          identity: widget.config.deviceNpub,
          documentToken: tab.signerDocumentToken!,
          workspace: tab.diagnosticsWorkspace!,
          expires: DateTime.now().add(const Duration(seconds: 30))));
    }
  }

  void _recordWebViewDiagnostic(BrowserTab tab, WebResourceError error) {
    final terminated =
        error.errorType == WebResourceErrorType.webContentProcessTerminated;
    if (tab.diagnosticsScope != null) {
      _recordHostDiagnostic(tab, 'webview', level: 'error');
    } else {
      final transition = tab._diagnosticsTransition;
      final errorOrigin = SignerPolicy.normalizeOrigin(error.url ?? '');
      if (transition != null &&
          !tab.disposed &&
          widget.config.hasDeviceSecret &&
          widget.config.deviceNpub == transition.identity &&
          DateTime.now().isBefore(transition.expires) &&
          (errorOrigin == transition.origin ||
              (terminated &&
                  SignerPolicy.normalizeOrigin(tab.currentUrl ?? '') ==
                      transition.origin))) {
        unawaited(_diagnosticsStore.append(transition.scope, [
          {
            'ts': DateTime.now().millisecondsSinceEpoch,
            'source': 'host',
            'level': 'error',
            'code': 'webview',
          }
        ]).catchError((Object _) => 0));
      }
    }
    if (terminated) {
      tab.clearDiagnosticsTransition();
      tab.revokeSigningDocument();
    }
  }

  void _recordHostDiagnostic(BrowserTab tab, String code,
      {String level = 'info'}) {
    final scope = tab.diagnosticsScope;
    if (scope == null || tab.disposed || !widget.config.hasDeviceSecret) return;
    unawaited(_diagnosticsStore.append(scope, [
      {
        'ts': DateTime.now().millisecondsSinceEpoch,
        'source': 'host',
        'level': level,
        'code': code,
      }
    ]).catchError((Object _) => 0));
  }

  Future<void> _onDiagnosticsMessage(BrowserTab tab, String requestId,
      String method, Map<String, dynamic> payload) async {
    final params = payload['params'];
    final workspace = params is Map ? params['workspaceId'] : null;
    final origin = SignerPolicy.normalizeOrigin(tab.currentUrl ?? '');
    final token = tab.signerDocumentToken;
    final epoch = tab.signerDocumentEpoch;
    final identity = widget.config.deviceNpub;
    bool valid() =>
        mounted &&
        !tab.disposed &&
        _tabById(tab.id) == tab &&
        _activeTabId == tab.id &&
        widget.config.hasDeviceSecret &&
        widget.config.deviceNpub == identity &&
        token != null &&
        payload['signerDocumentToken'] == token &&
        tab.signerDocumentToken == token &&
        tab.signerDocumentEpoch == epoch &&
        SignerPolicy.normalizeOrigin(tab.currentUrl ?? '') == origin &&
        _signerPolicy.canInject(tab.currentUrl ?? '');
    final transition = tab._diagnosticsTransition;
    final canCancelTransition = transition != null &&
        mounted &&
        !tab.disposed &&
        _tabById(tab.id) == tab &&
        _activeTabId == tab.id &&
        widget.config.hasDeviceSecret &&
        identity == transition.identity &&
        origin == transition.origin &&
        DateTime.now().isBefore(transition.expires) &&
        payload['signerDocumentToken'] == transition.documentToken;
    if (!valid() && canCancelTransition) {
      // Revocation/deletion only: an old document can cancel its pending native
      // transition, but can never read, append or restore any capability.
      if (workspace != transition.workspace) tab.clearDiagnosticsTransition();
      if (workspace == transition.workspace &&
          (method == 'diagnostics.clear' ||
              (method == 'diagnostics.configure' &&
                  params['enabled'] == false))) {
        tab.clearDiagnosticsTransition();
        if (method == 'diagnostics.clear') {
          await _diagnosticsStore.clear(transition.scope);
        }
        await _resolveSignerRequest(tab, requestId, {
          'result': method == 'diagnostics.clear'
              ? {'version': 1, 'cleared': true}
              : {'version': 1, 'enabled': false}
        });
        return;
      }
    }
    if (!valid() ||
        workspace is! String ||
        !RegExp(r'^[a-zA-Z0-9-]{1,80}$').hasMatch(workspace)) {
      await _resolveSignerRequest(
          tab, requestId, {'error': 'Diagnostics scope revoked or invalid.'});
      return;
    }
    final scope = DiagnosticsStore.scopeKey(
        origin, identity, workspace, tab.diagnosticsTabKey);
    // A request in another workspace revokes the old grant before any await.
    if (tab.diagnosticsWorkspace != workspace) {
      tab.clearDiagnosticsTransition();
      tab.diagnosticsConfigEpoch++;
      tab.diagnosticsScope = null;
      tab.diagnosticsWorkspace = null;
    }
    try {
      Map<String, dynamic> result;
      if (method == 'diagnostics.configure') {
        final configEpoch = ++tab.diagnosticsConfigEpoch;
        if (params['enabled'] != true) {
          tab.clearDiagnosticsTransition();
          tab.diagnosticsScope = null;
          tab.diagnosticsWorkspace = null;
          result = {'version': 1, 'enabled': false};
        } else {
          if (tab.diagnosticsConsentPending) {
            throw StateError('Diagnostics consent already pending.');
          }
          if (tab.diagnosticsScope != scope) {
            tab.diagnosticsConsentPending = true;
            bool approved;
            try {
              approved = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                            title: const Text('Allow local diagnostics?'),
                            content: Text(
                                '$origin requests sanitized local evidence for workspace $workspace in this tab.\n\nOnly event codes and bounded timing/status/stack metadata are saved for up to 30 minutes. No page text, payloads, screenshots or other tabs. Reports are sent separately by Flight Deck. Reload, navigation or locking revokes access.'),
                            actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Deny')),
                              FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Allow this document'))
                            ],
                          )) ==
                  true;
            } finally {
              tab.diagnosticsConsentPending = false;
            }
            if (!valid() ||
                !approved ||
                tab.diagnosticsConfigEpoch != configEpoch) {
              throw StateError('Diagnostics consent denied or revoked.');
            }
            final saved = await _diagnosticsStore.snapshot(scope);
            if (!valid() || tab.diagnosticsConfigEpoch != configEpoch) {
              throw StateError('Diagnostics scope revoked.');
            }
            tab.diagnosticsRecovered = saved.isNotEmpty;
            tab.diagnosticsScope = scope;
            tab.diagnosticsWorkspace = workspace;
            _recordHostDiagnostic(tab, 'lifecycle');
          }
          result = {'version': 1, 'enabled': true};
        }
      } else if (method == 'diagnostics.clear') {
        tab.clearDiagnosticsTransition();
        await _diagnosticsStore.clear(scope);
        tab.diagnosticsRecovered = false;
        result = {'version': 1, 'cleared': true};
      } else {
        if (tab.diagnosticsScope != scope) {
          throw StateError('Native diagnostics consent required.');
        }
        if (method == 'diagnostics.append') {
          final events = params['events'];
          if (events is! List) throw StateError('Invalid diagnostics events.');
          final accepted = await _diagnosticsStore.append(scope, events);
          result = {'version': 1, 'accepted': accepted};
        } else if (method == 'diagnostics.snapshot') {
          result = {
            'version': 1,
            'events': await _diagnosticsStore.snapshot(scope),
            'host': {
              'version': '0.1.7+9',
              'platform': Platform.operatingSystem
            },
            'recovered': tab.diagnosticsRecovered,
            'limitations': [
              'Bounded saved evidence; no OS crash dumps or crash-time sending.',
              'Host capture covers document readiness, main-frame WebView errors and available transport stage codes.'
            ]
          };
        } else {
          throw StateError('Unknown diagnostics method.');
        }
      }
      if (!valid() ||
          (method != 'diagnostics.configure' &&
              method != 'diagnostics.clear' &&
              tab.diagnosticsScope != scope)) {
        return;
      }
      await _resolveSignerRequest(tab, requestId, {'result': result});
    } catch (_) {
      if (valid()) {
        await _resolveSignerRequest(tab, requestId,
            {'error': 'Diagnostics unavailable, denied or revoked.'});
      }
    }
  }

  Future<void> _onSignerMessage(int tabId, JavaScriptMessage message) async {
    final tab = _tabById(tabId);
    if (tab == null) return;
    final payload = _decodeMessage(message.message);
    if (payload == null) return;
    final requestId = payload['id']?.toString() ?? '';
    final method = payload['method']?.toString() ?? '';
    if (requestId.isEmpty || method.isEmpty) return;

    if (method.startsWith('diagnostics.')) {
      final verified = await tab.nativeChannelsReady;
      if (!verified ||
          !(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
        await _resolveSignerRequest(tab, requestId,
            {'error': 'Verified native diagnostics channel unavailable.'});
        return;
      }
      await _onDiagnosticsMessage(tab, requestId, method, payload);
      return;
    }

    if (method == 'openTab') {
      final params = payload['params'] is Map<String, dynamic>
          ? payload['params'] as Map<String, dynamic>
          : <String, dynamic>{};
      final url = params['url']?.toString() ?? '';
      final normalized = _normalizeOpenTabUrl(
        url,
        tab.currentUrl ?? widget.config.flightDeckUrl,
      );
      if (normalized == null) {
        await _resolveSignerRequest(
          tab,
          requestId,
          {'error': 'invalid new tab URL'},
        );
        return;
      }
      _createTab(normalized);
      await _resolveSignerRequest(tab, requestId, {'result': true});
      return;
    }

    if (method == 'bookmarkIcon' ||
        method == 'removeBookmark' ||
        method == 'editBookmark') {
      final identity = widget.config.deviceNpub;
      final epoch = tab.signerDocumentEpoch;
      await _launcherSettingsQueue;
      if (!mounted ||
          tab.disposed ||
          identity != widget.config.deviceNpub ||
          epoch != tab.signerDocumentEpoch) {
        return;
      }
    }
    if (method == 'bookmarkIcon') {
      final params = payload['params'];
      if (tab.isHome || params is! Map<String, dynamic>) return;
      final url = canonicalBrowserBookmarkUrl(params['url']?.toString());
      final icon = safeBookmarkIconUrl(params['iconUrl']?.toString());
      if (url == null ||
          icon == null ||
          canonicalBrowserBookmarkUrl(tab.currentUrl) != url ||
          Uri.parse(url).origin != Uri.parse(icon).origin) {
        return;
      }
      final index = _bookmarks.indexWhere((b) => b.url == url);
      if (index < 0 || _bookmarks[index].iconUrl == icon) return;
      final original = _bookmarks[index];
      _bookmarks = List.of(_bookmarks)
        ..[index] = BrowserBookmark(
            title: original.title,
            url: original.url,
            iconUrl: icon,
            customImage: original.customImage,
            startup: original.startup);
      await _persistBookmarks();
      if (mounted) _reloadHomeTabs();
      return;
    }
    if (method == 'setStartup' || method == 'setLabelColour') {
      if (!tab.isHome || _restoringTabs) return;
      final params = payload['params'];
      if (params is! Map<String, dynamic>) return;
      final identity = widget.config.deviceNpub;
      final epoch = tab.signerDocumentEpoch;
      final syncEpoch = _signerSyncEpoch;
      bool current() =>
          mounted &&
          !tab.disposed &&
          tab.isHome &&
          tab.signerDocumentEpoch == epoch &&
          syncEpoch == _signerSyncEpoch &&
          identity == widget.config.deviceNpub;
      final saving = _launcherSettingsQueue.then((_) async {
        if (!current()) return;
        try {
          if (method == 'setLabelColour') {
            final colour = params['colour'];
            if (colour is! String ||
                safeLabelColour(colour) != colour.toLowerCase()) {
              return;
            }
            await _bookmarkStore.saveLabelColour(identity, colour);
            if (current()) _labelColour = safeLabelColour(colour);
          } else {
            final url = canonicalBrowserBookmarkUrl(params['url']?.toString());
            final enabled = params['enabled'];
            if (enabled is! bool ||
                url == null ||
                !_visibleBookmarks.any((b) => b.url == url)) {
              return;
            }
            if (url == _localFlightDeckBookmark?.url) {
              await _bookmarkStore.saveBuiltInStartup(identity, enabled);
              if (current()) _builtInStartup = enabled;
            } else {
              final updated = [
                for (final app in _bookmarks)
                  if (app.url != url)
                    app
                  else
                    BrowserBookmark(
                        title: app.title,
                        url: app.url,
                        iconUrl: app.iconUrl,
                        customImage: app.customImage,
                        startup: enabled)
              ];
              await _bookmarkStore.save(identity, updated);
              if (current()) _bookmarks = updated;
            }
          }
          // Update controls without reloading the home document or launching apps.
          if (current()) {
            for (final home
                in List<BrowserTab>.of(_tabs.where((t) => t.isHome))) {
              if (!current()) return;
              if (home.disposed || !home.isHome) continue;
              await home.controller.runJavaScript(
                  'document.querySelectorAll(".star").forEach(el => {const values = '
                  '${jsonEncode({
                    for (final app in _visibleBookmarks) app.url: app.startup
                  })};'
                  'const enabled = values[el.dataset.url] === true;'
                  'el.setAttribute("aria-pressed", String(enabled));'
                  'el.textContent = enabled ? "★" : "☆";});'
                  'document.querySelectorAll(".name").forEach(el => el.style.color = ${jsonEncode(_labelColour)});'
                  'document.getElementById("label-colour").value = ${jsonEncode(_labelColour)};');
            }
          }
        } catch (_) {
          if (mounted && current()) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content:
                    Text('Could not save launcher settings. Please retry.')));
            _loadHomeForTab(tab);
          }
        }
      });
      _launcherSettingsQueue = saving;
      await saving;
      return;
    }
    if (method == 'chooseBackground' || method == 'resetBackground') {
      if (!tab.isHome) return;
      final identity = widget.config.deviceNpub;
      final epoch = tab.signerDocumentEpoch;
      try {
        final image = method == 'resetBackground'
            ? null
            : await pickBookmarkImage(background: true);
        if (method != 'resetBackground' && image == null) return;
        if (!mounted ||
            tab.disposed ||
            !tab.isHome ||
            tab.signerDocumentEpoch != epoch ||
            identity != widget.config.deviceNpub) {
          return;
        }
        await _bookmarkStore.saveBackground(identity, image);
        if (!mounted || identity != widget.config.deviceNpub) return;
        _selectorBackground = image;
        _reloadHomeTabs();
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(error is AvatarUploadException
                  ? error.message
                  : 'Could not choose a background.')));
        }
      }
      return;
    }

    if (method == 'navigateTab' ||
        method == 'removeBookmark' ||
        method == 'editBookmark') {
      // Saved-app mutations are capabilities of the native home document only.
      if (!tab.isHome) return;
      final params = payload['params'] is Map<String, dynamic>
          ? payload['params'] as Map<String, dynamic>
          : <String, dynamic>{};
      final url = canonicalBrowserBookmarkUrl(params['url']?.toString());
      if (url == null || !_visibleBookmarks.any((b) => b.url == url)) return;
      if (method == 'editBookmark') {
        await _editBookmark(tab, url);
      } else if (method == 'removeBookmark') {
        await _removeBookmark(url);
      } else {
        _loadAddressForTab(tab, url, hideAddressBarAfterLoad: true);
      }
      return;
    }

    if (method == 'getPublicKey') {
      await _resolveSignerRequest(
        tab,
        requestId,
        {'result': widget.config.devicePublicKeyHex},
      );
      return;
    }

    if ((method == 'signEvent' || method == 'signNip98') &&
        !widget.config.hasDeviceSecret) {
      await _resolveSignerRequest(
          tab, requestId, {'error': NativeCoreBridge.signerLockedError});
      return;
    }

    final signingIdentity = widget.config.deviceNpub;
    final signingDocument = tab.graspBridge;
    final graspDocument = tab.graspBridge;
    final graspGrantEpoch = graspDocument?.grantEpoch;
    final signingPage = tab.currentUrl;
    final signingParams = payload['params'] is Map<String, dynamic>
        ? payload['params'] as Map<String, dynamic>
        : <String, dynamic>{};
    final meshTarget = _meshSigningTarget(method, signingParams);
    final documentToken = tab.signerDocumentToken;
    final documentEpoch = tab.signerDocumentEpoch;
    final nativeAuth = MeshAuthRequest.parse(method, signingParams);
    final pageOriginForAuth = SignerPolicy.normalizeOrigin(signingPage ?? '');
    // Tower pages must continue through verified Tower pairing, including after
    // disconnect. This is a separate, request-only capability for direct WApps.
    final driveAuth =
        graspDocument?.permitsDriveAuthentication(signingParams) == true;
    final serviceAuthGrant =
        graspDocument?.authenticationGrant(method, signingParams);
    final nip42Grant = method == 'signEvent' && signingParams['kind'] == 22242
        ? serviceAuthGrant
        : null;
    void traceNip42(String stage) {
      if (method == 'signEvent' && signingParams['kind'] == 22242) {
        graspDocument?.recordAuthentication(nip42Grant?.grantId, stage);
      }
    }

    traceNip42('signer_request');
    final graspAuth = driveAuth || serviceAuthGrant != null;
    final directAuth = graspAuth ||
        ((meshTarget != null ||
                method == 'signNip98' ||
                (method == 'signEvent' &&
                    {'27235', '22242'}
                        .contains(signingParams['kind']?.toString()))) &&
            _isFipsAppUrl(signingPage ?? '') &&
            pageOriginForAuth !=
                SignerPolicy.normalizeOrigin(widget.config.flightDeckUrl) &&
            pageOriginForAuth !=
                SignerPolicy.normalizeOrigin(widget.localFlightDeckUrl));
    bool nativeContextValid() =>
        ((meshTarget == null && !graspAuth && !directAuth) || _fipsEnabled) &&
        mounted &&
        _tabById(tabId) == tab &&
        _activeTabId == tabId &&
        widget.config.hasDeviceSecret &&
        widget.config.deviceNpub == signingIdentity &&
        tab.currentUrl == signingPage &&
        documentToken != null &&
        payload['signerDocumentToken'] == documentToken &&
        tab.signerDocumentToken == documentToken &&
        tab.signerDocumentEpoch == documentEpoch &&
        (!graspAuth ||
            (identical(tab.graspBridge, graspDocument) &&
                graspDocument!.grantEpoch == graspGrantEpoch &&
                graspDocument.permitsAuthentication(method, signingParams) &&
                (serviceAuthGrant == null ||
                    graspDocument
                            .authenticationGrant(method, signingParams)
                            ?.grantId ==
                        serviceAuthGrant.grantId)));
    Future<void> auditNativeDenial(String outcome) =>
        widget.signerStore.appendAudit(
          SignerAuditEntry.create(
            pageOrigin: pageOriginForAuth,
            targetOrigin: SignerPolicy.normalizeOrigin(nativeAuth!.target),
            targetUrl: nativeAuth.target,
            method: nativeAuth.operation,
            deviceNpub: signingIdentity,
            allowed: false,
            outcome: outcome,
          ),
        );
    var nativeApproved = false;
    var nativeRemembered = false;
    bool signingContextValid() {
      if (directAuth) return nativeApproved && nativeContextValid();
      if (meshTarget == null) return true;
      if (!mounted ||
          _tabById(tabId) != tab ||
          !widget.config.hasDeviceSecret ||
          widget.config.deviceNpub != signingIdentity ||
          tab.currentUrl != signingPage) {
        return false;
      }
      // Existing directly loaded FIPS WApps may still sign their own origin.
      final pageOrigin = SignerPolicy.normalizeOrigin(signingPage ?? '');
      if (Uri.tryParse(pageOrigin)?.host.endsWith('.fips') == true &&
          pageOrigin == SignerPolicy.normalizeOrigin(meshTarget)) {
        return true;
      }
      // Tower's transport authorizes HTTP requests, not relay authentication.
      final scheme = Uri.tryParse(meshTarget)?.scheme;
      if (scheme != 'http' && scheme != 'https') return false;
      return signingDocument != null &&
          identical(tab.graspBridge, signingDocument) &&
          signingDocument.permitsMeshSigning(
              payload['towerDocumentToken'] is String
                  ? payload['towerDocumentToken'] as String
                  : null,
              meshTarget);
    }

    if (directAuth) {
      if (nativeAuth == null || !nativeContextValid() || tab.meshAuthPending) {
        traceNip42('signer_scope_denied');
        await _resolveSignerRequest(tab, requestId, {
          'error': 'fips_signing_scope_required: An active exact FIPS service '
              'grant is required for signing.'
        });
        return;
      }
      final nativePolicyOperation = serviceAuthGrant?.policyOperation ??
          (method == 'signEvent' ? 'signEvent' : 'nip98');
      final nativePolicyTarget = serviceAuthGrant?.endpoint ??
          (method == 'signEvent'
              ? _signEventPolicyTarget(signingParams)
              : SignerPolicy.normalizeOrigin(nativeAuth.target));
      final rule = await widget.signerStore.findPolicyRule(
        pageOrigin: pageOriginForAuth,
        operation: nativePolicyOperation,
        target: nativePolicyTarget,
        deviceNpub: signingIdentity,
      );
      if (!nativeContextValid()) return;
      if (rule != null && !rule.allows) {
        traceNip42('signer_policy_denied');
        await auditNativeDenial('policy_denied');
        if (!nativeContextValid()) return;
        await _resolveSignerRequest(
            tab, requestId, {'error': 'denied by signer policy'});
        return;
      }
      if (tab.meshAuthPending) {
        await _resolveSignerRequest(tab, requestId,
            {'error': 'Another authentication approval is pending.'});
        return;
      }
      nativeRemembered = serviceAuthGrant != null && rule?.allows == true;
      SignerPromptResult nativeApproval;
      if (nativeRemembered) {
        nativeApproval = const SignerPromptResult(approved: true);
      } else {
        tab.meshAuthPending = true;
        try {
          nativeApproval = await _confirmMeshAuthentication(
            pageOriginForAuth,
            nativeAuth,
            signingIdentity,
            serviceAuthGrant,
          );
        } finally {
          tab.meshAuthPending = false;
        }
      }
      nativeApproved = nativeApproval.approved;
      traceNip42(nativeApproved ? 'signer_approved' : 'signer_denied');
      if (!nativeContextValid()) return;
      if (!nativeApproved) {
        await auditNativeDenial('user_denied');
        if (!nativeContextValid()) return;
        await _resolveSignerRequest(tab, requestId, {'error': 'denied'});
        return;
      }
      if (nativeApproval.remember && serviceAuthGrant != null) {
        await _rememberSignerPolicy(
          pageOrigin: pageOriginForAuth,
          operation: nativePolicyOperation,
          target: nativePolicyTarget,
          decision: SignerPolicyRuleDecision.allow,
          label: 'FIPS ${serviceAuthGrant.purpose} '
              '${serviceAuthGrant.operation} via ${serviceAuthGrant.peerNpub}',
        );
      }
    }

    if (!signingContextValid()) {
      await _resolveSignerRequest(tab, requestId, {
        'error': 'fips_signing_scope_required: An active exact FIPS service '
            'grant is required for signing.'
      });
      return;
    }

    if (method == 'signEvent') {
      final event = payload['params'] is Map<String, dynamic>
          ? payload['params'] as Map<String, dynamic>
          : <String, dynamic>{};
      final pageUrl = tab.currentUrl ?? widget.config.flightDeckUrl;
      final pageOrigin = SignerPolicy.normalizeOrigin(pageUrl);
      if (!_signerPolicy.canSignNip07(pageUrl)) {
        final reason = 'unsupported NIP-07 page origin: $pageOrigin';
        setState(() {
          tab.message = 'Signer denied: $reason';
        });
        await _resolveSignerRequest(tab, requestId, {'error': reason});
        return;
      }
      const operation = 'signEvent';
      final policyTarget = _signEventPolicyTarget(event);
      final policyRule = await widget.signerStore.findPolicyRule(
        pageOrigin: pageOrigin,
        operation: operation,
        target: policyTarget,
        deviceNpub: widget.config.deviceNpub,
      );
      if (policyRule != null && !policyRule.allows) {
        await _recordNip07Audit(
          pageOrigin: pageOrigin,
          targetUrl: nativeApproved ? nativeAuth!.target : pageUrl,
          event: event,
          allowed: false,
          outcome: 'policy_denied',
          reason: 'denied by signer policy',
          rememberedApproval: true,
        );
        await _resolveSignerRequest(
          tab,
          requestId,
          {'error': 'denied by signer policy'},
        );
        return;
      }
      final remembered = policyRule != null && policyRule.allows;
      final approval = (nativeApproved || remembered)
          ? const SignerPromptResult(approved: true)
          : await _confirmSignEvent(event, pageOrigin);
      if (!approval.approved) {
        if (approval.denyAlways) {
          await _rememberSignerPolicy(
            pageOrigin: pageOrigin,
            operation: operation,
            target: policyTarget,
            decision: SignerPolicyRuleDecision.deny,
            label: 'Sign event ${policyTarget.replaceFirst('kind:', 'kind ')}',
          );
        }
        await _recordNip07Audit(
          pageOrigin: pageOrigin,
          targetUrl: nativeApproved ? nativeAuth!.target : pageUrl,
          event: event,
          allowed: false,
          outcome: approval.denyAlways ? 'policy_saved_deny' : 'user_denied',
          reason: approval.denyAlways
              ? 'denied by user and saved as policy'
              : 'denied by user',
        );
        await _resolveSignerRequest(tab, requestId, {'error': 'denied'});
        return;
      }
      if (approval.remember) {
        await _rememberSignerPolicy(
          pageOrigin: pageOrigin,
          operation: operation,
          target: policyTarget,
          decision: SignerPolicyRuleDecision.allow,
          label: 'Sign event ${policyTarget.replaceFirst('kind:', 'kind ')}',
        );
      }
      if (!signingContextValid()) {
        await _resolveSignerRequest(tab, requestId,
            {'error': 'Mesh pairing or signing identity changed.'});
        return;
      }
      final result = await widget.bridge.signEvent(
        config: widget.config,
        event: event,
      );
      if (!signingContextValid()) return;
      if (!result.ok) {
        traceNip42('signer_failed');
        await _recordNip07Audit(
          pageOrigin: pageOrigin,
          targetUrl: nativeApproved ? nativeAuth!.target : pageUrl,
          event: event,
          allowed: false,
          outcome: 'signer_error',
          reason: result.error ?? 'native signer failed',
        );
        await _resolveSignerRequest(tab, requestId, {'error': result.error});
        return;
      }
      await _recordNip07Audit(
        pageOrigin: pageOrigin,
        targetUrl: nativeApproved ? nativeAuth!.target : pageUrl,
        event: event,
        allowed: true,
        outcome: nativeApproved
            ? nativeRemembered
                ? 'signed_with_scoped_service_policy'
                : 'signed_exact_request'
            : remembered
                ? 'signed_with_policy'
                : 'signed',
        rememberedApproval:
            !nativeApproved && (remembered || approval.remember),
      );
      if (!signingContextValid()) return;
      traceNip42('signer_signed');
      await _resolveSignerRequest(tab, requestId, {
        'result': result.json,
      });
      return;
    }

    if (method == 'nip44.encrypt' || method == 'nip44.decrypt') {
      await _handleNip44Request(
        tab: tab,
        requestId: requestId,
        method: method,
        params: payload['params'] is Map<String, dynamic>
            ? payload['params'] as Map<String, dynamic>
            : <String, dynamic>{},
      );
      return;
    }

    if (method == 'signNip98') {
      final request = payload['params'] is Map<String, dynamic>
          ? payload['params'] as Map<String, dynamic>
          : <String, dynamic>{};
      final requestMethod = request['httpMethod']?.toString() ?? 'GET';
      final requestUrl = request['url']?.toString() ?? '';
      final requestBody = request['body']?.toString();
      final scopedPolicy = SignerPolicy(trustedOrigins: [
        ..._signerPolicy.trustedOrigins,
        if (nativeApproved && nativeContextValid()) pageOriginForAuth,
        if (meshTarget != null && signingContextValid())
          SignerPolicy.normalizeOrigin(meshTarget),
      ]);
      final decision = scopedPolicy.validateNip98(
        pageUrl: tab.currentUrl ?? widget.config.flightDeckUrl,
        targetUrl: requestUrl,
        method: requestMethod,
        body: requestBody,
      );
      if (!decision.allowed) {
        setState(() {
          tab.message = 'Signer denied: ${decision.reason}';
        });
        await _recordSignerAudit(
          decision: decision,
          targetUrl: requestUrl,
          method: requestMethod,
          allowed: false,
          outcome: 'policy_denied',
          reason: decision.reason,
        );
        await _resolveSignerRequest(tab, requestId, {'error': decision.reason});
        return;
      }
      const policyOperation = 'nip98';
      final policyRule = await widget.signerStore.findPolicyRule(
        pageOrigin: decision.pageOrigin,
        operation: policyOperation,
        target: decision.targetOrigin,
        deviceNpub: widget.config.deviceNpub,
      );
      if (policyRule != null && !policyRule.allows) {
        await _recordSignerAudit(
          decision: decision,
          targetUrl: requestUrl,
          method: decision.method,
          allowed: false,
          outcome: 'policy_denied',
          reason: 'denied by signer policy',
          rememberedApproval: true,
        );
        await _resolveSignerRequest(
          tab,
          requestId,
          {'error': 'denied by signer policy'},
        );
        return;
      }
      final rememberedPolicy = policyRule != null && policyRule.allows;
      final rememberedApproval = widget.config.rememberNip98Approvals &&
          await widget.signerStore.hasApproval(
            pageOrigin: decision.pageOrigin,
            targetOrigin: decision.targetOrigin,
            deviceNpub: widget.config.deviceNpub,
          );
      final remembered = rememberedPolicy || rememberedApproval;
      final approval = (nativeApproved || remembered)
          ? const SignerPromptResult(approved: true)
          : await _confirmNip98(request, decision);
      if (!approval.approved) {
        if (approval.denyAlways) {
          await _rememberSignerPolicy(
            pageOrigin: decision.pageOrigin,
            operation: policyOperation,
            target: decision.targetOrigin,
            decision: SignerPolicyRuleDecision.deny,
            label: 'NIP-98 ${decision.pageOrigin} -> ${decision.targetOrigin}',
          );
        }
        await _recordSignerAudit(
          decision: decision,
          targetUrl: requestUrl,
          method: decision.method,
          allowed: false,
          outcome: approval.denyAlways ? 'policy_saved_deny' : 'user_denied',
          reason: approval.denyAlways
              ? 'denied by user and saved as policy'
              : 'denied by user',
        );
        await _resolveSignerRequest(tab, requestId, {'error': 'denied'});
        return;
      }
      if (approval.remember) {
        await _rememberSignerPolicy(
          pageOrigin: decision.pageOrigin,
          operation: policyOperation,
          target: decision.targetOrigin,
          decision: SignerPolicyRuleDecision.allow,
          label: 'NIP-98 ${decision.pageOrigin} -> ${decision.targetOrigin}',
        );
      }
      if (approval.remember && widget.config.rememberNip98Approvals) {
        await widget.signerStore.rememberApproval(
          SignerApproval(
            pageOrigin: decision.pageOrigin,
            targetOrigin: decision.targetOrigin,
            deviceNpub: widget.config.deviceNpub,
            createdAt: DateTime.now().toUtc(),
            label: 'NIP-98 ${decision.pageOrigin}',
          ),
        );
      }
      if (!signingContextValid()) {
        await _resolveSignerRequest(tab, requestId,
            {'error': 'Mesh pairing or signing identity changed.'});
        return;
      }
      final result = await widget.bridge.signNip98(
        config: widget.config,
        method: decision.method,
        url: requestUrl,
        body: requestBody,
      );
      if (!signingContextValid()) return;
      if (!result.ok) {
        await _recordSignerAudit(
          decision: decision,
          targetUrl: requestUrl,
          method: decision.method,
          allowed: false,
          outcome: 'signer_error',
          reason: result.error ?? 'native signer failed',
          rememberedApproval: remembered,
        );
        await _resolveSignerRequest(tab, requestId, {'error': result.error});
        return;
      }
      await _recordSignerAudit(
        decision: decision,
        targetUrl: requestUrl,
        method: decision.method,
        allowed: true,
        outcome: nativeApproved
            ? 'signed_exact_request'
            : remembered
                ? 'signed_with_remembered_approval'
                : 'signed',
        rememberedApproval:
            !nativeApproved && (remembered || approval.remember),
      );
      if (!signingContextValid()) return;
      await _resolveSignerRequest(tab, requestId, {
        'result': result.json['authorization'],
        'event': result.json['event'],
      });
    }
  }

  String? _meshSigningTarget(String method, Map<String, dynamic> params) {
    final urls = <String>[];
    if (method == 'signNip98') urls.add(params['url']?.toString() ?? '');
    if (method == 'signEvent' &&
        {'27235', '22242'}.contains(params['kind']?.toString()) &&
        params['tags'] is List) {
      for (final tag in params['tags'] as List) {
        if (tag is List &&
            tag.length >= 2 &&
            (tag[0] == 'u' || tag[0] == 'relay')) {
          urls.add(tag[1].toString());
        }
      }
    }
    for (final url in urls) {
      if (Uri.tryParse(url)?.host.endsWith('.fips') == true) {
        // Multiple targets cannot inherit a grant for just one of them.
        return urls.length == 1 ? url : 'http://ambiguous.fips/';
      }
    }
    return null;
  }

  Future<SignerPromptResult> _confirmMeshAuthentication(
    String pageOrigin,
    MeshAuthRequest request,
    String identity,
    FipsAuthenticationGrant? grant,
  ) async {
    return await showDialog<SignerPromptResult>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Approve private app authentication?'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Requesting website'),
                  SelectableText(pageOrigin),
                  const SizedBox(height: 12),
                  Text('Exact target · ${request.operation}'),
                  SelectableText(request.target),
                  const SizedBox(height: 12),
                  Text('Signing identity: $identity'),
                  if (grant != null) ...[
                    const SizedBox(height: 12),
                    Text('Service purpose: ${grant.purpose}'),
                    SelectableText('${grant.peerNpub} at ${grant.endpoint}'),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                      'Sign this authentication request only. The website '
                      'supplied this address; appearing in chat or an app list does '
                      'not verify it. No other address or port is approved.'),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(
                      context, const SignerPromptResult(approved: false)),
                  child: const Text('Deny')),
              FilledButton(
                  onPressed: () => Navigator.pop(
                      context, const SignerPromptResult(approved: true)),
                  child: const Text('Once')),
              if (grant != null)
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    const SignerPromptResult(
                      approved: true,
                      remember: true,
                    ),
                  ),
                  child: const Text('Always allow'),
                ),
            ],
          ),
        ) ??
        const SignerPromptResult(approved: false);
  }

  Map<String, dynamic>? _decodeMessage(String message) {
    try {
      final parsed = jsonDecode(message);
      return parsed is Map<String, dynamic> ? parsed : null;
    } catch (_) {
      return null;
    }
  }

  String _signEventPolicyTarget(Map<String, dynamic> event) {
    return 'kind:${event['kind']?.toString() ?? 'unknown'}';
  }

  Future<void> _rememberSignerPolicy({
    required String pageOrigin,
    required String operation,
    required String target,
    required SignerPolicyRuleDecision decision,
    required String label,
  }) {
    return widget.signerStore.rememberPolicyRule(
      SignerPolicyRule(
        pageOrigin: pageOrigin,
        operation: operation,
        target: target,
        deviceNpub: widget.config.deviceNpub,
        decision: decision,
        createdAt: DateTime.now().toUtc(),
        label: label,
      ),
    );
  }

  Future<SignerPromptResult> _confirmNip98(
    Map<String, dynamic> request,
    SignerPolicyDecision decision,
  ) async {
    final url = request['url']?.toString() ?? '';
    return await showDialog<SignerPromptResult>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Approve NIP-98 signature'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('WebView origin: ${decision.pageOrigin}'),
                  Text('Target origin: ${decision.targetOrigin}'),
                  Text('Method: ${decision.method}'),
                  Text('URL: $url'),
                  const Text('Event kind: 27235'),
                  Text('Device: ${widget.config.deviceNpub}'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(
                    const SignerPromptResult(
                      approved: false,
                      denyAlways: true,
                    ),
                  ),
                  child: const Text('Deny always'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(
                    const SignerPromptResult(approved: false),
                  ),
                  child: const Text('Deny'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    const SignerPromptResult(approved: true),
                  ),
                  child: const Text('Approve'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    const SignerPromptResult(
                      approved: true,
                      remember: true,
                    ),
                  ),
                  child: const Text('Approve always'),
                ),
              ],
            );
          },
        ) ??
        const SignerPromptResult(approved: false);
  }

  Future<SignerPromptResult> _confirmSignEvent(
    Map<String, dynamic> event,
    String pageOrigin,
  ) async {
    final kind = event['kind']?.toString() ?? 'unknown';
    final content = event['content']?.toString() ?? '';
    final tags = event['tags'] is List ? event['tags'] as List<dynamic> : [];
    return await showDialog<SignerPromptResult>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Approve Nostr event signature'),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Website: $pageOrigin'),
                    Text('Kind: $kind'),
                    Text('Tags: ${tags.length}'),
                    Text('Device: ${widget.config.deviceNpub}'),
                    if (content.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      const Text('Content preview:'),
                      SelectableText(
                        content.length > 500
                            ? '${content.substring(0, 500)}...'
                            : content,
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(
                    const SignerPromptResult(
                      approved: false,
                      denyAlways: true,
                    ),
                  ),
                  child: const Text('Reject always'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(
                    const SignerPromptResult(approved: false),
                  ),
                  child: const Text('Reject'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    const SignerPromptResult(approved: true),
                  ),
                  child: const Text('Sign'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    const SignerPromptResult(
                      approved: true,
                      remember: true,
                    ),
                  ),
                  child: const Text('Sign always'),
                ),
              ],
            );
          },
        ) ??
        const SignerPromptResult(approved: false);
  }

  Future<void> _handleNip44Request({
    required BrowserTab tab,
    required String requestId,
    required String method,
    required Map<String, dynamic> params,
  }) async {
    final pageUrl = tab.currentUrl ?? widget.config.flightDeckUrl;
    final pageOrigin = SignerPolicy.normalizeOrigin(pageUrl);
    if (!_signerPolicy.canSignNip07(pageUrl)) {
      final reason = 'unsupported NIP-44 page origin: $pageOrigin';
      setState(() {
        tab.message = 'Signer denied: $reason';
      });
      await _resolveSignerRequest(tab, requestId, {'error': reason});
      return;
    }

    final peerPubkey = params['peerPubkey']?.toString() ?? '';
    final payload = params['payload']?.toString() ?? '';
    final operation = method == 'nip44.encrypt' ? 'encrypt' : 'decrypt';
    final policyRule = await widget.signerStore.findPolicyRule(
      pageOrigin: pageOrigin,
      operation: method,
      target: _nip44PolicyTarget,
      deviceNpub: widget.config.deviceNpub,
    );
    if (policyRule != null && !policyRule.allows) {
      await _recordNip44Audit(
        pageOrigin: pageOrigin,
        peerPubkey: peerPubkey,
        operation: operation,
        allowed: false,
        outcome: 'policy_denied',
        reason: 'denied by signer policy',
        rememberedApproval: true,
      );
      await _resolveSignerRequest(
        tab,
        requestId,
        {'error': 'denied by signer policy'},
      );
      return;
    }
    final remembered = policyRule != null && policyRule.allows;
    final approval = remembered
        ? const SignerPromptResult(approved: true)
        : await _confirmNip44(
            operation: operation,
            pageOrigin: pageOrigin,
            peerPubkey: peerPubkey,
            payload: payload,
          );
    if (!approval.approved) {
      if (approval.denyAlways) {
        await _rememberSignerPolicy(
          pageOrigin: pageOrigin,
          operation: method,
          target: _nip44PolicyTarget,
          decision: SignerPolicyRuleDecision.deny,
          label: 'NIP-44 $operation for $pageOrigin',
        );
      }
      await _recordNip44Audit(
        pageOrigin: pageOrigin,
        peerPubkey: peerPubkey,
        operation: operation,
        allowed: false,
        outcome: approval.denyAlways ? 'policy_saved_deny' : 'user_denied',
        reason: approval.denyAlways
            ? 'denied by user and saved as policy'
            : 'denied by user',
      );
      await _resolveSignerRequest(tab, requestId, {'error': 'denied'});
      return;
    }
    if (approval.remember) {
      await _rememberSignerPolicy(
        pageOrigin: pageOrigin,
        operation: method,
        target: _nip44PolicyTarget,
        decision: SignerPolicyRuleDecision.allow,
        label: 'NIP-44 $operation for $pageOrigin',
      );
    }

    final result = method == 'nip44.encrypt'
        ? await widget.bridge.nip44Encrypt(
            config: widget.config,
            peerPubkey: peerPubkey,
            plaintext: payload,
          )
        : await widget.bridge.nip44Decrypt(
            config: widget.config,
            peerPubkey: peerPubkey,
            ciphertext: payload,
          );
    if (!result.ok) {
      await _recordNip44Audit(
        pageOrigin: pageOrigin,
        peerPubkey: peerPubkey,
        operation: operation,
        allowed: false,
        outcome: 'signer_error',
        reason: result.error ?? 'native NIP-44 failed',
        rememberedApproval: remembered,
      );
      await _resolveSignerRequest(tab, requestId, {'error': result.error});
      return;
    }

    await _recordNip44Audit(
      pageOrigin: pageOrigin,
      peerPubkey: peerPubkey,
      operation: operation,
      allowed: true,
      outcome: remembered ? '${operation}_with_policy' : operation,
      rememberedApproval: remembered || approval.remember,
    );
    await _resolveSignerRequest(tab, requestId, {
      'result': operation == 'encrypt'
          ? result.json['ciphertext']
          : result.json['plaintext'],
    });
  }

  Future<SignerPromptResult> _confirmNip44({
    required String operation,
    required String pageOrigin,
    required String peerPubkey,
    required String payload,
  }) async {
    final title = operation == 'encrypt'
        ? 'Approve NIP-44 encryption'
        : 'Approve NIP-44 decryption';
    return await showDialog<SignerPromptResult>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text(title),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Website: $pageOrigin'),
                    Text('Peer pubkey: $peerPubkey'),
                    Text('Device: ${widget.config.deviceNpub}'),
                    if (payload.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(operation == 'encrypt'
                          ? 'Plaintext preview:'
                          : 'Ciphertext preview:'),
                      SelectableText(
                        payload.length > 500
                            ? '${payload.substring(0, 500)}...'
                            : payload,
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(
                    const SignerPromptResult(
                      approved: false,
                      denyAlways: true,
                    ),
                  ),
                  child: const Text('Deny always'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(
                    const SignerPromptResult(approved: false),
                  ),
                  child: const Text('Deny'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    const SignerPromptResult(approved: true),
                  ),
                  child: const Text('Approve'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    const SignerPromptResult(
                      approved: true,
                      remember: true,
                    ),
                  ),
                  child: const Text('Approve always'),
                ),
              ],
            );
          },
        ) ??
        const SignerPromptResult(approved: false);
  }

  Future<void> _recordSignerAudit({
    required SignerPolicyDecision decision,
    required String targetUrl,
    required String method,
    required bool allowed,
    required String outcome,
    String reason = '',
    bool rememberedApproval = false,
  }) async {
    await widget.signerStore.appendAudit(
      SignerAuditEntry.create(
        pageOrigin: decision.pageOrigin,
        targetOrigin: decision.targetOrigin,
        targetUrl: targetUrl,
        method: method,
        deviceNpub: widget.config.deviceNpub,
        allowed: allowed,
        outcome: outcome,
        reason: reason,
        rememberedApproval: rememberedApproval,
      ),
    );
  }

  Future<void> _recordNip07Audit({
    required String pageOrigin,
    required String targetUrl,
    required Map<String, dynamic> event,
    required bool allowed,
    required String outcome,
    String reason = '',
    bool rememberedApproval = false,
  }) async {
    await widget.signerStore.appendAudit(
      SignerAuditEntry.create(
        pageOrigin: pageOrigin,
        targetOrigin: pageOrigin,
        targetUrl: targetUrl,
        method: 'signEvent kind ${event['kind'] ?? 'unknown'}',
        deviceNpub: widget.config.deviceNpub,
        allowed: allowed,
        outcome: outcome,
        reason: reason,
        rememberedApproval: rememberedApproval,
      ),
    );
  }

  Future<void> _recordNip44Audit({
    required String pageOrigin,
    required String peerPubkey,
    required String operation,
    required bool allowed,
    required String outcome,
    String reason = '',
    bool rememberedApproval = false,
  }) async {
    await widget.signerStore.appendAudit(
      SignerAuditEntry.create(
        pageOrigin: pageOrigin,
        targetOrigin: pageOrigin,
        targetUrl: peerPubkey,
        method: 'nip44.$operation',
        deviceNpub: widget.config.deviceNpub,
        allowed: allowed,
        outcome: outcome,
        reason: reason,
        rememberedApproval: rememberedApproval,
      ),
    );
  }

  Future<void> _resolveSignerRequest(
    BrowserTab tab,
    String id,
    Map<String, dynamic> payload,
  ) async {
    final encoded = jsonEncode(payload);
    await tab.controller.runJavaScript(
      'window.__wingmanResolve && window.__wingmanResolve(${jsonEncode(id)}, $encoded);',
    );
  }

  Future<void> _injectTabCapture(BrowserTab tab) async {
    await tab.controller.runJavaScript(_tabCaptureScript());
  }

  String _tabCaptureScript() {
    return '''
(() => {
  if (window.__wingmanTabCapture) return;
  window.__wingmanTabCapture = true;
  let seq = 0;
  function openWingmanTab(rawUrl) {
    if (!rawUrl || !window.WingmanSigner) return Promise.resolve(false);
    let href;
    try {
      href = new URL(String(rawUrl), window.location.href).href;
    } catch (_) {
      return Promise.resolve(false);
    }
    const id = `tab-\${++seq}`;
    WingmanSigner.postMessage(JSON.stringify({
      id,
      method: 'openTab',
      params: { url: href },
    }));
    return Promise.resolve(true);
  }
  const originalWindowOpen = window.open ? window.open.bind(window) : null;
  window.open = (url, target, features) => {
    const normalizedTarget = String(target || '_blank').toLowerCase();
    if (normalizedTarget !== '_self') {
      openWingmanTab(url);
      return null;
    }
    if (originalWindowOpen) return originalWindowOpen(url, target, features);
    if (url) window.location.href = String(url);
    return null;
  };
  document.addEventListener('click', (event) => {
    const target = event.target;
    const anchor = target && target.closest ? target.closest('a[href]') : null;
    if (!anchor) return;
    const linkTarget = String(anchor.getAttribute('target') || '').toLowerCase();
    if (!linkTarget || linkTarget === '_self') return;
    event.preventDefault();
    openWingmanTab(anchor.href);
  }, true);
})();
''';
  }

  String _bridgeScript(String devicePublicKeyHex, String? towerDocumentToken,
      String signerDocumentToken, String pageOrigin) {
    final escapedPublicKey =
        devicePublicKeyHex.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    return '''
(() => {
  if (window !== window.top || location.origin !== ${jsonEncode(pageOrigin)}) return;
  const signerDocumentToken = ${jsonEncode(signerDocumentToken)};
  if (window.nostr && window.nostr.__wingmanDocument === signerDocumentToken) return;
  const pending = new Map();
  let seq = 0;
  window.__wingmanResolve = (id, payload) => {
    const entry = pending.get(id);
    if (!entry) return;
    pending.delete(id);
    if (payload && payload.error) entry.reject(new Error(String(payload.error)));
    else entry.resolve(payload ? payload.result : undefined);
  };
  function callNative(method, params) {
    const id = String(++seq);
    const message = JSON.stringify({ id, method, params: params || {}, signerDocumentToken, towerDocumentToken: ${jsonEncode(towerDocumentToken)} });
    const promise = new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
    });
    if (method.startsWith('diagnostics.')) {
      // Revoked documents may never receive another native callback.
      const timeout = setTimeout(() => {
        const entry = pending.get(id);
        if (!entry) return;
        pending.delete(id);
        entry.reject(new Error('Diagnostics request expired or revoked.'));
      }, 30000);
      promise.then(() => clearTimeout(timeout), () => clearTimeout(timeout));
    }
    WingmanSigner.postMessage(message);
    return promise;
  }
  if (${Platform.isAndroid || Platform.isIOS || Platform.isMacOS}) Object.defineProperty(window, 'wingmanDiagnostics', {configurable: true, value: Object.freeze({
    version: 1,
    configure: (params) => callNative('diagnostics.configure', params),
    append: (params) => callNative('diagnostics.append', params),
    snapshot: (params) => callNative('diagnostics.snapshot', params),
    clear: (params) => callNative('diagnostics.clear', params),
  })});
  window.nostr = {
    __wingman: true,
    __wingmanDocument: signerDocumentToken,
    getPublicKey: () => callNative('getPublicKey').then((value) => value || "$escapedPublicKey"),
    signNip98: (request) => callNative('signNip98', request),
    signEvent: (event) => callNative('signEvent', event),
    getRelays: () => Promise.resolve({}),
    nip04: {
      encrypt: () => Promise.reject(new Error('nip04 encryption is not enabled in Nostr Browser yet')),
      decrypt: () => Promise.reject(new Error('nip04 decryption is not enabled in Nostr Browser yet')),
    },
    nip44: {
      encrypt: (peerPubkey, plaintext) => callNative('nip44.encrypt', { peerPubkey, payload: plaintext }),
      decrypt: (peerPubkey, ciphertext) => callNative('nip44.decrypt', { peerPubkey, payload: ciphertext }),
    },
  };
})();
''';
  }
}

class _TabReorderHandle extends StatelessWidget {
  const _TabReorderHandle({
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isTouchPlatform = switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    if (isTouchPlatform) {
      return ReorderableDelayedDragStartListener(
        index: index,
        child: child,
      );
    }
    return ReorderableDragStartListener(
      index: index,
      child: child,
    );
  }
}

const _tabColours = <String, Color>{
  'Red': Colors.red,
  'Orange': Colors.orange,
  'Yellow': Colors.amber,
  'Green': Colors.green,
  'Blue': Colors.blue,
  'Purple': Colors.purple,
  'Pink': Colors.pink,
};

class _BrowserTabButton extends StatelessWidget {
  const _BrowserTabButton({
    required this.title,
    required this.active,
    required this.fipsTransport,
    required this.closeable,
    required this.onPressed,
    required this.onClose,
    required this.onSecondaryTapUp,
    this.tabColour,
    this.width = 190,
  });

  final String title;
  final bool active;
  final bool fipsTransport;
  final bool closeable;
  final VoidCallback onPressed;
  final VoidCallback onClose;
  final double width;
  final Color? tabColour;
  final GestureTapUpCallback onSecondaryTapUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: tabColour == null
            ? (active ? colors.surface : Colors.transparent)
            : Color.alphaBlend(
                tabColour!.withValues(alpha: active ? 0.28 : 0.14),
                active ? colors.surface : colors.surfaceContainerHighest,
              ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
        child: InkWell(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
          onTap: onPressed,
          onSecondaryTapUp: onSecondaryTapUp,
          child: Container(
            width: width,
            height: 34,
            padding: const EdgeInsets.only(left: 12, right: 4),
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(6),
              ),
              border: Border.all(
                color: tabColour ??
                    (active ? colors.outlineVariant : Colors.transparent),
                width: active && tabColour != null ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Tooltip(
                  message: fipsTransport
                      ? 'Encrypted FIPS mesh transport'
                      : 'Web transport',
                  child: Icon(
                    fipsTransport ? Icons.hub_outlined : Icons.public,
                    key: fipsTransport
                        ? const ValueKey('fips-transport-indicator')
                        : null,
                    size: 16,
                    color: active ? colors.onSurface : colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          active ? colors.onSurface : colors.onSurfaceVariant,
                    ),
                  ),
                ),
                if (closeable)
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      tooltip: 'Close tab',
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BrowserAvatarMenu extends StatelessWidget {
  const _BrowserAvatarMenu({
    required this.deviceNpub,
    required this.profile,
    required this.onEditProfile,
    required this.identityActionLabel,
    required this.onOpenSetup,
    required this.onOpenSigner,
    required this.onOpenStatus,
    this.onLogOut,
  });

  final String deviceNpub;
  final NostrProfile profile;
  final VoidCallback onEditProfile;
  final String identityActionLabel;
  final VoidCallback onOpenSetup;
  final VoidCallback onOpenSigner;
  final VoidCallback onOpenStatus;
  final VoidCallback? onLogOut;

  @override
  Widget build(BuildContext context) {
    final label = profile.labelFor(deviceNpub);
    return PopupMenuButton<_BrowserAvatarAction>(
      tooltip: 'Profile',
      offset: const Offset(0, 8),
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: _BrowserProfileChip(
          label: label,
          profile: profile,
        ),
      ),
      onSelected: (action) {
        switch (action) {
          case _BrowserAvatarAction.editProfile:
            onEditProfile();
          case _BrowserAvatarAction.setup:
            onOpenSetup();
          case _BrowserAvatarAction.signer:
            onOpenSigner();
          case _BrowserAvatarAction.status:
            onOpenStatus();
          case _BrowserAvatarAction.logOut:
            onLogOut?.call();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: SizedBox(
            width: 280,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _ProfileAvatar(profile: profile, label: label),
              title: Text(
                label,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: _profileSubtitle(profile),
            ),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _BrowserAvatarAction.editProfile,
          child: ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(identityActionLabel),
          ),
        ),
        const PopupMenuItem(
          value: _BrowserAvatarAction.setup,
          child: ListTile(
            leading: Icon(Icons.tune),
            title: Text('Setup'),
          ),
        ),
        const PopupMenuItem(
          value: _BrowserAvatarAction.signer,
          child: ListTile(
            leading: Icon(Icons.shield_outlined),
            title: Text('Signer'),
          ),
        ),
        const PopupMenuItem(
          value: _BrowserAvatarAction.status,
          child: ListTile(
            leading: Icon(Icons.monitor_heart_outlined),
            title: Text('Status'),
          ),
        ),
        if (onLogOut != null) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _BrowserAvatarAction.logOut,
            child: ListTile(
              leading: Icon(Icons.logout),
              title: Text('Log out'),
            ),
          ),
        ],
      ],
    );
  }
}

class _BrowserProfileChip extends StatelessWidget {
  const _BrowserProfileChip({
    required this.label,
    required this.profile,
  });

  final String label;
  final NostrProfile profile;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 34,
      height: 34,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: colors.primary, width: 1.5),
          color: colors.surface,
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: _ProfileAvatar(profile: profile, label: label, radius: 12.5),
        ),
      ),
    );
  }
}

enum _BrowserAvatarAction {
  editProfile,
  setup,
  signer,
  status,
  logOut,
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({
    required this.profile,
    required this.label,
    this.radius = 20,
  });

  final NostrProfile profile;
  final String label;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final avatarUrl = profile.avatarUrl;
    final cachedBytes = profile.cachedAvatarBytes;
    final fallback = CircleAvatar(
      radius: radius,
      child: Text(_initials(label)),
    );
    if (cachedBytes != null) {
      return ClipOval(
        child: Image.memory(
          cachedBytes,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => fallback,
        ),
      );
    }
    if (avatarUrl.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        avatarUrl,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => fallback,
      ),
    );
  }

  String _initials(String value) {
    final words = value
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty) return 'W';
    if (words.length == 1) return words.first.substring(0, 1).toUpperCase();
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }
}

Widget? _profileSubtitle(NostrProfile profile) {
  final nip05 = profile.nip05.trim();
  if (nip05.isNotEmpty) {
    return Text(nip05, overflow: TextOverflow.ellipsis);
  }
  final name = profile.name.trim();
  if (name.isNotEmpty) {
    return Text('@$name', overflow: TextOverflow.ellipsis);
  }
  return null;
}

class _EditNostrProfileDialog extends StatefulWidget {
  const _EditNostrProfileDialog({
    required this.deviceNpub,
    required this.profile,
    required this.onSave,
    required this.onUploadAvatar,
    this.onExportKey,
  });

  final Future<String?> Function() onUploadAvatar;
  final Future<String> Function(String pin)? onExportKey;
  final String deviceNpub;
  final NostrProfile profile;
  final Future<ProfilePublishResult> Function(NostrProfile profile) onSave;

  @override
  State<_EditNostrProfileDialog> createState() =>
      _EditNostrProfileDialogState();
}

class _EditNostrProfileDialogState extends State<_EditNostrProfileDialog> {
  late final TextEditingController _displayNameController;
  late final TextEditingController _nameController;
  late final TextEditingController _pictureController;
  late final TextEditingController _nip05Controller;
  late final TextEditingController _websiteController;
  late final TextEditingController _aboutController;

  bool _busy = false;
  bool _uploading = false;
  OverlayEntry? _toast;
  Timer? _toastTimer;

  void _showToast(String message) {
    _toastTimer?.cancel();
    _toast?.remove();
    _toast?.dispose();
    final colors = Theme.of(context).colorScheme;
    _toast = OverlayEntry(
        builder: (_) => Positioned(
              left: 24,
              right: 24,
              bottom: 24,
              child: IgnorePointer(
                  child: SafeArea(
                      child: Center(
                          child: Material(
                elevation: 6,
                color: colors.inverseSurface,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Semantics(
                        liveRegion: true,
                        child: Text(message,
                            style: TextStyle(color: colors.onInverseSurface)))),
              )))),
            ));
    Overlay.of(context, rootOverlay: true).insert(_toast!);
    _toastTimer = Timer(const Duration(seconds: 5), () {
      _toast?.remove();
      _toast?.dispose();
      _toast = null;
    });
  }

  Future<void> _uploadAvatar() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _uploading = true;
    });
    try {
      final url = await widget.onUploadAvatar();
      if (!mounted || url == null) return;
      setState(() => _pictureController.text = url);
      _showToast('Image uploaded. Save to update your profile.');
    } catch (error) {
      if (mounted) {
        _showToast(error is AvatarUploadException
            ? error.message
            : 'Upload failed. Check the image and connection, then retry.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _uploading = false;
        });
      }
    }
  }

  Future<void> _exportKey() async {
    final unlock = widget.onExportKey;
    if (unlock == null || _busy) return;
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ProfileKeyExportDialog(unlock: unlock));
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await widget.onSave(_currentProfile());
      if (!mounted) return;
      if (result.published) {
        Navigator.of(context).pop(true);
      } else {
        _showToast('Could not publish. Your draft is safe. Tap Save to retry.');
      }
    } catch (_) {
      if (mounted) {
        _showToast(
            'Could not save. Check your identity and connection, then retry.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _displayNameController =
        TextEditingController(text: widget.profile.displayName);
    _nameController = TextEditingController(text: widget.profile.name);
    _pictureController = TextEditingController(text: widget.profile.pictureUrl);
    _nip05Controller = TextEditingController(text: widget.profile.nip05);
    _websiteController = TextEditingController(text: widget.profile.website);
    _aboutController = TextEditingController(text: widget.profile.about);
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _toast?.remove();
    _toast?.dispose();
    _displayNameController.dispose();
    _nameController.dispose();
    _pictureController.dispose();
    _nip05Controller.dispose();
    _websiteController.dispose();
    _aboutController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _currentProfile();
    final label = preview.labelFor(widget.deviceNpub);
    final npub = widget.deviceNpub;
    final shortNpub = npub.length > 20
        ? '${npub.substring(0, 10)}…${npub.substring(npub.length - 5)}'
        : npub;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Edit profile'),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        actionsPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    _ProfileAvatar(profile: preview, label: label, radius: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Row(children: [
                            Flexible(
                                child: Text(shortNpub,
                                    key: const ValueKey('profile-npub'),
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                    overflow: TextOverflow.ellipsis)),
                            IconButton(
                                tooltip: 'Copy npub',
                                visualDensity: VisualDensity.compact,
                                iconSize: 16,
                                onPressed: () async {
                                  await Clipboard.setData(
                                      ClipboardData(text: widget.deviceNpub));
                                  if (mounted) _showToast('Public key copied.');
                                },
                                icon: const Icon(Icons.copy)),
                          ]),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _field(
                  controller: _displayNameController,
                  label: 'Display name',
                  icon: Icons.badge_outlined,
                ),
                _field(
                  controller: _nameController,
                  label: 'Username',
                  icon: Icons.alternate_email,
                ),
                _field(
                  controller: _pictureController,
                  label: 'Avatar URL',
                  icon: Icons.image_outlined,
                  suffixIcon: IconButton(
                    tooltip: 'Upload image',
                    onPressed: _busy ? null : _uploadAvatar,
                    icon: _uploading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.upload_outlined),
                  ),
                ),
                _field(
                  controller: _nip05Controller,
                  label: 'Nostr address (NIP-05)',
                  icon: Icons.verified_outlined,
                ),
                _field(
                  controller: _websiteController,
                  label: 'Website',
                  icon: Icons.link,
                ),
                _field(
                  controller: _aboutController,
                  label: 'About',
                  icon: Icons.notes_outlined,
                  maxLines: 2,
                ),
                if (widget.onExportKey != null)
                  TextButton.icon(
                      onPressed: _busy ? null : _exportKey,
                      icon: const Icon(Icons.key),
                      label: const Text('Export private key (nsec)')),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy && !_uploading ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    int maxLines = 1,
    Widget? suffixIcon,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        enabled: !_busy,
        controller: controller,
        maxLines: maxLines,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          prefixIcon: Icon(icon, size: 20),
          suffixIcon: suffixIcon,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          labelText: label,
          isDense: true,
        ),
      ),
    );
  }

  NostrProfile _currentProfile() {
    return NostrProfile(
      displayName: _displayNameController.text.trim(),
      name: _nameController.text.trim(),
      pictureUrl: _pictureController.text.trim(),
      nip05: _nip05Controller.text.trim(),
      website: _websiteController.text.trim(),
      about: _aboutController.text.trim(),
    );
  }
}

class _BrowserTabsSnapshot {
  const _BrowserTabsSnapshot({
    required this.version,
    required this.activeIndex,
    required this.tabs,
  });

  final int version;
  final int activeIndex;
  final List<_BrowserTabSnapshot> tabs;

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'active_index': activeIndex,
      'tabs': [for (final tab in tabs) tab.toJson()],
    };
  }
}

class _BrowserTabSnapshot {
  const _BrowserTabSnapshot({
    required this.title,
    required this.url,
    required this.isHome,
    this.prefix = '',
    this.colour,
    this.diagnosticsTabKey,
  });

  final String? diagnosticsTabKey;
  final String? title;
  final String? url;
  final bool isHome;
  final String prefix;
  final String? colour;

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'url': url,
      'is_home': isHome,
      if (diagnosticsTabKey != null) 'diagnostics_tab_key': diagnosticsTabKey,
      if (prefix.isNotEmpty) 'prefix': prefix,
      if (colour != null) 'colour': colour,
    };
  }
}

class _DiagnosticsTransition {
  const _DiagnosticsTransition(
      {required this.scope,
      required this.origin,
      required this.identity,
      required this.documentToken,
      required this.workspace,
      required this.expires});
  final String scope;
  final String origin;
  final String identity;
  final String documentToken;
  final String workspace;
  final DateTime expires;
}

class BrowserTab {
  BrowserTab({
    required this.id,
    required this.controller,
    required this.addressController,
    required this.addressFocusNode,
    required this.title,
    this.isHome = false,
  });

  final int id;
  final WebViewController controller;
  final TextEditingController addressController;
  final FocusNode addressFocusNode;
  String title;
  String prefix = '';
  String? colour;
  String? currentUrl;
  String? message;
  String? fipsDisabledUrl;
  bool isHome;
  GraspFipsBrowserBridge? graspBridge;
  String? signerDocumentToken;
  int signerDocumentEpoch = 0;
  String diagnosticsTabKey = TowerFipsProxy.capability();
  int diagnosticsConfigEpoch = 0;
  String? diagnosticsScope;
  String? diagnosticsWorkspace;
  bool diagnosticsRecovered = false;
  bool diagnosticsConsentPending = false;
  _DiagnosticsTransition? _diagnosticsTransition;
  Timer? _diagnosticsTransitionTimer;

  void _setDiagnosticsTransition(_DiagnosticsTransition transition) {
    clearDiagnosticsTransition();
    _diagnosticsTransition = transition;
    _diagnosticsTransitionTimer =
        Timer(const Duration(seconds: 30), clearDiagnosticsTransition);
  }

  void clearDiagnosticsTransition() {
    _diagnosticsTransitionTimer?.cancel();
    _diagnosticsTransitionTimer = null;
    _diagnosticsTransition = null;
  }

  bool meshAuthPending = false;
  Future<bool> nativeChannelsReady = Future.value(false);
  int? androidWebViewIdentifier;
  bool disposed = false;

  void revokeSigningDocument() {
    graspBridge?.close();
    graspBridge = null;
    revokeDiagnostics();
    signerDocumentToken = null;
    signerDocumentEpoch++;
  }

  void revokeDiagnostics() {
    diagnosticsConfigEpoch++;
    diagnosticsScope = null;
    diagnosticsWorkspace = null;
    diagnosticsRecovered = false;
  }

  bool canGoBack = false;
  bool canGoForward = false;

  String get label => prefix.isEmpty ? pageLabel : '$prefix: $pageLabel';

  String get pageLabel {
    final trimmed = title.trim();
    if (trimmed.isNotEmpty) return trimmed;
    final uri = Uri.tryParse(currentUrl ?? '');
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return 'New tab';
  }

  bool get isFips {
    try {
      FipsAppTarget.parse(currentUrl ?? addressController.text);
      return true;
    } on FormatException {
      return false;
    }
  }

  void dispose() {
    disposed = true;
    clearDiagnosticsTransition();
    revokeSigningDocument();
    final nativeId = androidWebViewIdentifier;
    if (nativeId != null) unawaited(GraspAndroidChannel.remove(nativeId));
    addressController.dispose();
    addressFocusNode.dispose();
  }
}

class BrowserBookmarkMenuState {
  const BrowserBookmarkMenuState({
    required this.available,
    required this.bookmarked,
  });

  const BrowserBookmarkMenuState.unavailable()
      : available = false,
        bookmarked = false;

  final bool available;
  final bool bookmarked;

  @override
  bool operator ==(Object other) {
    return other is BrowserBookmarkMenuState &&
        other.available == available &&
        other.bookmarked == bookmarked;
  }

  @override
  int get hashCode => Object.hash(available, bookmarked);
}

class SignerPromptResult {
  const SignerPromptResult({
    required this.approved,
    this.remember = false,
    this.denyAlways = false,
  });

  final bool approved;
  final bool remember;
  final bool denyAlways;
}
