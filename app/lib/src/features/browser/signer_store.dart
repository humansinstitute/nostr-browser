import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SignerStore {
  SignerStore({
    SignerStoreBackend? backend,
    this.maxAuditEntries = 200,
  }) : _backend = backend ?? SharedPreferencesSignerStoreBackend();

  static const _auditKey = 'wingman.signer.audit.v1';
  static const _approvalsKey = 'wingman.signer.approvals.v1';
  static const _policyRulesKey = 'wingman.signer.policy_rules.v1';

  final SignerStoreBackend _backend;
  final int maxAuditEntries;

  Future<List<SignerAuditEntry>> listAudit() async {
    final raw = await _backend.getStringList(_auditKey) ?? const <String>[];
    return raw
        .map(SignerAuditEntry.tryParse)
        .whereType<SignerAuditEntry>()
        .toList(growable: false);
  }

  Future<void> appendAudit(SignerAuditEntry entry) async {
    final entries =
        [entry, ...await listAudit()].take(maxAuditEntries).toList();
    await _backend.setStringList(
      _auditKey,
      entries.map((entry) => jsonEncode(entry.toJson())).toList(),
    );
  }

  Future<void> clearAudit() async {
    await _backend.setStringList(_auditKey, const <String>[]);
  }

  Future<List<SignerApproval>> listApprovals() async {
    final raw = await _backend.getStringList(_approvalsKey) ?? const <String>[];
    return raw
        .map(SignerApproval.tryParse)
        .whereType<SignerApproval>()
        .toList(growable: false);
  }

  Future<bool> hasApproval({
    required String pageOrigin,
    required String targetOrigin,
    required String deviceNpub,
  }) async {
    final key = SignerApproval.keyFor(
      pageOrigin: pageOrigin,
      targetOrigin: targetOrigin,
      deviceNpub: deviceNpub,
    );
    return (await listApprovals()).any((approval) => approval.key == key);
  }

  Future<void> rememberApproval(SignerApproval approval) async {
    final approvals = await listApprovals();
    final next = [
      approval,
      ...approvals.where((item) => item.key != approval.key),
    ];
    await _backend.setStringList(
      _approvalsKey,
      next.map((approval) => jsonEncode(approval.toJson())).toList(),
    );
  }

  Future<void> revokeApproval(String key) async {
    final next =
        (await listApprovals()).where((approval) => approval.key != key);
    await _backend.setStringList(
      _approvalsKey,
      next.map((approval) => jsonEncode(approval.toJson())).toList(),
    );
  }

  Future<List<SignerPolicyRule>> listPolicyRules() async {
    final raw =
        await _backend.getStringList(_policyRulesKey) ?? const <String>[];
    return raw
        .map(SignerPolicyRule.tryParse)
        .whereType<SignerPolicyRule>()
        .toList(growable: false);
  }

  Future<SignerPolicyRule?> findPolicyRule({
    required String pageOrigin,
    required String operation,
    required String target,
    required String deviceNpub,
  }) async {
    final rules = await listPolicyRules();
    final key = SignerPolicyRule.keyFor(
      pageOrigin: pageOrigin,
      operation: operation,
      target: target,
      deviceNpub: deviceNpub,
    );
    for (final rule in rules) {
      if (rule.key == key) return rule;
    }
    return null;
  }

  Future<void> rememberPolicyRule(SignerPolicyRule rule) async {
    final rules = await listPolicyRules();
    final next = [
      rule,
      ...rules.where((item) => item.key != rule.key),
    ];
    await _backend.setStringList(
      _policyRulesKey,
      next.map((rule) => jsonEncode(rule.toJson())).toList(),
    );
  }

  Future<void> revokePolicyRule(String key) async {
    final next = (await listPolicyRules()).where((rule) => rule.key != key);
    await _backend.setStringList(
      _policyRulesKey,
      next.map((rule) => jsonEncode(rule.toJson())).toList(),
    );
  }
}

abstract class SignerStoreBackend {
  Future<List<String>?> getStringList(String key);
  Future<void> setStringList(String key, List<String> value);
}

