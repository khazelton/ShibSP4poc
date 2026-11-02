#!/usr/bin/env bash
# Creates the agent service accounts in the ldap container from ldap/bootstrap/user-configs/
# (idempotent). Passwords are set separately by ./gen-agent-secret.sh <username>.
set -euo pipefail
cd "$(dirname "$0")"
ADMIN_PW=$(grep -E '^LDAP_ADMIN_PASSWORD=' .env 2>/dev/null | cut -d= -f2- || true)
ADMIN_PW=${ADMIN_PW:-poc-admin-password}
docker compose exec -T \
  -e LLDAP_URL=http://localhost:17170 \
  -e LLDAP_ADMIN_USERNAME=admin \
  -e LLDAP_ADMIN_PASSWORD="$ADMIN_PW" \
  -e USER_CONFIGS_DIR=/bootstrap/user-configs \
  -e GROUP_CONFIGS_DIR=/bootstrap/group-configs \
  -e DO_CLEANUP=false \
  ldap /app/bootstrap.sh
