#!/usr/bin/env bash
# Bring Netskope steering up under a dead-man's switch.
#
# The client has no runtime off-switch worth relying on -- a tenant can set
# allowClientDisabling=false, which refuses `stAgentCli disable`, and the daemon
# reinstates its rules whenever it restarts. So the only safe way to watch it steer
# is to make something else responsible for turning it off. This starts the daemon
# (and the tray, without which it never builds a user tunnel), probes connectivity,
# and stops both the moment connectivity dies -- or when the hard timeout expires,
# or if this script is killed. Networking is never left broken waiting on a human.
#
# Pair it with services.netskope.autoStart = false, so a bad boot cannot beat you to
# it. Requires permission to start/stop stagentd (root, or a polkit rule for wheel).
#
#   ./steering-test.sh                 # 200s window, backs out after ~6s of loss
#   HARD_TIMEOUT=60 ./steering-test.sh # shorter leash
#
# The probes are chosen to tell the failure modes apart rather than just say "down":
# ICMP is never marked by the client, so `ping` surviving while TCP dies means
# traffic is being steered into a hole rather than the link being down; and a
# full-size DF ping distinguishes an MTU blackhole from a routing one.

set -u

HARD_TIMEOUT="${HARD_TIMEOUT:-200}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
LOG="${LOG:-${TMPDIR:-/tmp}/netskope-steering-$(date +%Y%m%d-%H%M%S).log}"

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }

snapshot() {
  say "  | links:   $(ip -br link 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  say "  | ip rule: $(ip rule list 2>/dev/null | tr '\n' ' ')"
  # The client policy-routes marked traffic into its own table; if that table has no
  # default route, everything steered is silently dropped.
  for t in 1 9; do
    say "  | table $t: $(ip route show table $t 2>/dev/null | tr '\n' ' ')"
  done
  say "  | default: $(ip route show default 2>/dev/null | tr '\n' ' ')"
}

backed_out=0
backout() {
  [ "$backed_out" = 1 ] && return
  backed_out=1
  say "BACKOUT: stopping tray + stagentd"
  systemctl --user stop stagentui stagentapp >>"$LOG" 2>&1
  systemctl stop stagentd >>"$LOG" 2>&1
  sleep 3
  say "post-stop: stagentd=$(systemctl is-active stagentd)"
  snapshot
  for i in 1 2 3 4 5 6; do
    if timeout 4 getent hosts example.com >/dev/null 2>&1; then
      say "RECOVERED: DNS resolves again ($((i * 2))s after stop)"
      say "NB: the daemon has been seen to SEGV on stop and leave its rules behind."
      say "    If anything still misbehaves: ip rule del fwmark 0x5 lookup 9;"
      say "    ip route flush table 9   (both need root)"
      return
    fi
    sleep 2
  done
  say "STILL BROKEN after stop -- leftover rules; flush as above, or reboot"
}
# INT/TERM must back out AND leave: a trap that merely returns drops back into the
# probe loop.
trap 'backout; exit 0' INT TERM
trap backout EXIT

probe_round() {
  local dns=0 tcp=0 tls=0 small=0 big=0
  timeout 3 getent hosts example.com >/dev/null 2>&1 && dns=1
  timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null && tcp=1
  timeout 5 curl -sS -o /dev/null https://example.com 2>/dev/null && tls=1
  timeout 3 ping -c1 -W2 -s 56 1.1.1.1 >/dev/null 2>&1 && small=1
  timeout 4 ping -c1 -W3 -M do -s 1372 1.1.1.1 >/dev/null 2>&1 && big=1
  echo "$dns $tcp $tls $small $big"
}

say "=== baseline (steering off) ==="
say "probe[dns tcp tls ping56 ping1372]: $(probe_round)"
snapshot

say "=== starting stagentd + tray (hard timeout ${HARD_TIMEOUT}s) ==="
systemctl start stagentd >>"$LOG" 2>&1 || { say "daemon start failed"; exit 1; }
sleep 2
# Without the per-user agent the daemon has no session ("Failed to get Active User
# Session ID") and never builds a tunnel, so steering is never exercised.
systemctl --user start stagentapp stagentui >>"$LOG" 2>&1 || say "tray start returned nonzero (continuing)"

start=$(date +%s)
fails=0
snapped=0
while :; do
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -ge "$HARD_TIMEOUT" ] && { say "hard timeout reached"; break; }

  read -r dns tcp tls small big <<<"$(probe_round)"
  say "t+${elapsed}s dns=$dns tcp=$tcp tls=$tls ping56=$small ping1372=$big"

  if [ "$snapped" = 0 ] && { [ "$big" = 0 ] || [ "$tls" = 0 ] || [ "$dns" = 0 ]; }; then
    snapped=1
    say "FIRST DEGRADATION -- capturing state"
    snapshot
  fi

  if [ "$((dns + tcp + tls))" = 0 ]; then
    fails=$((fails + 1))
    say "  ... dead round $fails/$FAIL_THRESHOLD"
    [ "$fails" -ge "$FAIL_THRESHOLD" ] && { say "CONNECTIVITY LOST"; snapshot; break; }
  else
    fails=0
  fi
  sleep 3
done

say "=== final state ==="
snapshot
say "log: $LOG"
exit 0
