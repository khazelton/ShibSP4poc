# PoC outline: OIDC login to a campus app via Shibboleth SP v4 Hub/Agent

Drafted 2026-11-01. Background and exact config keys in [sp4-research.md](sp4-research.md).

## Goal

Show that a campus Java web app running in **Jetty** can be protected by an SP v4 **Agent** (Apache httpd as auth reverse proxy), with the **Hub** doing OpenID Connect (auth code flow) against the campus IdP's OIDC OP, and the app receiving identity as HTTP headers — with the app and agent having no idea OIDC is involved. The app also needs **its own OAuth2 access tokens** to call campus APIs as itself (not as the user); it obtains those directly from the OP via `client_credentials`, independent of SP v4. Secondary: exercise the agent-registration (ID + shared secret) path that the TechEx discussion flagged as the scaling pain point.

## Framing decision

SP v4 hub is an OIDC **RP**, not an OP. It consumes tokens and hands attributes to the agent; it does not issue tokens to the app. So the PoC shape is:

```
browser ──▶ Apache + mod_shib4 (Agent) ──HTTP/TLS, basic auth──▶ Hub (IdP 5.2 + shibd plugins)
                 │                                                   │
                 │ mod_proxy, attrs as HTTP headers                   │ OIDC auth code flow
                 ▼                                                   ▼
          Jetty: campus app                               campus IdP + OIDC OP plugin
```

**Why httpd still appears:** SP v4 ships agents only for Apache 2.4, IIS, and FastCGI; there is no Java/Jetty agent and the project says new agents are "not an initial goal." Apache is therefore a thin auth proxy, not the app server. The app runs in Jetty. (Writing a Jetty agent against the hub remoting protocol is a possible follow-on; see Phase 5.)

