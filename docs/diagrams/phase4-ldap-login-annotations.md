# Phase 4 login swimlanes: annotated addendum

Companion to the two-page sequence diagram:

- `phase4-ldap-login-1of2.html` (source `phase4-ldap-login-1of2.sequence.json`): login start and Google authentication, arrows m01–m08.
- `phase4-ldap-login-2of2.html` (source `phase4-ldap-login-2of2.sequence.json`): code exchange, claims and the protected request, arrows m09–m21.

For each arrow, this note gives the protocol, what the message carries, and what it means. The arrows are listed in the diagrams' order.

**Provenance.** The diagrams were drawn on 2026-11-01 against hub nightly 0.0.3-20261101 and regenerated on 2026-11-04 for nightly 0.0.3-35. This addendum was written on 2026-11-03 against nightly 0.0.3-32, rechecked against the -35 login of 2026-11-04 (00:12 UTC on 2026-11-05), and first checked against the live stack using:
- the hub's DEBUG log for a full login at 16:06 UTC;
- a fresh `curl` of the login redirect;
- the config in `deploy/`.

Where the running system differed from the original labels, the arrow's entry says so; the diagrams were relabelled the same day. See also "What changed since the diagrams were drawn" at the end. Client IDs, `sub` values, authorization codes, the `hd` value and cookie values are redacted or left out.

## Cast and channels

| Lane | What it is | Network identity |
|------|------------|------------------|
| Browser | The user's browser | Host machine, reaches `https://localhost` (agent) and Google |
| Agent | Rocky 9 Apache 2.4 + `mod_shib4` (SP 4.0.0beta1) | `172.30.0.20`, published as `https://localhost` |
| Hub | IdP 5.2.3 on Jetty 12.1, plus the SP hub plugins (`sp-dist`/`sp-oidc-dist` 0.0.3, `oidc-common` 3.4.0) | `172.30.0.10`, `hub.localtest`, TLS on 8443 |
| Google OP | `accounts.google.com` and its token, JWKS and UserInfo endpoints | Internet |
| LDAP | lldap, the directory of agent service accounts | `172.30.0.40:3890`, plain LDAP |
| App | Jetty 12, the protected application | `app:8081`, reachable only from the agent |

The diagram uses four distinct channels:

