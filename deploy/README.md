# deploy/ — Phase 1 stack on this Mac

Three containers on one Docker network. See `../docs/poc-outline.md` for the why.

| Service | Image | What |
|---------|-------|------|
| `hub`   | `./hub` (IdP 5.2.3 + Jetty 12.1 + shibd core/OIDC snapshot plugins) | OIDC RP toward Google; serves agents at `http://hub:8080/idp/profile/sp/` |
| `agent` | `./agent` (Rocky 9 + httpd 2.4 + `shibboleth-sp-4.0.0beta1`) | `https://localhost`; protects `/secure`, proxies to app |
| `app`   | `jetty:12-jdk17` | JSP pages under `app/webapps`; reachable only from the agent |

## 0. Google (Phase 0)

1. GCP Console → APIs & Services → OAuth consent screen: External, Testing, add your Google account as a test user.
2. Credentials → Create OAuth client ID → Web application. Leave redirect URIs empty for now.
3. `cp .env.example .env`, fill in `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`.
4. (Phase 3b) IAM → Service accounts → create one, download JSON key → `app/secrets/sa.json`.

## 1. Build and start

```sh
cd deploy
docker compose build          # hub takes several minutes (IdP install + Jetty + plugins)
docker compose up -d
docker compose logs -f hub    # wait for Jetty "Started" and no AgentResolverService errors
curl -k https://localhost/Shibboleth.sso/Status   # agent ↔ hub health
```

## 2. First login

Redirect URI is now known (discovered from the agent's 302): register
**`https://localhost/Shibboleth.sso/Validate`** as an *Authorized redirect URI* on the Google OAuth client.

Browse to `https://localhost/secure/` (accept the self-signed cert) → Google login → back to `/secure/` → Jetty page lists `X-Shib-*` headers. `https://localhost/Shibboleth.sso/Session` shows the agent's view of the session and attribute names.

## 3. Where things live inside the containers

- hub: `/opt/shibboleth-idp/conf/sp/{sp.properties,agents.xml,oidc.properties,oidc-credentials.xml}`, logs in `/opt/shibboleth-idp/logs/` (volume `hub-logs`). `hub/entrypoint.sh` applies the PoC settings on every start.
- agent: `/etc/shibboleth-sp/agent.ini` (bind-mounted from `agent/conf/`), httpd conf `/etc/httpd/conf.d/shib4-poc.conf` (bind-mounted). Agent logs → journal/syslog inside the container; `docker compose logs agent` shows httpd only.
- app: `/var/lib/jetty/webapps/{secure,public}`.

## Phase 2 (applied)

- `./gen-agent-secret.sh` once (and to rotate): writes `AGENT_SECRET` to `.env` (hub) and `agent/conf/shibboleth-sp/agent.pwd` (agent).
- hub: `sp.agent.authn.method = basic`; agent bean `sp4-agent.localtest` in `hub/conf/agents.xml` with `allowedAddressRanges=172.30.0.20/32`; TLS on 8443 with a build-time self-signed cert for `hub.localtest`, PEM exported to the `hub-tls` volume at start.
- agent: pinned `172.30.0.20`; `agent.ini` → `https://hub.localtest:8443/…`, `authMethod = basic`, `tlsCAFile=/etc/pki/sp4-hub/hub.crt`, `secretFile=/etc/shibboleth-sp/agent.pwd`.
- Negative tests (wrong secret / wrong IP) — see `docs/poc-outline.md` Phase 2. Responses are HTTP 200 with `event InvalidCredentials` / `AccessDenied` in the body.

## Known gaps to resolve on first run

- `mod_shib4.so` path in `agent/conf/shib4-poc.conf` — check `rpm -ql shibboleth-sp | grep mod_shib4`.
- Attribute env-var names (`mail`, `displayName`, …) depend on the hub's `oidc-claim-rules.xml`; adjust the `RequestHeader set` lines after seeing `/Shibboleth.sso/Session`.
- Snapshot tarball names in `hub/Dockerfile` ARGs go stale daily; refresh the URLs if the build 404s.
