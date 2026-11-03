# Direct reply to Scott Cantor, and his response

Keith's reply to Scott's 2026-11-02 message on the dev-list write-up, sent directly (not on-list). The IGA product is kept generic until the midPoint demo exists. Scott's response follows; outcomes are recorded in `docs/poc-outline.md` Phase 4.

## Sent (2026-11-02)

> Scott,
>
> Thanks for going through all of it. Glad the LDAP pieces were useful; I understand that the agentID IS the username. I'll treat the hub-side id as a logging name and wait for the usernames fix before retesting rotation across two accounts.
>
> An agent, like other non-person entities, needs what any service account needs: someone accountable for it, credential rotation, and removal when the app is retired. If the hub can consume that information, rather than growing its own registry, the hub side stays small:
>
> - Decoupling the credential from the agent's identity (the bug you mentioned), so the credential can rotate, or two can overlap, without touching the agent definition. I'll watch for that fix.
> - The PoC supports pluggable credential validation, and the current version uses LDAP for that purpose.
> - Agents.xml is easy to generate and I confirmed that the AgentResolverService reload picks up a newly added agent with no restart, so "generate the file and let it reload" works today.
>
> Going forward, I'm interested in exploring an IGA tool approach to provision service accounts with an owner and a rotation policy, the credential delivered to the agent host, and the allow-list generated from it.
>
> Best regards, Keith

## Scott's response (2026-11-03), summarised

- The usernames fix should be in that morning's build; LDAP itself not yet tested by him. (Confirmed fixed in nightly -32.)
- Pluggable credential validation was the crux of his question. At OSU there was no near-term path to it, and broad pushback suggested virtually nobody uses LDAP for service accounts in a coordinated enterprise way. At scale he expects manually issued credentials, as with OpenID deployments. In his view it's a people and process problem, not a tools problem.
- He wants a hybrid "loader" bean: XML defines configuration for a group of agents, and a loader pulls the raw per-agent data from a flat file or LDAP and applies those settings to all of them. Advanced config stays in hub XML as a mostly one-time cost.
