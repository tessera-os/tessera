# TesseraAuth — first-party sign-in (Kira)

This library provides Cognito user-pool authentication for **Tessera-owned
apps**. Cognito stores passwords and issues tokens. The Tessera Accounts Kira
service validates access tokens and manages account profiles, but **does not
receive user passwords**. Applications should normally embed the prebuilt
[`TesseraSignIn`](../tessera-sign-in/README.md) UI instead of writing their own
email/password screens or calling these APIs manually.

## Local development Cognito client

| Setting | Value |
| --- | --- |
| User pool | `us-east-1_tkpP6ILqj` |
| Region | `us-east-1` |
| First-party client ID | `1for95pl6ud3s2c4sscntn4tol` |
| Client secret | None (public client) |
| Login | `USER_AUTH` with `PREFERRED_CHALLENGE=PASSWORD` |
| API | `https://cognito-idp.us-east-1.amazonaws.com/` |

All API interactions use Kira's `Network` TLS client with the public
`AWSCognitoIdentityProviderService` operations. No AWS IAM keys, temporary AWS
SSO credentials, or AWS SDK are required by the application.

## Connect an app

In your app's `package.kira`, add:

```kira
let dependencies: [Dependency] = [
    Dependency { name: "TesseraAuth", path: "../tessera-auth" }
]
```

Build the Tessera app's native form with `Email`, `Password`, and `Log In`
controls. On submission, use the form values with the Kira client:

```kira
import TesseraAuth
import Network as Net

let config = TesseraAuthConfig {
    region: "us-east-1",
    clientId: "1for95pl6ud3s2c4sscntn4tol"
}

let result = tesseraSignIn(network, config, email, password)
match result {
    Ok(outcome) -> match outcome {
        SignedIn(tokens) -> { /* persist tokens securely; enter app */ }
        Challenge(challenge) -> { /* present MFA, OTP or password-change form */ }
    }
    Error(failure) -> { /* show a generic sign-in failure */ }
}
```

The snippet represents code **inside** the app's existing login handler;
`network`, `email`, and `password` are supplied by the app. Use the shared
`Network` instance already managed by the app. For a `SOFTWARE_TOKEN_MFA`
challenge, present the 6-digit authenticator code and call
`tesseraAnswerChallenge(network, config, email, challenge, code)`; similarly
for `PASSWORD`, `EMAIL_OTP`, `SMS_MFA`, `SMS_OTP` and `NEW_PASSWORD_REQUIRED`.
Do not consider a challenge complete until Cognito returns `SignedIn`.

## Operations available in Kira

| Kira function | Cognito operation | UI |
| --- | --- | --- |
| `tesseraSignIn` | `InitiateAuth` (`USER_AUTH`, `PASSWORD`) | Email/password |
| `tesseraAnswerChallenge` | `RespondToAuthChallenge` | MFA/OTP/new password |
| `tesseraSignUp` | `SignUp` | Create account |
| `tesseraConfirmEmail` | `ConfirmSignUp` | Verify email code |
| `tesseraResendConfirmation` | `ResendConfirmationCode` | Resend verification code |
| `tesseraBeginMfaEnrollment` | `AssociateSoftwareToken` | TOTP setup key |
| `tesseraFinishMfaEnrollment` | `VerifySoftwareToken`, then `RespondToAuthChallenge` | Finish TOTP setup |
| `tesseraForgotPassword` | `ForgotPassword` | Forgot password |
| `tesseraResetPassword` | `ConfirmForgotPassword` | Reset with code |
| `tesseraRefresh` | `InitiateAuth` (`REFRESH_TOKEN_AUTH`) | Refresh expired access/ID tokens |
| `tesseraRevokeSession` | `RevokeToken` | Log out current session |

`tesseraSignIn` returns `SignedIn(TesseraTokens)` on success or
`Challenge(TesseraAuthChallenge)` if Cognito requires an additional step.
Challenge sessions are opaque and short-lived: pass them back to Cognito, not
to your Accounts API or user profile database. MFA setup via `MFA_SETUP` is
supported by `tesseraBeginMfaEnrollment`/`tesseraFinishMfaEnrollment`, including
verification of the authenticator's first code. Password recovery and email
verification remain Cognito-owned.

Use OS secure storage for refresh tokens (never logs, plaintext KiraDB or
URLs). `tesseraRefresh` does not normally return a new refresh token when
refresh-token rotation is disabled; retain the existing token until revoked
or expired. Clear the local access, ID, and refresh tokens immediately on
logout, even if revocation fails due to networking.

To identify the authenticated user on the Tessera Accounts backend, send only
the access token:

```http
GET /v1/me HTTP/1.1
Authorization: Bearer <access_token>
```

The Accounts API authenticates this user with Cognito `GetUser`, checks that
their Cognito issuer and app client are allowed, then responds with their
profile. The client must not send or accept caller-selected `sub` values.

## Security / deployment

- Create a **distinct public Cognito app client for each owned app** and
  allowlist it on the Accounts backend. Don't use the development client for
  every production app.
- Native apps can integrate this Kira client. Browser-only UIs need a safe
  browser integration strategy, preferably a first-party backend-for-frontend
  session with `HttpOnly`, `Secure`, `SameSite` cookies; **do not keep refresh
  tokens in localStorage**.
- Direct API sign-in and hosted OIDC sign-in work against the same Cognito user
  pool but do not share a hosted browser login cookie. Shared OS-wide first-party
  SSO requires a future account broker.
- Cognito is the password authority. Never log credentials, challenge answers,
  bearer tokens, or refresh tokens; configure request logging accordingly.
- Configure account-abuse protections, real email sending, MFA enrollment, and
  app-specific clients before a public launch.

Run `kira check tessera-packages/tessera-auth` to type-check this library and
its tests. Local executable test linkage depends on the installed KLF SDK.