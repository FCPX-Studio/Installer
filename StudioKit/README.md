# StudioKit

Shared code for the Studio plugin installers and the FxPlug extensions.

| Module | Used by | Role |
| --- | --- | --- |
| `StudioLicense` | installers + FxPlug | machine fingerprint, token format, Ed25519 verification, App Group storage |
| `StudioActivation` | installers | HTTPS client of the license server |
| `StudioInstallKit` | installers | `Product.json` manifest, file installation with rollback, PlugInKit registration |
| `StudioInstallerUI` | installers | SwiftUI installer screens |
| `studio-license-tool` | development | `keygen`, `fingerprint`, `sign`, `serve` (mock license server), `check` (reads the installed license like the FxPlug) |

In Debug builds, the installer accepts the launch argument `-LicenseAPIURL http://127.0.0.1:8787`
to talk to `studio-license-tool serve` instead of the production API.

## FxPlug side

The FxPlug extension links `StudioLicense` only, and declares the same App Group as the
installer (`$(TeamIdentifierPrefix)com.fcpxstudio`).

```swift
import StudioLicense

let status: LicenseStatus = {
    guard let verifier = try? LicenseVerifier(publicKeyBase64: "<public key>",
                                              productId: "com.votresociete.depthstudio",
                                              majorVersion: 1),
          let store = try? LicenseStore(appGroupIdentifier: "ABCDE12345.com.fcpxstudio")
    else { return .invalid(.malformed) }
    return verifier.status(in: store)
}()
// Check once when the plugin loads; per frame, only read `status.isLicensed` (watermark otherwise).
```

## License server contract

All requests are `POST` with a JSON body. Errors use any non-2xx status with
`{"error": {"code": "activation_limit_reached", "message": "Human readable message"}}`;
the installer shows `message` to the user.

### `POST /v1/licenses/activate`

```json
{ "licenseKey": "XXXX-XXXX-XXXX-XXXX", "productId": "com.votresociete.depthstudio",
  "machineFingerprint": "SHA256:…", "machineName": "Mac Studio", "appVersion": "1.0",
  "macOSVersion": "Version 15.3 (Build …)" }
```

Checks the key (unknown → `404 invalid_key`, revoked → `403 revoked`, past its expiration
date → `403 license_expired`), the product, and the number of activations
(→ `409 activation_limit_reached`). The activation is **definitive**: there is no confirmation step.
Activating again from a Mac that already holds an activation for this key (same
`machineFingerprint`) must reuse it instead of consuming a new slot (reinstalls, updates).

```json
{ "activationId": "act_…", "activationLimit": 2, "activationsUsed": 1,
  "license": { "payload": "<base64 of the token JSON bytes>",
               "signatureAlgorithm": "Ed25519",
               "signature": "<base64 Ed25519 signature of those exact bytes>" } }
```

Token JSON (dates ISO 8601 UTC without fractional seconds, e.g. `2026-11-13T12:00:00Z`):

```json
{ "formatVersion": 1, "licenseId": "lic_…", "activationId": "act_…",
  "productId": "com.votresociete.depthstudio", "edition": "trial",
  "machineFingerprint": "SHA256:…", "issuedAt": "2026-11-13T12:00:00Z",
  "expiresAt": "2026-12-13T12:00:00Z", "maxMajorVersion": 1 }
```

- `expiresAt`: the license key's expiration date (trials), `null` or omitted for a perpetual license.
  The FxPlug checks it offline and falls back to demo mode once it has passed.
- `maxMajorVersion`: highest major version covered, `null` or omitted for all versions.
- `licenseId`: opaque server ID of the license. Never put the license key in the token:
  the file is readable on disk.

### `POST /v1/licenses/deactivate`

`{ "activationId": "act_…", "machineFingerprint": "SHA256:…" }` frees the slot of this Mac.
Both values come from the signed token stored on the Mac, so the license key is not needed.
The server checks that the activation belongs to this fingerprint (otherwise
`404 activation_not_found`) and deletes it. Answers `{}`.

`LicenseSigner` is the reference implementation of the signature: sign the UTF-8 bytes
of the token JSON with Ed25519 and base64-encode payload and signature.

To test your server's tokens, save the `license` object of a response to `test.license` and run
`studio-license-tool check <publicKey> <productId> test.license`.
