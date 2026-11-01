# Shibboleth SP v4 research notes

Fetched 2026-11-01 from the Shibboleth Confluence wiki. All SP4/Hub/Agent docs carry a "not yet released / preliminary / not for production" banner. Treat specifics as subject to change; re-check the source page before relying on a property name.

## Status and versions

- Hub = set of plugins installed into a Shibboleth IdP. **IdP V5.2.0+ required** as host. The host IdP need not function as an IdP (entityID/scope prompts ignored). This is a separate install from the campus IdP; the campus IdP (v4.2+) is unaffected.
- Agent prereleases (shibboleth.net/downloads/service-provider/):
  - `4.0.0beta1` ↔ Hub plugin `0.0.3-SNAPSHOT` (current target)
  - `4.0.0alpha2` ↔ `0.0.2-SNAPSHOT`; `4.0.0alpha1` ↔ `0.0.1-SNAPSHOT`
- Hub plugins are nightly snapshots, not tagged. Repos:
  - core: https://build.shibboleth.net/maven/snapshots/net/shibboleth/sp/sp-dist/
  - SAML: https://build.shibboleth.net/maven/snapshots/net/shibboleth/sp/sp-saml-dist/
  - OIDC: https://build.shibboleth.net/maven/snapshots/net/shibboleth/sp/sp-oidc-dist/
  - OIDC common dep: https://build.shibboleth.net/maven/snapshots/net/shibboleth/oidc/oidc-common-dist/3.4.0-SNAPSHOT/
  - nightly table: https://shibboleth.net/cgi-bin/projstatus.cgi
- Source: codeberg.org/Shibboleth/{java-plugin-shibd, java-plugin-shibd-saml, java-plugin-shibd-oidc, cpp-sp (main branch)}.
- RPM package name is `shibboleth-sp` (distinct from 3.x `shibboleth`; can coexist, not meant to run together).
- Agent and SAML further along than OIDC. OIDC gaps as of Oct 2025: token-based claim refresh, RP metadata/keyset endpoints, OIDC Federation, OP-initiated logout, PAR, auditing, dynamic client registration.

## Architecture

- **Agent** (C/C++, `mod_shib4.so` for Apache 2.4; IIS; FastCGI). Stripped down, no XML/crypto deps. Talks only to the hub. `shibd` no longer exists. **No Java/Jetty/Tomcat agent exists**; "new agents may be developed but this is not an initial goal." Java apps sit behind httpd/IIS as reverse proxy.
- **Hub** (Java, IdP plugins, Spring Web Flow). Never talks to user agents directly. Stateless about agents. Protocol-neutral: "invisible to an agent whether SAML, OpenID Connect, or something else is involved."
- Hub config model: `AgentResolver` → **Agent** (id + credentials + issuer) → **Application(s)** (protocol config; agent only sees its ID) → **Authority** (neutral term for SAML IdP or OIDC OP).
- Agent→hub: HTTP 1.1 carrying serialized DDF objects, endpoint `<hub>/idp/profile/sp/`. TLS with static trust anchors (`tlsCAFile`), no metadata-driven trust. **Agent auth = shared secret (HTTP basic) + IP allowlist.** Agents do not support client TLS auth.
- Sessions: filesystem-backed by default on the agent side.
- **OIDC role: hub is RP only.** Consumes OP tokens, maps claims to attributes, hands them to agent. Does not issue tokens; access token not exposed to app ("Maybe" in features table).

## OIDC RP features (v1 per features table)

Yes: auth code flow; OP discovery (`/.well-known/openid-configuration`); JWKS fetch/cache/rollover; `state`, `nonce`, `acr_values`, `max_age`, `prompt`, `login_hint`, `claims`, `resource`; client auth `client_secret_basic`/`_post`/`_jwt`, `private_key_jwt`; ID token validation+decryption; UserInfo (plain/JWT, signed/encrypted); claim mapping; JAR request objects; RP-initiated logout.
No: implicit, hybrid (not planned). v2 planned: DCR, OIDC Federation, PAR, DPoP, JARM, OP-initiated logouts. v3: mTLS, introspection, token exchange, FAPI.

## Hub install