**Tokens.** The app needs tokens to call APIs **as itself** (confirmed 2026-11-01). That is `client_credentials` — no user context, so SP v4 is not in that path at all. The app is registered at the OP as its own confidential client (`client_id` #2, distinct from the hub's RP registration) and mints tokens on demand. Had the app needed *user-delegated* tokens, SP v4 would have been the wrong tool: the hub keeps its access token in session and does not release it to the agent (features table "No/Maybe"; token exchange is v3 roadmap).

```
Jetty app ──client_credentials (client_id #2 + secret)──▶ OP token endpoint ──▶ JWT access token
Jetty app ──Bearer <token>──▶ campus API (validates via OP JWKS or introspection)
```

## Components

| # | Component | Choice for PoC |
|---|-----------|----------------|
| 1 | OP | Campus IdP (v4.2+) with OIDC OP plugin — or a throwaway IdP 5 + OP plugin if campus IdP can't take a test client |
| 2 | Hub host | Fresh IdP **≥ 5.2.0** + Jetty plugin, VM or container. Not the campus IdP |
| 3 | Hub plugins | `sp-dist` 0.0.3-SNAPSHOT core + `sp-oidc-dist` (+ `oidc-common` 3.4.0-SNAPSHOT) |
| 4 | Agent | `shibboleth-sp` 4.0.0beta1 RPM on Rocky 9, Apache 2.4 event MPM, `mod_proxy_http` to Jetty |
| 5 | App server | Jetty 12 (ee10), same host as agent for PoC; listens on 127.0.0.1 only |
| 6 | App | Servlet that (a) dumps identity headers and (b) on `/callapi` fetches a `client_credentials` token and calls the test API |
| 7 | OP client #2 | App's own confidential client at the OP: `grant_types=client_credentials`, scopes/resource for the test API |
| 8 | Test API | Second servlet (or separate Jetty) that accepts `Bearer`, validates JWT against OP JWKS (nimbus-jose-jwt), echoes claims. **Stands in for campus APIs for the whole PoC.** Register at OP as unregistered resource server (`encryptionOptional`) or with an `audience` entry |

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
- Jetty on 127.0.0.1:8081 with header-dump webapp. (Port 8080 is the hub's IdP/Jetty; keep separate.)
- Apache: protect `/secure` with `AuthType shibboleth` / `requireSession 1` / `Require valid-user`, then `ProxyPass /secure http://127.0.0.1:8081/secure`.
- Attribute export must be **headers**, since env vars do not cross `mod_proxy`. Two options:
  - agent `agent.ini` `[attribute-mappings]` (legacy header path), or
  - keep env-var export and set `RequestHeader set X-Eppn "%{eppn}e"` per attribute in Apache — cleaner, stays on the recommended agent path.
  Jetty must only accept these headers from httpd (bind loopback; strip inbound `X-*`/`HTTP_*` at the proxy with `RequestHeader unset`) or any client can spoof identity.
- Exit: browser → `/secure` → OP login → back → Jetty header dump shows `sub`, `eppn`.

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

### Phase 3b — App's own tokens (`client_credentials`)
Independent of Phases 1–3; can run in parallel once Phase 0 is done.
- Register OP client #2 for the app: confidential, `grant_types: ["client_credentials"]`, `token_endpoint_auth_method: client_secret_basic` (or `private_key_jwt` later), scope(s) for the test API, `resource` indicator (RFC 8707) if the OP enforces audience.
- OP side (plugin **V3.1+** required): add `client_credentials` to `idp.oauth2.grantTypes` or on the client's `OAUTH2.Token` bean; put `OAUTH2.Token` + `OAUTH2.TokenAudience` in the RP's profile collection in `relying-party.xml`; set `accessTokenType="JWT"` and (for an unregistered test API) `encryptionOptional="true"` on `OAUTH2.TokenAudience`. Client metadata JSON needs `scope` and extension claim `"audience"` listing the API, or set `idp.oauth2.defaultAllowedAudience`. OP refuses to mint a token without `aud`.
- App: on `/callapi`, POST `grant_type=client_credentials` to the OP token endpoint, cache token until `exp`, call test API with `Authorization: Bearer`.
- Test API: validate JWT access token (RFC 9068) — `iss`, `aud`/`resource`, `exp`, signature via OP JWKS. Fallback: OP introspection endpoint (RFC 7662).
- Secret handling: app `client_secret` lives in Jetty-side config outside the webapp; same lifecycle story as agent secrets → Phase 4 (midPoint provisions both).
- Exit: logged-in user hits `/callapi`; page shows identity headers **and** the API's echoed token claims (`sub` = app client_id, `aud`, `scope`).
- Negative: expired/wrong-audience token → 401 from API.

### Phase 4 (stretch) — Agent registration at scale
Directly answers Scott's ACAMP ask: "how do you issue credentials to all these agents, and how should agent config in the hub look?" See research doc, ACAMP section.

- Baseline: document what a hub operator does per agent today (bean in `agents.xml`, secret, IP range, issuer, OP client registration).
- **Agents as service accounts in the directory.** Hub validates agent basic-auth against LDAP via a custom `shibboleth.sp.AgentValidators` entry in `conf/global.xml`; `agents.xml` carries only `p:id`, `p:usernames`, `p:allowedAddressRanges`, `p:issuer` — no secrets. Exploits the agentID↔credential decoupling Scott described.
- **Provision the service account from IGA (midPoint).** Agent = midPoint service object with owner, lifecycle, rotation policy; midPoint pushes account to LDAP and delivers the secret to the agent host (`secretFile`). Rotation = midPoint changes LDAP password + redeploys `agent.pwd`; hub untouched. This is Keith's "treat agents like human principals" point made concrete, and addresses the governance/ownership objection raised on the floor.
- **Flat-file agent list.** Generate the per-agent `agents.xml` fragment (or whatever flat format v1 lands on) from midPoint/LDAP, Ansible-style, so hub config is derived, not hand-edited. Matches Chris B.'s "my hub is an Ansible playbook" model.
- Output: short write-up for Scott / dev list — friction points, what a hub-side "agent list" format would need to carry to make this clean, and whether token-based enrollment (Scott's longer-term idea) is even needed if IGA owns the lifecycle.

### Phase 5 (stretch, bigger) — Native Jetty agent
- Goal: drop httpd. A Jetty `Handler`/servlet `Filter` that speaks the hub remoting protocol (HTTP 1.1 + serialized DDF, `/idp/profile/sp/`), does basic-auth to the hub, holds session state, and populates request attributes.
- Inputs: sphub1 `RemotingProtocol` (2868281349) and `RemoteOperationsReference` (3677028369); `cpp-sp` main branch for the DDF wire format.
- Only attempt after Phases 1–3 prove the hub side. Worth proposing to the dev list first — a Java agent may already be on someone's roadmap.

## Known risks

- Beta software, snapshot hub plugins; breakage between agent and hub versions — pin to compatibility row.
- OIDC side least mature: no RP JWKS endpoint, no OP-initiated logout, no DCR. Use `client_secret_*` auth, not `private_key_jwt`, for first pass.
- Redirect URI, scope, logout config undocumented on OIDCBasics — expect source diving.
- Proxy hop forces header-based identity transfer. Header spoofing is the classic failure; lock Jetty to loopback and strip inbound identity headers at httpd.
- Two Jettys on one host (hub's IdP on 8080, app on 8081) — easy to confuse; name them clearly or split hosts early.
- Hub needs IdP 5.2 while campus runs 4.2 — fine for hub host, but OP plugin on a 4.2 IdP should be verified for compatibility with current RP expectations.

## Open questions for stakeholders

1. ~~Does the app need tokens or just identity?~~ Resolved: identity via SP v4, plus `client_credentials` tokens for app-as-itself API calls. (If user-delegated tokens ever become a requirement, revisit — SP v4 does not cover that today.)
2. Can the campus IdP accept **two** test OIDC clients (hub RP + app client_credentials), or do we stand up our own OP? (Target API: decided 2026-11-01 — use the Phase 3b test API for now; real campus APIs out of scope until PoC proves the flow.)
3. Who owns agent IDs/secrets long term — hub admin or IAM? (Shapes Phase 4.)
4. Interest in offering results to Shib dev list / Scott as early SP4 feedback?