class SharedPreferencesSignerStoreBackend implements SignerStoreBackend {
  SharedPreferencesSignerStoreBackend({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<List<String>?> getStringList(String key) {
    return _preferences.getStringList(key);
  }

  @override
  Future<void> setStringList(String key, List<String> value) {
    return _preferences.setStringList(key, value);
  }
}

class MemorySignerStoreBackend implements SignerStoreBackend {
  final Map<String, List<String>> _values = {};

  @override
  Future<List<String>?> getStringList(String key) async {
    final value = _values[key];
    return value == null ? null : List<String>.of(value);
  }

  @override
  Future<void> setStringList(String key, List<String> value) async {
    _values[key] = List<String>.of(value);
  }
}

class SignerApproval {
  SignerApproval({
    required this.pageOrigin,
    required this.targetOrigin,
    required this.deviceNpub,
    required this.createdAt,
    this.label,
  }) : key = keyFor(
          pageOrigin: pageOrigin,
          targetOrigin: targetOrigin,
          deviceNpub: deviceNpub,
        );

  SignerApproval._({
    required this.key,
    required this.pageOrigin,
    required this.targetOrigin,
    required this.deviceNpub,
    required this.createdAt,
    required this.label,
  });

  final String key;
  final String pageOrigin;
  final String targetOrigin;
  final String deviceNpub;
  final DateTime createdAt;
  final String? label;

  static String keyFor({
    required String pageOrigin,
    required String targetOrigin,
    required String deviceNpub,
  }) {
    return '$deviceNpub|$pageOrigin|$targetOrigin|nip98';
  }

  static SignerApproval? tryParse(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) return null;
      final pageOrigin = decoded['page_origin']?.toString() ?? '';
      final targetOrigin = decoded['target_origin']?.toString() ?? '';
      final deviceNpub = decoded['device_npub']?.toString() ?? '';
      final createdAt =
          DateTime.tryParse(decoded['created_at']?.toString() ?? '');
      if (pageOrigin.isEmpty ||
          targetOrigin.isEmpty ||
          deviceNpub.isEmpty ||
          createdAt == null) {
        return null;
      }
      return SignerApproval._(
        key: decoded['key']?.toString() ??
            keyFor(
              pageOrigin: pageOrigin,
              targetOrigin: targetOrigin,
              deviceNpub: deviceNpub,
            ),
        pageOrigin: pageOrigin,
        targetOrigin: targetOrigin,
        deviceNpub: deviceNpub,
        createdAt: createdAt,
        label: decoded['label']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'page_origin': pageOrigin,
      'target_origin': targetOrigin,
      'device_npub': deviceNpub,
      'created_at': createdAt.toIso8601String(),
      if (label != null && label!.isNotEmpty) 'label': label,
    };
  }
}

enum SignerPolicyRuleDecision {
  allow,
  deny;

  static SignerPolicyRuleDecision? tryParse(String value) {
    for (final decision in values) {
      if (decision.name == value) return decision;
    }
    return null;
  }
}

class SignerPolicyRule {
  SignerPolicyRule({
    required this.pageOrigin,
    required this.operation,
    required this.target,
    required this.deviceNpub,
    required this.decision,
    required this.createdAt,
    this.label,
  }) : key = keyFor(
          pageOrigin: pageOrigin,
          operation: operation,
          target: target,
          deviceNpub: deviceNpub,
        );

  SignerPolicyRule._({
    required this.key,
    required this.pageOrigin,
    required this.operation,
    required this.target,
    required this.deviceNpub,
    required this.decision,
    required this.createdAt,
    required this.label,
  });

  final String key;
  final String pageOrigin;
  final String operation;
  final String target;
  final String deviceNpub;
  final SignerPolicyRuleDecision decision;
  final DateTime createdAt;
  final String? label;

  bool get allows => decision == SignerPolicyRuleDecision.allow;

  static String keyFor({
    required String pageOrigin,
    required String operation,
    required String target,
    required String deviceNpub,
  }) {
    return '$deviceNpub|$pageOrigin|$operation|$target';
  }

