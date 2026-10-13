# WApp Signer Trust Contract

Status: implemented for `WP-10-01`
Date: 2026-07-04

## Goal

Define the minimum Tower-backed identity contract Wingman App needs before a WApp can receive native signing access through the embedded browser.

The local app can keep a temporary developer allowlist for prototypes, but production signer grants must not trust origin strings alone.

## Trust Inputs

A trusted WApp identity should be resolved from Tower before the app grants `window.nostr` access:

- `workspace_id`: workspace that owns the WApp record.
- `personal_wapp_id`: Tower PG `flightdeck_pg_personal_wapps.id`.
- `app_id`: Autopilot app registry ID where available.
- `wapp_id`: external/template WApp ID where available.
- `launch_url`: URL shown to the user and loaded by the browser.
- `allowed_origins`: normalized origins allowed to receive the signer bridge.
- `source_wingman_url`: Wingman/Autopilot host that registered or serves the app.
- `status`: active/disabled/revoked state.
- `row_version`: Tower row version for cache invalidation.

## Current Tower Evidence

Tower PG already serializes personal WApp rows with these useful fields:

- `id`
- `workspace_id`
- `scope_id`
- `channel_id`
- `title`
- `description`
- `launch_url`
- `icon_url`
- `app_id`
- `wapp_id`
- `source_wingman_url`
- `status`
- `metadata`
- `row_version`

The likely read path is:

```text
GET /api/v4/flightdeck-pg/workspaces/:workspaceId/personal-wapps
```

Tower now accepts an explicit signer trust profile as `metadata.signer` on personal WApp records and serializes the normalized result as `signer_profile`.

## `metadata.signer` Shape

```json
{
  "signer": {
    "enabled": true,
    "allowed_origins": ["https://example-wapp.service-3.example.com"],
    "allowed_nip98_target_origins": [
      "https://example-wapp.service-3.example.com",
      "https://tower.example.com"
    ],
    "allowed_event_kinds": [27235],
    "capabilities": ["nip98"],
    "trust_version": 1
  }
}
```

Rules:

- `launch_url` origin must be present in `allowed_origins`.
- `allowed_origins` must be exact normalized origins, not wildcard domains.
- `allowed_nip98_target_origins` must be exact normalized origins.
- `kind 27235` is the only default event kind for production v1.
- `signEvent`, NIP-04, and NIP-44 must remain disabled unless a later permission policy explicitly enables them.
- A disabled, missing, or malformed signer profile fails closed.

## Local App Policy

The local signer policy must check all of these before prompting:

1. The current WebView page origin is trusted.
2. The requested NIP-98 target URL is valid HTTP or HTTPS.
3. The target origin is trusted for the loaded WApp or Flight Deck profile.
4. The requested HTTP method is supported.
5. The request body is bounded and can be hashed exactly.
6. The native prompt shows the page origin, target origin, method, URL, event kind, and device npub.

For the current prototype, `AppConfig.trustedOrigins` supplies the trusted origin set. That is acceptable only as a developer allowlist until Tower exposes the full WApp trust profile.

## Acceptance For `WP-10-01`

- Origin alone is documented as insufficient for production signer trust.
- Tower-backed WApp rows are identified as the source of launch and identity metadata.
- A concrete signer metadata profile is defined.
- Unknown, disabled, or mismatched origins fail closed.
- `WP-10-02` can implement local policy without guessing the future Tower contract.

## Tower Implementation

`WP-10-01` remains aliased to `TOWER-GAP-08` on the board until review is accepted. The code path is implemented in Tower:

- `normalizeFlightDeckPgPersonalWappSignerMetadata` validates and normalizes `metadata.signer`.
- Personal WApp create/update routes reject malformed enabled signer profiles.
- `serializeFlightDeckPgPersonalWapp` returns `signer_profile` for app clients.
