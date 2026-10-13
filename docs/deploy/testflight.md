# iOS TestFlight release checks

Use the existing Apple team `<existing-apple-team>` and these identifiers:

- Runner: `com.wingmanbefree.wingmanApp`
- Packet Tunnel: `com.wingmanbefree.wingmanApp.FipsPacketTunnel`

## External TestFlight with an Open to Anyone link

Use this path only with explicit authorization for external testers and a public
invitation link. The default command and existing schema-1 runs remain private.
Choose `--audience external` and a distinct `--group` at **init**; those choices
are fixed for the run. External export uses
`TestFlightExternalExportOptions.plist` with
`testFlightInternalTestingOnly=false`. The standalone helper accepts
`--external`; it still only builds/exports. Preserve Private Internal, its existing
builds, members and automatic distribution settings.

First read App Store Connect's complete iOS version/build history, including
processing uploads, and verify the bundle identifier and existing audience.
Confirm the existing Xcode GUI account/team separately. A browser login page is
a browser authentication gate; CLI `No Accounts` does not establish Xcode
sign-out. Handle actual human Apple gates in their visible UI and report the
exact blocker. Never request credentials, extract keys or revoke certificates.

After observing history, select a **version newer than Apple's latest version**
and a **build greater than every observed build**. The variables below represent
those verified choices and a unique run name; they are not preset numbers:

```sh
python3 tools/ios/testflight_release.py init --run "$RUN" \
  --audience external --group 'WMAPP Public' \
  --version "$NEXT_VERSION" --build "$NEXT_BUILD"
```

Fill the generated preflight with fresh observations as in the private workflow,
with these external fields:

- `group` is the exact intended external group name, `internal=false`, and
  `public_link=false` until review approval. `external_group_id` is its observed
  ID if the group exists; otherwise leave it `null` until created/read back.
- `private_group` separately verifies `group="Private Internal"`, `internal=true`,
  `tester_count=1`, `sole_tester_is_owner=true`, `settings_unchanged=true`. The
  last field includes the group's builds and automatic distribution settings.
- `other_distribution_groups=[]` means no unexpected audience beyond the
  preserved private group and the intended external group. Review all groups'
  automatic distribution settings. Stop and report drift; do not delete testers
  or adjust settings to manufacture a passing observation.
- There is no external named-tester count or cap requirement.

Run the focused tests below and sequential Flutter analysis/tests before the
actual release. Commit tested source before building and keep source stable.
Then use `run --run "$RUN" --dry-run`, followed by `run --run "$RUN"`.
The run records source commit/diff and export-policy SHA-256, archive file
hashes, IPA SHA-256 and both signed executable hashes. Build logs record the
fetched Flight Deck commit/bundle version and pinned native core revision.
Both targets retain the same signing/profile/entitlement checks as private
releases. A policy change invalidates artifact validation.

If CLI export cannot resolve the existing account, export the retained archive
in Organizer with **TestFlight internal testing only disabled** and **Manage
version and build number disabled**, using team `<existing-apple-team>` and automatic
signing. Export into this run's directory and use `verify`. Internal Only build
8 cannot be converted to an external build by changing its group.

For upload, use `upload --run "$RUN" --via organizer` for intent/instructions
and the actual Organizer flow, or `--via cli` for a real network upload using
the existing Xcode account. Both pin external eligibility and preserve the
uncertain-delivery barrier. Never repeat an upload to discover whether it
succeeded. Read Apple's receipt and exact build record, then wait for processing.
Neither export nor a successful upload command proves external availability.

Use the encryption inventory below for the new build's actual compliance
questions. Do not reuse an old build's answer as a classification, claim only
OS encryption, invent an exemption/code, or set `ITSAppUsesNonExemptEncryption`
without determining the applicable classification and territories.

