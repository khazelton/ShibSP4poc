# Draft post for dev@shibboleth.net

Status: **sent** to dev@shibboleth.net on 2026-11-01 (after Keith's review). Text below is the draft it was based on; everything in it was observed in this repo's `deploy/` stack, and file references point at that stack. Replies and follow-ups: track in `docs/poc-outline.md` Phase 4.

---

**Subject:** SP4 beta1 + Hub 0.0.3 PoC: OIDC login via Google, agent auth via LDAP — what worked, what didn't

Hi all,

Following Scott's ACAMP session on scaling SP4 deployments (and his request for feedback on how sites would issue agent credentials), I built a small end-to-end PoC over the weekend. Summary first, then the defects I hit, then a couple of design questions. Versions and config are exact so this can be reproduced or dismissed quickly.

**Setup**

- Agent: `shibboleth-sp-4.0.0beta1-1.el9.aarch64` on Rocky 9 / Apache 2.4 (event MPM), fronting a Jetty 12 app as a reverse proxy. Attributes exported as env vars, then `RequestHeader set` into `X-Shib-*` headers for the proxy hop.
- Hub: IdP 5.2.3 as plugin host, Jetty plugin 1.0.1 (Jetty 12.1.4), `net.shibboleth.plugin.shibd` 0.0.3-20261101.015656-28, `net.shibboleth.plugin.shibd.oidc` 0.0.3-20261101.015959-28, `net.shibboleth.oidc.common` 3.4.0-20261101.012414-318.
- OP: Google (auth code, `client_secret_basic`, scopes `openid profile email`). Chosen only because it needed no coordination; nothing here depends on it being Google.
- Agent credentials: lldap container as a stand-in directory; hub validates agent basic-auth against it.
- All of it in Docker on an arm64 Mac; three rebuilds a minute, so iteration was fast.

**What worked**

- OIDC end to end on the first attempt once the redirect URI was known: `/secure/` → agent `session-initiator` → Google → `/Shibboleth.sso/Validate` → hub `token-consumer` (code exchange, JWKS from provider metadata, ID token validation, UserInfo call, claim transcoding) → attributes in the agent session → headers in the app. Nothing on the OIDC path needed patching.
- Agent ↔ hub over TLS with basic auth and a per-agent address range. Negative tests give clean, legible events in the DDF body: `InvalidCredentials` (bad secret), `AccessDenied` (source address outside `allowedAddressRanges`).
- Agent credentials moved out of hub config into LDAP via `LDAPCredentialValidator`. Rotation = change the directory password + redeliver the secret file to the agent; the hub process is untouched (verified by container start time). This is the "treat agents as service accounts managed like human identities" model from the ACAMP discussion, and it works — with the caveats in #4/#5 below.

**Defects / surprises (hub 0.0.3 snapshot unless noted)**

1. *Stock IdP attribute-filter.xml silently drops `mail`.* `ExtractOIDCClaims` logged `mapped to attribute IDs: [sub, email_verified, mail, displayName, givenName, sn, picture]`, but `mail` never reached the agent. Cause: the host IdP's default `Per-Attribute-singleValued` policy has a rule for `mail` that releases it only to SAML SPs requesting it via metadata; `sp.oidc.acceptUnfilteredAttributes=true` only admits attributes with *no* rule, so it can't help. Suggest the hub either ship its own filter policy file or document that the IdP's default filter applies to hub attribute release. Same install also logs `ResolutionException: Attribute Definition 'uid': provided principal name was empty` on every login from the stock resolver — cosmetic, but noisy.

2. *Documented `shibboleth.sp.AgentValidators` form fails.* SecuringAgentConnections shows `<ref bean="shibboleth.sp.AgentSecretValidator"/>` and `<bean parent="shibboleth.sp.LDAPValidator"/>` in `conf/global.xml`. On this build the webapp fails to start: `NoSuchBeanDefinitionException: No bean named 'shibboleth.sp.AgentSecretValidator' available`. Those beans are defined in `sp-abstract-beans.xml` (flow scope), which the root context can't see. Workaround: declare the validators by class in `global.xml`:

   ```
   <util:list id="shibboleth.sp.AgentValidators">
     <bean class="net.shibboleth.sp.authn.impl.AgentSecretCredentialValidator" p:id="spagent-internal"/>
     <bean class="net.shibboleth.idp.authn.impl.LDAPCredentialValidator" p:id="spagent-ldap"
           p:authenticator-ref="poc.AgentLDAPAuthenticator"/>
   </util:list>
   ```

3. *SP's `LDAPAuthenticationFactory` bean is out of sync with IdP 5.2.3's factory.* Instantiating `net.shibboleth.idp.authn.config.LDAPAuthenticationFactoryBean` with the property set the SP plugin uses fails with `StartTLS timeout cannot be null or negative`, then `Reconnect timeout cannot be null or negative`. The IdP's own `password-authn-beans.xml` passes `startTLSTimeout`, `autoReconnect` and `reconnectTimeout`; the SP's doesn't. So even if #2 were fixed, `shibboleth.sp.LDAPValidator` would fail against 5.2.3 as shipped.

4. *`p:usernames` cannot work with an external validator.* With the agent bean as `p:id="sp4-agent.localtest" p:usernames="#{{ 'sa1-sp4-agent', 'sa2-sp4-agent' }}"` and the agent presenting `sa1-sp4-agent`, the log shows `spagent-ldap: Login by 'sa1-sp4-agent' succeeded` immediately followed by a non-proceed event (`InvalidCredentials` with both validators listed, `AuthenticationException` with LDAP alone). `ValidateAgentCredentials.buildAuthenticationResult` checks `subject.getPrincipals(UsernamePrincipal.class).contains(new UsernamePrincipal(agent.getId()))` — i.e. the *agent id*, which only the internal validator puts in the Subject. Net effect: with external validation the presented username must equal the agent id, so the identity/credential decoupling described at ACAMP (several service accounts per agent, graceful rotation across them) isn't reachable yet. Workaround I used: agent id = LDAP uid = `agent.ini agentID`. Suggest `buildAuthenticationResult` accept any principal in `agent.getUsernames()` (or stamp the agent id principal itself after a successful external validation).

5. *Agent has no username setting independent of `agentID`.* RemotingSettings confirms `agentID` is "the 'username' used by the Agent when connecting to the Hub"; there's no `secretUsername`-style knob. Fine if #4 is fixed hub-side, but worth stating in the docs since the ACAMP conversation implied agents could present different credentials over time.

6. *IdP installer ignored `idp.host.name` for the Jetty keystore under Docker.* `credentials/idp-userfacing.p12` came out as `CN=172.17.0.2` (the build container's address) despite `idp.host.name=hub.localtest` in the property file. Possibly my invocation (`--propertyFile … --noPrompt`), possibly an installer quirk; mentioning in case others hit the same when containerising the hub. I regenerated the keystore with openssl.

7. *Doc gaps that cost time (small):* the OIDC redirect URI format isn't written down anywhere I could find — it's the agent's TokenConsumer handler, `https://<agent>/Shibboleth.sso/Validate`; `sp.oidc.scopes` takes the lowercase scope names (the `# e.g. PROFILE or EMAIL` comment reads like enum constants); agent→hub responses are always HTTP 200 with the outcome in the DDF body, which is worth a sentence in the agent docs since a naive health check on status codes sees nothing.

**Two design questions, since Scott asked**

- *Agent list format.* The thing that made the LDAP model pleasant was that `agents.xml` became trivial — id, address range, authentication method, nothing secret. If the v1 flat file is "AgentID + optional credential" and the directory holds the credential, then the flat file is really just an allow-list, and generating it from the directory (or from an IGA tool that owns the service accounts) is a few lines. I'd rather see that than a hub-side database with a GUI, at least to start.
- *Who owns the username.* Right now the identity the hub logs (`p:id`) and the identity the agent presents (`agentID`) are the same string in practice (#4/#5). If the intent is that they diverge — service account rotates, agent identity doesn't — it would help to say so explicitly in the model, because the current code enforces the opposite.

Happy to share the compose stack (three containers plus lldap, ~15 files) if useful; it reproduces everything above in a couple of minutes on a laptop.

Keith Hazelton

---

*Notes for the sender:* numbers in #2–#4 refer to the 20261101 nightlies; re-check `plugin.sh -l` before posting if the snapshots moved. Google client/service-account details intentionally omitted. If asked for the stack, `sync2github` the repo (secrets are gitignored: `deploy/.env`, `deploy/app/secrets/`, `agent.pwd`).
