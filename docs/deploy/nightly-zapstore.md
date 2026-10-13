# Wingman Nightly on Zapstore

Wingman Nightly uses `com.wingmanbefree.wingman_app.nightly`, installs alongside
stable WMAPP and has its own private persistent Android signing keystore.
Stable package, publisher and `zapstore.yaml` remain unchanged. Nightly's public
catalog and repository ownership proof live at
https://github.com/OtherStuffAI/wingman-nightly; the catalog's root `zapstore.yaml`
pins the configured publisher's publisher. `zapstore-nightly.yaml` is the reusable source configuration.

## Release procedure

Use `tools/nightly_zapstore.py` under an authorized publisher broker session. Provision
an owner-only PKCS12 Android keystore and owner-only password reference outside
Git at `~/.config/wmapp/wingman-nightly-release.p12` and
`~/.config/wmapp/wingman-nightly-release.password`, alias `wingman-nightly`.
These are Android credentials, separate from the Nostr identity. Never derive,
export or provide a Nostr private key. Back up Android credentials privately;
future APK updates require the same certificate.

1. One existing 22:00 `Australia/Perth` scheduler session prepares validated,
   compatible source checkpoints on main: Flight Deck first, WMAPP second.
   Preserve incompatible/concurrent edits and report them. TestFlight executes
   its existing private release contract, records its result and finishes its
   claim before Android. An Apple failure does not silently skip Android.
2. Set the verified `FLIGHT_DECK_PG_APP_NPUB` from scoped Flight Deck context.
   Run `python3 tools/nightly_zapstore.py build`. It checks no TestFlight claim
   is active, queries relay history, reserves above all local/remote numbers,
   derives the marketing version from the exact committed pubspec, and builds
   Flight Deck then Android from isolated committed archives. It validates
   Flight Deck public source/tests/dist, Flutter analysis/tests and ARM64 APK.
   Generated files never modify shared source. Local reservations never expire.
   For independently authorized first-publication setup only,
   `--committed-source` may preserve incompatible active edits and records their
   exclusion while validating the exact committed snapshots. Scheduled runs
   require clean, validated source and must not use this exception.
3. Build also compiles the pinned native Drive filesystem helper required by
   Flutter integration tests. On a known pre-delivery build prerequisite failure,
   `resume-build` validates the retained source archive journals and resumes the
   same reservation; signing or delivery artifacts prohibit that recovery.
   Run `prepare`. It verifies the APK signature, exact package/version/name,
   certificate, ARM64 contents, FIPS library/service and canonical extracted icon.
   zsp v0.4.17 emits JSONL with `SIGN_WITH` set to the configured publisher's **public** npub,
   `--offline --no-compress --channel nightly --commit <commit>`.
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
   exact WMAPP/Flight Deck commits, source archive hashes, FD build identity and
   asset hashes, APK hash/version/package/certificate and publisher identity.
   Never include operational logs, local paths, credentials or device identifiers.
6. Run `prepare-public` after `public-assets`. It uploads the icon to the same
   authorized GitHub release, downloads/verifies that icon and the public APK,
   and broker-signs events with exact GitHub asset URLs. Then run `publish-public`
   once. It records `delivery_pending` before relay mutation, publishes the app
   event first so repository proof can whitelist the publisher, then the proof,
   asset and release events to `wss://relay.zapstore.dev`, and reads every event back.
   GitHub release hosting is an independently authorized asset path supported by
   NIP-82; it performs no CDN authentication or policy changes. The optional
   `publish` action uses broker-authorized Blossom upload only when separately
   granted. A denied CDN host never falls back to generic kind-24242 signing.
   For a narrowly authorized CDN grant, scope `blossom.authorize` to upload only,
   `https://cdn.zapstore.dev`, the configured publisher's identity, this Nightly package/purpose and
   exact APK/icon hashes/sizes; never widen unrelated session capabilities.
   Only all gates passing produce `published`. A receipt alone is insufficient.
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
