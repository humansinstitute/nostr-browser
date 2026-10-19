import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/fips_runtime_service.dart';
import '../../core/flight_deck_update_manager.dart';
import '../../core/native_core_bridge.dart';
import '../../core/signer_vault.dart';
import '../browser/browser_screen.dart';
import '../browser/nostr_profile_relay_client.dart';
import '../browser/signer_store.dart';
import '../drive/drive_screen.dart';
import '../onboarding/signer_onboarding_screen.dart';
import '../nstack/nstack_access.dart';
import '../nstack/nstack_discovery.dart';
import '../nstack/nstack_recovery.dart';
import '../nstack/nstack_screen.dart';
import '../nstack/nstack_store.dart';
import '../setup/setup_screen.dart';
import '../signer/signer_screen.dart';
import '../status/status_screen.dart';
import 'macos_menu_bridge.dart';

class ShellHome extends StatefulWidget {
  const ShellHome({
    required this.config,
    this.relayDiagnosticsSaved = false,
    this.relayDiagnosticsAtLaunch = false,
    this.onRelayDiagnosticsChanged,
    this.localFlightDeckUrl = '',
    this.flightDeckUpdates,
    this.profileRelayClient,
    this.fipsRuntime,
    required this.bridge,
    required this.signerStore,
    required this.onConfigChanged,
    this.onLogOut,
    this.signerVault,
    this.onUnlocked,
    super.key,
  });

  final AppConfig config;
  final bool relayDiagnosticsSaved;
  final bool relayDiagnosticsAtLaunch;
  final Future<void> Function(bool)? onRelayDiagnosticsChanged;
  final String localFlightDeckUrl;
  final FlightDeckUpdateController? flightDeckUpdates;
  final NostrProfileRelayClient? profileRelayClient;
  final FipsRuntimeService? fipsRuntime;
  final NativeCoreBridge bridge;
  final SignerStore signerStore;
  final ValueChanged<AppConfig> onConfigChanged;
  final VoidCallback? onLogOut;
  final SignerVault? signerVault;
  final ValueChanged<SignerVaultUnlock>? onUnlocked;

  @override
  State<ShellHome> createState() => _ShellHomeState();
}

