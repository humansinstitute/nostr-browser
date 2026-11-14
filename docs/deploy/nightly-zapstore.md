# Nostr Browser nightly on Zapstore

Read [shared nightly policy](nightly-release-policy.md) before either lane.
The canonical release source is Nostr Browser; the old WMAPP checkout is not required.

Nostr Browser nightly uses `com.wingmanbefree.wingman_app.nightly`, installs alongside
stable WMAPP and has its own private persistent Android signing keystore.
Stable package, publisher and `zapstore.yaml` remain unchanged. Nightly's public
catalog and repository ownership proof live at
https://github.com/OtherStuffAI/wingman-nightly; the catalog's root `zapstore.yaml`
pins the intended publisher. `zapstore-nightly.yaml` is the reusable source configuration.

The public catalog accepts only the `main` release metadata channel. The nightly
lane uses `c=main` while retaining its separate nightly Android package, signing
certificate and version names. This does not publish or replace the stable app.
Public GitHub APK availability alone does not establish Zapstore availability.

## Current publication path

The nightly package is owned by Pete's Nostr identity, as pinned in `zapstore-nightly.yaml`; its Android package and certificate are unchanged. Future Zapstore releases use the enrolled native AP Vault through its `scripts/publish.ts` helper and `docs/PUBLISHING.md`. Verify status and the final public APK, prepare the application/asset/release triple, then sign, independently verify, publish and read back the exact reviewed events. The active owner certificate proof already exists: do not generate another C1 ownership proof on every release. Only a separately reviewed renewal or ownership change should replace it.

The legacy Rick broker tools intentionally hold signing/publication after the transfer, including retained old proof events. Their Android build-only and readback actions remain available. The Zapstore scheduler is disabled; this documentation does not enable it or claim AP Vault nightly automation is integrated. Keep that job disabled until a separately validated AP Vault release integration is ready.

## Legacy broker implementation (publishing held)

The following describes the retained legacy tooling, not the current publication procedure. Never bypass its owner guard or change its publisher environment to imitate owner signing.

`tools/nightly_zapstore.py` retains the build and readback implementation. Provision
an owner-only PKCS12 Android keystore and owner-only password reference outside
Git at `~/.config/wmapp/wingman-nightly-release.p12` and
`~/.config/wmapp/wingman-nightly-release.password`, alias `wingman-nightly`.
These are Android credentials, separate from the Nostr identity. Never derive,
export or provide a Nostr private key. Back up Android credentials privately;
future APK updates require the same certificate.

1. The legacy lane was designed for independent scheduler sessions at 22:00 `Australia/Perth`; Zapstore scheduling is currently disabled.
   This lane performs Android only; Apple claims, failure or compliance never
   gate it. Use the short process-owned lock only for source preparation and
   immutable snapshots, then release it before packaging/delivery.
2. Set the verified broker publisher public identity from
   scoped context. Run `python3 tools/nightly_zapstore.py dry-run` before `build`.
   It queries complete signed relay history and verifies the original private
   Android certificate. Build reserves above all local/remote numbers and takes
   an exact committed NBrowser snapshot. It runs Flutter functional tests,
   analysis, build and checks that the APK contains no retired embedded assets. Source preparation
   repairs routine divergence and portable docs while preserving local work.
   Scheduled runs must not use `--committed-source` to hide compatible changes.
   Known build failures retain their number/logs without preventing later nights.
3. Build also compiles the pinned native Drive filesystem helper required by
   Flutter integration tests. On a known pre-delivery build prerequisite failure,
   `resume-build` validates the retained source archive journals and resumes the
   same reservation; signing or delivery artifacts prohibit that recovery.
   Run `prepare`. It verifies the APK signature, exact package/version/name,
   certificate, ARM64 contents, FIPS library/service and canonical extracted icon.
   zsp v0.4.17 emits JSONL with `SIGN_WITH` set to the configured publisher's **public** npub,
   `--offline --no-compress --channel main --commit <commit>`.
   No publisher signing or upload occurs inside zsp. The adapter signs kind 3063
   first, rewrites kind 30063's asset reference to the actual broker-signed ID,
   then signs kinds 30063 and 32267. It rejects stable packages, changed identity,
   templates/signatures and unexpected asset hosts.
4. zsp's `identity --offline` signs NIP-C1's ownership message with the Android
   keystore and outputs unsigned kind 30509 (`d`, `signature`, `expiry`). The
   broker independently signs that event. Its timestamp must exactly match the
   Android proof timestamp; the adapter verifies the RSA proof against the DER
   certificate and rejects a mismatch. At most three fresh proofs are generated
   before publication; broker denials never trigger fallback or policy widening.
5. Publish committed source archives and public build-proof JSON as GitHub
   release assets using the authorized public Nightly catalog. Proof includes
   the exact NBrowser commit and source archive hash, APK hash/version/package/certificate and publisher identity.
   Never include operational logs, local paths, credentials or device identifiers.
