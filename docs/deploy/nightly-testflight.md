# Daily private TestFlight release

Read [shared nightly policy](nightly-release-policy.md) for independent lanes,
short process locks, immutable snapshots and supported recovery.

Autopilot's supported scheduler starts one bounded agent session daily at
22:00 `Australia/Perth` (`0 22 * * *`, 14:00 UTC). The enabled trigger stores
the full execution contract, repository paths, identity and reporting route.
No Autopilot restart is needed for scheduler CRUD.

## Authentication and release gates

The API integration reads a private owner-only credential reference and signs
short-lived ES256 tokens. It verifies the exact app, complete paginated build
and upload history, and pinned existing private group and sole tester. Native
Xcode archive/export/upload receives only the authorized key reference, key ID
and issuer ID. Never print PEM, JWT or Authorization headers. Python uses the
host CA bundle (on macOS `/etc/ssl/cert.pem`); TLS verification is mandatory.

Install the pinned Python dependencies in a private virtual environment before
running the API actions:

```sh
python3 -m venv "$RELEASE_VENV"
"$RELEASE_VENV/bin/python" -m pip install -r tools/ios/requirements-testflight.txt
```

Keep the environment and local reference under ignored operational storage.
The reference schema is `schema: 1`, `key_path`, `key_id`, `issuer_id`,
`private_group_id`, and `pete_tester_id`. Verify the group/tester identity live
before pinning their opaque IDs; never match an approximate display name.
Both reference and key must be owner-only regular files without symlink paths.

`dry-run` distinguishes `auth.ready` from `auth.release_ready`. Authentication
alone cannot authorize a new upload when Apple processing, an unresolved upload
or a local pending delivery remains. Live read-only validation does not prove
that Xcode API export/upload or group assignment works; the authorized nightly
release is the first opportunity to prove those mutations end to end.

All build and upload numbers, including inactive reservations and failed uploads,
participate in monotonic numbering. Marketing versions include upload history.
`AWAITING_UPLOAD` is not automatically abandoned. A reviewed legacy exception
must pin the exact upload ID, version, number and creation date, plus retained
private evidence and its SHA-256. Every preflight verifies a null uploaded date
and an empty complete upload-file collection; any change fails closed. Local
cancelled runs require an exact state hash and the same retained cancellation
evidence. Existing records remain untouched. New or unmatched pending deliveries
always block release; never delete Apple records or bypass a pending state.

The optional private reference fields `inactive_uploads` and
`reconciled_local_runs` hold these reviewed pins. Each upload rule has `version`,
`build`, `created_at`, `evidence_path`, and `evidence_sha256`; each local run rule
has `state_sha256` and the two evidence fields. Evidence schema 1 pins `app_id`,
`basis: reviewed_inactive_legacy_reservations`, `inactive_uploads` (IDs mapped to
exact version/build/creation facts), `cancelled_local_runs` (run names mapped to
state hashes), and optional `delivered_local_runs`. A delivered-run entry pins
the exact state hash, app, version, build, local terminal stage, Apple build ID,
and internal status; only `api_testing` and `api_action_required` qualify. This
allows a known completed delivery to stop blocking newer source without calling
the build Testing or erasing a compliance action. An operator must establish
the cancellation or completed-delivery facts before creating a rule; an empty
file list, elapsed time, or a newer build alone establishes neither.

## Release execution contract

1. Set a session completion goal and `nextAction=reflect`. Read the task and
   complete current thread, latest comments, all repository agent guides and
   the current release-tool implementation before acting.
2. Inspect both working trees, staged changes, branch and upstream. Default
   to `main`; reconcile compatible divergence with a normal merge while preserving
   local commits and edits. Use an isolated checkout for packaging when needed;
   stop only for unresolved incompatible changes or moving selected inputs. Preserve unrelated and concurrent files. Never stash, reset,
   rebase, force-push or bypass hooks.
3. Flight Deck comes first. Review all compatible nonignored software and
   reusable documentation, run focused tests and required public-source,
   unit, release-note, build and distribution checks. Follow its release-note
   numbering rules for source changes. Build in an isolated snapshot with
   pinned build number/ID/time so generated metadata cannot dirty shared
   source. Verify the exact tested staged tree remains unchanged, then commit
   a Conventional Commit checkpoint. A clean tree retains its existing commit.
   Push the configured authoritative upstream only as a normal fast-forward
   when safely permitted; resolve compatible divergence before building. Retain local history and instructions;
   portable documentation edits and noisy performance thresholds alone must not
   suppress a correctly validated signed release. Report benchmark observations
   separately; actual functional regressions remain release blockers.
