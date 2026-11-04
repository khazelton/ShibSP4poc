# PoC outline: OIDC login to a campus app via Shibboleth SP v4 Hub/Agent

Drafted 2026-11-01. Background and exact config keys in [sp4-research.md](sp4-research.md).

## Goal

Show that a campus Java web app running in **Jetty** can be protected by an SP v4 **Agent** (Apache httpd as auth reverse proxy), with the **Hub** doing OpenID Connect (auth code flow) against an OP — **Google for the PoC**, campus IdP OIDC OP later — and the app receiving identity as HTTP headers — with the app and agent having no idea OIDC is involved. The app also needs **its own OAuth2 access tokens** to call campus APIs as itself (not as the user); it obtains those directly from the OP via `client_credentials`, independent of SP v4. Secondary: exercise the agent-registration (ID + shared secret) path that the TechEx discussion flagged as the scaling pain point.

## Framing decision

SP v4 hub is an OIDC **RP**, not an OP. It consumes tokens and hands attributes to the agent; it does not issue tokens to the app. So the PoC shape is:

```
browser ──▶ Apache + mod_shib4 (Agent) ──HTTP/TLS, basic auth──▶ Hub (IdP 5.2 + shibd plugins)
                 │                                                   │
                 │ mod_proxy, attrs as HTTP headers                   │ OIDC auth code flow
                 ▼                                                   ▼
          Jetty: campus app                     OP: Google (PoC) / campus IdP OIDC OP (prod)
```

**Why httpd still appears:** SP v4 ships agents only for Apache 2.4, IIS, and FastCGI; there is no Java/Jetty agent and the project says new agents are "not an initial goal." Apache is therefore a thin auth proxy, not the app server. The app runs in Jetty. (Writing a Jetty agent against the hub remoting protocol is a possible follow-on; see Phase 5.)

