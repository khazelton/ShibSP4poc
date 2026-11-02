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
setprop "$SP"   sp.agent.authn.method   "basic"
setprop "$SP"   poc.agent.secret        "${AGENT_SECRET:-unset}"

# Phase 4: validate agent credentials against LDAP (service accounts), in addition to
# the in-config validator. Bean list must live in conf/global.xml (not agents.xml).
if [ -n "${AGENT_LDAP_URL:-}" ]; then
  setprop "$SP" sp.agent.authn.LDAP.authenticator "directAuthenticator"
  setprop "$SP" sp.agent.authn.LDAP.ldapURL       "${AGENT_LDAP_URL}"
  setprop "$SP" sp.agent.authn.LDAP.dnFormat      "${AGENT_LDAP_DNFORMAT:-uid=%s,ou=people,dc=localtest}"
  setprop "$SP" sp.agent.authn.LDAP.useStartTLS   "false"
  setprop "$SP" sp.agent.authn.LDAP.sslConfig     "jvmTrust"
  # NOTE: the documented form (<ref bean="shibboleth.sp.AgentSecretValidator"/> and
  # <bean parent="shibboleth.sp.LDAPValidator"/>) fails on hub 0.0.3 with
  # NoSuchBeanDefinitionException: those beans live in the SP flow context, which the
  # root context (global.xml) cannot see. Define the validators by class instead.
  if ! grep -q 'shibboleth.sp.AgentValidators' conf/global.xml; then
    cat > /tmp/validators.xml <<'XML'
    <!-- SP hub: agent credential validators (PoC Phase 4). See hub/entrypoint.sh. -->
    <!-- Same property set as the plugin's shibboleth.sp.LDAPAuthenticationFactory, minus the
         flow-scoped trust-config refs (unused with jvmTrust). Values come from sp.properties. -->
    <bean id="poc.AgentLDAPAuthenticator"
          class="net.shibboleth.idp.authn.config.LDAPAuthenticationFactoryBean"
          p:authenticatorType="#{'%{sp.agent.authn.LDAP.authenticator:directAuthenticator}'.trim()}"
          p:trustType="#{'%{sp.agent.authn.LDAP.sslConfig:jvmTrust}'.trim()}"
          p:connectionStrategyType="#{'%{sp.agent.authn.LDAP.connectionStrategy:ACTIVE_PASSIVE}'.trim()}"
          p:ldapUrl="%{sp.agent.authn.LDAP.ldapURL}"
          p:useStartTLS="%{sp.agent.authn.LDAP.useStartTLS:false}"
          p:startTLSTimeout="%{sp.agent.authn.LDAP.startTLSTimeout:PT3S}"
          p:connectTimeout="%{sp.agent.authn.LDAP.connectTimeout:PT3S}"
          p:responseTimeout="%{sp.agent.authn.LDAP.responseTimeout:PT3S}"
          p:autoReconnect="%{sp.agent.authn.LDAP.autoReconnect:true}"
          p:reconnectTimeout="%{sp.agent.authn.LDAP.reconnectTimeout:PT10S}"
          p:accountStateExpirationPeriod="%{sp.agent.authn.LDAP.accountStateExpirationPeriod:#{null}}"
          p:accountStateWarningPeriod="%{sp.agent.authn.LDAP.accountStateWarningPeriod:#{null}}"
          p:disablePooling="%{sp.agent.authn.LDAP.disablePooling:false}"
          p:blockWaitTime="%{sp.agent.authn.pool.LDAP.blockWaitTime:PT3S}"
          p:minPoolSize="%{sp.agent.authn.pool.LDAP.minSize:3}"
          p:maxPoolSize="%{sp.agent.authn.pool.LDAP.maxSize:10}"
          p:validateOnCheckout="%{sp.agent.authn.pool.LDAP.validateOnCheckout:false}"
          p:validatePeriodically="%{sp.agent.authn.pool.LDAP.validatePeriodically:true}"
          p:validatePeriod="%{sp.agent.authn.pool.LDAP.validatePeriod:PT5M}"
          p:validateDn="#{'%{sp.agent.authn.pool.LDAP.validateDN:}'.trim()}"
          p:validateFilter="#{'%{sp.agent.authn.pool.LDAP.validateFilter:(objectClass=*)}'.trim()}"
          p:bindPoolPassivatorType="#{'%{sp.agent.authn.LDAP.bindPoolPassivator:none}'.trim()}"
          p:prunePeriod="%{sp.agent.authn.pool.LDAP.prunePeriod:PT5M}"
          p:idleTime="%{sp.agent.authn.pool.LDAP.idleTime:PT10M}"
          p:dnFormat="%{sp.agent.authn.LDAP.dnFormat}"
          p:baseDn="#{'%{sp.agent.authn.LDAP.baseDN:undefined}'.trim()}"
          p:userFilter="#{'%{sp.agent.authn.LDAP.userFilter:undefined}'.trim()}"
          p:subtreeSearch="%{sp.agent.authn.LDAP.subtreeSearch:false}"
          p:resolveEntryOnFailure="%{sp.agent.authn.LDAP.resolveEntryOnFailure:false}"
          p:resolveEntryWithBindDn="%{sp.agent.authn.LDAP.resolveEntryWithBindDN:false}"
          p:velocityEngine-ref="shibboleth.VelocityEngine"
          p:bindDn="#{'%{sp.agent.authn.LDAP.bindDN:undefined}'.trim()}"
          p:bindDnCredential="%{sp.agent.authn.LDAP.bindDNCredential:undefined}"
          p:usePasswordPolicy="%{sp.agent.authn.LDAP.usePasswordPolicy:false}"
          p:usePasswordExpiration="%{sp.agent.authn.LDAP.usePasswordExpiration:false}"
          p:activeDirectory="%{sp.agent.authn.LDAP.activeDirectory:false}"
          p:freeIPA="%{sp.agent.authn.LDAP.freeIPADirectory:false}"
          p:EDirectory="%{sp.agent.authn.LDAP.eDirectory:false}"
          p:accountStateLoginFailures="%{sp.agent.authn.LDAP.accountStateLoginFailures:0}" />

    <util:list id="shibboleth.sp.AgentValidators">
        <bean class="net.shibboleth.sp.authn.impl.AgentSecretCredentialValidator" p:id="spagent-internal" />
        <bean class="net.shibboleth.idp.authn.impl.LDAPCredentialValidator" p:id="spagent-ldap"
              p:authenticator-ref="poc.AgentLDAPAuthenticator" />
    </util:list>

</beans>
XML
    perl -0pi -e 'BEGIN{local $/; open F,"</tmp/validators.xml"; $r=<F>; close F} s|</beans>\s*$|$r|' conf/global.xml
  fi
fi

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