```
# host IdP ≥ 5.2.0, with IdP Jetty plugin
wget https://shibboleth.net/downloads/SHIBBOLETH_SNAPSHOT_PGP_KEYS
idp/bin/plugin.sh --noCheck --truststore SHIBBOLETH_SNAPSHOT_PGP_KEYS -i <sp-dist tar.gz url>
idp/bin/plugin.sh --noCheck --truststore SHIBBOLETH_SNAPSHOT_PGP_KEYS -i <sp-oidc-dist tar.gz url>
# (released form, later: bin/plugin.sh -I net.shibboleth.plugin.shibd[.saml|.oidc])
```

Hub config files (core plugin):
- `conf/sp/sp.properties` — globals: `sp.issuer`, `sp.defaultAuthority`, `sp.agent.authn.method` (`basic`), `sp.agent.authn.allowedAddressRanges` (CIDR list, default loopback), `sp.agent.authn.cached`, `sp.agent.authn.cacheDuration`.
- `conf/sp/agents.xml` — Agent beans, Applications, RP overrides.
- `conf/sp/credentials.xml` — keys/secrets.
- `conf/global.xml` — custom validators under reserved id `shibboleth.sp.AgentValidators`.

Agent bean examples:
```xml
<bean p:id="app1.example.org" parent="shibboleth.sp.Agent"
      p:authenticationMethod="basic"
      p:allowedAddressRanges="192.168.1.0/24"
      p:credentials="#{ {null : '%{custom.secret}'} }"
      p:issuer="https://app1.example.org/sp" />
<!-- multiple service accounts -->
<bean p:id="app2.example.org" parent="shibboleth.sp.Agent"
      p:usernames="#{{ 'SA1-spagent-app2', 'SA2-spagent-app2' }}" ... />
```
`credentials` = Map username→password; `null` key = use bean id as username. `issuer` = SAML entityID or OIDC client_id, hub-controlled.

OIDC plugin adds:
- `conf/sp/oidc.properties` — `sp.oidc.defaultClientSecret`, `sp.oidc.signing.rs.key`, `sp.oidc.signing.es.key`, `sp.oidc.encryption.rsa.key`, `sp.oidc.acceptUnfilteredAttributes` (test bypass for attribute filter).
- `conf/sp/oidc-credentials.xml` — JWK beans; uncomment `shibboleth.oidc.DefaultCredential` (parent `shibboleth.oidc.ClientSecretCredential`) for secret auth. Must be imported in `agents.xml`.
- `conf/sp/oidc-metadata-providers.xml` — default `ProviderHTTPResolver` does dynamic discovery; works unmodified.
- `conf/attributes/oidc-claim-rules.xml` — claim→IdPAttribute transcoding; import into `conf/attributes/default-rules.xml`. `sub` always mapped. ID token + UserInfo merged.
- OIDC.SSO profile auto-enabled for all agents/apps. Auth code flow only. **No DCR — register RP manually at OP** (redirect URIs, keys); OP issues client_id/secret.
- Per-agent OP: `p:authenticatingAuthority="https://op.example.org"`; per-agent client_id: `p:issuer="<client_id>"`.
- Per-OP secret override: `shibboleth.sp.RelyingPartyOverrides` list, `RelyingPartyByName` bean with `c:relyingPartyIds="<op issuer>"`, `OIDC.SSO` profile with `clientCredential`.
- Asymmetric keys: `bin/jwtgen-sp.sh -t RSA -s 2048 -u sig -i defaultRSASign | tail -n +2 > credentials/sp/sp-signing-rs.jwk` (and EC/enc variants). Public keys must be registered at OP by hand; RP JWKS endpoint not yet supported.
- Not documented on OIDCBasics: redirect URI format, scopes, logout config. Check `DefiningRelyingPartyConfiguration` / `AdvancedTopics` or the source.

## Agent install / config

