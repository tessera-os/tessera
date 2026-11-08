# TesseraSignIn

Tessera's **first-party**, ready-made sign-in UI for every Tessera-owned app.
It is a pure Kira package built with KiraUI, backed by `TesseraAuth` and the
shared Tessera Accounts Cognito user pool. It is **not** the hosted OAuth screen
for third-party apps.

## What apps get

Apps embed **one** `TesseraSignInView`. They do not build their own forms,
navigation or Cognito integration. The library provides:

- Branded Tessera header, adaptive KiraUI controls and styles for light/dark
  appearance and desktop/mobile layout
- Email/password sign-in with masked `SecureField` and Return-to-submit
- Account creation with password confirmation and emailed verification codes
- Email verification and resend-code action
- Forgot-password request, reset-code form and new-password submission
- Authenticator, email and SMS code challenges, and forced password changes
- TOTP authenticator enrollment when Cognito requests `MFA_SETUP`, with a
  manual setup key and six-digit verification
- Generic error messages, rate-limit guidance, disabled invalid submits,
  retry handling and clearing of passwords/codes when changing screens
- A single `onSignedIn(TesseraTokens)` callback, called **only after** Cognito
  reports successful authentication

All colors, text styles, spacing, buttons and fields use KiraUI's built-in
platform appearance, so the sign-in surface follows Tessera's existing UI
on desktop and mobile. The application name is the only per-app copy.

## Integrate into a Tessera app

Add a package dependency (adjust relative path to the consuming package):

```kira
let dependencies: [Dependency] = [
    Dependency { name: "TesseraSignIn", path: "../tessera-sign-in" },
    Dependency { name: "TesseraAuth", path: "../tessera-auth" },
    Dependency { name: "KiraUI", path: "../../kira-packages/kira-ui" }
]
```

Then, wherever the app normally displays its login gate:

```kira
import KiraUI
import TesseraAuth
import TesseraSignIn

construct NotesAccountGate(onSignedIn: (TesseraTokens) -> Void) extends Widget {
    body {
        TesseraSignInView(
            config: TesseraAuthConfig {
                region: "us-east-1",
                clientId: "1for95pl6ud3s2c4sscntn4tol"
            },
            application: "Notes",
            onSignedIn: onSignedIn
        )
    }
}
```

The app's caller supplies `onSignedIn`, which must establish a secure local
session and navigate into the app. The UI kit does **not** persist tokens or
choose an OS credential-store implementation for the host. Do not treat
displaying a success message alone as a persistent login.

### Cognito and account API

The local development public Cognito client is
`1for95pl6ud3s2c4sscntn4tol`, region `us-east-1`, user pool
`us-east-1_tkpP6ILqj`. These IDs are not secrets. Use **separate public
client IDs** for production apps and configure them in the Accounts backend's
`ACCOUNTS_ALLOWED_CLIENT_IDS`. All users belong to the same Cognito pool.

The embedding app passes the returned **access** token to `GET /v1/me` on
Tessera Accounts. The Accounts API validates first-party tokens with Cognito
`GetUser`; it does not accept passwords or trust client-chosen user IDs.

## Flow and security

`TesseraSignInView` calls `performTesseraSignIn`, which dispatches a typed
action to the appropriate `TesseraAuth` Cognito API operation using TLS:

```text
Login -> [Cognito SignedIn] -> onSignedIn(tokens)
      -> [Cognito challenge] -> code / new password / TOTP setup -> continue

Create account -> confirmation email -> Verify -> Login
Forgot password -> reset email -> New password -> Login
```

Each request owns its network connection and has a ten-second network
deadline. Today these requests run synchronously from the UI action; on a
slow connection the sign-in view can temporarily stop responding until the
request completes. Move authentication into an async worker before using
this kit in latency-sensitive production UX.

The view keeps entered secrets in KiraUI state only while the form needs them.
After submission, navigation or successful authentication it clears passwords,
codes and setup secrets. The supplied callback receives tokens once and is
responsible for secure storage (system account service / OS keychain),
refresh and logout. Do not log tokens or passwords or persist them in plain
settings, a text file or KiraDB.

`MFA_SETUP` can enroll an authenticator using a manual setup key. It does not
produce a QR code. Unsupported custom/WebAuthn challenges show an explicit
message and Back to Sign In; they **never** mark a user authenticated. Clients
created outside Tessera are not allowed to use this direct-auth package.

## Verify

From the workspace root:

```sh
kira check tessera-packages/tessera-auth
kira check tessera-packages/tessera-sign-in
kira test tessera-packages/tessera-sign-in
```

The last command requires the host SDK/linker to support Kira test executables.

For an interactive example, see
[`example/`](example/) (`kira check tessera-packages/tessera-sign-in/example`).
The example uses the development client and intentionally discards tokens
rather than pretending to establish a persistent account session.
It runs as a KiraUI window on a developer machine. On Tessera, the embedding
application uses its normal `RunTesseraApplication` host; the sign-in widget
itself is the same.