Once processed and compliant, create/read back the intended external group and
assign the exact build. Complete TestFlight test information and submit **Beta
App Review**. Do not submit a production App Store version. Verify required
feedback/review contact details from authorized existing records; do not invent
contacts. Describe the app, what to test and reproducible reviewer access.
Current onboarding supports **Create identity** and a local 4–12 digit PIN,
or importing an existing Nostr key. Basic identity creation requires no Tower
account; connected workspaces/services may need separate access. Confirm those
flows and provide authorized reviewer access where needed before submission.

Readback uses the same receipt/build, processing and compliance fields as the
private path, with `internal_only=false`, plus:

| Field | Required observation |
| --- | --- |
| `external_group_id`, `assigned_to_group` | Exact external group ID and this build's assignment; once observed, the run pins the ID. |
| `test_metadata_complete`, `review_submission_id` | Saved complete test metadata and Apple's submission reference. If no distinct submission ID is exposed, use the exact Apple build record ID with visible review status as the reference and explain this in the task evidence. |
| `beta_review_status` | Normalize the visible status to `not_submitted`, `waiting_for_review`, `in_review`, `approved`, `rejected`, or `action_required`. |
| `build_testing_status` | The visible status for this exact build; readiness requires `Testing`. |
| `public_link`, `invitation_access` | Enabled link and `Open to Anyone`, after approval. |
| `tester_criteria`, `custom_tester_limit` | `[]`, `null`: no added criteria or custom cap; retain Apple's normal behavior. |
| `public_link_url`, `public_landing_accepting` | Observed `https://testflight.apple.com/join/...` and its public landing page accepting testers, verified without App Store Connect access. |

Refresh `observed_at` and run `readback --run "$RUN"` after each milestone.
External states distinguish `processed_awaiting_review`, `beta_review_pending`,
`beta_review_action_required`, `approved_awaiting_public_link` and
`ready_for_external_testing`. The last state requires approval, completed
processing/compliance, exact external assignment, **Testing**, Open to Anyone
and verified public access. `status` suppresses any pending public URL.
These are explicit Apple UI observations, not independent API verification.

For a pending review, leave a task continuation with app/version/build/receipt,
source and IPA hashes, group ID, submission reference, observation time and the
exact next check. Keep all operational evidence ignored. After approval, start
testing if required and create the public link with **Open to Anyone** selected
and **Set Limit** unchecked. Read back the saved settings, exact build/group
and public landing before sharing the active link. Rejection, agreements,
compliance, Keychain prompts and review waits remain truthful task blockers.

The sections below describe the **private workflow**; their Owner-only audience
rules apply to private runs. Shared account, signing, artifact validation and
encryption guidance also applies to the external path above.

## Resumable private release command

From the repository root, use Python 3 and the existing Xcode account. No API
key, Apple password, or signing-key export is required. `run` automates local
build/export and validation; `upload --via cli` sends an explicit future upload
using that account. The default `upload` records intent and gives bounded
Organizer instructions. Apple history, compliance and group readback use the existing Apple UI sessions. This workflow does not claim unattended Apple API
access or infer sign-out from CLI `No Accounts`.

Choose a unique run name and a version/build after inspecting Apple history.
For example, **only if Apple still has no build newer than 8**:

```sh
python3 tools/ios/testflight_release.py init --run private-0.1.7-9 --version 0.1.7 --build 9
```

This creates an ignored run directory and an unconfirmed `preflight.json` under
`tmp/docs/handoffs/testflight/<run>/`. Fill the JSON using **fresh observations**,
not assumptions or copied previous-release evidence. Replace every `null`:

| Field | Required observation |
| --- | --- |
| `observed_at` | Timezone-aware ISO timestamp from the actual observation, at most 24 hours old; e.g. output of `python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())'`. |
| `xcode_gui_account_present`, `team` | Existing account visible in Xcode Settings → Apple Accounts; intended team `<existing-apple-team>`. Keep signed in. |
| `app_id`, `bundle` | App Store Connect's numeric app ID (string) and App Information bundle identifier. |
| `latest_version`, `existing_builds`, `history_complete` | Latest iOS version string, integer build numbers across all iOS history including processing uploads, and `true` only after checking the full history. |
| `group`, `internal`, `tester_count`, `sole_tester_is_owner` | Existing `Private Internal`, `true`, `1`, `true` after verifying its sole member is Owner. Do not record email addresses. |
| `public_link`, `other_distribution_groups` | `false`, `[]` after checking the app's distribution audience, including external and automatically distributing groups. Stop on unexpected audience; do not remove or change testers to pass the check. |
| `automatic_distribution_reviewed` | `true` after reviewing all groups' automatic distribution settings. Preserve the existing setting for Private Internal; automatic assignment still requires readback. |

