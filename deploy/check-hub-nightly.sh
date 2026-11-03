#!/usr/bin/env bash
# check-hub-nightly.sh — is there a hub snapshot worth rebuilding for?
#
# Resolves the newest *signed* nightly of each hub plugin (same rule as hub/Dockerfile),
# downloads it, and compares every jar against the jars baked into a local hub image.
# Comparison is by per-entry CRC (from `unzip -v`), ignoring directories, MANIFEST.MF
# and META-INF/maven/, so a rebuild with no code change reads as "unchanged".
#
# Usage:  ./check-hub-nightly.sh [image]        (default image: sp4-hub:dev)
#         KEEP=1 ./check-hub-nightly.sh          keep the work dir for inspection
# Exit:   0 = no code change, 1 = code changed (rebuild: docker compose build --no-cache hub),
#         2 = error
#
# Entries matching WATCH are flagged: they hold the 0.0.3 defects reported to dev@
# (docs/dev-list-writeup.md #2-#4). Override with WATCH='regex' ./check-hub-nightly.sh
set -euo pipefail

IMAGE=${1:-sp4-hub:dev}
SNAP_BASE=https://build.shibboleth.net/maven/snapshots/net/shibboleth
PLUGINS="sp/sp-dist/0.0.3-SNAPSHOT sp/sp-oidc-dist/0.0.3-SNAPSHOT oidc/oidc-common-dist/3.4.0-SNAPSHOT"
WATCH=${WATCH:-'ValidateAgentCredentials|AgentSecretCredentialValidator|sp-abstract-beans\.xml|LDAP'}
LIB=/opt/shibboleth-idp/dist/plugin-webapp/WEB-INF/lib

die() { echo "error: $*" >&2; exit 2; }
command -v unzip >/dev/null || die "unzip not found"
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE not found"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/hub-nightly.XXXXXX")
cleanup() { [ -n "${KEEP:-}" ] && echo "work dir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

# newest *.tar.gz in a snapshot dir that also has a .asc (unsigned nightlies are skipped)
latest_tgz() {
  curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 "$1/" | grep -oE '[a-z-]+-dist-[0-9.]+-[0-9]{8}\.[0-9]{6}-[0-9]+\.tar\.gz\.asc' \
    | sort -u | tail -1 | sed 's|\.asc$||'
}

# entry listing "CRC name" for a jar, minus noise that changes on every build
fingerprint() {
  unzip -v "$1" | awk 'NF>=8 && $7 ~ /^[0-9a-f]{8}$/ {print $7, $8}' \
    | grep -vE ' (.*/|META-INF/MANIFEST\.MF|META-INF/maven/.*)$' | sort -k2
}

# jars currently in the image
mkdir -p "$WORK/image"
cid=$(docker create "$IMAGE")
docker cp -q "$cid:$LIB/." "$WORK/image/" || { docker rm "$cid" >/dev/null; die "cannot copy $LIB from $IMAGE"; }
docker rm "$cid" >/dev/null
echo "image:  $IMAGE (created $(docker image inspect -f '{{.Created}}' "$IMAGE" | cut -c1-16))"

changed=0
for p in $PLUGINS; do
  dir="$SNAP_BASE/$p"
  tgz=$(latest_tgz "$dir") || die "cannot list $dir"
  [ -n "$tgz" ] || die "no signed tarball in $dir"
  echo "remote: $tgz"
  mkdir -p "$WORK/remote/$p"
  curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 "$dir/$tgz" | tar xz -C "$WORK/remote/$p" || die "download/extract failed: $tgz"

  for jar in $(find "$WORK/remote/$p" -path '*/WEB-INF/lib/*.jar' | sort); do
    name=$(basename "$jar")
    local_jar="$WORK/image/$name"
    if [ ! -f "$local_jar" ]; then
      echo "  NEW   $name (not in image)"; changed=1; continue
    fi
    diffs=$(diff <(fingerprint "$local_jar") <(fingerprint "$jar") \
              | awk '/^[<>]/ {print $3}' | sort -u || true)
    if [ -n "$diffs" ]; then
      changed=1
      echo "  DIFF  $name ($(echo "$diffs" | wc -l | tr -d ' ') entries)"
      echo "$diffs" | while read -r e; do
        if echo "$e" | grep -qE "$WATCH"; then echo "        * $e   <-- watched"; else echo "          $e"; fi
      done
    fi
  done
done

if [ "$changed" = 0 ]; then
  echo "result: no code changes vs $IMAGE"
  exit 0
fi
echo "result: code changed — rebuild with: docker compose build --no-cache hub"
exit 1
