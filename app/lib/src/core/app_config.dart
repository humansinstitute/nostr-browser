class AppConfig {
  const AppConfig({
    required this.towerUrl,
    required this.appNpub,
    required this.flightDeckUrl,
    required this.workspaceId,
    required this.workspaceServiceNpub,
    required this.channelId,
    required this.deviceSecret,
    required this.registrationSecret,
    required this.deviceNpub,
    required this.devicePublicKeyHex,
    required this.trustedOrigins,
    required this.rememberNip98Approvals,
    required this.displayExperimentalFlightDeckDriveSync,
  });

  factory AppConfig.defaults() {
    return const AppConfig(
      towerUrl: '',
      appNpub: '',
      flightDeckUrl: '',
      workspaceId: '',
      workspaceServiceNpub: '',
      channelId: '',
      deviceSecret: '',
      registrationSecret: '',
      deviceNpub: '',
      devicePublicKeyHex: '',
      trustedOrigins: [],
      rememberNip98Approvals: true,
      displayExperimentalFlightDeckDriveSync: false,
    );
  }

  final String towerUrl;
  final String appNpub;
  final String flightDeckUrl;
  final String workspaceId;
  final String workspaceServiceNpub;
  final String channelId;
  final String deviceSecret;
  final String registrationSecret;
  final String deviceNpub;
  final String devicePublicKeyHex;
  final List<String> trustedOrigins;
  final bool rememberNip98Approvals;
  final bool displayExperimentalFlightDeckDriveSync;

  bool get hasTower => towerUrl.trim().isNotEmpty;
  bool get hasAppNpub => appNpub.trim().isNotEmpty;
  bool get hasWorkspace => workspaceId.trim().isNotEmpty;
  bool get hasWorkspaceService => workspaceServiceNpub.trim().isNotEmpty;
  bool get hasChannel => channelId.trim().isNotEmpty;
  bool get hasDeviceSecret => deviceSecret.trim().isNotEmpty;
  bool get hasDeviceNpub => deviceNpub.trim().isNotEmpty;
  bool get hasDevicePublicKeyHex => devicePublicKeyHex.trim().isNotEmpty;

  bool get canSync =>
      hasTower && hasAppNpub && hasWorkspace && hasChannel && hasDeviceSecret;
  bool get canRegisterDevice =>
      hasTower && hasWorkspaceService && hasDeviceNpub;

  AppConfig copyWith({
    String? towerUrl,
    String? appNpub,
    String? flightDeckUrl,
    String? workspaceId,
    String? workspaceServiceNpub,
    String? channelId,
    String? deviceSecret,
    String? registrationSecret,
    String? deviceNpub,
    String? devicePublicKeyHex,
    List<String>? trustedOrigins,
    bool? rememberNip98Approvals,
    bool? displayExperimentalFlightDeckDriveSync,
  }) {
    return AppConfig(
      towerUrl: towerUrl ?? this.towerUrl,
      appNpub: appNpub ?? this.appNpub,
      flightDeckUrl: flightDeckUrl ?? this.flightDeckUrl,
      workspaceId: workspaceId ?? this.workspaceId,
      workspaceServiceNpub: workspaceServiceNpub ?? this.workspaceServiceNpub,
      channelId: channelId ?? this.channelId,
      deviceSecret: deviceSecret ?? this.deviceSecret,
      registrationSecret: registrationSecret ?? this.registrationSecret,
      deviceNpub: deviceNpub ?? this.deviceNpub,
      devicePublicKeyHex: devicePublicKeyHex ?? this.devicePublicKeyHex,
      trustedOrigins: trustedOrigins ?? this.trustedOrigins,
      rememberNip98Approvals:
          rememberNip98Approvals ?? this.rememberNip98Approvals,
      displayExperimentalFlightDeckDriveSync:
          displayExperimentalFlightDeckDriveSync ??
              this.displayExperimentalFlightDeckDriveSync,
    );
  }

  List<String> effectiveTrustedOrigins() {
    final origins = <String>{
      for (final origin in trustedOrigins) origin.trim(),
      _originOf(towerUrl),
      _originOf(flightDeckUrl),
    }..remove('');
    return origins.toList(growable: false);
  }

  static String _originOf(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    if (uri.hasPort) return '${uri.scheme}://${uri.host}:${uri.port}';
    return '${uri.scheme}://${uri.host}';
  }
}
