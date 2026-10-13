import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/browser/nostr_profile_store.dart';

void main() {
  test('parses kind 0 profile metadata without exposing npub fallback', () {
    final profile = NostrProfile.fromKind0Content('''
{
  "name": "example-user",
  "display_name": "Example User",
  "picture": "https://example.com/avatar.png",
  "nip05": "example-user@example.com",
  "website": "https://example.com",
  "about": "Building Wingman"
}
''');

    expect(profile, isNotNull);
    expect(profile!.labelFor('npub1rawdetails'), 'Example User');
    expect(profile.avatarUrl, 'https://example.com/avatar.png');
    expect(profile.toKind0Json()['display_name'], 'Example User');
  });

  test('uses generic profile label when no relay profile has been fetched', () {
    const profile = NostrProfile();

    expect(profile.labelFor('npub1rawdetails'), 'Profile');
  });
}