4. Validate NBrowser analysis/tests sequentially and release tooling tests. Review
   and commit all compatible tested nonignored source/docs on `main`, checking
   for concurrent edits before committing. Ignore operational evidence and
   generated bundles. Never stage everything without inspecting the candidates.
5. After both validated source checkpoints are committed and stable, run
   `"$RELEASE_VENV/bin/python" tools/ios/nightly_testflight.py claim`. The helper
   pins the exact clean NBrowser and Flight Deck commits. Save the returned
   Perth day and source pair. An active claim fails closed globally. A finished
   same-day attempt blocks the same source pair, but a later attempt may claim
   genuinely newer committed source. Legacy same-day claims without pinned
   source use the supported evidence-backed retry route. A crash never expires a claim;
   uncertain delivery retains it.
6. Check authentication and release gates before expensive packaging. Run
   `nightly_testflight.py dry-run` with the private virtual environment. On
   failure report the exact prerequisite and both source commits, finish as
   `blocked_auth` only for missing/failed auth, otherwise `failed`, and stop.
   Do not ask for a provisioned key again or manufacture readiness.
7. Run `testflight_release.py api-preflight --run <unique-name>`, then
   `api-reserve` with the same run name. Reservation queries fresh history,
   applies Apple/local pending barriers, and reserves a number greater than
   all build/upload/local numbers under the global release lock. API reserve,
   build, upload and assignment-capable readback require this session's active
   current Perth daily claim. All API actions reject `--dry-run`; `api-preflight`
   is read-only.
   Never reuse uncertain numbers or re-upload a pending delivery.
8. Create isolated snapshots of the exact committed Flight Deck and NBrowser trees
   under ignored private evidence. Use `git archive` or a private local clone;
   never build the shared working copy. Install frozen Flight Deck dependencies,
   set `FLIGHT_DECK_PG_APP_NPUB` to the verified Flight Deck app identity from
   the scoped Flight Deck context (local overrides do not set it automatically),
   pin `FLIGHTDECK_BUILD_NUMBER`, `FLIGHTDECK_BUILD_ID`, `SOURCE_DATE_EPOCH`,
   build and verify `dist`, then pass that snapshot through `FLIGHT_DECK_DIR`
   to the existing NBrowser release workflow. Record commit, version/build and
   asset hashes. The archive and IPA must embed the canonical NBrowser Git
   repository and exact source commit in both signed targets. Keep generated
   output in the snapshot, not shared tracked files.
9. Run `testflight_release.py api-build --run <unique-name>` to perform the
   isolated FD-first build and export; then `api-upload` once. Use its barriers
   and signing checks for Runner and Packet Tunnel. Validate the exact exported artifact, archive, profiles, entitlements,
   identifiers, team and matching monotonic build. No upload until every gate
   passes. One upload attempt only; uncertainty requires readback, never retry.
10. App `0000000000`, bundle `com.wingmanbefree.wingmanApp`, existing Private Internal
    internal group, sole Owner and manual distribution remain mandatory. No
    external group, public link, tester invitation or production submission.
    Run `api-readback --run <unique-name> --poll-seconds 600` for bounded processing
    and exact group assignment/readback. Recovery without an active claim uses
    `api-readback --read-only`; it checks status and writes local evidence but
    cannot assign groups. Resolve actual standard encryption beyond
    OS crypto accurately using the documented inventory and authorized territories.
    The API never patches encryption flags or reuses an older declaration. If
    Apple requires compliance action after upload, report the exact uploaded build
    and questionnaire as a human continuation; previous-build compliance alone
    must not suppress a fresh upload. Never invent answers; do not invent exemptions
    or change territories. Assign only the exact processed build to the existing
    group and independently read it back. Report `Testing`, `Processing`, action
    required or failure; never call a receipt or IPA a published release.
11. Write one readable result on the originating task and same thread, including
    commits, FD build/assets, Apple build/receipt if any and exact blocker/status.
    Finish with the exact claimed `--day` and
    `--result blocked_auth|failed|processing|action_required|testing`.
    Set `nextAction=stop` only after reporting and handoff. If reporting or upload
    outcome is uncertain, retain the active claim for reconciliation.

Operational prompts, logs, screenshots and receipts belong only in verified
ignored, untracked `tmp/docs/handoffs/`. Check every destination before writing;
reject symlink paths. Preserve existing evidence and verify hashes when moving
it. Do not raise the deployment target for a future nonblocking warning.

## Read-only validation

```sh
"$RELEASE_VENV/bin/python" tools/ios/nightly_testflight.py dry-run
"$RELEASE_VENV/bin/python" -m unittest discover -s tools/tests -p 'test*testflight*.py'
git diff --check
```

