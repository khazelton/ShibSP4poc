# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# ShibSP4poc

Proof-of-concept of OIDC login for a campus app behind a Shibboleth SP v4 agent registered with an SP v4 Hub, plus the app minting its own tokens to call an API. Built and verified end to end on 2026-11-01 (Phases 0–4 of `docs/poc-outline.md`). Findings were emailed to dev@shibboleth.net the same day; replies are the next input.

## Read first

- `docs/poc-outline.md` — phased plan, what was observed per phase, open items. Start here.
- `docs/sp4-research.md` — digest of the SP4 wiki pages (config keys, versions, defects). Do not re-fetch wiki pages before reading it.
- `docs/dev-list-writeup.md` — the sent findings post; hub 0.0.3 defects #1–#7 with exact config.
- `docs/session-walkthrough-2026-11-01.md` — annotated history of how the stack was built and why.
- `deploy/README.md` — runbook: Google setup, build, first login, Phase 2/3b/4 details.
- `README.md` — original problem statement and TechEx/ACAMP session notes.

## Running the stack

Everything lives in `deploy/` (Docker Compose, fixed subnet 172.30.0.0/24).

```sh
cd deploy
docker compose up -d                     # normal start; images already built
docker compose down                      # stop; named volumes survive
docker compose build hub && docker compose up -d hub            # after hub/ changes
./gen-agents-xml.py --reload             # after editing hub/agents/agents.csv (agent list); validates, regenerates, hot-reloads
./check-hub-nightly.sh                   # newer hub snapshot with real code changes? exit 1 = rebuild with --no-cache
docker compose build app && docker compose up -d --force-recreate app   # after Java/JSP changes
docker compose up -d --no-deps --force-recreate agent           # after agent/conf/ changes (bind-mounted)
curl -sk https://localhost/Shibboleth.sso/Status | grep -o '<RemotingService><OK/>'   # agent↔hub health
docker compose logs -f hub               # IdP/Jetty startup; per-request logs in volume hub-logs (idp-process*.log)
```

Services: `ldap` (lldap, .40, UI 127.0.0.1:17170), `hub` (IdP 5.2.3 + Jetty 12.1 + shibd 0.0.3 snapshot plugins, .10, alias `hub.localtest`, 8080/8443), `agent` (Rocky 9 httpd + `shibboleth-sp-4.0.0beta1`, .20, https://localhost), `app` (Jetty 12, Maven multi-module, .30, agent-only).

URLs: `https://localhost/secure/` (login + headers), `https://localhost/secure/callapi` (service-account token → test API), `https://localhost/Shibboleth.sso/Session`.

Build is Docker-only: no local Maven/Java toolchain is expected. `app/` is built inside its multi-stage Dockerfile; there are no unit tests.

### Secrets (gitignored, must exist before `up`)

- `deploy/.env` — `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` (template `.env.example`).
- `deploy/app/secrets/sa.json` — Google service-account key for Phase 3b.
- `deploy/hub/htpasswd/agents.htpasswd` — flat-file agent credentials (`sa3-sp4-agent`), written by `./gen-agent-secret.sh --htpasswd sa3-sp4-agent`. Optional: if it's missing, the hub skips the htpasswd validator.
- `deploy/agent/conf/shibboleth-sp/agent.pwd` — agent secret; written by `./gen-agent-secret.sh sa1-sp4-agent`, which also sets the lldap password.

If volumes were wiped (`down -v`): `./ldap-seed.sh && ./gen-agent-secret.sh sa1-sp4-agent && docker compose up -d --no-deps --force-recreate agent`.

Never commit or print secrets; redact client IDs, `sub` values and emails when quoting logs.

## Architecture in one paragraph

Browser → agent (`mod_shib4`, `/secure` requires a session) → agent calls hub `sp/session-initiator` over TLS with basic auth (`agentID=sa1-sp4-agent`, one of the `p:usernames` of hub agent `sp4-agent.localtest`; hub validates via the chain internal → `shibboleth.sp.LDAPValidator` (lldap) → `shibboleth.sp.HTPasswdValidator` (flat file)) → hub returns Google authorize URL → browser logs in at Google → redirect URI is the agent's `/Shibboleth.sso/Validate` → agent calls hub `sp/token-consumer` → hub does code exchange, JWKS validation, UserInfo, claim transcoding and attribute filtering → attributes land in the agent session → Apache exports them as `X-Shib-*` headers and proxies to Jetty. Separately, the app signs a JWT-bearer assertion with the service-account key, gets a Google ID token with `aud=API_AUDIENCE`, and the test API at `/api/echo` validates it against Google's JWKS. Diagrams: `docs/diagrams/phase4-ldap-login*.html` (archify; `.sequence.json` is the source).

Hub config applied at container start by `deploy/hub/entrypoint.sh` (sp.properties, oidc.properties, LDAP validator beans in `global.xml`). Static hub files in `deploy/hub/conf/`. Agent beans are generated from `deploy/hub/agents/agents.csv` into a bind-mounted file listed in `shibboleth.sp.AgentResolverResources`, so don't add agents to `conf/agents.xml`. Agent↔hub responses are always HTTP 200; the outcome is `event 1 <Name>` in the DDF body.

## Hub 0.0.3 quirks that shape the config (details in `docs/dev-list-writeup.md`)

- Fixed in nightly 0.0.3-32 (2026-11-03), workarounds removed: validator beans are now visible from root context (documented `global.xml` form used), the LDAP factory has full properties, and `p:usernames` works with external validators. Rolling back to an older image (`sp4-hub:20261102` = -31) would need the old workarounds from git history (before the -32 commit).
- `agentID` *is* the basic-auth username (by design, per Scott). The hub's `p:id` is the agent's identity for logs and audit only.
- SP LDAP properties no longer chain to `idp.authn.LDAP.*` (as of -32); set every `sp.agent.authn.LDAP.*` explicitly. The factory's `startTLSTimeout`/`autoReconnect`/`reconnectTimeout` read `sp.authn.LDAP.*` (inconsistent prefix, reported).
- Stock IdP `attribute-filter.xml` drops `mail`; `deploy/hub/conf/attribute-filter.xml` replaces it.
- Snapshot plugins are resolved at build time (newest tarball with a `.asc`); a rebuild can pick up a newer nightly and change the above. Run `./check-hub-nightly.sh` first.

## Conventions

- Phase findings go in `docs/poc-outline.md`; new wiki facts go in `docs/sp4-research.md`.
- Single-file bind mounts break on inode change: mount directories.
- Commit messages: Conventional Commits, normal prose.
