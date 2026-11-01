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

# Phase 1: agent reaches hub over the docker network with no secret.
# Phase 2 narrows this and sets sp.agent.authn.method = basic.
setprop "$SP"   sp.agent.authn.allowedAddressRanges "0.0.0.0/0,::/0"

# OIDC plugin wiring per OIDCBasics (imports are appended once).
grep -q 'oidc-credentials.xml' conf/sp/agents.xml || \
  sed -i 's|</beans>|    <import resource="oidc-credentials.xml" />\n</beans>|' conf/sp/agents.xml
grep -q 'oidc-claim-rules.xml' conf/attributes/default-rules.xml || \
  sed -i 's|</beans>|    <import resource="oidc-claim-rules.xml" />\n</beans>|' conf/attributes/default-rules.xml
# (client-secret credential bean lives in the COPY'd conf/sp/oidc-credentials.xml)

# PoC logging: DEBUG for the hub and OIDC packages (shows claims received, agent ops).
grep -q 'name="net.shibboleth.sp"' conf/logback.xml || \
  sed -i 's|</configuration>|    <logger name="net.shibboleth.sp" level="DEBUG" />\n    <logger name="net.shibboleth.oidc" level="DEBUG" />\n</configuration>|' conf/logback.xml

# Foreground Jetty via the plugin's script (sets -Didp.home, tmpdir, log dir).
# JETTY_HOME / JETTY_BASE come from the image ENV; http host was opened in the Dockerfile.
exec bin/runjetty.sh run