JSON uses lowercase `true`/`false`; an empty history is `[]` only when verified.
The script requires a build greater than every observed Apple build and a version
at least as high as Apple's latest version. Build 8 from an earlier release is
not a current history check. Refresh the observations before upload if expired.

Run preflight without building, signing, or uploading:

```sh
python3 tools/ios/testflight_release.py run --run private-0.1.7-9 --dry-run
```

The dry-run checks the repository team/bundle settings, safe export plist and
human observations. It does **not** establish usable signing assets; the actual
build/export validates the signatures and profiles. Run Flutter analysis/tests
sequentially as below, then the future release command is:

```sh
python3 tools/ios/testflight_release.py run --run private-0.1.7-9
```

`run` forwards the explicit version/build to the existing build helper, preserving
`app/pubspec.yaml`. It preserves prior Flutter archive/IPA directories under the
private run and verifies their hashes, builds the pinned native core and current
Flight Deck bundle, then retains a run-specific archive. It validates Runner and
FipsPacketTunnel identifiers, versions, teams, signatures and packet tunnel
entitlements. Export validation additionally requires unexpired App Store
profiles with no device list, no enterprise provisioning and no debug signing.
The state records archive, IPA and executable hashes. Export success is local
artifact evidence only.

All workflow commands share a nonblocking lock because Flutter output paths are
shared. Do not run standalone Flutter/build helpers concurrently with a release.
Do not change source files while building. Keep each run's archive, export,
observations and state together; do not edit `state.json` to skip checks.

### Upload and readback

After `run` reports a validated export, the optional scripted upload command is:

```sh
python3 tools/ios/testflight_release.py upload --run private-0.1.7-9 --via cli
```

**This command sends a real upload.** It copies the checked export plist into
private evidence with `destination=upload`, retaining team, internal-only and
unmanaged version/build settings, then calls `xcodebuild -exportArchive` with
`-allowProvisioningUpdates` and the run's validated archive. Xcode can use an
account already added in Apple Accounts; new API credentials are not inherently
required. Account resolution previously failed in the CLI despite a signed-in
GUI, so delivery with that session is not proven until an authorized real release.
This implementation was validated with mocked uploads, never a live upload.

The script records `upload_pending` **before** contacting Apple. CLI completion
records a command timestamp, not upload/processing success. Any failure leaves
an uncertain pending state and never retries automatically. Inspect the private
upload log and Apple history for the exact build before deciding on Organizer
fallback. A `No Accounts` message still does not establish sign-out.

For the proven Organizer route, use this command **instead of** `--via cli`:

```sh
python3 tools/ios/testflight_release.py upload --run private-0.1.7-9 --via organizer
```

Both routes recheck history/audience and artifact hashes, persist `upload_pending`,
and create `readback.json`. The Organizer route prints instructions. **Organizer mode does not send a build to Apple.** Open the
printed run-specific archive in Organizer, choose **Validate App**, then
**Distribute App → Custom → App Store Connect → Upload** using the existing
account. Enable **TestFlight internal testing only** and disable **Manage version
and build number**; read back both settings and the exact version/build before
continuing. Never change the tester audience or enable a public link.

The available Xcode GUI session is sufficient for Organizer; it is not an App
Store Connect API credential. Automated processing polls and tester membership
reads would require a separately authorized API integration. This workflow uses
explicit human UI readback rather than requesting new credentials or assuming
browser cookies can authenticate an API. Neither route changes groups/testers.

Fill `readback.json` only after seeing Apple's receipt/build record. Update
`observed_at` and confirm the prefilled app ID/team/bundle/version/build. Set:

