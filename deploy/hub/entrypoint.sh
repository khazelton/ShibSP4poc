#!/usr/bin/env bash
# Applies PoC config to the hub at container start, then runs Jetty in the foreground.
# Idempotent: every edit is a "set or replace" so restarts are safe.
set -euo pipefail
cd "${IDP_HOME}"

: "${GOOGLE_CLIENT_ID:?GOOGLE_CLIENT_ID not set}"
: "${GOOGLE_CLIENT_SECRET:?GOOGLE_CLIENT_SECRET not set}"

# setprop FILE KEY VALUE  -- replace "key = ..." / "#key = ..." or append
setprop() {
  local f=$1 k=$2 v=$3
  if grep -qE "^#?\s*${k}\s*=" "$f"; then
    sed -i -E "s|^#?\s*${k}\s*=.*|${k} = ${v}|" "$f"
  else
    printf '\n%s = %s\n' "$k" "$v" >> "$f"
  fi
}

SP=conf/sp/sp.properties
OIDC=conf/sp/oidc.properties

# Identity leg: hub as OIDC RP against Google
setprop "$SP"   sp.issuer                         "${GOOGLE_CLIENT_ID}"
setprop "$SP"   sp.defaultAuthority               "https://accounts.google.com"
setprop "$OIDC" sp.oidc.defaultClientSecret       "${GOOGLE_CLIENT_SECRET}"
setprop "$OIDC" sp.oidc.acceptUnfilteredAttributes "true"        # PoC only; Phase 3 adds a filter
# Extra scopes beyond openid, else Google returns only "sub". Values are sent verbatim
# (verified: "PROFILE,EMAIL" went out literally), so use the lowercase OIDC scope names.
setprop "$OIDC" sp.oidc.scopes                    "profile,email"

# Phase 2: agents must authenticate (basic) and come from their declared address.
# The global range stays at the loopback default; each Agent bean in agents.xml
# carries its own allowedAddressRanges. The secret is referenced from agents.xml
# as %{poc.agent.secret}.
: "${AGENT_SECRET:?AGENT_SECRET not set - run ./gen-agent-secret.sh}"
setprop "$SP"   sp.agent.authn.method   "basic"
setprop "$SP"   poc.agent.secret        "${AGENT_SECRET}"

# Export the hub's TLS cert (made by the IdP installer for hub.localtest) for agents.
if [ -d /tls-export ]; then
  openssl pkcs12 -in credentials/idp-userfacing.p12 -passin pass:changeit -nokeys -clcerts 2>/dev/null \
    | openssl x509 > /tls-export/hub.crt
  chmod 644 /tls-export/hub.crt
fi

# OIDC plugin wiring per OIDCBasics (agents.xml is COPY'd with the import already in it).
grep -q 'oidc-claim-rules.xml' conf/attributes/default-rules.xml || \
  sed -i 's|</beans>|    <import resource="oidc-claim-rules.xml" />\n</beans>|' conf/attributes/default-rules.xml
# (client-secret credential bean lives in the COPY'd conf/sp/oidc-credentials.xml)

# PoC logging: DEBUG for the hub and OIDC packages (shows claims received, agent ops).
grep -q 'name="net.shibboleth.sp"' conf/logback.xml || \
  sed -i 's|</configuration>|    <logger name="net.shibboleth.sp" level="DEBUG" />\n    <logger name="net.shibboleth.oidc" level="DEBUG" />\n</configuration>|' conf/logback.xml

# Foreground Jetty via the plugin's script (sets -Didp.home, tmpdir, log dir).
# JETTY_HOME / JETTY_BASE come from the image ENV; http host was opened in the Dockerfile.
exec bin/runjetty.sh run
