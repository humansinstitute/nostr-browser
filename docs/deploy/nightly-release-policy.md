# Independent nightly store releases

Two existing scheduler sessions run at 22:00 Australia/Perth. Each owns one
store outcome. TestFlight processing, compliance, claims and failures never gate
Android; Android state never gates TestFlight. Both use canonical Nostr Browser
and the configured current Flight Deck checkout. Do not run a second upload to
test scheduling.

## Source preparation and validation

Read current source, upstream and local edits first. Preserve local commits and
all edits. Repair routine divergence with a normal merge; never reset, rebase,
stash, force-push or silently replace current source with an older remote tree.
Make portable guide corrections generic and retain original operational bytes
privately when necessary. Guide findings are repaired/reported, not a reason to
abandon valid packaging. Public source archives must still exclude private data.

Serialize shared source mutations with the process-owned source lock:

```sh
python3 tools/release_sources.py -- sh /absolute/ignored/source-preparation.sh
```

The reviewed script performs only source reconciliation, validation/checkpoint
and normal push commands. Inspect candidate paths and tested hashes before
committing. Use isolated validation trees with frozen dependencies for expensive
checks. Keep the source-lock interval short: never include store build,
processing, compliance, upload, publication or reporting. The lock uses `flock`;
the kernel releases it on process exit/crash. Do not delete its persistent file.
This replaces the old whole-release directory lock. Preserve any old lock
record as evidence rather than stealing another session's lock.

Commit all compatible tested nonignored software and reusable docs, Flight Deck
first. Keep operational evidence ignored. Required checks include focused
regressions, static analysis/compilation, Flutter tests and Flight Deck
`check:public-source`, `test:release`, build and `verify:dist`. The release test
mode still asserts actual worker results and event-loop progress; its 50 ms
host scheduling observation is recorded without becoming an upload gate.
Strict `test` remains available for performance investigation. No functional
failure may be relabelled as noise or reported as passing.

Helpers archive exact selected commits under the short source lock before
expensive packaging. Subsequent shared HEAD/edits cannot change those snapshots.
Both snapshots have a real Git source index for public-source checks. Signed
artifacts, source identity, bundle assets, package/certificate, private audience,
monotonic numbers and uncertain-delivery gates remain mandatory.

## Recovery and availability

TestFlight uses source-aware daily claims. A failed same-source attempt is
recoverable only through `nightly_testflight.py retry-source --run <retained-run>
--previous-owner <owner>` with fresh complete clear Apple history, retained
pre-delivery states, no export reservation or upload intent, and a verified
archived prior worker if ownership changes. History is retained. Exported IPAs
use their own native proof recovery, never a rebuild/re-upload shortcut.

Successful Xcode export logs are copied byte-for-byte with original timestamps
before temporary files disappear. `api-upload` automatically invokes supported
same-run recovery when the exact empty export-created reservation is present.
It rechecks signed IPA/archive, private export policy, native reservation request,
preflight absence, exact ID/version/date and fresh empty upload files. Unmatched
or uncertain deliveries still block. After altool delivers the build, history
can recognize its leftover empty reservation only by revalidating that original
proof and state hash, retained signed artifact, exact live processed build and
unchanged private audience. The Apple record remains and its number is counted.

A prior processed build awaiting legal compliance does not suppress a new upload.
Report the exact already-uploaded build and actual questionnaire; never invent
answers, exemptions or territories. Later workers/days use:

```sh
python3 tools/ios/nightly_testflight.py resume-readback --run <delivered-run> --previous-owner <finished-owner>
python3 tools/ios/testflight_release.py api-readback --run <delivered-run> --poll-seconds 600
```

Use the configured private Python environment and public app/team selectors.
This appends readback-only authority for the exact delivered source/run after a
finished processing/action-required claim, with no active release. It cannot
reserve, build or upload. Finish that claim before claiming a fresh nightly
release. Read-only observation is available without assignment authority.

Android build failures retain logs and their reserved code as
`failed_before_delivery`, allowing a later night to build fresh validated source.
An archived pre-build crash can use `reconcile-build --day <original-day>` only
with verified archived ownership, no publication/signing evidence, complete
live history and absence of that reserved code. Delivery stages never expire.
The supported `restore-history --evidence <reviewed-private-proof>` route can
reconstruct an absent ledger from signed live releases and exact retained task
proof of pre-build failures. It never overwrites an existing ledger or pretends
lost local files were recovered.

Android's ordered actions are `build`, `prepare`, `public-assets`,
`prepare-public`, `publish-public`. Confirm exact signed relay IDs, anonymous CDN
GET redirect to the signed GitHub APK URL, downloaded APK hash/certificate/assets,
and branded public listing before `published`. Successful relay mutation first
records `uploaded`; failed availability checks resume via `readback --day
<original-day>`, without republishing. Browser button interaction and device
installation are separate checks and must be reported accurately.

For either lane: report Testing/published, processing, action-required, failed or
uncertain truthfully on its bound current task and originating thread. Preserve
pending delivery evidence; no automatic retry. Use the live saved trigger's
scoped binder and identity, not an archived historical task. No managed-service
restart is needed or authorized by this procedure.
