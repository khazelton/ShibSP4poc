README.md
devspace/ShibSp4PoC

- - -
_2026-11-01 14:59 Introduction to the Shib SP v4 Hub/Agent model_

Problem: An on campus application that wants to accept Authentication over OAuth2/OIDC

Context: The campus runs Shib SPv4 on top of Shib IdPv4.2+ 

Deliverable: An OAuth2/OIDC login to that campus app behind a Shib SP v4 OAuth2 endpoint registered with the Shib SPv4 Hub.

From techex-2026.adoc +

For an overview of the project, the best starting point is PoC outline: OIDC login to a campus app via Shibboleth SP v4 Hub/Agent, https://github.com/khazelton/ShibSP4poc/blob/b80e5e21e4cd8ba7a5da4d59642006fe1306f8e6/docs/poc-outline.md
 
- - -
10:20 am - 11:10  
    Marq 4 Scaling Shibboleth 4 SP deployents - Scott Cantor - Shib Project https://docs.google.com/document/d/1GciCfd8_zfkF76GQ-5XSpOLZDAmYd3WtON9rOqYJA5w/edit?usp=sharing < ACAMP scribing doc +

ScottC: scott@restingparrotsoftware.com

https://shibboleth.atlassian.net/wiki/spaces/DEV/pages/2981429255/Service+Provider+V4+Redesign <- SP v4 redesign; Organizing page for material connected to the project to redesign the Service Provider software +

Why are we doing this?
https://shibboleth.atlassian.net/wiki/spaces/DEV/pages/1203471357/SP4Details <- original discussion +
https://shibboleth.atlassian.net/wiki/spaces/DEV/pages/2110391683/DesignNotes <- Newer version +


Jetty/http is all you need.

clientID and shared secret: manually entering each of 200 SPs; Not Great

v1 was basic auth over TLS;

It's a mgmt pain.  Hub authN can handle it better than hacky manual solutions. Asking hub guy to do it, incl most of the config

IDs and secret mgmt at scale. How? Not really a hub admin job, it's really IAM/IGA, but somebody gotta do it.

Version 1 of a hub: Flat file of agent records for short term; Longer run: delegated model, simple gui over a Db. With capability to carry the SP 'metadata'?

Tell Scott you want to track development of Shib SP/RP v 4. 

]=+0  Offer to develop a PoC with Scott's SP v4 model

Perhaps Evolveum and Unicon WSAs behind the curtain.

Comes back to service account management

>> Slavek's idea on Svc Mgmt. as a mP functionality <<

You can offer a Hub as a service, but do not think of it as doing "federation". It's a proxy.

DB for the hub is in scope--longer term, think of the hub is an appliance (is mP too heavy?)

Interested parties: bjorn, scand; matthew AAF

Next year--Internet2 plans to deploy it for Internet2 internal Shib

Scott: "So I hear you saying Svc mgmt is a mess. If you want this, we need to hear your thoughts and opinions"
