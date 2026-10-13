import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wingman_app/src/core/fips_runtime_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final npub = 'npub1${List.filled(58, 'q').join()}';
  const compatibleAttestation = '{"schema":2,"fipsVersion":"0.5.0",'
      '"rendezvousApp":"wingman-fips-poc-v1",'
      '"nostrShareLocalCandidates":true,"lanEnabled":true,'
      '"lanScope":"wingman-fips-poc-v1","tunEnabled":true,'
      '"dnsEnabled":true,"udpAdvertiseOnNostr":true,'
      '"udpAcceptConnections":true,"udpOutboundOnly":false,'
      '"bootstrapPeerNpub":"${FipsRuntimeService.bootstrapPeerNpub}",'
      '"bootstrapPeerAddress":"${FipsRuntimeService.bootstrapPeerAddress}"}';

  test(
      'desktop off persists across services and never touches system lifecycle',
      () async {
    final calls = <String>[];
    FipsRuntimeService create() => FipsRuntimeService(
          isMacOS: true,
          processRunner: (executable, arguments) async {
            calls.add('$executable $arguments');
            return ProcessResult(0, 0, '', '');
          },
        );
    final service = create();
    expect((await service.stop()).state, FipsRuntimeState.disabled);
    final relaunched = create();
    expect(await relaunched.isEnabled, isFalse);
    expect((await relaunched.inspect()).state, FipsRuntimeState.disabled);
    expect((await relaunched.ensureReadyForAppAccess()).state,
        FipsRuntimeState.disabled);
    expect(
        (await relaunched.installOrRepair()).state, FipsRuntimeState.disabled);
    expect(calls, isEmpty);
    await relaunched.setEnabled(true);
    expect(await create().isEnabled, isTrue);
  });

  test('off cancels bootstrap wait and prevents any more peer commands',
      () async {
    final peerRead = Completer<void>();
    var peerCalls = 0;
    var enabled = true;
    final service = FipsRuntimeService(
      isMacOS: true,
      bundledPackagePath: '/bundle/fips.pkg',
      readEnabled: () async => enabled,
      writeEnabled: (value) async {
        enabled = value;
      },
      fileExists: (_) async => true,
      readTextFile: (_) async => compatibleAttestation,
      processRunner: (executable, arguments) async {
        if (arguments.contains('--version')) {
          return ProcessResult(0, 0, '0.5.0', '');
        }
        if (arguments.contains('status')) {
          return ProcessResult(0, 0,
              '{"state":"running","tun_state":"active","persistent":true}', '');
        }
        if (arguments.contains('peers')) {
          peerCalls += 1;
          if (!peerRead.isCompleted) peerRead.complete();
          return ProcessResult(0, 0, '{"peers":[]}', '');
        }
        return ProcessResult(0, 0, '', '');
      },
    );
    final starting = service.ensureReadyForAppAccess();
    await peerRead.future;
    await service.stop();
    expect((await starting.timeout(const Duration(seconds: 1))).state,
        FipsRuntimeState.disabled);
    expect(peerCalls, 1);
    expect(enabled, isFalse);
  });

  test('failed preference write leaves FIPS access closed', () async {
    final service = FipsRuntimeService(
        isMacOS: true,
        readEnabled: () async => true,
        writeEnabled: (_) async {
          throw StateError('storage failed');
        });
    expect((await service.setEnabled(true)).state, FipsRuntimeState.failed);
    expect(await service.isEnabled, isFalse);
    expect((await service.ensureReadyForAppAccess()).state,
        FipsRuntimeState.disabled);
  });

  test('stale preference load cannot reopen a disabled runtime', () async {
    final stored = Completer<bool>();
    final service = FipsRuntimeService(
        isMacOS: true,
        readEnabled: () => stored.future,
        writeEnabled: (_) async {});
    final loading = service.isEnabled;
    await service.stop();
    stored.complete(true);
    expect(await loading, isFalse);
    expect(await service.isEnabled, isFalse);
  });

  test('setting writes serialize and last off wins an in-flight enable',
      () async {
    final firstWrite = Completer<void>();
    final writes = <bool>[];
    final service = FipsRuntimeService(
        isMacOS: true,
        readEnabled: () async => false,
        writeEnabled: (value) async {
          writes.add(value);
          if (writes.length == 1) await firstWrite.future;
        });
    final enabling = service.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    final disabling = service.stop();
    firstWrite.complete();
    expect((await enabling).state, FipsRuntimeState.disabled);
    expect((await disabling).state, FipsRuntimeState.disabled);
    expect(writes, [true, false]);
    expect(await service.isEnabled, isFalse);
  });

  test('bootstrap connect failure cooldown avoids repeating process work',
      () async {
    final commands = <List<String>>[];
    final service = FipsRuntimeService(
        isMacOS: true,
        fileExists: (_) async => true,
        readTextFile: (_) async => compatibleAttestation,
        processRunner: (_, arguments) async {
          commands.add(arguments);
          if (arguments.contains('--version')) {
            return ProcessResult(0, 0, '0.5.0', '');
          }
          if (arguments.contains('status')) {
            return ProcessResult(
                0,
                0,
                '{"state":"running","tun_state":"active","persistent":true}',
                '');
          }
          if (arguments.contains('peers')) {
            return ProcessResult(0, 0, '{"peers":[]}', '');
          }
          return ProcessResult(0, 1, '', 'connection unavailable');
        });
    expect((await service.ensureReadyForAppAccess()).state,
        FipsRuntimeState.degraded);
    final count = commands.length;
    expect((await service.ensureReadyForAppAccess()).state,
        FipsRuntimeState.degraded);
    expect(commands.length, count);
    await service.stop();
    await service.setEnabled(true);
    await service.ensureReadyForAppAccess();
    expect(commands.where((args) => args.contains('connect')).length, 2);
  });

  test('off interrupts active bootstrap timer instead of awaiting its deadline',
      () async {
    final connectedCommand = Completer<void>();
    var peers = 0;
    final service = FipsRuntimeService(
        isMacOS: true,
        fileExists: (_) async => true,
        readTextFile: (_) async => compatibleAttestation,
        processRunner: (_, arguments) async {
          if (arguments.contains('--version')) {
            return ProcessResult(0, 0, '0.5.0', '');
          }
          if (arguments.contains('status')) {
            return ProcessResult(
                0,
                0,
                '{"state":"running","tun_state":"active","persistent":true}',
                '');
          }
          if (arguments.contains('peers')) {
            peers += 1;
            return ProcessResult(0, 0, '{"peers":[]}', '');
          }
          if (arguments.contains('connect')) connectedCommand.complete();
          return ProcessResult(0, 0, '', '');
        });
    final operation = service.ensureReadyForAppAccess();
    await connectedCommand.future;
    // Flush the connect continuation so the retry timer is genuinely active.
    await Future<void>.delayed(Duration.zero);
    await service.stop();
    expect((await operation.timeout(const Duration(milliseconds: 100))).state,
        FipsRuntimeState.disabled);
    expect(peers, 1);
  });

  test('constructs an authorization command without shell-interpolating paths',
      () {
    const packagePath = '/Applications/Wingman App.app/Contents/Resources/'
        'FIPS/fips-0.5.0-macos.pkg';
    final command = FipsRuntimeService.installCommand(packagePath);

    expect(command.executable, '/usr/bin/osascript');
    expect(command.arguments.first, '-e');
    expect(command.arguments, contains(packagePath));
    expect(
      command.arguments,
      contains('/Applications/Wingman App.app/Contents/Resources/FIPS/'
          'configure-fips-wingman-poc.sh'),
    );
    expect(command.arguments[1], contains('quoted form of packagePath'));
    expect(
      command.arguments[1],
      contains('quoted form of configurationScriptPath'),
    );
  });

  test('constructs Linux pkexec activation without shell interpolation', () {
    const installPath = '/opt/Wingman App/data/fips/install.sh';
    final command = FipsRuntimeService.linuxInstallCommand(installPath);

    expect(command.executable, '/usr/bin/pkexec');
    expect(command.arguments, [
      '/bin/sh',
      '/opt/Wingman App/data/fips/install_fips_wingman_linux.sh',
    ]);
  });

  test('locates the bundled Linux systemd runtime beside the executable', () {
    expect(
      FipsRuntimeService.defaultBundledPackagePath(
        isMacOS: false,
        isLinux: true,
      ),
      endsWith('/data/fips/install.sh'),
    );
    expect(
      FipsRuntimeService.defaultAttestationPath(
        isMacOS: false,
        isLinux: true,
      ),
      '/etc/fips/wingman-poc-runtime.json',
    );
  });

  test('uses Linux service and attestation paths', () async {
    final calls = <(String, List<String>)>[];
    final service = FipsRuntimeService(
      bundledPackagePath: '/bundle/fips/install.sh',
      isMacOS: false,
      isLinux: true,
      fileExists: (_) async => true,
      readTextFile: (path) async {
        expect(path, '/etc/fips/wingman-poc-runtime.json');
        return compatibleAttestation;
      },
      processRunner: (executable, arguments) async {
        calls.add((executable, arguments));
        if (arguments.contains('--version')) {
          return ProcessResult(1, 0, '0.5.0', '');
        }
        if (executable == '/usr/bin/systemctl') {
          return ProcessResult(2, 0, 'active', '');
        }
        return ProcessResult(3, 1, '', 'control socket unavailable');
      },
    );

    final status = await service.inspect();

    expect(status.state, FipsRuntimeState.starting);
    expect(calls.last.$1, '/usr/bin/systemctl');
    expect(calls.last.$2, ['is-active', 'fips.service']);
  });

  test('installs bundled Linux FIPS through pkexec', () async {
    final calls = <(String, List<String>)>[];
    var installed = false;
    final service = FipsRuntimeService(
      bundledPackagePath: '/bundle/fips/install.sh',
      isMacOS: false,
      isLinux: true,
      fileExists: (path) async =>
          path.startsWith('/bundle/fips/') ||
          (path == '/usr/local/bin/fipsctl' && installed),
      readTextFile: (_) async => installed ? compatibleAttestation : null,
      processRunner: (executable, arguments) async {
        calls.add((executable, arguments));
        if (executable == '/usr/bin/pkexec') {
          installed = true;
          return ProcessResult(1, 0, 'installed', '');
        }
        if (arguments.contains('--version')) {
          return ProcessResult(2, 0, '0.5.0', '');
        }
        return ProcessResult(
          3,
          0,
          '{"state":"Running","tun_state":"active",'
              '"persistent":true,"npub":"$npub"}',
          '',
        );
      },
    );

    final status = await service.installOrRepair();

    expect(status.state, FipsRuntimeState.running);
    expect(calls.first.$1, '/usr/bin/pkexec');
    expect(calls.first.$2, [
      '/bin/sh',
      '/bundle/fips/install_fips_wingman_linux.sh',
    ]);
  });

  test('parses a running daemon status without exposing its key', () async {
    final calls = <(String, List<String>)>[];
    final service = FipsRuntimeService(
      bundledPackagePath: '/bundle/fips.pkg',
      fipsctlPath: '/usr/local/bin/fipsctl',
      isMacOS: true,
      fileExists: (_) async => true,
      readTextFile: (_) async => compatibleAttestation,
      processRunner: (executable, arguments) async {
        calls.add((executable, arguments));
        if (arguments.contains('--version')) {
          return ProcessResult(1, 0, '0.5.0 (rev test)', '');
        }
        return ProcessResult(
          2,
          0,
          '{"data":{"state":"Running","tun_state":"active",'
              '"persistent":true,"identity":{"npub":"$npub"}}}',
          '',
        );
      },
    );

    final status = await service.inspect();

    expect(status.state, FipsRuntimeState.running);
    expect(status.nodeNpub, npub);
    expect(calls.last.$2, ['show', 'status']);
  });

  test('reports an installed but not-ready launch daemon as starting',
      () async {
    final service = FipsRuntimeService(
      bundledPackagePath: '/bundle/fips.pkg',
      isMacOS: true,
      fileExists: (_) async => true,
      readTextFile: (_) async => compatibleAttestation,
      processRunner: (executable, arguments) async {
        if (arguments.contains('--version')) {
          return ProcessResult(1, 0, '0.5.0', '');
        }
        if (executable == '/bin/launchctl') {
          return ProcessResult(3, 0, 'loaded', '');
        }
        return ProcessResult(2, 1, '', 'control socket unavailable');
      },
    );

    final status = await service.inspect();

    expect(status.state, FipsRuntimeState.starting);
  });

  test('allows a WebView attempt while first-login control access is pending',
      () async {
    final service = FipsRuntimeService(
      bundledPackagePath: '/bundle/fips.pkg',
      isMacOS: true,
      fileExists: (_) async => true,
      readTextFile: (_) async => compatibleAttestation,
      processRunner: (executable, arguments) async {
        if (arguments.contains('--version')) {
          return ProcessResult(1, 0, '0.5.0', '');
        }
        if (executable == '/bin/launchctl') {
          return ProcessResult(3, 0, 'loaded', '');
        }
        return ProcessResult(2, 1, '', 'connect: Permission denied (EACCES)');
      },
    );

    final status = await service.inspect();

    expect(status.state, FipsRuntimeState.controlAccessPending);
    expect(status.canAttemptAppAccess, isTrue);
    expect(status.isRunning, isFalse);
    expect(
        status.detail, contains('open a FIPS app without the optional probe'));
  });

  test('distinguishes missing bundle, missing install, and old install',
      () async {
    Future<FipsRuntimeStatus> inspectWith({
      required Future<bool> Function(String) exists,
      FipsProcessRunner? runner,
    }) {
      return FipsRuntimeService(
        bundledPackagePath: '/bundle/fips.pkg',
        isMacOS: true,
        fileExists: exists,
        processRunner: runner,
      ).inspect();
    }

    expect(
      (await inspectWith(exists: (_) async => false)).state,
      FipsRuntimeState.notBundled,
    );
    expect(
      (await inspectWith(
        exists: (path) async => path == '/bundle/fips.pkg',
      ))
          .state,
      FipsRuntimeState.notInstalled,
    );
    expect(
      (await inspectWith(
        exists: (_) async => true,
        runner: (_, __) async => ProcessResult(1, 0, '0.4.2', ''),
      ))
          .state,
      FipsRuntimeState.installRequired,
    );
  });

  test('marks non-persistent or inactive-TUN status as degraded', () async {
    final service = FipsRuntimeService(
      bundledPackagePath: '/bundle/fips.pkg',
      isMacOS: true,
      fileExists: (_) async => true,
      readTextFile: (_) async => compatibleAttestation,
      processRunner: (_, arguments) async {
        if (arguments.contains('--version')) {
          return ProcessResult(1, 0, '0.5.0', '');
        }
        return ProcessResult(
          2,
          0,
          '{"state":"Running","tun_state":"configured",'
              '"persistent":false}',
          '',
        );
      },
    );

    final status = await service.inspect();

    expect(status.state, FipsRuntimeState.degraded);
    expect(status.detail, contains('persistent identity: false'));
  });

  test('uses the v0.5.0 JSON probe syntax', () async {
    final calls = <(String, List<String>)>[];
    final service = FipsRuntimeService(
      bundledPackagePath: '/bundle/fips.pkg',
      isMacOS: true,
      fileExists: (_) async => true,
      readTextFile: (_) async => compatibleAttestation,
      processRunner: (executable, arguments) async {
        calls.add((executable, arguments));
        if (arguments.contains('--version')) {
          return ProcessResult(1, 0, '0.5.0', '');
        }
        if (arguments.length >= 2 && arguments[0] == 'show') {
          return ProcessResult(
            2,
            0,
            '{"state":"Running","tun_state":"active","persistent":true}',
            '',
          );
        }
        return ProcessResult(3, 0, '{"verdict":"ok"}', '');
      },
    );

    final result = await service.probe(npub);

    expect(result.ok, isTrue);
    expect(calls.last.$2, ['probe', npub, '--json', '--timeout', '15']);
  });

  test('requires repair when a running v0.5.0 lacks mesh attestation',
      () async {
    var statusInspected = false;
    final service = FipsRuntimeService(
      bundledPackagePath: '/bundle/fips.pkg',
      isMacOS: true,
      fileExists: (_) async => true,
      readTextFile: (_) async => null,
      processRunner: (_, arguments) async {
        if (arguments.contains('--version')) {
          return ProcessResult(1, 0, '0.5.0', '');
        }
        statusInspected = true;
        return ProcessResult(
          2,
          0,
          '{"state":"Running","tun_state":"active","persistent":true}',
          '',
        );
      },
    );

    final status = await service.inspect();

    expect(status.state, FipsRuntimeState.installRequired);
    expect(status.detail, contains('mesh setup is missing or outdated'));
    expect(statusInspected, isFalse);
  });

  test('reports cancelled bundled activation without retrying authorization',
      () async {
    var authorizationRuns = 0;
    final service = FipsRuntimeService(
      bundledPackagePath: '/bundle/fips.pkg',
      isMacOS: true,
      fileExists: (_) async => true,
      processRunner: (executable, _) async {
        expect(executable, '/usr/bin/osascript');
        authorizationRuns += 1;
        return ProcessResult(1, 1, '', 'User canceled.');
      },
    );

    final status = await service.installOrRepair();

    expect(status.state, FipsRuntimeState.failed);
    expect(status.detail, contains('cancelled or failed'));
    expect(status.detail, contains('User canceled.'));
    expect(authorizationRuns, 1);
  });

  test('coalesces simultaneous app-link activation into one admin prompt',
      () async {
    final authorization = Completer<ProcessResult>();
    var authorizationRuns = 0;
    final service = FipsRuntimeService(
      bundledPackagePath: '/bundle/fips.pkg',
      isMacOS: true,
      fileExists: (_) async => true,
      readTextFile: (_) async => null,
      processRunner: (executable, arguments) async {
        if (arguments.contains('--version')) {
          return ProcessResult(1, 0, '0.5.0', '');
        }
        expect(executable, '/usr/bin/osascript');
        authorizationRuns += 1;
        return authorization.future;
      },
    );

    final first = service.ensureReadyForAppAccess();
    final second = service.ensureReadyForAppAccess();
    await Future<void>.delayed(Duration.zero);

    expect(authorizationRuns, 1);
    authorization.complete(ProcessResult(2, 1, '', 'User canceled.'));
    expect((await first).state, FipsRuntimeState.failed);
    expect((await second).state, FipsRuntimeState.failed);
  });

  test('awaits the authenticated no-DNS bootstrap before app access', () async {
    var peerChecks = 0;
    final calls = <List<String>>[];
    final service = FipsRuntimeService(
      bundledPackagePath: '/bundle/fips.pkg',
      isMacOS: true,
      fileExists: (_) async => true,
      readTextFile: (_) async => compatibleAttestation,
      processRunner: (_, arguments) async {
        calls.add(arguments);
        if (arguments.contains('--version')) {
          return ProcessResult(1, 0, '0.5.0', '');
        }
        if (arguments.first == 'connect') {
          return ProcessResult(2, 0, '{}', '');
        }
        if (arguments == const ['show', 'peers']) {
          peerChecks += 1;
          final peers = peerChecks < 2
              ? '{"peers":[]}'
              : '{"peers":[{"npub":"${FipsRuntimeService.bootstrapPeerNpub}",'
                  '"connectivity":"connected"}]}';
          return ProcessResult(3, 0, peers, '');
        }
        return ProcessResult(
          4,
          0,
          '{"state":"Running","tun_state":"active",'
              '"persistent":true,"npub":"$npub"}',
          '',
        );
      },
    );

    final status = await service.ensureReadyForAppAccess();

    expect(status.state, FipsRuntimeState.running);
    expect(
      calls,
      contains(
        equals([
          'connect',
          FipsRuntimeService.bootstrapPeerNpub,
          FipsRuntimeService.bootstrapPeerAddress,
          'udp',
        ]),
      ),
    );
    expect(peerChecks, 2);
  });

  test('redacts private key material from diagnostics', () {
    final nsec = 'nsec1${List.filled(58, 'q').join()}';
    final redacted = FipsRuntimeService.redactSecrets(
      'failed nsec=$nsec private_key=abcdef secret:xyz',
    );

    expect(redacted, isNot(contains(nsec)));
    expect(redacted, isNot(contains('abcdef')));
    expect(redacted, isNot(contains('xyz')));
  });
}
