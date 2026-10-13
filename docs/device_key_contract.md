# Device Key And NIP-98 Grant Contract

Status: phase 1 draft
Date: 2026-06-30
Related work package: WP-01-03

## Purpose

Wingman App should use a per-device Nostr key for day-to-day sync and WApp signing. The user's main Nostr identity approves and revokes devices, but the desktop/mobile app should not need the user's master key after setup.

## Current Tower Baseline

Tower currently has workspace user key routes:

- `POST /api/v4/user/workspace-keys`
- `GET /api/v4/user/workspace-keys`
- `POST /api/v4/user/workspace-keys/rotate`
- `GET /api/v4/user/workspace-key-mappings`

These routes prove the core delegated-key pattern:

- registration must be signed by the real user npub;
- a registered key can later sign NIP-98 requests;
- Tower resolves the workspace key back to the owning user;
- inactive keys fail closed through the delegation check.

For Wingman App, this should become an explicit device key model with labels, audit trail, revocation, and per-device policy.

## Terms

- Human key: Owner's or another user's main Nostr identity.
- Device key: a Nostr key generated or imported by one Wingman App install.
- Workspace service npub: the Tower/workspace service identity used in existing workspace-key rows.
- Device grant: Tower-side authorization that maps a device npub to a human actor and visible workspace permissions.
- Local key store: platform secure storage that holds the device private key.

## Device Record

Required fields:

- `id`
- `user_npub`
- `device_npub`
- `workspace_id`
- `workspace_service_npub`
- `label`
- `platform`: `macos`, `linux`, `android`, `ios`, or `unknown`
- `app_version`
- `created_at`
- `last_seen_at`
- `revoked_at`
- `revoked_by_npub`
- `status`: `pending`, `active`, `revoked`, or `stale`
- `capabilities`
- `policy`

Suggested `capabilities`:

```json
{
  "tower_nip98": true,
  "drive_read": true,
  "drive_write": false,
  "wapp_nip98": true,
  "wapp_sign_event": "prompt"
}
```

Suggested `policy`:

```json
{
  "allowed_origins": ["https://*.runwingman.com"],
  "default_event_kinds": [27235],
  "requires_prompt_for": ["signEvent", "nip04.decrypt", "nip44.decrypt"]
}
```

## Registration Flow

1. Wingman App generates a Nostr device key locally.
2. The app presents the device npub, label, platform, and requested capabilities.
3. The human key signs a NIP-98 request to Tower.
4. Tower verifies the human is a workspace member.
5. Tower creates or activates the device record.
6. Tower records an audit event.
7. The app stores the device private key in platform secure storage.

Required route:

```http
POST /api/v4/user/devices
```

Request:

```json
{
  "workspace_id": "workspace-id",
  "workspace_service_npub": "tower-service-npub",
  "device_npub": "device-npub",
  "label": "Example laptop",
  "platform": "macos",
  "app_version": "0.1.0",
  "capabilities": {
    "tower_nip98": true,
    "drive_read": true,
    "drive_write": false,
    "wapp_nip98": true
  }
}
```

Response:

```json
{
  "device": {
    "id": "device-id",
    "device_npub": "device-npub",
    "status": "active"
  }
}
```

Compatibility:

The existing `/api/v4/user/workspace-keys` route can be used for an early prototype if the device npub is treated as `workspace_user_key_npub`, but the first crate should name its abstraction `DeviceGrant` rather than `WorkspaceKey`.

## Request Authentication

Every Tower HTTP request from the app uses NIP-98:

- event kind `27235`;
- `u` tag exactly matching the request URL;
- `method` tag matching the HTTP method;
- `payload` tag for non-empty request bodies;
- short clock skew window;
- signer is the device npub.

Tower must resolve the device npub before applying workspace permissions. The effective actor is the human user; the signing actor remains the device for audit.

Suggested identity response fields:

```json
{
  "identity": {
    "actor_npub": "human-npub",
    "signer_npub": "device-npub",
    "auth_type": "device_key",
    "device_id": "device-id"
  }
}
```

## Revocation Flow

Required route:

```http
DELETE /api/v4/user/devices/:deviceId
```

or:

```http
POST /api/v4/user/devices/:deviceId/revoke
```

Required behavior:

- only the human user or an authorized workspace admin can revoke;
- Tower sets `revoked_at` and `revoked_by_npub`;
- all subsequent device-signed NIP-98 requests fail closed;
- cached key-resolution entries are invalidated immediately;
- revocation is visible in audit/event history.

Prototype compatibility:

The existing workspace-key rotation flow deactivates old keys, but it does not provide labelled device records or direct single-device revoke. Do not present it as the final app UX.

## Audit Requirements

Audit records should include:

- `device.register`
- `device.rotate`
- `device.revoke`
- `device.last_seen`
- `device.policy.update`

Each audit event should store:

- human actor npub;
- device npub;
- workspace id;
- request origin when relevant;
- app version;
- capabilities or policy diff.

## WApp Signer Policy

The embedded browser must not expose raw private keys. WApps receive a `window.nostr` bridge with policy-mediated methods.

Default v1 policy:

- allow NIP-98 auth signing for trusted Tower/WApp origins;
- prompt for arbitrary `signEvent`;
- deny or prompt for decrypt methods;
- never allow an untrusted origin to call the native signer.

Trusted origin identity should come from Tower/WApp assignment records, not only hard-coded hostnames.

## First Crate Boundary

The first native crate should expose:

- `generate_device_key`
- `import_device_key`
- `device_npub`
- `sign_nip98`
- `register_device` as a Tower-client method, initially feature-gated if Tower only has workspace-key routes
- `revoke_device` as a Tower-client method, initially returning `UnsupportedByTowerContract`

The crate should keep key storage behind an interface so Flutter and platform adapters can use Keychain, libsecret/KWallet, Android Keystore, and iOS Keychain later.

## Implemented In WP-02-02

`crates/wmapp-core` now implements:

- `DeviceKey::generate`;
- `DeviceKey::import` for hex and `nsec` secrets;
- `DeviceKey::npub` and public-key hex derivation;
- `DevelopmentKeyStore` as a non-secure development storage backend;
- `Nip98Signer` for kind `27235` events;
- `wmapp-core device generate`;
- `wmapp-core device import`;
- `wmapp-core sign-nip98`.

Platform secure storage remains a later adapter task.