**Tokens.** The app needs tokens to call APIs **as itself** (confirmed 2026-11-01). That is `client_credentials` — no user context, so SP v4 is not in that path at all. The app is registered at the OP as its own confidential client (`client_id` #2, distinct from the hub's RP registration) and mints tokens on demand. Had the app needed *user-delegated* tokens, SP v4 would have been the wrong tool: the hub keeps its access token in session and does not release it to the agent (features table "No/Maybe"; token exchange is v3 roadmap).

```
Jetty app ──JWT-bearer (service-account key, target_audience)──▶ Google token endpoint ──▶ signed ID token
Jetty app ──Bearer <token>──▶ test API (validates via Google JWKS, aud = itself)
   [campus OP later: client_credentials (client_id #2 + secret) ──▶ OP token endpoint ──▶ JWT access token]
```

## Components

| # | Component | Choice for PoC |
|---|-----------|----------------|
| 1 | OP | **Google** (`https://accounts.google.com`) via a Google Cloud OAuth client owned by the PoC author. Campus IdP + OIDC OP plugin is the production target; swap later (see Phase 0-alt) |
| 2 | Hub host | Fresh IdP **≥ 5.2.0** + Jetty plugin, VM or container. Not the campus IdP |
| 3 | Hub plugins | `sp-dist` 0.0.3-SNAPSHOT core + `sp-oidc-dist` (+ `oidc-common` 3.4.0-SNAPSHOT) |
| 4 | Agent | `shibboleth-sp` 4.0.0beta1 RPM on Rocky 9, Apache 2.4 event MPM, `mod_proxy_http` to Jetty |
| 5 | App server | Jetty 12 (ee10), same host as agent for PoC; listens on 127.0.0.1 only |
| 6 | App | Servlet that (a) dumps identity headers and (b) on `/callapi` fetches a `client_credentials` token and calls the test API |
| 7 | App credential | Google **service account** (JSON key) in the same GCP project; app uses JWT-bearer with `target_audience` to get a Google-signed ID token for the test API. (Google has no `client_credentials`; with campus OP this becomes OP client #2 + `client_credentials`) |
| 8 | Test API | Second servlet (or separate Jetty) that accepts `Bearer`, validates the ID token against Google JWKS (`https://www.googleapis.com/oauth2/v3/certs`) with `aud` = its own URL, echoes claims. **Stands in for campus APIs for the whole PoC.** |

## Phases

### Phase 0 — OP ready (Google)
- GCP project (author's). APIs & Services → OAuth consent screen: User type *External*, publishing status *Testing*, add author's Google account as test user. (Workspace account → *Internal* instead.)
- Create OAuth client, type **Web application**. Record `client_id` / `client_secret`. Authorized redirect URI: **`https://localhost/Shibboleth.sso/Validate`** (discovered 2026-11-01 from the agent's 302 — it is the agent's TokenConsumer handler, not a hub URL; the browser never talks to the hub).
- Create a **service account** in the same project; download JSON key → Jetty host, outside the webapp, mode 600. No GCP roles needed — it only signs assertions.
- Hub-facing values: `sp.defaultAuthority = https://accounts.google.com`, `sp.issuer = <client_id>`, `sp.oidc.defaultClientSecret = <client_secret>`.
- Claims available: `sub`, `email`, `email_verified`, `name`, `given_name`, `family_name`, `picture`, `hd` (Workspace only). **No `eppn`** — map `email` in `oidc-claim-rules.xml`. No `end_session_endpoint` → skip logout tests.
- Exit: `curl https://accounts.google.com/.well-known/openid-configuration` from hub host; service-account key present on Jetty host.

### Phase 0-alt — campus OP (production target, later)
- Campus IdP OIDC OP plugin ≥ 3.1. Register two clients: hub RP (auth code, `openid profile email eduperson`) and app client (`client_credentials`, `audience` = test API). Swap `sp.defaultAuthority`/`sp.issuer`/secret, restore `eppn` claim rule, and replace the Phase 3b token client with a plain `client_credentials` POST. Everything else unchanged.

### Phase 1 — Hub up, local agent — **DONE 2026-11-01**
First browser login succeeded first try: `/secure/` → Google → `/Shibboleth.sso/Validate` → hub `token-consumer` 200 → Jetty page. Stack in `deploy/`; see `deploy/README.md`. Leftover: hub logs `ResolutionException: Attribute Definition 'uid': provided principal name was empty` from the host IdP's stock `attribute-resolver.xml` — harmless, fix in Phase 3.

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
- Exit: browser → `/secure` → Google login → back → Jetty header dump shows `sub`, `email`.

### Phase 2 — Networked agent with secret — **DONE 2026-11-01**
Agent `sp4-agent.localtest` (pinned 172.30.0.20) → `https://hub.localtest:8443` with `authMethod=basic`, secret from `agent.pwd`, hub cert via shared volume. Hub log: `AgentSecretCredentialValidator spagent-internal … succeeded`, `ValidateAgentAddress: permitted`. Negative tests against `/idp/profile/sp/ping`: wrong secret → `event InvalidCredentials`; wrong source IP → `event AccessDenied` (both HTTP 200 — errors travel in the DDF body). Secret delivery = `deploy/gen-agent-secret.sh` writing both ends. Original plan follows.

- Move agent to second host. Hub behind TLS (Jetty plugin).
- Hub: `sp.agent.authn.method = basic`; Agent bean with `p:id`, `p:allowedAddressRanges`, `p:credentials` from externalized property, `p:issuer`.
- Agent `agent.ini [remoting]`: `agentID`, `baseURL=https://hub/idp/profile/sp/`, `authMethod = basic`, `tlsCAFile`, `secretFile`.
- Negative tests: wrong secret → 401; off-range IP → denied.
- Exit: same login flow works cross-host; failure cases rejected.

### Phase 3 — Attribute shaping — **partly done 2026-11-01**
- ~~Replace `acceptUnfilteredAttributes` with a real attribute filter.~~ Done: `deploy/hub/conf/attribute-filter.xml` (permit policy for the Google claim set; stock IdP filter was silently dropping `mail`). `sp.oidc.acceptUnfilteredAttributes` still `true` as belt-and-braces — drop it once the policy is final. Empty `attribute-resolver.xml` kills the `uid` error.
- Verified at the app: `X-Shib-Sub, -Mail, -DisplayName, -GivenName, -Sn, -Session-Id, -Application-Id`.
- `X-Remote-User` is `(null)`: nothing maps to `REMOTE_USER` yet. Find the SP4 agent equivalent of SP3's `REMOTE_USER="eppn mail"` (not in shipped `agent.ini`; check `AttributeHandling` page / `[attribute-settings]`).
- Map claims → `mail` (from `email`), `displayName` (from `name`), and a synthetic `eppn` = `email` for app compatibility, via `oidc-claim-rules.xml`; verify header names in app. Optionally gate on `hd` to restrict to one Workspace domain.
- Optional: second Application ID on same agent (`ShibRequestSetting applicationId`) pointing at a different OP override.

### Phase 3b — App's own tokens (Google service account, JWT-bearer) — **DONE 2026-11-01**
`deploy/app/` is now a Maven multi-module build (inside Docker): `secure.war` (`index.jsp` + `/secure/callapi`, `CallApiServlet`) and `api.war` (`/api/echo`, `EchoServlet`). Hand-rolled RFC 7523 with nimbus-jose-jwt: SA key → RS256 assertion with `target_audience=https://sp4-poc-api.localtest` → `oauth2.googleapis.com/token` → ID token (`iss=https://accounts.google.com`, `aud=<API_AUDIENCE>`, `email=<SA>`) → API validates via Google JWKS + explicit `iss`/`aud`/`sub`/`exp` checks → 200 with echoed claims; `?expectAud=…` mismatch → 401 "audience mismatch". nimbus `DefaultJWTClaimsVerifier` 4-arg ctor NPE'd in 9.40; explicit checks used instead. Original plan follows.

Independent of Phases 1–3; can run in parallel once Phase 0 is done. Google has no `client_credentials`; the equivalent for "app calls API as itself" is a service account minting a Google-signed **ID token** for a chosen audience (same mechanism Cloud Run / IAP use).
- App, on `/callapi`:
  1. Build RS256 JWT from the service-account key: `iss`/`sub` = SA email, `aud` = `https://oauth2.googleapis.com/token`, `target_audience` = test API URL, `iat`/`exp` (≤1h).
  2. POST to `https://oauth2.googleapis.com/token` with `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=<jwt>`.
  3. Response `id_token` is the bearer. Cache until `exp`. Call test API with `Authorization: Bearer`.
  Google's `google-auth-library-oauth2-http` does steps 1–3 as `IdTokenCredentials` with `targetAudience`; hand-rolling with nimbus-jose-jwt is ~40 lines and shows the mechanics better for the write-up.
- Test API: validate `id_token` — RS256 signature via `https://www.googleapis.com/oauth2/v3/certs`, `iss` ∈ {`https://accounts.google.com`, `accounts.google.com`}, `aud` = own URL, `exp`; echo `sub`, `email` (SA email), `aud`, `iss`.
- Secret handling: SA JSON key lives in Jetty-side config outside the webapp, mode 600; same lifecycle story as agent secrets → Phase 4 (key rotation via GCP IAM, provisioning via IGA).
- Exit: logged-in user hits `/callapi`; page shows identity headers **and** the API's echoed token claims (`email` = SA, `aud` = API URL).
- Negative: wrong `target_audience` or expired token → 401 from API.
- Campus-OP variant (Phase 0-alt): replace steps 1–3 with a `client_credentials` POST; OP side needs plugin V3.1+, `client_credentials` in `idp.oauth2.grantTypes` or on the client's `OAUTH2.Token` bean, `OAUTH2.Token` + `OAUTH2.TokenAudience` in `relying-party.xml`, `accessTokenType="JWT"`, and an `audience` in client metadata or `idp.oauth2.defaultAllowedAudience` (OP refuses tokens without `aud`). Test API swaps JWKS URL and `iss`.

### Phase 4 (stretch) — Agent registration at scale — **first slice DONE 2026-11-01**
Directly answers Scott's ACAMP ask: "how do you issue credentials to all these agents, and how should agent config in the hub look?" See research doc, ACAMP section.

**Done (browser login verified 2026-11-02 00:01 UTC through the LDAP-validated agent):** agent credentials moved out of the hub entirely. `lldap` container = directory of agent service accounts; hub `conf/global.xml` `shibboleth.sp.AgentValidators` = internal + `LDAPCredentialValidator` (directAuthenticator, `uid=%s,ou=people,dc=localtest`); `agents.xml` bean carries **no secret**. `gen-agent-secret.sh <uid>` sets the LDAP password and writes `agent.pwd`; agent recreated with `--no-deps`; hub `StartedAt` unchanged → rotation never touches the hub. Old password → `InvalidCredentials`.

**Found (feedback for the SP4 team, hub 0.0.3-20261101):**
1. Documented `<ref bean="shibboleth.sp.AgentSecretValidator"/>` / `<bean parent="shibboleth.sp.LDAPValidator"/>` in `global.xml` fails: `NoSuchBeanDefinitionException` — those beans live in the SP flow context, invisible to the root context. Workaround: declare validators by class in `global.xml` (see `hub/entrypoint.sh`).
2. Plugin's `shibboleth.sp.LDAPAuthenticationFactory` lacks `autoReconnect`/`reconnectTimeout` (and `startTLSTimeout`) that IdP 5.2.3's `LDAPAuthenticationFactoryBean` requires → "Reconnect timeout cannot be null" even if it were reachable.
3. **`p:usernames` cannot work with external validators**: `ValidateAgentCredentials.buildAuthenticationResult` requires `UsernamePrincipal(agent.getId())` in the Subject; only the internal validator produces that. With LDAP the presented username *must equal the agent id* — the identity/credential decoupling described at ACAMP isn't wired through yet. Workaround used: `p:id` = LDAP `uid` = `agent.ini agentID` = `sp4-agent`.
4. Agent has no separate username setting; `agentID` is the basic-auth username (confirmed in RemotingSettings). Any decoupling must be hub-side.

**Reported:** findings 1–4 (plus the `mail` filter and installer-cert items) sent to dev@shibboleth.net on 2026-11-01 — see `docs/dev-list-writeup.md`.

**Reply from Scott Cantor (received 2026-11-02).** LDAP validation had not been seriously tested by anyone; most issues are simple to fix and he will add unit tests for the LDAP scenario. Dispositions, numbered as in the write-up:

| # | Item | Disposition |
|---|------|-------------|
| 1 | Stock filter drops `mail` | Not a hub defect. Both SAML and OIDC Basics pages say the IdP filter applies; example policy ships at `conf/examples/attribute-filter-sp.xml` (present in our image). Plugin will not overwrite the IdP default. Fuller attribute-handling doc deferred. |
| 1b | `uid` `ResolutionException` on every login | Resolver shouldn't normally run; he'll ask Phil whether the OIDC plugin forces or accidentally triggers it. Skeletal SP resolver example likely. The "where does the principal come from" hook for the resolver is still an open slot. |
| 2, 3 | Validator bean scoping; LDAP factory missing properties | Covered by "most issues are simple to correct" + LDAP unit tests. Expect fixes in a later 0.0.3/0.0.4 nightly. |
| 4 | `p:usernames` unusable with external validators | He'll review the code and add tests for that case. |
| 5 | No agent username separate from `agentID` | By design: `agentID` *is* the username, period. When it differs from the hub's `p:id`, the hub id is only a logging artifact. |
| 6 | Installer ignores `idp.host.name` for Jetty keystore | File a separate bug if wanted, but largely historical — likely dropped in V6 in favour of the Jetty plugin. Advice: script the keystore yourself (as we did). |
| 7 | Always-200 responses | Aimed at agent developers; technical docs may already say so. Tracing exists but isn't documented yet. |
| — | Agent list format | Would rather define an LDAP schema for agents and a source plugin that loads them directly than generate a flat file. But doubts demand: "directories failed pretty soundly as application repositories"; audience likely tiny. Not much work, not front burner. Open to persuasion. |
| — | `p:id` vs `agentID` divergence | "That's simply a bug" — the model intends them to diverge (confirms #4). |

**Consequences for this PoC:** keep the custom `attribute-filter.xml` but rebase it on `attribute-filter-sp.xml`; after a nightly that fixes #2–#4, rebuild the hub and retest the documented `AgentValidators` form and `p:usernames` rotation across two LDAP service accounts. Scott's scepticism about directories argues for doing the flat-file/htpasswd option alongside (or before) midPoint→LDAP, and for framing the IGA case around who uses it rather than the mechanism.

**Retest 2026-11-02 against nightly -31** (`sp-dist-0.0.3-20261102.114708-31`, `sp-oidc-dist-…115010-31`, `oidc-common-dist-3.4.0-20261102.111546-321`): hub rebuilt with `--no-cache`; previous image kept as `sp4-hub:20261101`. **No SP fixes yet**: every class in the `sp-*` jars is byte-identical to the previous build, including `ValidateAgentCredentials.class` and `sp-abstract-beans.xml`. The only code changes are in oidc-common (`OAuth2Client-beans.xml`; `BaseJWTSignatureSecurityHandler` gained a `ProfileRequestContextCriteriaSetBuilder`). Agent↔hub health is OK on the new image with the LDAP validator, and a browser login at `/secure/` succeeded, so the oidc-common JWT signature change didn't break ID-token validation against Google. Retest #2–#4 when the `sp-*` jars change.

**agents.xml reload verified 2026-11-02:** `shibboleth.sp.AgentResolverService` is a standard `ReloadableService`, polled every `sp.service.agents.checkInterval` (PT5M in the shipped sp.properties) and reloadable on demand with `bin/reload-service.sh -u http://localhost:8080/idp -id shibboleth.sp.AgentResolverService`. Adding a throwaway agent and reloading gave `Initializing with Agents: [sp4-agent, reload-test]`; reverting dropped it, and agent health stayed OK. A generated agents.xml therefore needs no hub restart. Keith's direct reply to Scott (as sent) is in `docs/reply-to-scott-2026-11-02.md`.

**Scott's second reply (2026-11-03):**
- The `p:usernames` fix went in that morning; he hadn't tested LDAP itself yet.
- Pluggable credential validation "was really the crux of my question". At OSU there was no near-term path to it, and pushback from everyone else suggested that "virtually nobody" uses LDAP for service accounts in a coordinated, enterprise way, only one-offs. His working assumption for scale is manually issued credentials, which is how OpenID is being deployed too. He sees this as a people and process problem, not a tools problem.
- On agents.xml generation: he wants a **hybrid "loader" bean** that defines sets of configuration for a group of agents in XML, then loads the raw per-agent data (flat file or LDAP) and applies those settings to all of them at once. Advanced config stays in the hub's XML as a mostly one-time cost; day-to-day agent entries live elsewhere.

**Retest 2026-11-03 against nightly -32** (`sp-dist-0.0.3-20261103.015906-32`, `sp-oidc-dist-…020212-32`, `oidc-common-dist-3.4.0-20261103.012517-322`; flagged by `check-hub-nightly.sh`). The -31 image is kept as `sp4-hub:20261102`. **Defects #2, #3 and #4 are fixed:**
- #2: validator beans moved to a new root-context file, `agent-authn.xml` (now also includes JAAS, Kerberos, HTPasswd and X.509 validators). The documented `<ref bean="shibboleth.sp.AgentSecretValidator"/>` + `<bean parent="shibboleth.sp.LDAPValidator"/>` in `global.xml` starts and authenticates.
- #3: the factory now sets `startTLSTimeout`, `autoReconnect` and `reconnectTimeout`. Nit: those three read `sp.authn.LDAP.*` while the rest read `sp.agent.authn.LDAP.*`.
- #4: `ValidateAgentCredentials` now takes the single `UsernamePrincipal` and checks it against the agent's id and usernames. Tested with agent `p:id="sp4-agent.localtest"` and `p:usernames` sa1/sa2. `agentID=sa1-sp4-agent` worked, rotation to `sa2-sp4-agent` worked with the hub's `StartedAt` unchanged, and `agentID=sp4-agent` (a valid LDAP account not in the list) was rejected with `Unknown agent based on credential ID` / `UnknownUsername` before any password check.
- Side changes in -32: SP LDAP properties no longer chain to `idp.authn.LDAP.*`; shipped `sp.properties` now sets `trustCertificates`/`trustStore` to non-existent files under `credentials/sp/`, which is harmless with `jvmTrust`. Nit: with `p:usernames` set, the internal validator logs `Authentication of agent … failed` at INFO for every LDAP-authenticated request (it used to say "No shared secrets configured locally … ignoring").
- Repo config switched to the documented form and `p:usernames`; workarounds for #2–#4 removed from `hub/entrypoint.sh` and `agents.xml`; `agent.ini` agentID is `sa1-sp4-agent`. Fresh hub container from the rebuilt image verified healthy, with LDAP login by `sa1-sp4-agent` resolved to `sp4-agent.localtest`. Browser login at `/secure/` confirmed by Keith 2026-11-03 (expected Jetty page), so the OIDC path is unaffected.

**Done (Phase 4b, 2026-11-03): htpasswd as the "no directory" option.** The validator is the IdP's `HTPasswdCredentialValidator`, exposed in -32 as abstract `shibboleth.sp.HTPasswdValidator` (`p:resource`). The validator chain in `global.xml` is now internal → LDAP → htpasswd, each included only if configured (`AGENT_LDAP_URL`, `AGENT_HTPASSWD`). `sa3-sp4-agent` exists only in `hub/htpasswd/agents.htpasswd` (directory bind mount, gitignored) and is the third entry in the agent's `p:usernames`.
- `agentID=sa3-sp4-agent`: LDAP login fails (no entry), then htpasswd succeeds, and the request completes as `sp4-agent.localtest`.
- Live rotation (`gen-agent-secret.sh --htpasswd sa3-sp4-agent`) with the hub's `StartedAt` unchanged: the new secret authenticates, so the hub re-read the file (the validator tracks `lastModified`).
- Wrong password gives `InvalidCredentials`.
- Hashes: `$apr1$`, `{SHA}`, crypt (`$5$`/`$6$`) via commons-codec; **no bcrypt** (`htpasswd -B`), worth a doc line upstream.
- Cost of mixing sources: an htpasswd-only user pays one failed LDAP bind per uncached authentication, and logs an INFO failure from each earlier validator. Order the chain by where most agents live.
- Relevance to Scott's loader-bean idea: the htpasswd file already is the "day-to-day" flat data (username plus credential); only the username→agent mapping still lives in agents.xml.

**Done (2026-11-03): agents.xml generated from a flat list** (stand-in for Scott's loader bean). `deploy/gen-agents-xml.py` turns `hub/agents/agents.csv` (id, group, allowed ranges, usernames, owner) into Agent beans through per-group templates (`hub/agents/templates/<group>.xml`), writing `hub/agents/generated/agents-generated.xml`. The hub loads it through `shibboleth.sp.AgentResolverResources` (static `agents.xml` + `conditional:` generated file; defining the bean overrides the plugin's default list) from a bind mount, so changes need only a reload.
- Agent loaded from the generated file; `p:allowedAddressRanges` accepts a SpEL list. `sa1` login is OK.
- Adding a row and running `--reload` gave `Initializing with Agents: [sp4-agent.localtest, app2.localtest]` with the hub's `StartedAt` unchanged. Removing it restored one agent.
- Validation catches an unknown group, a bad CIDR, and a username already owned by another agent (exit 2, output untouched). `--check` exits 1 when stale.
- What this says about a real loader: it needs only id, address ranges, usernames and a group/profile reference per agent, plus an owner for governance. Owner is carried only as a comment here, and the hub has no field for it. Uniqueness of usernames across agents is a constraint the loader (or the hub) must enforce. To check quickly, diff the jar contents rather than logging in.

**Scott's third reply (2026-11-03, to the -32 follow-up; full text in `docs/followup-to-scott-2026-11-03.md`):**

| Item | Disposition |
|------|-------------|
| `sp.authn.LDAP.*` prefix on three factory properties | He'll fix it when he copies the properties into the commented `sp.properties`. |
| Internal validator logs INFO "failed" when only `p:usernames` is set | Bug; the internal validator shouldn't log when there is no local secret. He'll fix it. |
| `sp.properties` trust paths point at missing files | Intended, as in the IdP: there's no real default. **`jvmTrust` isn't meant for real use.** Our PoC uses it only because LDAP is plain `ldap://` without StartTLS, so no trust is exercised. |
| No bcrypt in htpasswd | commons-codec lacks it. He asked whether IdP docs claim bcrypt support. Open: check the IdP HTPasswd doc page before pressing further. |
| Loader fields (id, ranges, usernames, group, owner) | Matches his external agent loader work. The hub doesn't need owner. Real loaders also need **issuer** and possibly an **authority override**. |
| Username uniqueness | The bean loader now ignores duplicates (bug fixed that day). External sources must enforce uniqueness themselves; it's already documented. |
| Per-agent metadata | "That's fair." Leaning towards an **LDIF-style flat file, one line per field**, because many fields are lists. Sketch expected by about 2026-11-06; only file loading is left to write. |

**Consequences:** when the loader lands in a nightly, retarget `gen-agents-xml.py` (or replace it) with the LDIF-style format, and add `issuer`/authority columns. Until then the CSV stand-in stays. Expect the next nightly to carry the prefix and logging fixes; `check-hub-nightly.sh` will flag it.

**Clean rebuild against nightly -35 (2026-11-04)** (`sp-dist-0.0.3-20261104.140648-35`, `sp-oidc-dist-…140853-35`, `oidc-common-dist-3.4.0-20261103.012517-322`). `check-hub-nightly.sh` flagged code changes in `agent-authn.xml`, `agents-system.xml`, `sp.properties`, `AgentSecretCredentialValidator`, `DefaultAgentResolver` and a new `FlatFileExternalAgentResolver`. The rebuild lives in a separate repo, `~/devspace/shibSP4clean`: the same Dockerfiles and hub/agent config, but no LDAP and no app, with the agent authenticating as `sa3-sp4-agent` via htpasswd on subnet 172.31.0.0/24. The -32 config works unchanged on -35: agent↔hub remoting OK, and a Google login at `/secure/` put all expected attributes in the session (the `/secure` proxy error is expected without the app). The internal-validator logging fix has landed: with `p:usernames` set it now logs "No shared secrets configured locally … ignoring" instead of INFO "failed". Not yet checked: the `sp.authn.LDAP.*` prefix fix (needs LDAP). This PoC's own image is still -32.

**`FlatFileExternalAgentResolver` in -35 (read from bytecode, tested 2026-11-04 in shibSP4clean).** This is Scott's LDIF-style agent loader. Format, one `field: value` per line, `#` comments, a blank line ends a record:
```
id: sp4-agent.localtest
allowedRange: 172.30.0.20/32      # repeatable
username: sa1-sp4-agent           # repeatable
issuer: <client id>               # optional
authority: https://accounts.google.com   # optional
```
A record without `id:` is ignored. Duplicate ids or usernames are ignored with a WARN, so the first one wins. Lookups go by credential username first, then by agentID. Properties are `p:resource` (required) and `p:reloadInterval` (default 5 minutes; reloads only when the file's lastModified changes). It is wired in through a new list, `shibboleth.sp.ExternalAgentResolvers`, which `agents-system.xml` passes to `DefaultAgentResolver.externalResolvers`. Internally defined agents are checked first. Shared settings (auth method, address ranges, state manager, attribute services, RP overrides, and so on) are set on the resolver bean, not per record.
**Not usable yet in -35:**
1. There is no parent bean for it, so every dependency the `shibboleth.sp.Agent` parent supplies has to be set by hand; without them it fails with `StateManager cannot be null`.
2. Even fully wired, the reload fails: `Cannot convert value of type 'net.shibboleth.sp.impl.FlatFileExternalAgentResolver' to required type 'net.shibboleth.sp.AgentResolver'`. `AbstractExternalAgentResolver` implements `Resolver<Agent,CriteriaSet>` rather than `AgentResolver`, which is what `setExternalResolvers(List<AgentResolver>)` expects.

Probably just unfinished (Scott said only file loading was left). Worth mentioning to him, and retest when a parent bean such as `shibboleth.sp.FlatFileAgentResolver` appears. The format maps 1:1 to `hub/agents/agents.csv` minus `group` and `owner`; `gen-agents-xml.py` can emit it once the resolver works.

**Open:** midPoint (image already local) as the IGA source provisioning the lldap accounts and the flat agent list; the switch to Scott's loader format when it ships; checking the IdP docs for a bcrypt claim. (The htpasswd validator and the generated agent list are done; see above.)

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
- Hub needs IdP 5.2 while campus runs 4.2 — fine for hub host, but OP plugin on a 4.2 IdP should be verified for compatibility with current RP expectations (Phase 0-alt).
- Google as OP: redirect URI must match exactly (discover from first failure); consent screen in *Testing* mode limits logins to listed test users and expires refresh tokens after 7 days (irrelevant here — hub uses no refresh); no logout endpoint; `email` stands in for `eppn`. Hub-side OIDC code tested against Shib OP mostly — Google may surface edge cases (e.g. `iss` without trailing slash, `at_hash`). Treat any such failure as PoC feedback, not blocker.

## Open questions for stakeholders

1. ~~Does the app need tokens or just identity?~~ Resolved: identity via SP v4, plus `client_credentials` tokens for app-as-itself API calls. (If user-delegated tokens ever become a requirement, revisit — SP v4 does not cover that today.)
2. ~~Campus OP or own OP?~~ Resolved 2026-11-01: **Google** as OP for the PoC (author's GCP project); campus OP deferred to Phase 0-alt. Target API = Phase 3b test API; real campus APIs out of scope until the flow is proven.
3. Who owns agent IDs/secrets long term — hub admin or IAM? (Shapes Phase 4.)
4. Interest in offering results to Shib dev list / Scott as early SP4 feedback?
