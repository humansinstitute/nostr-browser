import 'pin_input_test_helpers.dart';
import 'package:wingman_app/src/widgets/immediate_pin_field.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/core/signer_vault.dart';
import 'package:wingman_app/src/features/browser/nostr_profile_store.dart';
import 'package:wingman_app/src/features/onboarding/signer_onboarding_screen.dart';
import 'package:wingman_app/src/features/onboarding/welcome_surface.dart';

class TestVault extends SignerVault {
  final pending = Completer<SignerVaultUnlock>();
  int unlocks = 0;
  String? lastPin;
  int clears = 0;
  @override
  Future<SignerVaultUnlock> unlock({required String pin}) {
    unlocks++;
    lastPin = pin;
    return pending.future;
  }

  @override
  Future<void> clear() async {
    clears++;
  }
}

SignerVaultRecord record(String npub) => SignerVaultRecord(
    version: 1,
    kdf: '',
    iterations: 1,
    salt: '',
    nonce: '',
    ciphertext: '',
    mac: '',
    npub: npub,
    publicKeyHex: '',
    createdAt: DateTime(2026, 1, 1));
Finder field(String label) => find.byWidgetPredicate((w) =>
    (w is ImmediatePinField && w.decoration.labelText == label) ||
    (w is TextField && w.decoration?.labelText == label));
void main() {
  setUp(() => SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty());
  testWidgets(
      'exact local identity cache, replacement fallback and reset confirmation',
      (tester) async {
    final vault = TestVault();
    await NostrProfileStore()
        .save('npub-test-a', const NostrProfile(displayName: 'Explorer'));
    Future<void> show(String npub) async {
      await tester.pumpWidget(MaterialApp(
          home: SignerOnboardingScreen(
              vault: vault, record: record(npub), onUnlocked: (_) {})));
      await tester.pumpAndSettle();
    }

    await show('npub-test-a');
    expect(find.text('Explorer'), findsOneWidget);
    expect(vault.unlocks, 0);
    await show('npub-test-b');
    expect(find.text('Explorer'), findsNothing);
    expect(find.text('Your Nostr identity'), findsOneWidget);
    await tester.tap(find.text('Reset local signer vault'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(vault.clears, 0);
    await tester.tap(find.text('Reset local signer vault'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(vault.clears, 1);
    expect(find.text('Create identity'), findsOneWidget);
    await enterEditorText(tester, field('PIN'), '1234');
    await enterEditorText(tester, field('Confirm PIN'), '4321');
    await tester.ensureVisible(find.text('Create and encrypt identity'));
    await tester.tap(find.text('Create and encrypt identity'));
    await tester.pumpAndSettle();
    expect(find.text('PIN entries do not match.'), findsOneWidget);
    await tester.ensureVisible(find.text('Import key'));
    await tester.tap(find.text('Import key'));
    await tester.pumpAndSettle();
    expect(field('Nostr private key'), findsOneWidget);
  });
  testWidgets('keyboard submit prevents duplicate unlocks and shows PIN errors',
      (tester) async {
    final vault = TestVault();
    await tester.pumpWidget(MaterialApp(
        home: SignerOnboardingScreen(
            vault: vault, record: record('npub-test'), onUnlocked: (_) {})));
    await tester.pumpAndSettle();
    await enterEditorText(tester, field('PIN'), '1234');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(vault.unlocks, 1);
    expect(tester.widget<ImmediatePinField>(field('PIN')).enabled, false);
    vault.pending.completeError(const SignerVaultException('Incorrect PIN.'));
    await tester.pumpAndSettle();
    expect(find.text('Incorrect PIN.'), findsOneWidget);
    expect(tester.widget<ImmediatePinField>(field('PIN')).enabled, true);
  });
  for (final size in [
    const Size(390, 844),
    const Size(1440, 900),
    const Size(768, 1024)
  ]) {
    testWidgets('welcome fits ${size.width} including keyboard',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: SignerOnboardingScreen(
              vault: TestVault(),
              record: record('npub1examplepublicidentity'),
              onUnlocked: (_) {})));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Unlock'));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('startup shares the welcome background', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WelcomeLoadingScreen()));
    await tester.pump();
    expect(find.byType(WelcomeSurface), findsOneWidget);
    expect(find.text('Preparing your local identity…'), findsOneWidget);
  });
}