- `receipt_or_build_id`: Apple's upload receipt identifier or exact build ID.
- `processing`: `processing`, `complete`, or Apple's failure/action state.
- `encryption_compliance`: `complete` only after Apple accepts the required
  answers/documents; otherwise `pending` (see inventory below).
- On completed processing/compliance, confirm the audience fields again,
  `internal_only=true`, and `assigned_to_group=true` after reading back this
  exact build in Private Internal. Add that build to the **existing** group only if
  needed; leave memberships/settings unchanged.
- `owner_sees_exact_build`: `true` only after Owner verifies that exact version and
  build in TestFlight; otherwise `false`.

```sh
python3 tools/ios/testflight_release.py readback --run private-0.1.7-9
python3 tools/ios/testflight_release.py status --run private-0.1.7-9
```

The recorded states distinguish `exported`, `upload_pending`,
`uploaded_processing`, `uploaded_action_required`, `processed_awaiting_tester`
and `ready_to_test`. `ready_to_test` requires the receipt/build ID, completed
processing/compliance, exact private assignment and tester visibility. These
are labelled **human Apple UI observations**, not independent API verification.
An IPA, an upload receipt, or a local device installation alone cannot mark a
release ready.

### Resume after a failure

Use `status` first. Never rerun upload to discover whether it succeeded.

- With `archived`, fix only the reported signing/account issue and rerun `run`
  to export the retained archive without rebuilding. A failed export directory
  is preserved; rename it within the ignored run before a fresh CLI export.
- If CLI says `No Accounts` while Xcode shows the existing account/team, use
  Organizer **Export** with the same internal-only/version settings into the
  run's `export/` directory. Keep exactly one freshly exported IPA there, then
  run `python3 tools/ios/testflight_release.py verify --run private-0.1.7-9`.
  A build failure may still leave a valid retained archive; check `status`.
  Organizer must not change the build number or overwrite the retained archive.
- A `building` state means archive completion was not safely recorded. Preserve
  that run and start a new unique run to rebuild; do not delete prior evidence.
- `exported` is resumable and may be reverified. Changing archive or IPA bytes
  invalidates recorded validation. Choose a new run and rebuild for a conflicting
  Apple build number; never patch a signed artifact.
- `upload_pending` survives cancellation/interruption. Inspect Organizer delivery
  logs and Apple build-upload history for the exact build. If a receipt/build
  exists, fill readback and continue. If Apple explicitly confirms no upload,
  the operator may perform the bounded Organizer upload from that pending run;
  do not create a second run to retry an uncertain delivery. Repeated `upload`
  commands refuse to proceed, and another run with the same app/build cannot
  bypass a pending or recorded delivery. Failed processing requires investigation, not an
  automatic second upload.
- Refresh `readback.json` and rerun `readback` while processing, compliance or
  tester visibility remains pending. This never uploads or changes groups.

If the visible Keychain dialog asks to allow `codesign`, enter the password
**in that dialog** and choose Allow, or Always Allow at your discretion. No
script reads the password or extracts a private key. Reauthentication is needed
only when Apple's UI explicitly requires it, not because the CLI says No Accounts.

Focused validation, without Apple access or uploads:

```sh
python3 -m unittest discover -s tools/tests -p test_testflight_release.py
bash -n build_ios_testflight.sh
```

Tests exercise human-observation fixtures and local failure modes; passing tests
are implementation evidence, not evidence of an actual release. Keep real run
logs and observations ignored. Do not link private evidence paths from public
product documentation.

## Account and version

