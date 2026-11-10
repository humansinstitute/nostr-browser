# Apple App Store readiness

Production App Store distribution is distinct from private TestFlight testing.
Verify the intended audience before selecting the release path. The automated
nightly API helper supports private internal TestFlight only; its successful
readback does not establish production availability.

## Verify source and Apple state

Read the repository guidance and [shared release policy](nightly-release-policy.md).
Preserve local commits and concurrent edits. Compare the selected commit with
upstream, check the release notes and validate the browser source. Build the
native test dependency before Flutter tests:

```sh
cargo build --locked --release -p wmapp-drive-fs
cd app
flutter analyze --no-pub
flutter test --no-pub
```

Run the release tooling and browser-only package regression suite from the
repository root using the configured private Python environment. Fixture-only
tests can use `WMAPP_APPLE_TEAM=TESTTEAM01`; this synthetic selector must never
be used for an actual signed build. Real signing requires the verified existing
team, unchanged bundle and extension identifiers, and valid distribution profiles.

Use the scoped Apple client for authenticated read-only inspection. Inspect
production versions, version localizations, screenshot sets, review information,
selected build, app-info privacy URL and complete build/upload history. Keep
credential references and operational output in ignored private storage. A
read-only inventory is not permission to bypass a failed reservation or artifact
integrity gate. Preserve mismatched historical archives and recorded hashes;
reconcile their exact evidence before further delivery.

## Prepare the listing and production artifact

Before submission, establish:

- Accurate description, keywords, support URL, privacy-policy URL and copyright.
- Genuine screenshots for the required supported device classes.
- Review contact details and instructions that allow review of the actual app.
- Accurate app privacy, age rating, content rights, encryption and availability
  declarations, with business/legal input where the source cannot establish them.
- A production-eligible signed build matching the selected marketing version,
  with a fresh monotonic build number verified against all uploads/reservations.

Do not invent contact details, publish a placeholder policy, infer declarations
from an older build, or substitute beta screenshots for a changed experience.
Resolve marketing-version differences between the app and production listing
before building. An internal-only TestFlight artifact cannot substitute for the
production export. Preserve the existing signing team and identifiers for both
Runner and the FIPS Packet Tunnel extension. Check the new signed artifact's
source provenance, entitlements and absence of retired embedded app assets.

Use an explicitly authorized production archive/export and App Store Connect
submission workflow. Do not repurpose the nightly internal API helper by
weakening its audience, claim, upload-uncertainty or integrity checks. Local
export may create an Apple upload reservation; inspect fresh history before
another delivery attempt and never retry an uncertain upload blindly.

## Report the actual outcome

Distinguish local export, accepted upload, processing, submission, review,
approval and public distribution. Verify public availability before describing
an App Store URL as an installation link. An unsubmitted draft or an internal
build in beta testing provides no verified public installation link.

References: [submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app),
[submission requirements](https://developer.apple.com/app-store/submitting/),
[App Review](https://developer.apple.com/app-store/review/).
