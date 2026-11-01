# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# ShibSP4poc

Proof-of-concept notes and work toward an OAuth2/OIDC login for a campus app behind a Shibboleth SP v4 endpoint registered with the SP v4 Hub.

## Current state

No code yet — no build, lint, or test commands exist. Repo is notes-only:
- `README.md` — problem statement plus raw session notes (TechEx 2026, Scott Cantor's "Scaling Shibboleth 4 SP deployments" talk). Treat it as the source of truth for goals and open questions.
- `docs/sp4-research.md` — digested SP v4 hub/agent/OIDC docs with exact config keys and a page index. Read this before fetching Shibboleth wiki pages again.
- `docs/poc-outline.md` — phased PoC plan and open questions.
- `memory/` — project working notes (empty placeholder).

Update this file with real commands once a toolchain is chosen.

## Problem framing

- **Problem:** an on-campus app wants to accept authentication over OAuth2/OIDC.
- **Context:** campus runs Shibboleth SP v4 on top of Shibboleth IdP v4.2+.
- **Deliverable:** OAuth2/OIDC login for that app, fronted by an SP v4 OAuth2 endpoint registered with the SP v4 Hub.

## SP v4 Hub/Agent model (key concepts from notes)

- SP v4 splits the SP into lightweight **agents** (at each app) and a central **hub**. Agent↔hub transport is plain HTTP(S); "Jetty/http is all you need."
- Agent authentication to the hub: v1 is basic auth over TLS with a client ID + shared secret per agent. Manually provisioning these for ~200 SPs is the core pain point; hub-side authN should handle it better.
- Client ID/secret lifecycle at scale is really an IAM/IGA (service-account management) problem, not a hub-admin job — this is the gap the PoC is meant to explore (possibly via midPoint, Evolveum/Unicon work).
- Hub v1 stores agent records in a flat file; longer term, a delegated model with a simple GUI over a DB, possibly carrying SP "metadata". Think of the hub as a proxy/appliance, **not** as doing federation.

## References

- SP v4 redesign hub page: https://shibboleth.atlassian.net/wiki/spaces/DEV/pages/2981429255/Service+Provider+V4+Redesign
- Original SP4 discussion: https://shibboleth.atlassian.net/wiki/spaces/DEV/pages/1203471357/SP4Details
- Newer design notes: https://shibboleth.atlassian.net/wiki/spaces/DEV/pages/2110391683/DesignNotes
