# deploy/ — Phase 1 stack on this Mac

Three containers on one Docker network. See `../docs/poc-outline.md` for the why.

| Service | Image | What |
|---------|-------|------|
| `hub`   | `./hub` (IdP 5.2.3 + Jetty 12.1 + shibd core/OIDC snapshot plugins) | OIDC RP toward Google; serves agents at `http://hub:8080/idp/profile/sp/` |
| `agent` | `./agent` (Rocky 9 + httpd 2.4 + `shibboleth-sp-4.0.0beta1`) | `https://localhost`; protects `/secure`, proxies to app |
| `app`   | `./app` (Maven multi-stage → Jetty 12) | `/secure` (JSP + `/callapi` servlet), `/api/echo` test resource server, `/public`; reachable only from the agent |

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

- `./gen-agent-secret.sh <username>` once (and to rotate): writes `agent/conf/shibboleth-sp/agent.pwd` and sets that user's password in lldap (Phase 4 superseded the earlier `AGENT_SECRET` env var; the hub no longer holds the secret).
- hub: `sp.agent.authn.method = basic`; agent bean `sp4-agent.localtest` in `hub/conf/agents.xml` with `allowedAddressRanges=172.30.0.20/32`; TLS on 8443 with a build-time self-signed cert for `hub.localtest`, PEM exported to the `hub-tls` volume at start.
- agent: pinned `172.30.0.20`; `agent.ini` → `https://hub.localtest:8443/…`, `authMethod = basic`, `tlsCAFile=/etc/pki/sp4-hub/hub.crt`, `secretFile=/etc/shibboleth-sp/agent.pwd`.
- Negative tests (wrong secret / wrong IP) — see `docs/poc-outline.md` Phase 2. Responses are HTTP 200 with `event InvalidCredentials` / `AccessDenied` in the body.

## Phase 4 (applied) — agent credentials in LDAP, not in the hub

- `ldap` service (lldap; UI http://127.0.0.1:17170, admin / `LDAP_ADMIN_PASSWORD` or `poc-admin-password`). Accounts from `ldap/bootstrap/user-configs/*.json` via `./ldap-seed.sh`.
- hub: `global.xml` gets `shibboleth.sp.AgentValidators` = `shibboleth.sp.AgentSecretValidator` + `shibboleth.sp.LDAPValidator`, the documented form (`hub/entrypoint.sh`; needs nightly 0.0.3-32 or later). In `agents.xml`, agent `sp4-agent.localtest` lists `p:usernames` `sa1-sp4-agent` and `sa2-sp4-agent`, and has no secret.
- agent: `agentID = sa1-sp4-agent` (one of the hub agent's usernames), `agent.pwd` from `./gen-agent-secret.sh sa1-sp4-agent`.
- Rotate to the other account: `./gen-agent-secret.sh sa2-sp4-agent`, set `agentID = sa2-sp4-agent` in `agent/conf/shibboleth-sp/agent.ini`, then `docker compose up -d --no-deps --force-recreate agent`. The hub is untouched. The LDAP account `sp4-agent` remains as a negative test: it isn't in `p:usernames`, so the hub rejects it with `UnknownUsername`.
- Phase 4b, flat-file credentials (no directory): `sa3-sp4-agent` exists only in `hub/htpasswd/agents.htpasswd` (gitignored, directory bind mount). Issue or rotate it with `./gen-agent-secret.sh --htpasswd sa3-sp4-agent`, set `agentID = sa3-sp4-agent`, then recreate the agent. The hub re-reads the file on change. The validator chain is internal → LDAP → htpasswd, so an htpasswd-only user costs one failed LDAP bind per (uncached) authentication. Hash formats are covered in `hub/htpasswd/README.md`; bcrypt is not supported.
- Agent list: agent beans are generated from `hub/agents/agents.csv` (one row per agent: id, group, allowed ranges, usernames, owner) through per-group XML templates. Edit the CSV, then run `./gen-agents-xml.py --reload`; there's no rebuild or restart. Details are in `hub/agents/README.md`.

## Phase 3b (applied)

- Service-account JSON key at `app/secrets/sa.json` (gitignored, excluded from the build context).
- `https://localhost/secure/callapi`: app signs a JWT-bearer assertion (`target_audience=$API_AUDIENCE`), gets a Google ID token, calls `$API_URL` with it, and shows the API's echoed claims plus a deliberate audience-mismatch 401.
- Env knobs on the `app` service: `SA_KEY_FILE`, `API_AUDIENCE`, `API_URL`.
- Rebuild after Java changes: `docker compose build app && docker compose up -d --force-recreate app`.

## Known gaps to resolve on first run

- `mod_shib4.so` path in `agent/conf/shib4-poc.conf` — check `rpm -ql shibboleth-sp | grep mod_shib4`.
- Attribute env-var names (`mail`, `displayName`, …) depend on the hub's `oidc-claim-rules.xml`; adjust the `RequestHeader set` lines after seeing `/Shibboleth.sso/Session`.
- Hub plugins are nightly snapshots resolved at build time (newest signed tarball). Before rebuilding, run `./check-hub-nightly.sh [image]`: it diffs the newest nightly's jars against the image by per-entry CRC. Exit 0 means no code change, so skip the rebuild; exit 1 means rebuild with `docker compose build --no-cache hub`, after tagging the current image (e.g. `docker tag sp4-hub:dev sp4-hub:$(date +%Y%m%d)`). Entries behind the defects reported to dev@ are flagged `<-- watched`.
- Daily watch: `./hub-nightly-watch.sh install` adds a LaunchAgent (`org.aktis.sp4poc.hub-nightly`, 07:13 local) that runs the check and posts a macOS notification once per new change set. It also notifies after 3 failed runs in a row. Log: `~/Library/Logs/sp4poc-hub-nightly.log`. Use `status` to see the state and `uninstall` to remove it.
