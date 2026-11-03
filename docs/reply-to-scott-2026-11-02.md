# Draft reply to Scott Cantor (direct, not on-list)

Status: draft, not sent. Replies to his 2026-11-02 message on the dev-list write-up.
Keep the IGA product generic until the midPoint demo exists.

---

Subject: Re: SP4 hub 0.0.3 — agent credentials in LDAP: findings

Scott,

Thanks for going through all of it. Glad the LDAP pieces were useful, and noted on agentID being the username, period. I'll treat the hub-side id as a logging name and wait for the usernames fix before retesting rotation across two accounts.

On the agent list, I think I gave the wrong impression, so let me narrow it. I'm not arguing for agents in LDAP, and I agree a schema plus a source plugin isn't worth your time for the audience it would have. What the PoC put in the directory was only the agent's *credential*, as an ordinary service account. That's not an "I'd like to put X in there" conversation with the LDAP team. Most campuses already issue service accounts in AD or LDAP, with an owner, a sponsor and an expiry date. The agent list itself stayed a plain allow-list in agents.xml with nothing secret in it.

What I actually care about is governance more than storage. An agent is a non-person entity, and it needs what any service account needs: someone accountable for it, credential rotation, and removal when the app is retired. Campuses that run an IGA tool already do that for service accounts. If the hub can consume the results of that, rather than growing its own registry, the hub side stays small:

1. Credential decoupled from agent identity (the bug you mentioned), so a credential can rotate, or two can overlap, without touching the agent definition.
2. Pluggable credential validation, which is already there (LDAP, and presumably htpasswd for anyone without a directory).
3. An agent list that's easy to generate. agents.xml already is: I confirmed the AgentResolverService reload picks up a newly added agent with no restart, so "generate the file and let it reload" works today.

So from my side there's no new feature request here beyond fixing #1. I'm planning to build the IGA-driven version end to end (service account provisioned with an owner and rotation policy, credential delivered to the agent host, allow-list generated) and will send you what it looks like once it works. That should be a better argument than this paragraph, either way.

Thanks again,
Keith
