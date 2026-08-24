#!/bin/bash
# Stops the Mac idle-sleeping while long agent runs are in flight.
#
# Agents die when the machine sleeps mid-response — the work already written to
# disk survives, anything in flight does not. This holds sleep off for a bounded
# window rather than indefinitely, so a forgotten process cannot keep the laptop
# awake for days.
#
#   ./keep-awake.sh start [hours]   hold sleep off (default 4h, max 12h)
#   ./keep-awake.sh stop            release it
#   ./keep-awake.sh status          is it currently held?
set -euo pipefail
PIDFILE="/tmp/ntcg-caffeinate.pid"

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "${1:-status}" in
  start)
    if running; then echo "already awake (pid $(cat "$PIDFILE"))"; exit 0; fi
    hours="${2:-4}"
    # Clamp: an unbounded hold is how a laptop cooks in a bag.
    [ "$hours" -gt 12 ] 2>/dev/null && hours=12
    secs=$(( hours * 3600 ))
    # -d display, -i idle, -m disk, -s system, -u asserts user activity
    nohup caffeinate -dimsu -t "$secs" >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    echo "sleep held off for ${hours}h (pid $!)"
    echo "NOTE: closing the lid still sleeps the Mac unless it is on external power with a display attached."
    ;;
  stop)
    if running; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; echo "released"
    else rm -f "$PIDFILE"; echo "was not held"; fi
    ;;
  status)
    if running; then echo "HELD (pid $(cat "$PIDFILE"))"; else echo "not held"; fi
    ;;
  *) echo "usage: $0 {start [hours]|stop|status}"; exit 1 ;;
esac
