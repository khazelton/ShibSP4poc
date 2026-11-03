Scott,

Thanks for going through all of it. Glad the LDAP pieces were useful; I understand that the agentID IS the username. I'll treat the hub-side id as a logging name and wait for the usernames fix before retesting rotation across two accounts.

On the agent list, I think I gave the wrong impression. I'm not arguing for agents in LDAP. The PoC put only the agent's credential in the directory, which is less than an "I'd like to put X in there" conversation with the LDAP team. Service accounts in AD or LDAP typically already have an owner, a sponsor and an expiry date. The agent list itself stayed a plain allow-list in agents.xml with nothing secret in it.

An agent is a non-person entity, and it needs what any service account needs: someone accountable for it, credential rotation, and removal when the app is retired. If the hub can consume the results of that, rather than growing its own registry, the hub side stays small:

1. Decoupling the credential from the agent's identity (the bug you mentioned), so the credential can rotate, or two can overlap, without touching the agent definition. I'll watch for that fix.

2. Pluggable credential validation, which is already there (LDAP, and presumably htpasswd for anyone without a directory).

3. An agent list that's easy to generate, which agents.xml already is. I confirmed that the AgentResolverService reload picks up a newly added agent with no restart, so "generate the file and let it reload" works today.

I'm interested in exploring an IGA-driven version: a service account provisioned with an owner and a rotation policy, the credential delivered to the agent host, and the allow-list generated from it.

                     Best regards --Keith