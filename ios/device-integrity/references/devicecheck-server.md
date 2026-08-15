# DeviceCheck — server API (depth)

The app produces a token with `DCDevice.current.generateToken()`; **only your server** talks to
Apple. Endpoints require an ES256 JWT signed with a **DeviceCheck key** (`.p8` + Key ID + Team ID)
created in the Apple Developer portal ("Keys" → enable DeviceCheck).

## Hosts

| Environment | Base URL |
|---|---|
| Production (App Store / TestFlight) | `https://api.devicecheck.apple.com` |
| Development / sandbox | `https://api.development.devicecheck.apple.com` |

Use the host matching the **token's** environment. A production token queried against the
development host (or vice versa) returns `Bit State Not Found` / a mismatch error.

## Endpoints (POST, JSON body)

- `/v1/query_two_bits` — read the two bits + `last_update_time` for the device.
- `/v1/update_two_bits` — set `bit0` / `bit1`.
- `/v1/validate_device_token` — confirm a token is genuine (no bit read/write).

### Authorization JWT (ES256)

```
Header:  { "alg": "ES256", "kid": "<DeviceCheck Key ID>" }
Payload: { "iss": "<Team ID>", "iat": <unix seconds> }
```

Sign with the `.p8` private key; send as `Authorization: Bearer <jwt>`. Keep `iat` fresh (tokens are
short-lived); mint per request or cache briefly.

### query_two_bits

```json
POST /v1/query_two_bits
{
  "device_token": "<base64 token from generateToken()>",
  "transaction_id": "<uuid>",
  "timestamp": 1699999999000        // milliseconds
}
```

Response (`200`):

```json
{
  "bit0": true,
  "bit1": false,
  "last_update_time": "2026-07"      // yyyy-MM, or absent if never set
}
```

### update_two_bits

```json
POST /v1/update_two_bits
{
  "device_token": "<base64 token>",
  "transaction_id": "<uuid>",
  "timestamp": 1699999999000,
  "bit0": true,
  "bit1": false
}
```

`200` with empty body on success.

### validate_device_token

Same envelope (`device_token`, `transaction_id`, `timestamp`); `200` = valid token.

## Status / error bodies

Apple returns plain-text bodies with HTTP status codes, e.g.:

- `200 OK` — success.
- `Bit State Not Found` — no bits set yet (treat as "unknown device", not an error) or wrong host/env.
- `Missing or incorrectly formatted device token payload` — bad `device_token`.
- `Invalid or missing header` — JWT problem (expired `iat`, wrong `kid`, wrong signing key).
- `401 Unauthorized` — JWT rejected.
- `429 Too Many Requests` — back off.

Handle `Bit State Not Found` as "first time we've seen this device" — initialize your own record and,
if needed, call `update_two_bits`.

## Timestamp

`timestamp` is **milliseconds** since epoch and must be close to Apple's server time — large skew is
rejected. Sync your server clock (NTP).

## Design notes

- Two bits are **per developer, per device**, and persist across reinstall/factory reset — ideal for
  "already claimed the signup bonus" or a soft device ban. They are not a user identifier.
- Tokens are ephemeral and privacy-preserving: you can't derive a stable device ID from them, only
  query/update the two bits through Apple.
- Document the two bits' purpose in your privacy disclosures; do not repurpose as covert tracking.
- Combine with App Attest: attestation trusts the *request*, the two bits *remember* the device.
