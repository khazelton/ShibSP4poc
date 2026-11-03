# Follow-up to Scott Cantor (direct), and his response

Keith's follow-up after verifying nightly -32, sent directly to Scott on 2026-11-03 at 11:44. The IGA product is kept generic. Scott replied at 11:59, with a short addendum after. Outcomes are recorded in `docs/poc-outline.md` Phase 4.

## Sent (2026-11-03)

Scott,

The 2026-11-03 nightly (0.0.3-32) fixed everything on my side:

- The documented AgentValidators form in global.xml (ref to AgentSecretValidator, parent LDAPValidator) now starts and authenticates. I've dropped my class-based workaround.
- The LDAP factory starts without the timeout and reconnect properties I'd had to add myself.
- p:usernames works with LDAP. Agent id sp4-agent.localtest, usernames sa1/sa2 in LDAP: the agent authenticated as sa1, then rotated to sa2 with no change on the hub. A valid LDAP account that isn't in the list gets UnknownUsername before any bind.

Small things I noticed, none blocking:

1. In agent-authn.xml, startTLSTimeout, autoReconnect and reconnectTimeout read sp.authn.LDAP.* while everything else reads sp.agent.authn.LDAP.*.
2. When p:usernames is set, the internal validator logs "Authentication of agent ... failed" at INFO on every request that a later validator accepts. Previously it logged "No shared secrets configured locally ... ignoring" at DEBUG.
3. The shipped sp.properties now sets trustCertificates/trustStore to files under credentials/sp/ that don't exist. That's harmless with jvmTrust, but someone might trip over it.

I also took your point about directories and tried the htpasswd validator as the no-directory option. A third username, held only in an htpasswd file, works on the same agent behind LDAP in the chain, and a rotated hash is picked up without a restart. One doc note: it takes $apr1$, {SHA} and crypt ($5$/$6$), but not bcrypt, which is what htpasswd -B produces.

On the loader: to see what the per-agent data would need to carry, I mocked up your hybrid model outside the hub. Group-level XML templates hold the settings, a flat file holds one row per agent, and a script generates a bean file. I listed that file in shibboleth.sp.AgentResolverResources next to agents.xml, so changes go live on reload. Each row needed only:

- agent id
- address ranges
- the usernames that may authenticate as the agent
- a reference to the group/template
- an owner

Two observations from that:

- Usernames have to be unique across agents, since the hub resolves the agent from the username. A loader would have to enforce that (or the resolver could refuse duplicates at load time).
- There's nowhere on an Agent to record an owner or contact, so I could only carry it as an XML comment. If the loader takes free-form metadata per agent, that would cover the accountability question without the hub needing to understand it.

Agreed that the hard part is people and process rather than tooling. I'd just like the hub to make the well-run case easy when someone has it.

Thanks again for the quick turnaround.

Best regards --Keith

## Scott's response (2026-11-03), summarised

- **`sp.authn.LDAP.*` prefix:** he'll fix it. He hasn't yet copied those properties into the commented `sp.properties`, which is where he reviews them for consistency.
- **Internal validator INFO "failed" line:** first answer was that logging a validator chain always trades noise against hidden information. In a follow-up message he called it a bug: the internal validator isn't meant to log when an agent has only usernames (no local secret). He'll fix it.
- **Non-existent trust files in `sp.properties`:** intended. The IdP does the same, because there's no real default to ship, and the paths do nothing until the matching option is turned on. **`jvmTrust` is not meant to be used**, even though no real default exists.
- **No bcrypt in htpasswd:** commons-codec doesn't implement it, as far as he knows. He asked whether the IdP documentation claims bcrypt support, and will check.
- **Loader fields:** the hub doesn't need an owner. Real deployments also need other fields, such as **issuer** and possibly an **override of the authority** to use. Otherwise our list matches his work on external agent loader code.
- **Username uniqueness:** the bean loader now ignores duplicates, and he fixed a bug there that day. External loaders can't do much, so the source system has to enforce uniqueness or deal with it. Uniqueness is already documented.
- **Per-agent metadata:** "That's fair." He hasn't settled on a format. Because so many fields are lists now, he's leaning towards an **LDIF-style flat file, one line per field**. A sketch is expected by the end of that week (about 2026-11-06); most of the code is done except the file loading.

## Scott's response (2026-11-03), verbatim

Scott's reply at 11:59, followed by his short addendum. Quoted lines are from Keith's email as Scott received it. The `$` characters were lost in transit, so `$apr1$` and `$5$/$6$` appear as `apr1apr1` and `55/66`.

```text
>     • In agent-authn.xml, startTLSTimeout, autoReconnect and reconnectTimeout read sp.authn.LDAP.* while everything else reads sp.agent.authn.LDAP.*.

I'll fix, but I haven't even copied them over to commented properties yet where I'd review for consistency.

>     • When p:usernames is set, the internal validator logs "Authentication of agent ... failed" at INFO on every request that a later validator accepts. Previously it logged "No shared secrets configured locally ... ignoring" at DEBUG.

I'll review the IdP behavior, but logging chains like that is essentially an impossible thing to do without either creating noise or hiding information, there is no answer that actually works well.

>     • The shipped sp.properties now sets trustCertificates/trustStore to files under credentials/sp/ that don't exist. That's harmless with jvmTrust, but someone might
> trip over it.

The IdP is the same and there is again no real default, they have to point to something that doesn't exist and don't do anything unless the relevant option is actually turned on by which time they'd be configured.

We do not intend anybody use jvmTrust, but there isn't a real default we can ship.

> One doc note: it takes apr1apr1, {SHA} and crypt (55/66), but not bcrypt, which is what htpasswd -B produces.

Does the IdP documentation say it does? I'll check, but that's not implemented in commons-codec to support AFAIK.

>     • agent id
>     • address ranges
>     • the usernames that may authenticate as the agent
>     • a reference to the group/template
>     • an owner

The Hub doesn't need "owner" obviously. There are some other fields needed in practice, e.g. issuer and possibly to override the authority to use, but by and large that matches my initial work being done on external agent loader code.

>     • Usernames have to be unique across agents, since the hub resolves the agent from the username. A loader would have to enforce that (or the resolver could refuse duplicates at load time).

The bean loader now does ignore them, and I fixed a bug there today in fact. The external ones can't do much about it, but in their case the source system would have to enforce it or at least deal with it. It is documented that they're unique already.

>     • There's nowhere on an Agent to record an owner or contact, so I could only carry it as an XML comment. If the loader takes free-form metadata per agent, that would cover the accountability question without the hub needing to understand it.

That's fair, and I haven't even come up with a format yet but because so many fields are lists now, I'm leaning LDIF style with a line per field or something along that line for the basic flat file option.

That should be sketched out by end of this week, I have most of the code done except the file load part.

-- Scott
```

Addendum:

```text
>     • When p:usernames is set, the internal validator logs "Authentication of agent ... failed" at INFO on every request that a later validator accepts. Previously it logged "No shared secrets configured locally ... ignoring" at DEBUG.

I see a bug there, you're right, so that's easily fixed, thanks. It isn't meant to log if only usernames are supplied.
```
