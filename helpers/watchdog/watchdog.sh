#!/bin/bash
# SketchyBar freeze watchdog (run by launchd every 10s).
# If the daemon stops answering for two consecutive checks, capture stack
# samples for post-mortem, then kill it (launchd KeepAlive restarts it) along
# with its Lua config process and any hung CLI clients.

SB=/opt/homebrew/bin/sketchybar
LOG_DIR="$HOME/Library/Logs/sketchybar"
STATE="${TMPDIR:-/tmp}/sketchybar_watchdog_failures"
MAX_REPORTS=10

with_timeout() { /usr/bin/perl -e 'alarm shift; exec @ARGV' "$@"; }

# Daemon = sketchybar process without arguments (clients always have args).
daemon_pid() {
  ps -axo pid=,args= | awk '$2 ~ /\/sketchybar$/ && NF == 2 { print $1; exit }'
}

pid=$(daemon_pid)
if [ -z "$pid" ]; then
  # Not running (launchd is restarting it or it was stopped on purpose).
  rm -f "$STATE"
  exit 0
fi

# The CLI gives up on an unresponsive daemon after ~100ms but still exits 0,
# just with empty output, so check the reply content, not the exit code.
if with_timeout 3 "$SB" --query bar 2>/dev/null | grep -q '"position"'; then
  rm -f "$STATE"
  exit 0
fi

failures=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
echo "$failures" > "$STATE"
# One miss can be a hiccup (wake from sleep, config reload); act on the second.
[ "$failures" -lt 2 ] && exit 0
rm -f "$STATE"

mkdir -p "$LOG_DIR"
stamp=$(date +%Y%m%d-%H%M%S)
report="$LOG_DIR/hang-$stamp.txt"
lua_pids=$(pgrep -P "$pid" lua)
{
  echo "sketchybar hang detected at $(date)"
  echo "daemon pid: $pid, lua pids: ${lua_pids:-none}"
  echo
  ps -axo pid,ppid,stat,%cpu,rss,etime,args | grep -E 'sketchybar|lua|system_stats|network_load|aerospace' | grep -v grep
  echo
  echo "===== sample sketchybar ($pid) ====="
  with_timeout 10 /usr/bin/sample "$pid" 2 2>&1
  for lp in $lua_pids; do
    echo
    echo "===== sample lua ($lp) ====="
    with_timeout 10 /usr/bin/sample "$lp" 2 2>&1
  done
} > "$report" 2>&1

ls -1t "$LOG_DIR"/hang-*.txt 2>/dev/null | tail -n +$((MAX_REPORTS + 1)) | xargs rm -f

kill -9 "$pid" $lua_pids 2>/dev/null
# Hung `sketchybar --trigger/--set/...` clients waiting for a reply.
ps -axo pid=,args= | awk '$2 ~ /sketchybar$/ && $3 ~ /^--/ { print $1 }' | xargs kill -9 2>/dev/null
# Helpers block in mach_msg too; the config restarts them on load.
killall -9 system_stats network_load 2>/dev/null

echo "$(date) watchdog: restarted frozen sketchybar, report: $report" >> "$LOG_DIR/watchdog.log"
