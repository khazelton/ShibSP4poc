#!/usr/bin/env bash
# Issues/rotates the secret for one agent service account and delivers it to both ends,
# the way an IGA/secret-management tool would:
#   directory <- password of <username> in the ldap container (hub validates against it)
#   agent     <- agent/conf/shibboleth-sp/agent.pwd (agent.ini secretFile)
# The hub sees nothing: no file, env var or restart on its side.
#
#   ./gen-agent-secret.sh                 # default username sa1-sp4-agent
#   ./gen-agent-secret.sh sa2-sp4-agent   # rotate onto the second service account
#
# After rotating, point agent.ini [remoting] agentID at <username> and recreate the agent
# only (--no-deps keeps compose from re-evaluating the hub):
#   docker compose up -d --no-deps --force-recreate agent
set -euo pipefail
cd "$(dirname "$0")"
USERNAME=${1:-sa1-sp4-agent}
SECRET=$(openssl rand -base64 36 | tr -d '\n/+=' | cut -c1-40)

printf '%s' "$SECRET" > agent/conf/shibboleth-sp/agent.pwd
chmod 600 agent/conf/shibboleth-sp/agent.pwd

if docker compose ps --status running ldap >/dev/null 2>&1 && [ -n "$(docker compose ps -q ldap)" ]; then
  ADMIN_PW=$(grep -E '^LDAP_ADMIN_PASSWORD=' .env | cut -d= -f2- || true)
  docker compose exec -T ldap /app/lldap_set_password \
    --base-url http://localhost:17170 \
    --admin-username admin --admin-password "${ADMIN_PW:-poc-admin-password}" \
    --username "$USERNAME" --password "$SECRET" >/dev/null
  echo "LDAP password set for ${USERNAME}"
else
  echo "ldap container not running; LDAP password NOT set (run ./ldap-seed.sh then re-run)"
fi
echo "secret (${#SECRET} chars) written to agent/conf/shibboleth-sp/agent.pwd"
echo "agent.ini [remoting] agentID must be: ${USERNAME}"