class _ShellHomeState extends State<ShellHome> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<BrowserScreenState> _browserKey =
      GlobalKey<BrowserScreenState>();
  ShellSurface _selectedSurface = ShellSurface.browser;
  final ValueNotifier<bool> _browserFocusMode = ValueNotifier(false);
  final ValueNotifier<BrowserBookmarkMenuState> _bookmarkMenuState =
      ValueNotifier(const BrowserBookmarkMenuState.unavailable());
  final MacOSMenuBridge _macOSMenuBridge = MacOSMenuBridge();
  late final FipsRuntimeService _fipsRuntime =
      widget.fipsRuntime ?? FipsRuntimeService();
  late final NStackRegistryStore _nstackRegistryStore = NStackRegistryStore();
  late final NStackGrantStore _nstackGrantStore = NStackGrantStore();
  late final NStackAccessService _nstackAccessService = NStackAccessService(
    registryStore: _nstackRegistryStore,
    grantStore: _nstackGrantStore,
  );
  late final NStackDiscoveryService _nstackDiscoveryService =
      NStackDiscoveryService(registryStore: _nstackRegistryStore);
  late final NStackRecoveryService _nstackRecoveryService =
      NStackRecoveryService(
    registryStore: _nstackRegistryStore,
    storage: TowerNStackStorageClient(),
    relay: WebSocketNStackRecoveryRelay(),
  );
  bool _fipsDiagnosticsExportBusy = false;
  String? _observedFlightDeckVersion;
  String? _lastFipsFailure;

  @override
  void initState() {
    super.initState();
    _attachFlightDeckUpdateListener();
    _macOSMenuBridge.listen(_openDrawer);
  }

  @override
  void didUpdateWidget(covariant ShellHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flightDeckUpdates != widget.flightDeckUpdates) {
      oldWidget.flightDeckUpdates?.removeListener(_onFlightDeckUpdateChanged);
      _attachFlightDeckUpdateListener();
    }
  }

  @override
  void dispose() {
    widget.flightDeckUpdates?.removeListener(_onFlightDeckUpdateChanged);
    _macOSMenuBridge.dispose();
    _browserFocusMode.dispose();
    _bookmarkMenuState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildDrawer(context),
      body: IndexedStack(
        index: _surfaceIndex(_selectedSurface),
        children: [
          _browserScreen(),
          _surfaceScaffold(
            title: 'NStacks',
            child: NStackScreen(
              config: widget.config,
              registryStore: _nstackRegistryStore,
              grantStore: _nstackGrantStore,
              accessService: _nstackAccessService,
              discoveryService: _nstackDiscoveryService,
              recoveryService: _nstackRecoveryService,
              onRegistryChanged: () {
                _nstackAccessService.revokeIdentity(widget.config.deviceNpub);
                _browserKey.currentState?.reloadNStackSettings();
              },
            ),
          ),
          _surfaceScaffold(
            title: 'Drive',
            child: DriveScreen(
              config: widget.config,
              bridge: widget.bridge,
              fipsRuntime: _fipsRuntime,
            ),
          ),
          _surfaceScaffold(
            title: 'Signer',
            child: SignerScreen(
              config: widget.config,
              signerStore: widget.signerStore,
            ),
          ),
          _surfaceScaffold(
            title: 'Status',
            child: StatusScreen(
              config: widget.config,
              bridge: widget.bridge,
              flightDeckUpdates: widget.flightDeckUpdates,
              onFlightDeckChanged: _reloadFlightDeck,
            ),
          ),
          _surfaceScaffold(
            title: 'Setup',
            child: SetupScreen(
              config: widget.config,
              relayDiagnosticsSaved: widget.relayDiagnosticsSaved,
              relayDiagnosticsAtLaunch: widget.relayDiagnosticsAtLaunch,
              onRelayDiagnosticsChanged: widget.onRelayDiagnosticsChanged,
              localFlightDeckUrl: widget.localFlightDeckUrl,
              bridge: widget.bridge,
              fipsRuntime: _fipsRuntime,
              onConfigChanged: widget.onConfigChanged,
              onClearBrowserData: _clearBrowserData,
              onOpenFipsApp: _openFipsApp,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _browserFocusMode,
      builder: (context, browserFocused, _) {
        return ValueListenableBuilder<BrowserBookmarkMenuState>(
          valueListenable: _bookmarkMenuState,
          builder: (context, bookmarkState, _) => NavigationDrawer(
            selectedIndex: _drawerIndexForSurface(_selectedSurface),
            onDestinationSelected: (index) {
              Navigator.of(context).pop();
              final surface = _surfaceForDrawerIndex(index);
              if (surface == null) return;
              _selectSurface(surface);
            },
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(28, 24, 16, 16),
                child: Text('Nostr Browser'),
              ),
              if (_selectedSurface == ShellSurface.browser && browserFocused)
                Semantics(
                  label: 'Show controls',
                  button: true,
                  excludeSemantics: true,
                  child: ListTile(
                    key: const ValueKey('show-controls-drawer-action'),
                    leading: const Icon(Icons.fullscreen_exit),
                    title: const Text('Show controls'),
                    onTap: _showBrowserControls,
                  ),
                ),
              if (_selectedSurface == ShellSurface.browser &&
                  bookmarkState.available)
                Semantics(
                  label: bookmarkState.bookmarked
                      ? 'Remove bookmark for current page'
                      : 'Add bookmark for current page',
                  button: true,
                  excludeSemantics: true,
                  child: ListTile(
                    key: const ValueKey('toggle-bookmark-drawer-action'),
                    leading: Icon(
                      bookmarkState.bookmarked
                          ? Icons.bookmark_remove
                          : Icons.bookmark_add_outlined,
                    ),
                    title: Text(
                      bookmarkState.bookmarked
                          ? 'Remove bookmark'
                          : 'Add bookmark',
                    ),
                    onTap: _toggleActivePageBookmark,
                  ),
                ),
              const NavigationDrawerDestination(
                icon: Icon(Icons.public),
                selectedIcon: Icon(Icons.public),
                label: Text('Browser'),
              ),
              const NavigationDrawerDestination(
                icon: Icon(Icons.dns_outlined),
                selectedIcon: Icon(Icons.dns),
                label: Text('NStacks'),
              ),
              const NavigationDrawerDestination(
                icon: Icon(Icons.folder_outlined),
                selectedIcon: Icon(Icons.folder),
                label: Text('Drive'),
              ),
              const NavigationDrawerDestination(
                icon: Icon(Icons.shield_outlined),
                selectedIcon: Icon(Icons.shield),
                label: Text('Signer'),
              ),
              const NavigationDrawerDestination(
                icon: Icon(Icons.monitor_heart_outlined),
                selectedIcon: Icon(Icons.monitor_heart),
                label: Text('Status'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _surfaceScaffold({
    required String title,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
          elevation: 1,
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Open menu',
                    onPressed: _openDrawer,
                    icon: const Icon(Icons.menu),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  _AvatarMenu(
                    deviceNpub: widget.config.deviceNpub,
                    onOpenSetup: () => _selectSurface(ShellSurface.setup),
                    onOpenSigner: () => _selectSurface(ShellSurface.signer),
                    onOpenStatus: () => _selectSurface(ShellSurface.status),
                    onLogOut: widget.onLogOut == null ? null : _confirmLogOut,
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }

  Widget _browserScreen() {
    return BrowserScreen(
      key: _browserKey,
      config: widget.config,
      localFlightDeckUrl: widget.localFlightDeckUrl,
      bridge: widget.bridge,
      signerStore: widget.signerStore,
      onOpenDrawer: _openDrawer,
      onOpenSetup: () => _selectSurface(ShellSurface.setup),
      onOpenSigner: () => _selectSurface(ShellSurface.signer),
      onOpenStatus: () => _selectSurface(ShellSurface.status),
      onFocusModeChanged: (focused) => _browserFocusMode.value = focused,
      onBookmarkMenuStateChanged: (state) => _bookmarkMenuState.value = state,
      onPrepareFipsNavigation: _prepareFipsNavigation,
      fipsRuntime: _fipsRuntime,
      profileRelayClient: widget.profileRelayClient,
      signerVault: widget.signerVault,
      nstackRegistryStore: _nstackRegistryStore,
      nstackAccessService: _nstackAccessService,
      onOpenIdentity: widget.signerVault == null ? null : _openIdentity,
      onLogOut: widget.onLogOut == null ? null : _confirmLogOut,
    );
  }

  Future<void> _openIdentity() async {
    final vault = widget.signerVault!;
    final record = await vault.loadRecord();
    if (!mounted || widget.config.hasDeviceSecret) return;
    final unlocked = await Navigator.of(context).push<SignerVaultUnlock>(
      MaterialPageRoute(
          builder: (context) => SignerOnboardingScreen(
                vault: vault,
                record: record,
                onUnlocked: (identity) => Navigator.of(context).pop(identity),
              )),
    );
    if (!mounted || unlocked == null) return;
    widget.onUnlocked?.call(unlocked);
  }

  Future<String?> _prepareFipsNavigation(String url) async {
    late FipsRuntimeStatus status;
    try {
      status = await _fipsRuntime.ensureReadyForAppAccess();
    } catch (_) {
      status = const FipsRuntimeStatus(
        state: FipsRuntimeState.failed,
        detail: 'Embedded FIPS failed unexpectedly. Open Setup to retry.',
      );
    }
    if (status.canAttemptAppAccess) {
      _lastFipsFailure = null;
      return null;
    }
    if (!mounted) return status.detail;

    if (_lastFipsFailure == status.detail) return status.detail;
    _lastFipsFailure = status.detail;
    final supportsExport = _fipsRuntime.supportsDiagnosticsExport;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Expanded(child: Text(status.detail)),
            if (supportsExport)
              TextButton(
                key: const ValueKey('fips-failure-open-setup'),
                onPressed: () => _selectSurface(ShellSurface.setup),
                child: const Text('Setup'),
              ),
          ],
        ),
        action: SnackBarAction(
          label: supportsExport ? 'Export' : 'Setup',
          onPressed: supportsExport
              ? _exportFipsDiagnosticsFromFailure
              : () => _selectSurface(ShellSurface.setup),
        ),
      ),
    );
    return status.detail;
  }

  Future<void> _exportFipsDiagnosticsFromFailure() async {
    if (_fipsDiagnosticsExportBusy) return;
    _fipsDiagnosticsExportBusy = true;
    final result = await _fipsRuntime.exportDiagnostics();
    _fipsDiagnosticsExportBusy = false;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.outcome == FipsDiagnosticsExportOutcome.cancelled
            ? 'Diagnostics export cancelled.'
            : result.detail),
      ),
    );
  }

  int _surfaceIndex(ShellSurface surface) {
    return switch (surface) {
      ShellSurface.browser => 0,
      ShellSurface.nstacks => 1,
      ShellSurface.drive => 2,
      ShellSurface.signer => 3,
      ShellSurface.status => 4,
      ShellSurface.setup => 5,
    };
  }

  int? _drawerIndexForSurface(ShellSurface surface) => switch (surface) {
        ShellSurface.browser => 0,
        ShellSurface.nstacks => 1,
        ShellSurface.drive => 2,
        ShellSurface.signer => 3,
        ShellSurface.status => 4,
        ShellSurface.setup => null,
      };
  ShellSurface? _surfaceForDrawerIndex(int index) => switch (index) {
        0 => ShellSurface.browser,
        1 => ShellSurface.nstacks,
        2 => ShellSurface.drive,
        3 => ShellSurface.signer,
        4 => ShellSurface.status,
        _ => null,
      };

  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  void _showBrowserControls() {
    Navigator.of(context).pop();
    _browserKey.currentState?.exitFocusMode();
  }

  void _toggleActivePageBookmark() {
    Navigator.of(context).pop();
    _browserKey.currentState?.toggleActivePageBookmark();
  }

  void _selectSurface(ShellSurface surface) {
    setState(() {
      _selectedSurface = surface;
    });
  }

  Future<void> _clearBrowserData() async {
    await _browserKey.currentState?.clearBrowserData();
  }

  void _attachFlightDeckUpdateListener() {
    final updates = widget.flightDeckUpdates;
    _observedFlightDeckVersion = updates?.snapshot.activeVersion;
    updates?.addListener(_onFlightDeckUpdateChanged);
  }

  void _onFlightDeckUpdateChanged() {
    final updates = widget.flightDeckUpdates;
    if (updates == null) return;
    final activeVersion = updates.snapshot.activeVersion;
    if (activeVersion.isEmpty || activeVersion == _observedFlightDeckVersion) {
      return;
    }
    _observedFlightDeckVersion = activeVersion;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reloadFlightDeck();
    });
  }

  void _reloadFlightDeck() {
    _browserKey.currentState?.reloadFlightDeck();
  }

  void _openFipsApp(String url) {
    setState(() {
      _selectedSurface = ShellSurface.browser;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _browserKey.currentState?.openTab(url);
    });
  }

  Future<void> _confirmLogOut() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Log out?'),
            content: const Text(
              'This locks the signer and clears the private key from this app session. '
              'The encrypted signer vault stays on this device, so you can unlock it again with your PIN.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.logout),
                label: const Text('Log out'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed) widget.onLogOut?.call();
  }
}

enum ShellSurface {
  browser,
  nstacks,
  drive,
  signer,
  status,
  setup,
}

class _AvatarMenu extends StatelessWidget {
  const _AvatarMenu({
    required this.deviceNpub,
    required this.onOpenSetup,
    required this.onOpenSigner,
    required this.onOpenStatus,
    this.onLogOut,
  });

  final String deviceNpub;
  final VoidCallback onOpenSetup;
  final VoidCallback onOpenSigner;
  final VoidCallback onOpenStatus;
  final VoidCallback? onLogOut;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_AvatarMenuAction>(
      tooltip: 'Account',
      icon: CircleAvatar(
        radius: 15,
        child: Text(_avatarLabel),
      ),
      onSelected: (action) {
        switch (action) {
          case _AvatarMenuAction.setup:
            onOpenSetup();
          case _AvatarMenuAction.signer:
            onOpenSigner();
          case _AvatarMenuAction.status:
            onOpenStatus();
          case _AvatarMenuAction.logOut:
            onLogOut?.call();
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: _AvatarMenuAction.setup,
          child: ListTile(
            leading: Icon(Icons.tune),
            title: Text('Setup'),
          ),
        ),
        const PopupMenuItem(
          value: _AvatarMenuAction.signer,
          child: ListTile(
            leading: Icon(Icons.shield_outlined),
            title: Text('Signer'),
          ),
        ),
        const PopupMenuItem(
          value: _AvatarMenuAction.status,
          child: ListTile(
            leading: Icon(Icons.monitor_heart_outlined),
            title: Text('Status'),
          ),
        ),
        if (onLogOut != null) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _AvatarMenuAction.logOut,
            child: ListTile(
              leading: Icon(Icons.logout),
              title: Text('Log out'),
            ),
          ),
        ],
      ],
    );
  }

  String get _avatarLabel {
    final trimmed = deviceNpub.trim();
    if (trimmed.isEmpty) return 'W';
    return trimmed.substring(0, 1).toUpperCase();
  }
}

enum _AvatarMenuAction {
  setup,
  signer,
  status,
  logOut,
}
