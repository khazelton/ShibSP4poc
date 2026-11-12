# Draft to Scott: forceAuthn with Google (not sent)

Drafted 2026-11-11. Background is in `poc-outline.md`, under Phase 0 ("Google can't be made to re-authenticate"). Recipient not yet decided: Scott directly, or dev@shibboleth.net like `dev-list-writeup.md`.

---

**Subject:** SP4 hub + Google: forceAuthn fails on missing auth_time; could the agent pass `prompt` on its own?

Hi Scott,

Another small finding from the SP4 PoC. Setup: hub nightly 0.0.3-43 (sp-dist/sp-oidc-dist 20261111 -43, oidc-common 3.4.0 -322) on IdP 5.2.3, agent `shibboleth-sp-4.0.0beta1` (`mod_shib4`, Apache on Rocky 9), and Google as the OP.

**What I wanted:** to make Google ask the user to sign in again for a protected path, instead of silently reusing the browser's Google session.

**What I tried:** `ShibRequestSetting forceAuthn 1` on the location (and also `/Shibboleth.sso/Login?...&forceAuthn=1`). The hub's `AddForceAuthenticationHandler` turns this into `prompt=login&max_age=0` on the authorization request, and Google accepts the request and shows its account chooser.

**What failed:** because `max_age` was sent, the token-consumer flow requires `auth_time` (`AuthTimeRequestedActivationCondition`, from `isAuthTimeRequired` on the state data). Google's ID token has no `auth_time`, so validation fails:

```
ValidateTokenClaims: JWT claims verification failed for subject '<redacted>'
JWTValidationException: No authentication time found in token
LogEvent: A non-proceed event occurred while processing the request: MessageProcessingError
```

The agent then returns a 500 to the browser. OIDC Core does require `auth_time` when `max_age` is requested, so the hub's behavior is correct here and Google is the one that falls short. Still, with this hub build there is no way to ask Google to re-authenticate:

- `PromptLookupStrategy` uses only the agent's `prompt` member, or derives `prompt=none` from `isPassive`.
- beta1 doesn't seem to send `prompt`. `/Shibboleth.sso/Login?prompt=login` and `?prompt=select_account` both produce an authorization request without it.
- `forceAuthn` always sends `max_age=0` along with `prompt=login`.

Two possible ways to support OPs like Google:

1. Have the agent pass `prompt` through (as a request setting and/or a Login handler parameter) without implying `max_age`, so `prompt=login` or `prompt=select_account` can be sent on its own.
2. A per-RP or per-OP option controlling what `forceAuthn` sends, e.g. `prompt=login` only, or not enforcing `auth_time` when the OP is known not to return it.

Is either of these on the roadmap, or is there a configuration route I've missed? For now we've reverted `forceAuthn` and test fresh logins in a private window. I expect `forceAuthn` to work as-is against a Shibboleth OP, which is our production target, but I haven't tested that yet.

Thanks,
Keith
