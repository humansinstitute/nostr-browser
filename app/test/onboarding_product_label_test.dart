import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/signer_vault.dart';
import 'package:wingman_app/src/features/onboarding/signer_onboarding_screen.dart';
import 'package:wingman_app/src/features/onboarding/welcome_surface.dart';

void main() {
  testWidgets('login experience displays the Nostr Browser product label',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SignerOnboardingScreen(
          vault: SignerVault(
            localStore: MemorySignerVaultLocalStore(),
            secretStore: MemorySignerVaultSecretStore(),
          ),
          record: null,
          onUnlocked: (_) {},
        ),
      ),
    );

    expect(find.text('Nostr Browser'), findsOneWidget);
    expect(find.text('Set Up Nostr Browser'), findsOneWidget);
    expect(find.text('WINGMAN'), findsNothing);
    expect(find.text('Set Up Wingman Signer'), findsNothing);
  });

  testWidgets('loading experience uses the Nostr Browser accessible label',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: WelcomeLoadingScreen()),
    );

    expect(find.text('Nostr Browser'), findsOneWidget);
    expect(find.bySemanticsLabel('Loading Nostr Browser'), findsOneWidget);
    expect(find.bySemanticsLabel('Loading Wingman'), findsNothing);
  });
}
