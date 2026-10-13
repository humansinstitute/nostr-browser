import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/flight_deck_update_manager.dart';
import '../../core/native_core_bridge.dart';

class StatusScreen extends StatelessWidget {
  const StatusScreen({
    required this.config,
    required this.bridge,
    this.flightDeckUpdates,
    this.onFlightDeckChanged,
    super.key,
  });

  final AppConfig config;
  final NativeCoreBridge bridge;
  final FlightDeckUpdateController? flightDeckUpdates;
  final VoidCallback? onFlightDeckChanged;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CoreStatus>(
      future: bridge.status(config),
      builder: (context, snapshot) {
        final status = snapshot.data;
        return AnimatedBuilder(
          animation: flightDeckUpdates ?? _noAnimation,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('Status', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 20),
              _row('Tower', status?.towerUrl ?? config.towerUrl),
              _row('App npub', status?.appNpub ?? config.appNpub),
              _row('Workspace', status?.workspaceId ?? config.workspaceId),
              _row('Channel', status?.channelId ?? config.channelId),
              _row('Device npub', status?.deviceNpub ?? config.deviceNpub),
              _row(
                'Device',
                (status?.deviceConfigured ?? config.hasDeviceSecret)
                    ? 'configured'
                    : 'missing',
              ),
              _row('Sync', status?.latestSync ?? 'not checked'),
              const SizedBox(height: 20),
              Text(status?.message ?? 'Loading native core status...'),
              const Divider(height: 48),
              _buildFlightDeckUpdates(context),
            ],
          ),
        );
      },
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(label)),
          Expanded(child: SelectableText(value.isEmpty ? '-' : value)),
        ],
      ),
    );
  }

  Widget _buildFlightDeckUpdates(BuildContext context) {
    final updates = flightDeckUpdates;
    final snapshot = updates?.snapshot ?? FlightDeckUpdateSnapshot.disabled();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Flight Deck updates',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        _row('Status', _phaseLabel(snapshot.phase)),
        _row('Current', snapshot.activeVersion),
        _row('Packaged', snapshot.packagedVersion),
        if (snapshot.availableVersion.isNotEmpty)
          _row('Available', snapshot.availableVersion),
        if (snapshot.previousVersion.isNotEmpty)
          _row('Previous', snapshot.previousVersion),
        if (snapshot.failedVersion.isNotEmpty)
          _row('Failed', snapshot.failedVersion),
        if (snapshot.lastCheckAt != null)
          _row('Last check', _formatTime(snapshot.lastCheckAt!)),
        if (snapshot.lastSuccessAt != null)
          _row('Last success', _formatTime(snapshot.lastSuccessAt!)),
        if (snapshot.lastFailureAt != null)
          _row('Last failure', _formatTime(snapshot.lastFailureAt!)),
        const SizedBox(height: 8),
        Text(snapshot.message),
        if (snapshot.error.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            snapshot.error,
            key: const ValueKey('flight-deck-update-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('flight-deck-check-update'),
              onPressed: snapshot.canCheck && updates != null
                  ? () => updates.checkForUpdates()
                  : null,
              icon: snapshot.busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(
                snapshot.phase == FlightDeckUpdatePhase.failed
                    ? 'Retry'
                    : 'Check now',
              ),
            ),
            if (snapshot.canApply && updates != null)
              FilledButton.icon(
                key: const ValueKey('flight-deck-apply-update'),
                onPressed: () => _apply(updates),
                icon: const Icon(Icons.system_update_alt),
                label: const Text('Apply update'),
              ),
            if (snapshot.canRollback && updates != null)
              OutlinedButton.icon(
                key: const ValueKey('flight-deck-rollback-update'),
                onPressed: () => _rollback(context, updates),
                icon: const Icon(Icons.restore),
                label: const Text('Roll back'),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _apply(FlightDeckUpdateController updates) async {
    final before = updates.snapshot.activeVersion;
    await updates.applyAvailable();
    if (updates.snapshot.activeVersion != before) onFlightDeckChanged?.call();
  }

  Future<void> _rollback(
    BuildContext context,
    FlightDeckUpdateController updates,
  ) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Roll back Flight Deck?'),
            content:
                Text('Switch back to ${updates.snapshot.previousVersion}?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Roll back'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    final before = updates.snapshot.activeVersion;
    await updates.rollback();
    if (updates.snapshot.activeVersion != before) onFlightDeckChanged?.call();
  }

  String _phaseLabel(FlightDeckUpdatePhase phase) {
    return switch (phase) {
      FlightDeckUpdatePhase.rollingBack => 'rolling back',
      _ => phase.name,
    };
  }

  String _formatTime(DateTime value) => value.toLocal().toIso8601String();
}

const _noAnimation = AlwaysStoppedAnimation<double>(0);
