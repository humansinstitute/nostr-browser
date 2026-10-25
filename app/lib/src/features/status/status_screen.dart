import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/native_core_bridge.dart';

class StatusScreen extends StatelessWidget {
  const StatusScreen({
    required this.config,
    required this.bridge,
    super.key,
  });

  final AppConfig config;
  final NativeCoreBridge bridge;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CoreStatus>(
      future: bridge.status(config),
      builder: (context, snapshot) {
        final status = snapshot.data;
        return ListView(
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
          ],
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
}
