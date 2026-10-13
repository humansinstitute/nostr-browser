import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../browser/signer_policy.dart';
import '../browser/signer_store.dart';

class SignerScreen extends StatefulWidget {
  const SignerScreen({
    required this.config,
    required this.signerStore,
    super.key,
  });

  final AppConfig config;
  final SignerStore signerStore;

  @override
  State<SignerScreen> createState() => _SignerScreenState();
}

class _SignerScreenState extends State<SignerScreen> {
  late Future<SignerState> _state = _load();

  @override
  Widget build(BuildContext context) {
    final policy = SignerPolicy.fromConfig(widget.config);
    return FutureBuilder<SignerState>(
      future: _state,
      builder: (context, snapshot) {
        final state = snapshot.data;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Signer',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _sectionTitle(context, 'Trusted origins'),
            const SizedBox(height: 8),
            for (final origin in policy.trustedOrigins)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.verified_user_outlined),
                title: SelectableText(origin),
              ),
            if (policy.trustedOrigins.isEmpty)
              const Text('No trusted origins.'),
            const SizedBox(height: 24),
            _sectionHeader(
              context,
              title: 'Signer policies',
              action: TextButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Reload'),
              ),
            ),
            if (state == null) const LinearProgressIndicator(),
            if (state != null && state.policyRules.isEmpty)
              const Text('No signer allow or deny policies.'),
            if (state != null)
              for (final rule in state.policyRules)
                Card(
                  margin: const EdgeInsets.only(top: 8),
                  child: ListTile(
                    leading: Icon(
                      rule.allows
                          ? Icons.check_circle_outline
                          : Icons.block_outlined,
                    ),
                    title: Text(
                      '${rule.decision.name.toUpperCase()} ${rule.operation}',
                    ),
                    subtitle: SelectableText(
                      [
                        rule.label ?? '',
                        'Website: ${rule.pageOrigin}',
                        'Target: ${rule.target}',
                        rule.deviceNpub,
                        rule.createdAt.toLocal().toString(),
                      ].where((line) => line.isNotEmpty).join('\n'),
                    ),
                    isThreeLine: true,
                    trailing: IconButton(
                      tooltip: 'Revoke',
                      onPressed: () => _revokePolicy(rule.key),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
                ),
            const SizedBox(height: 24),
            _sectionHeader(
              context,
              title: 'Remembered approvals',
              action: TextButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Reload'),
              ),
            ),
            if (state == null) const LinearProgressIndicator(),
            if (state != null && state.approvals.isEmpty)
              const Text('No remembered signer approvals.'),
            if (state != null)
              for (final approval in state.approvals)
                Card(
                  margin: const EdgeInsets.only(top: 8),
                  child: ListTile(
                    leading: const Icon(Icons.verified_outlined),
                    title: Text(
                        '${approval.pageOrigin} -> ${approval.targetOrigin}'),
                    subtitle: Text(
                      '${approval.deviceNpub}\n${approval.createdAt.toLocal()}',
                    ),
                    isThreeLine: true,
                    trailing: IconButton(
                      tooltip: 'Revoke',
                      onPressed: () => _revoke(approval.key),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
                ),
            const SizedBox(height: 24),
            _sectionHeader(
              context,
              title: 'Signer audit',
              action: TextButton.icon(
                onPressed: _clearAudit,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Clear'),
              ),
            ),
            if (state != null && state.audit.isEmpty)
              const Text('No signer requests recorded.'),
            if (state != null)
              for (final entry in state.audit)
                Card(
                  margin: const EdgeInsets.only(top: 8),
                  child: ListTile(
                    leading: Icon(
                      entry.allowed
                          ? Icons.check_circle_outline
                          : Icons.block_outlined,
                    ),
                    title: Text('${entry.method} ${entry.outcome}'),
                    subtitle: SelectableText(
                      [
                        '${entry.pageOrigin} -> ${entry.targetOrigin}',
                        entry.targetUrl,
                        entry.reason,
                        entry.createdAt.toLocal().toString(),
                      ].where((line) => line.isNotEmpty).join('\n'),
                    ),
                    isThreeLine: true,
                  ),
                ),
          ],
        );
      },
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Text(title, style: Theme.of(context).textTheme.titleMedium);
  }

  Widget _sectionHeader(
    BuildContext context, {
    required String title,
    required Widget action,
  }) {
    return Row(
      children: [
        Expanded(child: _sectionTitle(context, title)),
        action,
      ],
    );
  }

  Future<SignerState> _load() async {
    final policyRules = await widget.signerStore.listPolicyRules();
    final approvals = await widget.signerStore.listApprovals();
    final audit = await widget.signerStore.listAudit();
    return SignerState(
      policyRules: policyRules,
      approvals: approvals,
      audit: audit,
    );
  }

  void _refresh() {
    setState(() {
      _state = _load();
    });
  }

  Future<void> _revoke(String key) async {
    await widget.signerStore.revokeApproval(key);
    _refresh();
  }

  Future<void> _revokePolicy(String key) async {
    await widget.signerStore.revokePolicyRule(key);
    _refresh();
  }

  Future<void> _clearAudit() async {
    await widget.signerStore.clearAudit();
    _refresh();
  }
}

class SignerState {
  const SignerState({
    required this.policyRules,
    required this.approvals,
    required this.audit,
  });

  final List<SignerPolicyRule> policyRules;
  final List<SignerApproval> approvals;
  final List<SignerAuditEntry> audit;
}