- Supported: Apache 2.4 only; RHEL/Rocky 8/9/10, Amazon Linux 2023 (x86_64, aarch64); Windows (IIS, Apache Lounge). MPM worker/event, not prefork.
- Config dir: `/etc/shibboleth-sp` (RPM) or `/opt/shibboleth-sp/etc/shibboleth-sp`. Files: `agent.ini` (master), `handlers.ini`, `request-map.xml`, `iis-config.ini`.
- `agent.ini` remote hub:
```ini
[remoting]
agentID = SA-shib-hr.example.org
baseURL = https://ssohub.example.org/idp/profile/sp/
authMethod = basic
tlsCAFile = trustlist.pem
#secretSourceType = File
secretFile = agent.pwd
#authCachingCookie = __Host-JSESSIONID
```
Localhost default: `agentID = localhost`, `baseURL = http://127.0.0.1:8080/idp/profile/sp/`, no auth.
- Apache:
```apache
LoadModule shib_module /opt/shibboleth-sp/lib/shibboleth-sp/mod_shib4.so
UseCanonicalName On
<Location /secure>
  AuthType shibboleth
  ShibRequestSetting requireSession 1
  ShibRequestSetting applicationId foo   # optional, default "default"
  Require valid-user
</Location>
```
- Attributes → app: **server/env variables default and recommended**; headers legacy, need `[attribute-mappings]` in `agent.ini` listing every exported attr (`eppn = eppn` → `HTTP_EPPN`). System attrs: `Shib-Application-ID`, `Shib-Session-ID`, `Shib-Session-Expires`, `Shib-Session-Inactivity`.
- Health: `curl -k https://localhost/Shibboleth.sso/Status` (same-host only by default, see `handlers.ini`). Login handler `/Shibboleth.sso/Login`.
- Logs: syslog/journald; Apache gets subset.

## IdP OIDC OP plugin (the OP side)

- Officially supported for IdP ≥ 4.1. v3.0+ current line; v3.1+ adds OAuth2 features (RFC 6750, 7009, 7636, 7662, 8707, 9068, 9101, 9126, 9207). Implements Core, Discovery, DCR, RP-/front-/back-channel logout.
- Docs: https://shibboleth.atlassian.net/wiki/spaces/IDPPLUGINS/pages/1376878976/OIDC+OP; client registration: pages/1376879133 (OPMetadataClientRegistration); config: pages/3167158285 (OIDCConfig); release notes: pages/2776760321.

## Page index

Design (DEV space):
- SP V4 Redesign (parent): https://shibboleth.atlassian.net/wiki/spaces/DEV/pages/2981429255
- SP Service Architecture: .../DEV/pages/2981527576 (DRAFT, Jul 2025)
- Native Agent Design/Dev Plan: .../DEV/pages/3949789185 (Nov 2024)
- New Configuration Summary: .../DEV/pages/4100259844 (Nov 2025)
- OIDC RP Client Features Table: .../DEV/pages/5789155330
- OAuth 2.0 and OIDC State Handling: .../DEV/pages/5230952453 (superseded, context only)
- SP4 Prerelease Testing: .../DEV/pages/5053906948 (Oct 2025) ← start here
- SP4Details (2022) .../DEV/pages/1203471357 and DesignNotes (2024) .../DEV/pages/2110391683 — historical
- OpenIDSupport .../DEV/pages/1120895309 — dead 2010 OpenID 2.0 page, ignore

Hub (sphub1 space, base https://shibboleth.atlassian.net/wiki/spaces/sphub1/pages/):
HubOverview 4573888534 · HubSystemRequirements 4581687337 · Installation 4584505349 · GettingStarted 4591648775 · SecuringAgentConnections 4625989642 · SAMLBasics 4631101456 · OIDCBasics 5076385950 · AgentResolverBasics 4992073732 · DefiningRelyingPartyConfiguration 4825776129 · CredentialResolverBasics 5539168257 · AdvancedTopics 5133467649 · RemotingProtocol 2868281349 · RemoteOperationsReference 3677028369

Agent (spagent4 space, base .../spaces/spagent4/pages/):
AgentSystemRequirements 4520574978 · Installation and Upgrades 4971528195 · GettingStarted 4550492162 · ConnectingToHub 4549935120 · RemotingSettings 4525621249 · Apache 4568875009 · Sessions 4551999489 · AttributeHandling 4727603211 · Logging 4570415174 · ReleaseNotes 4522409985

Not fetchable: `wiki/spaces/SP4` overview and `SP4/pages/4568252432` (ApacheSettings) returned empty bodies. ACAMP Google Doc requires sign-in.

Support: dev list https://shibboleth.net/mailman/listinfo/dev; members via Slack/Jira. IdP Jetty plugin: .../IDPPLUGINS/pages/3910107152.
