#!/usr/bin/env bash
# Generates the shared secret for agent "sp4-agent.localtest" and delivers it to both
# ends, the way an IGA/secret-management tool would:
#   hub   <- deploy/.env            (AGENT_SECRET, read by hub/entrypoint.sh)
#   agent <- agent/conf/shibboleth-sp/agent.pwd  (read via agent.ini secretFile)
# Re-run to rotate. Both files are gitignored.
set -euo pipefail
cd "$(dirname "$0")"
SECRET=$(openssl rand -base64 36 | tr -d '\n/+=' | cut -c1-40)
touch .env
# ensure the file ends with a newline before appending
[ -s .env ] && [ "$(tail -c1 .env | od -An -c | tr -d ' ')" != '\n' ] && echo >> .env
if grep -q '^AGENT_SECRET=' .env; then
  sed -i.bak "s|^AGENT_SECRET=.*|AGENT_SECRET=${SECRET}|" .env && rm -f .env.bak
else
  printf 'AGENT_SECRET=%s\n' "$SECRET" >> .env
fi
printf '%s' "$SECRET" > agent/conf/shibboleth-sp/agent.pwd
chmod 600 agent/conf/shibboleth-sp/agent.pwd
echo "agent secret written to .env and agent/conf/shibboleth-sp/agent.pwd (${#SECRET} chars)"