  static SignerPolicyRule? tryParse(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) return null;
      final pageOrigin = decoded['page_origin']?.toString() ?? '';
      final operation = decoded['operation']?.toString() ?? '';
      final target = decoded['target']?.toString() ?? '';
      final deviceNpub = decoded['device_npub']?.toString() ?? '';
      final decision = SignerPolicyRuleDecision.tryParse(
        decoded['decision']?.toString() ?? '',
      );
      final createdAt =
          DateTime.tryParse(decoded['created_at']?.toString() ?? '');
      if (pageOrigin.isEmpty ||
          operation.isEmpty ||
          target.isEmpty ||
          deviceNpub.isEmpty ||
          decision == null ||
          createdAt == null) {
        return null;
      }
      return SignerPolicyRule._(
        key: decoded['key']?.toString() ??
            keyFor(
              pageOrigin: pageOrigin,
              operation: operation,
              target: target,
              deviceNpub: deviceNpub,
            ),
        pageOrigin: pageOrigin,
        operation: operation,
        target: target,
        deviceNpub: deviceNpub,
        decision: decision,
        createdAt: createdAt,
        label: decoded['label']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'page_origin': pageOrigin,
      'operation': operation,
      'target': target,
      'device_npub': deviceNpub,
      'decision': decision.name,
      'created_at': createdAt.toIso8601String(),
      if (label != null && label!.isNotEmpty) 'label': label,
    };
  }
}

class SignerAuditEntry {
  SignerAuditEntry({
    required this.id,
    required this.createdAt,
    required this.pageOrigin,
    required this.targetOrigin,
    required this.targetUrl,
    required this.method,
    required this.deviceNpub,
    required this.allowed,
    required this.outcome,
    required this.reason,
    required this.rememberedApproval,
  });

  final String id;
  final DateTime createdAt;
  final String pageOrigin;
  final String targetOrigin;
  final String targetUrl;
  final String method;
  final String deviceNpub;
  final bool allowed;
  final String outcome;
  final String reason;
  final bool rememberedApproval;

  static SignerAuditEntry create({
    required String pageOrigin,
    required String targetOrigin,
    required String targetUrl,
    required String method,
    required String deviceNpub,
    required bool allowed,
    required String outcome,
    String reason = '',
    bool rememberedApproval = false,
  }) {
    final now = DateTime.now().toUtc();
    return SignerAuditEntry(
      id: '${now.microsecondsSinceEpoch}',
      createdAt: now,
      pageOrigin: pageOrigin,
      targetOrigin: targetOrigin,
      targetUrl: targetUrl,
      method: method,
      deviceNpub: deviceNpub,
      allowed: allowed,
      outcome: outcome,
      reason: reason,
      rememberedApproval: rememberedApproval,
    );
  }

  static SignerAuditEntry? tryParse(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) return null;
      final createdAt =
          DateTime.tryParse(decoded['created_at']?.toString() ?? '');
      if (createdAt == null) return null;
      return SignerAuditEntry(
        id: decoded['id']?.toString() ?? '',
        createdAt: createdAt,
        pageOrigin: decoded['page_origin']?.toString() ?? '',
        targetOrigin: decoded['target_origin']?.toString() ?? '',
        targetUrl: decoded['target_url']?.toString() ?? '',
        method: decoded['method']?.toString() ?? '',
        deviceNpub: decoded['device_npub']?.toString() ?? '',
        allowed: decoded['allowed'] == true,
        outcome: decoded['outcome']?.toString() ?? '',
        reason: decoded['reason']?.toString() ?? '',
        rememberedApproval: decoded['remembered_approval'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'created_at': createdAt.toIso8601String(),
      'page_origin': pageOrigin,
      'target_origin': targetOrigin,
      'target_url': targetUrl,
      'method': method,
      'device_npub': deviceNpub,
      'allowed': allowed,
      'outcome': outcome,
      'reason': reason,
      'remembered_approval': rememberedApproval,
    };
  }
}