The dry run reads branches, commits, status and upstream configuration, checks
required tool availability and the private storage boundary, and reports actual
auth readiness. It never claims a real day, changes a release state or uploads.
Guard tests exercise source-aware same-day claims, duplicate source claims,
overlapping days, owner-only completion
and failure-closed outcomes using temporary fixtures. Read back the live enabled
schedule, timezone, next run, identity, paths and full reporting contract after
activation; do not manually fire a duplicate release merely to test scheduling.

## Official Apple references

- [API authentication](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)
- [Build upload schema](https://developer.apple.com/documentation/appstoreconnectapi/buildupload)
- [Build upload states](https://developer.apple.com/documentation/appstoreconnectapi/builduploadstate)
- [Build upload files](https://developer.apple.com/documentation/appstoreconnectapi/builduploadfile)
- [List groups by exact build](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-betagroups)
- [Upload and processing](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)

Use the installed `xcodebuild -help` for the supported authentication and export
options. Internal exports require `testFlightInternalTestingOnly=true` and
`manageAppVersionAndBuildNumber=false`; uploading changes only `destination` to
`upload`. API `Testing` verifies Apple status and assignment, while device
visibility remains unverified until the tester confirms the exact build.

## Recover a reservation created during local export

A successful Xcode export can create an `AWAITING_UPLOAD` reservation before
sending any binary. Timing and an empty upload-file list alone do not prove
ownership. Preserve the native `.xcdistributionlogs` bundle named in that run's
`export.log` under ignored operational storage, without changing its bytes or
file timestamps; make the retained log files owner-only.

When the same active claim owns the run, use:

```sh
"$RELEASE_VENV/bin/python" tools/ios/testflight_release.py api-recover-export \
  --run "$RUN" --export-logs "$RETAINED_NATIVE_EXPORT_LOGS"
```

For an explicitly authorized immediate release whose worker is archived and
whose current Perth-day claim finished `failed`, transfer that exact claim with:

```sh
"$RELEASE_VENV/bin/python" tools/ios/testflight_release.py api-recover-export \
  --run "$RUN" --previous-owner "$STOPPED_SESSION_ID" \
  --export-logs "$RETAINED_NATIVE_EXPORT_LOGS"
```

This command uploads nothing. It verifies the successful private export policy,
exact native creation request and `201 Created` reservation ID, absence of
subsequent native activity, original complete preflight, signed retained IPA
with `TFInternalTestingOnly=true`, archive/IPA hashes, fresh complete Apple
history and empty reservation files. The same-owner route verifies the current
active claim without replacing it. Any unrelated pending upload, processing
build, existing exact build, higher reservation, prior upload intent, changed
proof or uncertain evidence blocks recovery. It reads the prior worker's archive
through the supported session CLI and transfers only its exact failed current-day
claim, retaining the original claim as history. Active claims are never stolen.
The recovered claim permits only this retained run's upload and readback.

Then `api-upload --run "$RUN"` rechecks the pinned proof and live Apple facts,
records durable upload intent, and sends the exact retained IPA once with
Apple's native `altool --upload-package` and the existing private API reference.
It does not re-export or rebuild. The reservation remains in Apple history and
participates in every other run's numbering and pending gates. This is neither
cancellation nor a legacy inactive reservation exception. Upload failure remains
uncertain and cannot be retried. Use `api-readback` for processing and independent
private group assignment verification, then finish the recovered daily claim.
An interrupted recovery must be inspected before any further mutation.

Apple documents [altool as a supported upload route](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds).
The installed tool's `--help` specifies package identity and private-key-path
options. Processing and exact private audience readback remain mandatory.

## Continue readback after a completed questionnaire

If the same current-day worker has already finished its claim as
`action_required` or `processing`, and Apple subsequently accepts compliance,
resume only the already uploaded run:

```sh
"$RELEASE_VENV/bin/python" tools/ios/nightly_testflight.py resume-readback --run "$RUN"
"$RELEASE_VENV/bin/python" tools/ios/testflight_release.py api-readback --run "$RUN" --poll-seconds 600
```

This appends a claim while preserving the previous result. It requires the exact
delivered source pair, completed upload command, a finished prior claim and no
active release. A later worker/day supplies `--previous-owner <finished-owner>`. Its authority permits only this run's readback and private
group assignment; reservation, build, upload and other runs remain forbidden.
Finish the continued claim with the observed outcome. A different worker/day
uses that explicit readback-only handoff; never alter ledger history to impersonate
an owner or retry an upload. Read-only readback remains available without a claim.
