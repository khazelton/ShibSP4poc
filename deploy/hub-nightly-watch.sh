#!/usr/bin/env bash
# hub-nightly-watch.sh — run check-hub-nightly.sh daily from launchd and post a macOS
# notification when the hub snapshot has real code changes.
#
#   ./hub-nightly-watch.sh install     write + load ~/Library/LaunchAgents/$LABEL.plist (daily 07:13 local)
#   ./hub-nightly-watch.sh uninstall   unload + remove it
#   ./hub-nightly-watch.sh run         one check now (what launchd calls)
#   ./hub-nightly-watch.sh status      launchd state + tail of the log
#   ./hub-nightly-watch.sh test        send a test notification from the launchd job
#
# Notifies once per distinct change set (state in $STATE_DIR/last-notified), so an
# unrebuilt change doesn't nag every day; after you rebuild, check exits 0 and the state
# resets. Errors (exit 2: Docker down, network) are logged and notify only after 3 in a row.
set -uo pipefail

LABEL=org.aktis.sp4poc.hub-nightly
HERE=$(cd "$(dirname "$0")" && pwd)
STATE_DIR="$HOME/Library/Application Support/sp4poc"
LOG="$HOME/Library/Logs/sp4poc-hub-nightly.log"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

notify() {
  /usr/bin/osascript -e "display notification \"$2\" with title \"SP4 hub nightly\" subtitle \"$1\"" || true
}

run_check() {
  mkdir -p "$STATE_DIR"
  # one-shot delivery test from launchd's context: `./hub-nightly-watch.sh test`
  if [ -f "$STATE_DIR/notify-test" ]; then
    rm -f "$STATE_DIR/notify-test"
    notify "test" "Notification from the launchd job works"
    echo "=== $(date '+%F %T') notify-test sent" >> "$LOG"
  fi
  local out rc
  out=$("$HERE/check-hub-nightly.sh" "${HUB_IMAGE:-sp4-hub:dev}" 2>&1); rc=$?
  { echo "=== $(date '+%F %T') exit=$rc"; echo "$out"; } >> "$LOG"

  case $rc in
    0) rm -f "$STATE_DIR/last-notified" "$STATE_DIR/errors" ;;
    1) rm -f "$STATE_DIR/errors"
       # fingerprint = remote tarball names + changed entries (ignores the image timestamp line)
       local fp; fp=$(echo "$out" | grep -vE '^image:' | shasum | cut -c1-16)
       if [ "$(cat "$STATE_DIR/last-notified" 2>/dev/null)" != "$fp" ]; then
         local msg="Code changed — run deploy/check-hub-nightly.sh, then rebuild"
         echo "$out" | grep -q 'watched' && msg="Watched defect code changed (#2-#4?) — retest"
         notify "$(echo "$out" | grep -m1 '^remote: sp-dist' | sed 's/remote: //')" "$msg"
         echo "$fp" > "$STATE_DIR/last-notified"
       fi ;;
    *) local n; n=$(( $(cat "$STATE_DIR/errors" 2>/dev/null || echo 0) + 1 ))
       echo $n > "$STATE_DIR/errors"
       [ "$n" -eq 3 ] && notify "check failing" "3 failed runs in a row — see $LOG" ;;
  esac
  return $rc
}

install() {
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  cat > "$PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$HERE/hub-nightly-watch.sh</string><string>run</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>7</integer><key>Minute</key><integer>13</integer></dict>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
XML
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" && echo "installed: $PLIST (daily 07:13; log $LOG)"
}

uninstall() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" && echo "removed $PLIST"
}

status() {
  launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E 'state|last exit|runs' || echo "not loaded"
  [ -f "$LOG" ] && tail -20 "$LOG"
}

case "${1:-}" in
  install) install ;;
  uninstall) uninstall ;;
  run) run_check ;;
  status) status ;;
  test) mkdir -p "$STATE_DIR" && touch "$STATE_DIR/notify-test" \
          && launchctl kickstart "gui/$(id -u)/$LABEL" && echo "kicked $LABEL; watch for a test notification" ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