6. Run `prepare-public` after `public-assets`. It uploads the icon to the same
   authorized GitHub release, downloads/verifies that icon and the public APK,
   and broker-signs events with exact GitHub asset URLs. Then run `publish-public`
   once. It records `delivery_pending` before relay mutation, publishes the app
   event first so repository proof can whitelist the publisher, then the asset,
   release and certificate-proof events to `wss://relay.zapstore.dev`, and reads every event back.
   Current relay onboarding needs the release before it can check the certificate
   proof against the APK, matching the current official zsp publisher order.
   GitHub release hosting is an independently authorized asset path supported by
   NIP-82; it performs no CDN authentication or policy changes. The optional
   `publish` action uses broker-authorized Blossom upload only when separately
   granted. A denied CDN host never falls back to generic kind-24242 signing.
   For a narrowly authorized CDN grant, scope `blossom.authorize` to upload only,
   `https://cdn.zapstore.dev`, the configured publisher's identity, this Nightly package/purpose and
   exact APK/icon hashes/sizes; never widen unrelated session capabilities.
   Only all gates passing produce `published`. Relay success first records `uploaded`; anonymous APK/hash/certificate/assets and public listing checks must then pass. A receipt alone is insufficient.
   Independently verify the public listing and linked release/asset records.
   Release download metadata uses the exact APK hash with
   `https://cdn.zapstore.dev/<hash>?redirect=true`; verify a GET redirects to the
   signed GitHub asset URL. A bare CDN hash or a HEAD request may return 404.
   An intentional metadata correction requires confirmed prior delivery and
   `amend-listing`; retain `listing_update_pending` on uncertainty.
7. On uncertainty use `readback --day <original-day>` and inspect the exact
   retained signed IDs and public APK. Never retry upload or publication, repair
   ledger state, reuse a version code, or infer success from upload receipts.
   Reporting is independent for TestFlight and Android. Keep pending state until
   exact delivery and reporting are reconciled by an authorized operator.

   A legacy proof-first attempt that explicitly received the relay's exact
   “no APK to check this certificate against” rejection has a narrow recovery:
   `bun tools/zapstore_broker.ts continue-rejected-proof <retained-run> <certificate-hash>`.
   This requires the reservation owner, unchanged pending GitHub-backed artifact,
   original signed IDs, exact rejection log and fresh signed-event readback.
   It skips the previously accepted app, sends the previously unattempted asset
   and release, then the rejected proof. An exclusive intent journal prevents
   another continuation. Any uncertain or different error remains readback-only.
   Finish with the normal nightly `readback` command; never edit the ledger stage.

   After that legacy continuation, an explicit catalog rejection of `nightly`
   metadata can use the reviewed `migrate-catalog-main` broker action with the same
   run and certificate arguments. It requires an exact retained channel-rejection
   log (`catalog-channel-rejection.log`), unchanged signed artifact identities,
   fresh readback and the original owner. It preserves the original signed events,
   signs only corrected release metadata and sends it before the retained proof.
   An exclusive migration intent prevents repeats; `readback` selects the corrected
   signed release and still requires all public availability gates.

Run-specific evidence and state are ignored under `tmp/docs/handoffs/`.
Use `status` for read-only inspection. A duplicate day, active prior reservation,
wrong owner, invalid history or Android version limit fails closed. No extra
scheduler trigger or runtime restart is required. Future proof expiry requires
fresh Android ownership proof and broker signing.

## Validation

```sh
bun test ./tools/zapstore_broker.test.ts
python3 -m unittest discover -s tools/tests -p 'test_nightly_zapstore.py'
python3 -m unittest discover -s tools/tests -p 'test*testflight*.py'
```

Official formats: [publisher documentation](https://zapstore.dev/docs/publish),
[zsp source](https://github.com/zapstore/zsp),
[trust model](https://zapstore.dev/docs/trust-model). Repository proof must be
publicly readable before the app event reaches the relay. The Android certificate
and the configured publisher's Nostr publisher are distinct cryptographic identities.

Configure `WMAPP_ZAPSTORE_PUBLISHER_NPUB` and the matching publisher in a private manifest before publication. The public manifest intentionally has no publisher identity.

Set `WMAPP_ZAPSTORE_PUBLISHER_HEX` to the public hex encoding of the same verified publisher used in `WMAPP_ZAPSTORE_PUBLISHER_NPUB`. The broker refuses to run without it; event and broker identity checks retain exact publisher pinning.

Browser release APK validation rejects `assets/flightdeck/` and
`assets/ambulando/` payloads. No frontend identity, checkout or archive is needed.

## Publisher ownership transition hold

The legacy broker publisher checks all signed certificate claims on the official relay before each signature and each relay send, including retained-proof continuations, channel migrations and listing amendments. Nightly preparation checks before opening its Android signing inputs. If another publisher has claimed the certificate, the query is incomplete, or claim history is ambiguous, Zapstore publishing is held; local builds and readback remain available. This prevents an old scheduled release from publishing a newer old-owner claim after an ownership transfer.

This is a conservative Nostr-signed-claim hold, not independent app-key verification or a global ownership oracle. A foreign signed claim can require manual review even if its app-key proof is invalid. Once ownership moves, use the authorized owner's AP Vault release path; changing the old broker's publisher environment does not grant it owner signing authority. Do not bypass the hold or replay retained old-owner events.

## Android adaptive launcher icon

The manifest uses `@mipmap/ic_launcher` for both `icon` and `roundIcon`. Android 8+ selects the adaptive resource in `mipmap-anydpi-v26`, with independent full-bleed background and safe foreground layers. Earlier Android versions retain the legacy fallback. The dark background fills the mask; the approved Android artwork bytes are retained and inset 18 dp on the 108 dp layer. Both stable and nightly use these launcher resources.

When updating artwork, inspect both a circle and a squircle mask over the central 72 dp of the 108 dp layers, and keep essential foreground details within the central 66 dp safe circle. Check the merged release manifest and packaged resources, then run the app’s documented release build and lint. Launcher caches may need a normal refresh after an in-place update; never uninstall or clear user data to refresh an icon.