1. **Front channel (browser ↔ agent, browser ↔ Google):** HTTPS with redirects. Everything here passes through the user's browser and can be seen or altered by it.
2. **Remoting channel (agent → hub):** HTTP/1.1 over TLS to `https://hub.localtest:8443/idp/profile/sp/<operation>`.
   - The agent trusts a single PEM file (`tlsCAFile = /etc/pki/sp4-hub/hub.crt`), not metadata or a public CA. The certificate's SAN must match `hub.localtest`.
   - The agent authenticates with HTTP basic. The username is `agentID` from `agent.ini`, and the password comes from `agent.pwd`.
   - The body is a serialized DDF object (the SP's own structured-data format), and the response body is DDF text too.
   - The response status is **always HTTP 200**. Success or failure is in the body, for example `event 1 InvalidCredentials`.
3. **Back channel (hub → Google):** HTTPS from the hub to Google's endpoints. The browser is not involved.
4. **Credential check (hub → LDAP):** an LDAP simple bind over plain `ldap://` (no StartTLS). This is fine inside one Docker network; in production it would need LDAPS or StartTLS with a real trust store. Scott notes that `jvmTrust` is not meant for real use.

The agent never sees OIDC: it can't tell which protocol the hub speaks to the authority. The browser never talks to the hub.

---

## Page 1: login start and Google authentication

### m01 Browser → Agent: `GET /secure/` (no session)

- **Protocol:** HTTPS GET to `https://localhost/secure/`.
- **Contents:** an ordinary page request. There is no `__Host-shibsession…` cookie because the user has no agent session yet.
- **Semantics:**
  - Apache maps `/secure` to `AuthType shibboleth`, `ShibRequestSetting requireSession 1` and `Require shib-session` (`deploy/agent/conf/httpd/shib4-poc.conf`).
  - With no valid session, `mod_shib4` starts a login through its `SessionInitiator` handler (`handlers.ini [Login]`) instead of proxying to the app.
  - The requested URL becomes the target to return to after login.

### m02 Agent → Hub: `POST sp/session-initiator` (TLS 8443, basic auth)

- **Protocol:** remoting channel. `POST https://hub.localtest:8443/idp/profile/sp/session-initiator`, with `Authorization: Basic` (username `agentID`).
- **Contents:**
  - A DDF request for the `session-initiator` operation, with a transaction ID (e.g. `7c52dd93165b9a40` in the logged run).
  - The browser's request, **tunnelled**: the hub logs `Wrapping tunnelled HTTP request`. It has the URL, headers and cookies the hub needs to act as if it had seen the browser itself.
- **Semantics:** the hub first identifies and authenticates the agent. As of nightly -32, the steps run in this order:
  1. Resolve the agent **from the presented username**. `sa1-sp4-agent` is one of the `p:usernames` of agent `sp4-agent.localtest` in `conf/sp/generated/agents-generated.xml`. A username not on any agent's list is rejected here with `UnknownUsername`, before any password check.
  2. **Check the source address** (`ValidateAgentAddress`). `172.30.0.20` must fall in the agent's `p:allowedAddressRanges` (`172.30.0.20/32`); otherwise the result is `AccessDenied`.
  3. **Check the credential** through the `shibboleth.sp.AgentValidators` chain in `conf/global.xml`, which is internal → LDAP → htpasswd. The first validator to succeed wins.
     - The internal validator has no local secret for this agent, so it declines. As of -35 it logs DEBUG `No shared secrets configured locally …`. In -32 it logged a spurious INFO `Authentication of agent … failed`, which Scott acknowledged as a bug.
     - The LDAP validator is next (m03).

  If the hub had cached the agent's authentication (see the `cached_auth` note under m11), it would skip step 3. The hub log shows `No session record … full authentication will proceed` on every call, so in practice every remoting call is fully authenticated.
- **Label drift (fixed in the relabelled diagram):** the original label said `basic sp4-agent`. Since -32 the agent presents `sa1-sp4-agent`, which the hub maps to agent id `sp4-agent.localtest`.

### m03 Hub → LDAP: `bind uid=…,ou=people,dc=localtest`

- **Protocol:** LDAP v3 simple bind over plain TCP to `ldap://ldap:3890`.
- **Contents:**
  - Bind DN built from `sp.agent.authn.LDAP.dnFormat` = `uid=%s,ou=people,dc=localtest`, with the presented username substituted. Today that's `uid=sa1-sp4-agent,…`; the original diagram showed `uid=sp4-agent,…`.
  - Password: the basic-auth password the agent sent.
- **Semantics:**
  - The IdP's stock `LDAPCredentialValidator`, configured as a `directAuthenticator`, is reused as an agent validator. A successful bind is the whole test: no search and no attributes.
  - The directory holds only the credential. There is no agent metadata, ranges or application config there.
  - Rotation is `gen-agent-secret.sh <username>`: it sets the new password in LDAP and in the agent's `agent.pwd`, and the hub is never restarted.

### m04 LDAP → Hub: bind OK → `spagent-ldap` succeeded

- **Protocol:** LDAP BindResponse, resultCode 0 (success). A wrong password returns resultCode 49 (invalidCredentials).
- **Contents:** nothing beyond the result code.
- **Semantics:**
  - The hub logs `Credential Validator spagent-ldap: Login by 'sa1-sp4-agent' succeeded`, and the agent is authenticated as `sp4-agent.localtest`.
  - The hub then decodes the DDF operation and maps the request to an Application (`ResolveApplication` → `default`).
  - On failure the chain moves on to the htpasswd validator. For `sa3-sp4-agent`, which exists only in the htpasswd file, that's where it succeeds. If every validator fails, the agent gets `InvalidCredentials`, still with HTTP 200.

### Implicit arrow, not drawn: Hub → Google `GET /.well-known/openid-configuration`

- **Protocol:** HTTPS GET, back channel.
- **Semantics:**
  - Before building the authorize request, the hub resolves the authority `https://accounts.google.com` (from `sp.defaultAuthority`) to provider metadata through OIDC discovery.
  - The metadata gives the authorize, token, UserInfo and JWKS endpoint URLs and the supported features. It is cached; the logged run had a cache miss and fetched it on this request.
  - The OP is configured purely by this lookup. There is no static OP metadata file.

### m05 Hub → Agent: authorize URL + sealed state (DDF, HTTP 200)

- **Protocol:** HTTP 200 response on the remoting channel; DDF body.
- **Contents:** in effect, instructions for the agent to send the browser back. Specifically:
  - A redirect to Google's authorize endpoint, with the query string built by the hub (see m06).
  - A cookie for the agent to set, carrying **sealed state**:
    - The hub creates `AuthenticationRequestStateData`: the issuer (our client ID), the authority, the request time, and enough context to validate the response later (such as the nonce and the original target).
    - It **seals** that data (`State data will be sealed before preservation`), i.e. encrypts it with a hub-held key, so the browser can carry it but can neither read nor alter it.
    - The token it is preserved under has the form `<epoch-ms>_<32 hex>`, e.g. `1793721991635_…`.
- **Semantics:**
  - The hub keeps **no per-login server-side state**. The state goes out with the browser and comes back with it, which is how the hub stays "stateless about agents".
  - The hub writes an audit line under `Shibboleth-Audit.SP.SessionInitiator.OIDC`.

### m06 Agent → Browser: `302` → Google authorize

- **Protocol:** HTTP 302 on the front channel. Observed with `curl` on 2026-11-03.
- **Contents:**
  - `Set-Cookie: __Host-shibsp_state_default_<token>=<sealed state, about 400 chars>; HttpOnly; Max-Age=1800; Path=/; SameSite=None; Secure`. The cookie name includes the Application id (`default`) and the state token.
  - `Location: https://accounts.google.com/o/oauth2/v2/auth?` with these parameters:
    - `client_id` = our Google OAuth client, from `sp.issuer`;
    - `response_type=code` (authorization code flow);
    - `scope=openid profile email` (`sp.oidc.scopes` = `profile,email`, with `openid` added);
    - `response_mode=query` (code returned in the query string);
    - `redirect_uri=https://localhost/Shibboleth.sso/Validate`, the agent's `TokenConsumer` handler, registered at Google;
    - `state=<token>`, the same `<epoch-ms>_<hex>` string as the cookie-name suffix;
    - `nonce=<16 chars>`.
  - `Cache-control: private,no-store,no-cache`.
- **Semantics:**
  - `state` binds Google's eventual response to this browser. Only a browser holding the matching `__Host-shibsp_state_…` cookie can complete the login, which defends against CSRF and login injection.
  - `nonce` binds the ID token to this request, defending against replay.
  - **No PKCE**: there is no `code_challenge`. The confidential client authenticates at the token endpoint instead (m13).
  - The cookie lives 30 minutes; a login abandoned for longer has to restart.
  - `SameSite=None` lets the cookie survive the cross-site return from Google.

### m07 Browser ↔ Google: login / silent SSO

- **Protocol:** HTTPS between the browser and Google's login UI.
- **Contents:** Google's own business: the account chooser, password and second factor, consent for `profile email` on first use, and Google's session cookies.
- **Semantics:**
  - Outside the PoC's control and visibility.
  - If the user already has a Google session and has consented, this collapses to an immediate redirect ("silent SSO").
  - The hub sent no `prompt`, `max_age`, `acr_values` or `login_hint`, so Google applies its defaults.

### m08 Google → Browser: `302` → `https://localhost/Shibboleth.sso/Validate?code&state`

- **Protocol:** HTTP 302 on the front channel (`response_mode=query`).
- **Contents:**
  - `code`: a short-lived, single-use authorization code.
  - `state`: echoed unchanged.
  - Google appends informational parameters such as the granted `scope`.
- **Semantics:**
  - The redirect URI is the **agent**, not the hub, because the browser can't reach the hub. This is the one OIDC detail the hub docs don't state.
  - The code alone is useless without the client secret, which only the hub holds.

---

## Page 2: code exchange, claims and the protected request

### m09 Browser → Agent: `GET /Shibboleth.sso/Validate?code&state`

- **Protocol:** HTTPS GET on the front channel.
- **Contents:**
  - The `code` and `state` query parameters.
  - The browser automatically includes the `__Host-shibsp_state_default_<token>` cookie set in m06.
- **Semantics:**
  - `/Shibboleth.sso` is the agent's handler space. It is open in Apache (`AuthType None`, `Require all granted`) so the handlers can run before any session exists.
  - `[Validate] type = TokenConsumer` claims this request. Like m01, the agent does no protocol work itself; it forwards to the hub.

### m10 Agent → Hub: `POST sp/token-consumer` (basic auth)

- **Protocol:** remoting channel, `POST …/idp/profile/sp/token-consumer`, with basic auth.
- **Contents:** a DDF `token-consumer` operation with a new transaction ID (e.g. `bc0b3f461af80c9f`). It carries the tunnelled browser request, including the query (`code`, `state`) and the state cookie.
- **Semantics:**
  - Agent authentication runs again from scratch: resolve from the username, check the address, run the validator chain.
  - The hub picks the token-consumer flow `oidc/code/query`.
  - It finds the state token in `state`, takes the matching cookie, and **unwraps the sealed state** (`Unwrapping sealed state data after recovery from token …`).
  - A missing, expired or tampered cookie, or a `state` that matches no cookie, ends the flow here.
  - The hub then checks that Google signalled success (`ValidateAuthenticationResponseResult`).
- **Label drift (fixed):** as in m02, the username is now `sa1-sp4-agent`.

### m11 Hub → LDAP: bind (no cached auth)

- **Protocol and contents:** same as m03.
- **Semantics:**
  - The second login hop pays for a second LDAP bind.
  - The hub can cache agent authentication: the response carries a `cached_auth` token, and `sp.agent.authn.cached`/`cacheDuration` control it. But the hub found no session record for the agent here (`ValidateCachedAuthentication: No session record …`), so it authenticated in full.
  - Cost per login: at least two binds, plus one per later remoting call. For an htpasswd-only username, each call also costs one failed LDAP bind before the htpasswd validator is reached. Order the chain by where most agents' credentials live.

### m12 LDAP → Hub: bind OK

- As m04.

### m13 Hub → Google: `POST /token` (code, `client_secret_basic`)

- **Protocol:** HTTPS POST, back channel, to the token endpoint from discovery (`https://oauth2.googleapis.com/token`).
- **Contents:**
  - Form body: `grant_type=authorization_code`, `code`, `redirect_uri` (must match m06 exactly).
  - `Authorization: Basic base64(client_id:client_secret)`. The method is `client_secret_basic`. The secret is `sp.oidc.defaultClientSecret`, wired up through `shibboleth.oidc.DefaultCredential` in `conf/sp/oidc-credentials.xml`.
  - No `code_verifier` (no PKCE).
- **Semantics:**
  - Proves to Google that the party redeeming the code is the registered confidential client.
  - The browser and the agent never see the client secret; it exists only in the hub's config.
  - The codes are single-use, so replaying m09 fails at Google.

### m14 Google → Hub: `id_token` + `access_token` (RS256, checked via JWKS)

- **Protocol:** HTTP 200, JSON token response.
- **Contents:**
  - `id_token`: a JWS-signed JWT, RS256, with a `kid` header. Its claims include `iss`, `aud` (= client ID), `sub`, `exp`/`iat` and `nonce`, plus identity claims from the granted scopes.
  - `access_token`, `expires_in`, `token_type=Bearer`, `scope`.
  - A refresh token only if offline access had been requested, which it wasn't.
- **Semantics:** the hub validates the ID token before trusting anything in it.
  1. **Decryption check:** the token isn't encrypted (`JWT was not encrypted`), as expected, since no encryption keys are configured.
  2. **Signature:**
     - The token carries no keys usable for trust. The hub resolves Google's JWKS from the provider metadata (`https://www.googleapis.com/oauth2/v3/certs`); that is an implicit hub → Google GET, cached after the first fetch.
     - It then verifies RS256 with the key matching `kid` (`Verified JWT using algorithm RS256 and key …`).
  3. **Claims** (`DefaultIDTokenClaimsValidator`): issuer, audience, expiry and issue time, and the nonce against the value in the sealed state.

### m15 Hub → Google: `GET /v1/userinfo` (Bearer access token)

- **Protocol:** HTTPS GET, back channel. `GET https://openidconnect.googleapis.com/v1/userinfo` with `Authorization: Bearer <access_token>`.
- **Semantics:**
  - Fetches the profile claims the ID token may not contain.
  - The hub validates the UserInfo response (`ValidateUserInfoJSONObjectClaims`). Its `sub` must match the ID token's, so one account's profile can't be grafted onto another's login.

### m16 Google → Hub: claims

- **Protocol:** HTTP 200, JSON (unsigned; trusted because it came over TLS from the discovered endpoint, using our token).
- **Contents:** `sub`, `email`, `email_verified`, `name`, `given_name`, `family_name`, `picture` and `hd` (the hosted domain for Workspace accounts). The diagram leaves out `email_verified` here.
- **Semantics:** the hub merges ID-token and UserInfo claims, then **transcodes** them into IdP attributes using the rules in `conf/attributes/oidc-claim-rules.xml` (`ExtractOIDCClaims`):

  | Claim | Attribute |
  |-------|-----------|
  | `email` | `mail` |
  | `name` | `displayName` |
  | `given_name` | `givenName` |
  | `family_name` | `sn` |
  | `sub` | `sub` |
  | `email_verified` | `email_verified` |
  | `picture` | `picture` |
  | `hd` | not mapped |

  - `sub` and `hd` both log "No transcoding rule". `sub` is carried anyway, because the plugin always maps it. `hd` is dropped: add a rule if you want to gate on the domain.
  - Logged result: `mapped to attribute IDs: [sub, email_verified, mail, displayName, givenName, sn, picture]`.

### m17 Hub → Agent: attributes + session data (after filtering)

- **Protocol:** HTTP 200 response to m10; DDF body.
- **Contents:**
  - The attributes that survive the hub's **attribute filter**. That is the host IdP's `AttributeFilterService` running `deploy/hub/conf/attribute-filter.xml`, which releases all seven attributes above to every Application. The original diagram listed only the five the app uses.
  - Session data: the hub logs `Storing id_token, access and refresh tokens in session data`.
  - The original target URL, recovered from the sealed state.
- **Semantics:**
  - This is where attribute release policy is enforced. The stock IdP filter silently dropped `mail`, because it releases `mail` only to SAML SPs whose metadata asks for it. `sp.oidc.acceptUnfilteredAttributes=true` doesn't help, because it only admits attributes that have no rule at all.
  - The resolver (`attribute-resolver.xml`) is deliberately empty, so the stock `uid` definition can't throw on every login.
  - The hub writes an audit line under `Shibboleth-Audit.SP.TokenConsumer.OIDC`.
  - From here on the hub is out of the picture until the session expires.

### m18 Agent → Browser: `302` → `/secure/` + session cookie

- **Protocol:** HTTP 302 on the front channel.
- **Contents:**
  - `Location:` the original target, `/secure/`.
  - `Set-Cookie:` the agent session cookie. The diagram labels it `__Host-shibsession…`; the exact name was not re-checked for this note.
- **Semantics:**
  - The agent creates a session in its own filesystem cache (`[session-cache] type = filesystem`, `/var/cache/shibboleth-sp`) holding the attributes and session data.
  - The cookie is only a reference to that session.
  - The state cookie has done its job; it expires after its 30-minute `Max-Age` regardless.

### m19 Browser → Agent: `GET /secure/` (session cookie)

- **Protocol:** HTTPS GET on the front channel, now carrying the session cookie.
- **Semantics:**
  - `mod_shib4` finds a valid local session, so `Require shib-session` is satisfied with **no hub call**.
  - It exports the session's attributes as request environment variables: `sub`, `mail`, `displayName`, `givenName`, `sn`, `Shib-Session-ID`, `Shib-Application-ID`.

### m20 Agent → App: `ProxyPass` → `:8081` with `X-Shib-*` headers

- **Protocol:** plain HTTP inside the Docker network, from `ProxyPass /secure http://app:8081/secure`, with `ProxyPreserveHost On`.
- **Contents:** the original request plus headers built from the environment variables:
  - `X-Shib-Sub`, `X-Shib-Mail`, `X-Shib-DisplayName`, `X-Shib-GivenName`, `X-Shib-Sn`;
  - `X-Shib-Session-Id`, `X-Shib-Application-Id`;
  - `X-Remote-User`.
- **Semantics:**
  - The app trusts these headers because only the agent can reach it: Jetty's port isn't published.
  - **Anti-spoofing:** the vhost first runs `RequestHeader unset` on every one of these names, so a browser can't inject its own `X-Shib-Mail`. Any header-based integration needs this step.
  - `X-Remote-User` is currently empty because no attribute is mapped to `REMOTE_USER`; that's an open item.
  - The app never receives the OIDC tokens. They stay in the agent session (from m17).

### m21 App → Browser: `200` identity page

- **Protocol:** HTTP 200 from Jetty, **relayed back through the agent's reverse proxy** (`ProxyPassReverse`) over HTTPS. The diagram draws a direct arrow for brevity, but there is no direct path from the app to the browser.
- **Contents:** the `/secure/` JSP, which echoes the `X-Shib-*` headers it received.
- **Semantics:** this is the end-to-end success check that "browser login confirmed" refers to in `docs/poc-outline.md`.

---

## Negative paths (not drawn)

All of these return HTTP 200 on the remoting channel, with the outcome in the DDF body. The agent shows the user an error page.

| Where | Cause | Outcome |
|-------|-------|---------|
| m02/m10 | Username not in any agent's `p:usernames` | `UnknownUsername`; no password check |
| m02/m10 | Source address outside `allowedAddressRanges` | `AccessDenied` |
| m03/m11 | Wrong password in LDAP and in htpasswd | `InvalidCredentials` |
| m02/m10 | Empty or garbled body | `InvalidMessage` |
| m10 | State cookie missing or expired (over 30 min), or `state` doesn't match a cookie | Flow ends at state recovery |
| m14 | Bad signature, wrong `aud`/`iss`, expired token, nonce mismatch | Flow ends at ID-token validation |

## What changed since the diagrams were drawn

The diagrams were first drawn for the hub 0.0.3-20261101 setup. As of nightly -32 (2026-11-03):

- **Username vs. agent id:**
  - The agent presents `agentID = sa1-sp4-agent`; the labels show `sp4-agent`.
  - The hub agent's id is `sp4-agent.localtest`, with `p:usernames` sa1/sa2 (LDAP) and sa3 (htpasswd).
  - The page 2 card's statement that the "presented username must equal the agent id" is obsolete: `p:usernames` now works with external validators.
- **Validator chain:** internal → LDAP → htpasswd, declared in the documented `global.xml` form (`<ref bean="shibboleth.sp.AgentSecretValidator"/>`, `<bean parent="shibboleth.sp.LDAPValidator"/>`, `<bean parent="shibboleth.sp.HTPasswdValidator" p:resource=…/>`). The class-based workaround is gone.
- **Where agent definitions come from:**
  - The agent bean is generated from `deploy/hub/agents/agents.csv` by `deploy/gen-agents-xml.py`.
  - It loads alongside the static `agents.xml` through `shibboleth.sp.AgentResolverResources`, and reloads without a restart.
  - Scott's loader (an LDIF-style flat file, expected around 2026-11-06) will probably replace this.
- **Order of checks:** the agent is resolved from the username, and its address is checked, before any credential validator runs.

**Diagrams relabelled 2026-11-03:**
- m02, m10: `basic sa1-sp4-agent`;
- m03, m11: `bind uid=sa1-sp4-agent…`;
- m05, m06, m09: show the sealed-state cookie;
- m17: lists all seven attributes;
- both titles: marked "hub 0.0.3-32";
- the page 1 card and the page 2 card's third bullet: describe username-based agent resolution and the internal → LDAP → htpasswd chain.

The per-arrow notes above still mention the old labels, so they read correctly against either version.

**Regenerated 2026-11-04 for nightly -35:**
- The hub-side arrows (m02–m17) were checked against the hub log of a full Google login: one LDAP bind per remoting call (m03, m11), sealed state preserved and recovered, code exchange, RS256 verification, UserInfo, and the same seven mapped attributes (m16). The login itself succeeded in the browser; the agent-to-app arrows (m18–m21) weren't logged separately.
- The flow didn't change, so only the two titles did (now "hub 0.0.3-35").
- The internal validator's false INFO line is gone (see m02).
- The LDAP factory now reads `startTLSTimeout`, `autoReconnect` and `reconnectTimeout` from `sp.agent.authn.LDAP.*`. This doesn't affect any arrow.
- The session cookie name in m18 still wasn't checked, because curl can't complete a Google login.