Open [App Store Connect](https://appstoreconnect.apple.com/apps) using the
authorized Apple account. Verify the app by bundle identifier, inspect its
TestFlight build history, and record the existing internal group that contains
the intended tester. Check its current members and automatic distribution
settings before uploading. Group creation or adding the intended tester requires
release instructions that authorize it. Never enable a public link, invite other
testers, or distribute to other groups for a private release.

Verify the app's App Information bundle identifier before interpreting an empty
TestFlight page. For this private workflow, the existing Private Internal internal
group must have only Owner. If it is missing, empty, or has unexpected members,
stop distribution and report the discrepancy; do not create groups, add testers,
remove testers, enable public links, or broaden the audience.

Choose a build number greater than the existing iOS builds. The resumable
command supplies explicit Flutter version/build overrides; the standalone helper
uses `app/pubspec.yaml` unless overrides are supplied. Runner and FipsPacketTunnel
use Flutter's generated version and build settings. A local build number remains provisional until checked
against App Store Connect.

Inspect **Xcode → Settings → Apple Accounts** on the build Mac and verify the
account's team and role. An export error saying `No Accounts` does not establish
that the account is signed out: CLI export and the Xcode GUI can resolve accounts
differently. Request reauthentication only when Apple's UI or an explicit
authentication error requires it. Browser App Store Connect authentication is
separate from Xcode account access. Never put credentials in chat, source files
or build logs.

Both App IDs require the Network Extensions `packet-tunnel-provider`
capability. Automatic distribution export needs Apple Developer Program access
and suitable distribution profiles for both targets. A development certificate
or a macOS Developer ID certificate does not establish iOS distribution access.

If no usable distribution identity exists, use the intended team's **Manage
Certificates → + → Apple Distribution** in Xcode. Let Xcode generate and store
the signing key; do not extract it. Verify the resulting certificate's team and
validity, and check `security find-identity -v -p codesigning` for a usable
identity. Do not revoke existing certificates to work around an export failure.

When CLI account resolution fails despite verified GUI access, open the archive
in Organizer. To repair signing assets without uploading, choose **Distribute
App → Custom → App Store Connect → Export**, enable **TestFlight internal testing
only**, disable **Manage version and build number**, and choose **Automatically
manage signing**. Verify both generated profiles as described below. Profile
creation alone does not establish a signed IPA or a completed upload.

macOS may ask for the login keychain password when `codesign` first uses a new
distribution key. The human must enter that password directly into the visible
Keychain dialog and choose **Allow**, or **Always Allow** if they want to remember
access for `codesign`. This is local signing-key access, separate from Apple
account authentication. Leave the prompt for the human; never obtain the
password or bypass the keychain access controls.

## Build and inspect

Run Flutter validation sequentially; concurrent Flutter commands can race while
regenerating iOS package files:

```sh
cd app
flutter analyze
flutter test
cd ..
./build_ios_testflight.sh
```

The standalone helper builds the pinned FIPS core, fetches and builds Flight Deck
main, archives Runner, and checks that a fresh IPA was exported. Record the Flight
Deck commit and bundle version from the build output. Preserve an existing
archive before rebuilding if it is needed for comparison or recovery.

Inspect each signed target, not just Runner:

```sh
codesign --verify --deep --strict app/build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app
codesign -d --entitlements :- app/build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app
codesign -d --entitlements :- app/build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app/PlugIns/FipsPacketTunnel.appex
```

Check the target Info.plists for the expected identifiers and matching
`CFBundleShortVersionString`/`CFBundleVersion`. Decode each embedded provisioning
profile with `security cms -D -i <profile>` into private local evidence. Report
only the team, application identifier, expiry, profile class and required
entitlements; do not publish provisioned device identifiers. Verify the exported
IPA separately after extraction: its distribution profiles should not contain
`ProvisionedDevices`, and `get-task-allow` should be false. Verify the app icon
and record SHA-256 checksums for the IPA and signed executables.

After repairing signing access, retry an existing archive without rebuilding:

```sh
xcodebuild -exportArchive \
  -archivePath app/build/ios/archive/Runner.xcarchive \
  -exportPath app/build/ios/ipa \
  -exportOptionsPlist docs/deploy/TestFlightExportOptions.plist \
  -allowProvisioningUpdates
```

If the provisional build number conflicts with Apple's history, update the
version first and rebuild; do not upload the conflicting archive.

## Encryption inventory

WMAPP uses encryption beyond Apple's operating system HTTPS APIs:

| Component | Implementation and purpose |
| --- | --- |
| Signer vault | Dart `cryptography`: AES-256-GCM with PBKDF2-HMAC-SHA256 to protect the stored signer secret; see `app/lib/src/core/signer_vault.dart`. |
| Native FIPS mesh | Bundled Rust FIPS: Noise IK/XK with secp256k1 ECDH, ChaCha20-Poly1305 and SHA-256/HKDF to protect link/session traffic. The source revision is pinned by `tools/ios/prepare_core.py`; inspect its generated `src/noise` implementation. |
| Nostr authentication | secp256k1 signatures for identity and exact request authentication; see `app/lib/src/core/nostr_crypto.dart`. |
| Browser HTTPS | Platform TLS in the WebView, alongside the bundled implementations above. |

FIPS here names the mesh protocol; it is not a FIPS 140 certification claim.
The encryption inventory does not establish an export exemption. Do not answer
that the app uses no encryption or only operating system encryption. Keep
`ITSAppUsesNonExemptEncryption` unset until the applicable classification is
established. Do not invent an `ITSEncryptionExportComplianceCode`.

In App Store Connect, use **TestFlight → build → Manage** beside missing
encryption information, or **App Information → App Encryption Documentation**.
Answer using the implementations above and the actual distribution territory.
If Apple requires documentation, complete that process and use Apple's approved
code. A protocol that combines standard algorithms needs assessment against
Apple's questions; its name alone does not establish the answer.

## Upload and tester acceptance

Use the authorized Xcode account in Organizer: validate the archive, then
distribute as **TestFlight Internal Only**. Xcode supports a private export-plist
copy with `destination=upload`, preserving
`testFlightInternalTestingOnly=true`, but the resumable workflow uses the proven
Organizer path by default and offers CLI upload only with explicit `--via cli`.
Local export and upload are distinct steps.

For the Custom App Store Connect upload flow, inspect the options again:
**Upload** can default to different settings from a previous **Export**. Enable
**TestFlight internal testing only**, disable **Manage version and build number**,
and read back both selections before continuing. Record validation warnings with
their effective dates; a future requirement is not evidence of a current upload
failure. Keep account agreement notices distinct from the actual upload result.

After upload:

1. Record Apple's receipt/build ID and verify processing completes.
2. Resolve any encryption/compliance state using the inventory above.
3. Add only the intended existing internal group; verify its build assignment
   and eligible tester membership independently by reading them back.
4. Verify the tester can see/install the exact version/build in TestFlight.
   An upload receipt or successful local install does not establish this.

Keep run logs, operational notes, screenshots and device records only in ignored
`tmp/docs/handoffs/`. Keep the task in progress until the supervising reviewer
accepts the release evidence.

## Official references

- [Flutter iOS release guide](https://docs.flutter.dev/deployment/ios)
- [Apple upload and processing](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [Apple beta distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
- [Apple external testing and public invitations](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)
- [Apple TestFlight test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information)
- [Apple internal tester groups](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/)
- [Apple encryption documentation workflow](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/)

## Nightly API integration

The private nightly runner also supports `api-preflight`, `api-reserve`,
`api-build`, `api-upload` and `api-readback`. See
[nightly-testflight.md](nightly-testflight.md) for credential-reference setup,
complete history/audience gates, exact committed isolated Flight Deck-first
builds, cancellation reconciliation, daily claims and bounded processing checks.
These actions preserve the existing archive/IPA and both-target signature
validation and durable `upload_pending` barrier. They use only the existing
private manual internal group. Human Organizer observations and API readback
remain distinct evidence; API `Testing` does not prove device visibility.

Set `WMAPP_TESTFLIGHT_PRIVATE_GROUP` to the verified existing internal group name. The generic default is `Private Internal`; both release and readback tools require the same setting. Private observation files use `sole_tester_is_owner` and `owner_sees_exact_build`.

Set `WMAPP_APPSTORE_APP_ID` to the verified App Store Connect application ID; the public default is a placeholder. Apple bundle and signing-team identifiers remain unchanged.
