# PoC outline: OIDC login to a campus app via Shibboleth SP v4 Hub/Agent

Drafted 2026-11-01. Background and exact config keys in [sp4-research.md](sp4-research.md).

## Goal

Show that a campus web app can be protected by an SP v4 **Agent**, with the **Hub** doing OpenID Connect (auth code flow) against the campus IdP's OIDC OP, and the app receiving identity as env vars — with the app and agent having no idea OIDC is involved. Secondary: exercise the agent-registration (ID + shared secret) path that the TechEx discussion flagged as the scaling pain point.

## Framing decision

SP v4 hub is an OIDC **RP**, not an OP. It consumes tokens and hands attributes to the agent; it does not issue tokens to the app. So the PoC shape is:

```
browser ──▶ Apache + mod_shib4 (Agent) ──HTTP/TLS, basic auth──▶ Hub (IdP 5.2 + shibd plugins)
                 │                                                   │
                 │ env vars (eppn, etc.)                             │ OIDC auth code flow
                 ▼                                                   ▼
             campus app                                   campus IdP + OIDC OP plugin
```

If the app instead needs its own tokens (calls APIs as the user), SP v4 is the wrong tool — register the app directly with the OP. Confirm which case applies before building.

## Components

| # | Component | Choice for PoC |
|---|-----------|----------------|
| 1 | OP | Campus IdP (v4.2+) with OIDC OP plugin — or a throwaway IdP 5 + OP plugin if campus IdP can't take a test client |
| 2 | Hub host | Fresh IdP **≥ 5.2.0** + Jetty plugin, VM or container. Not the campus IdP |
| 3 | Hub plugins | `sp-dist` 0.0.3-SNAPSHOT core + `sp-oidc-dist` (+ `oidc-common` 3.4.0-SNAPSHOT) |
| 4 | Agent | `shibboleth-sp` 4.0.0beta1 RPM on Rocky 9, Apache 2.4 event MPM |
| 5 | App | Trivial CGI/PHP/Python page that dumps env vars (`REMOTE_USER`, attrs, `Shib-*`) |

## Phases

### Phase 0 — OP ready
- Confirm OIDC OP plugin installed on campus IdP (or stand up test IdP).
- Manually register an RP client: `client_id`, `client_secret`, redirect URI, scopes `openid profile email` (+ `eduperson` if campus exposes). **Redirect URI format for SP v4 hub not yet documented** — determine from hub logs/source on first attempt, then register.
- Exit: `/.well-known/openid-configuration` reachable from hub host.

### Phase 1 — Hub up, local agent
- Install IdP 5.2+, Jetty plugin. Install snapshot keyring + core + OIDC plugins.
- Generate JWKs (`bin/jwtgen-sp.sh`), import `oidc-credentials.xml` into `agents.xml`, `oidc-claim-rules.xml` into `default-rules.xml`.
- `sp.properties`: `sp.issuer = <client_id>`, `sp.defaultAuthority = <OP issuer>`. `oidc.properties`: `sp.oidc.defaultClientSecret`, `sp.oidc.acceptUnfilteredAttributes = true` (PoC only).
- Install agent on same host, default `localhost` agent, plain HTTP 127.0.0.1:8080.
- Protect `/secure` with `AuthType shibboleth` / `requireSession 1` / `Require valid-user`.
- Exit: browser → `/secure` → OP login → back → env dump shows `sub`, `eppn`.

### Phase 2 — Networked agent with secret (the real test)
- Move agent to second host. Hub behind TLS (Jetty plugin).
- Hub: `sp.agent.authn.method = basic`; Agent bean with `p:id`, `p:allowedAddressRanges`, `p:credentials` from externalized property, `p:issuer`.
- Agent `agent.ini [remoting]`: `agentID`, `baseURL=https://hub/idp/profile/sp/`, `authMethod = basic`, `tlsCAFile`, `secretFile`.
- Negative tests: wrong secret → 401; off-range IP → denied.
- Exit: same login flow works cross-host; failure cases rejected.

### Phase 3 — Attribute shaping
- Replace `acceptUnfilteredAttributes` with a real attribute filter.
- Map claims → `eppn`, `displayName`, `mail` via `oidc-claim-rules.xml`; verify env var names in app.
- Optional: second Application ID on same agent (`ShibRequestSetting applicationId`) pointing at a different OP override.

### Phase 4 (stretch) — Agent registration at scale
- Document what a hub operator must do per agent today (bean in `agents.xml`, secret, IP range, issuer, OP client registration).
- Prototype externalizing that: agents defined from a properties/DB source, secrets provisioned by an IAM/IGA tool (midPoint service account → `secretFile` + hub property). This is the "service account management" gap from the TechEx notes.
- Output: short write-up for Scott Cantor / dev list with findings and friction points.

## Known risks

- Beta software, snapshot hub plugins; breakage between agent and hub versions — pin to compatibility row.
- OIDC side least mature: no RP JWKS endpoint, no OP-initiated logout, no DCR. Use `client_secret_*` auth, not `private_key_jwt`, for first pass.
- Redirect URI, scope, logout config undocumented on OIDCBasics — expect source diving.
- Env vars not headers: if the target app expects `HTTP_*` headers, need `[attribute-mappings]` in `agent.ini` (legacy path).
- Hub needs IdP 5.2 while campus runs 4.2 — fine for hub host, but OP plugin on a 4.2 IdP should be verified for compatibility with current RP expectations.

## Open questions for stakeholders

1. Does the app need tokens (API calls) or just identity? Decides whether SP v4 applies.
2. Can the campus IdP accept a test OIDC client, or do we stand up our own OP?
3. Who owns agent IDs/secrets long term — hub admin or IAM? (Shapes Phase 4.)
4. Interest in offering results to Shib dev list / Scott as early SP4 feedback?
