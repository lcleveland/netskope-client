#!/usr/bin/env bash
# Bring Netskope steering up under a dead-man's switch.
#
# The client has no runtime off-switch worth relying on -- a tenant can set
# allowClientDisabling=false, and the daemon reinstates its rules whenever it
# restarts -- so the only safe way to watch it steer is to make something else
# responsible for turning it off. This starts the client, probes connectivity every
# few seconds, and tears everything down the moment connectivity dies, when the hard
# timeout expires, or if this script is killed. It never leaves the network broken
# waiting on a human.
#
# Pair it with services.netskope.autoStart = false, so a bad run costs one command
# rather than a reboot into an older generation.
#
#   ./steering-test.sh                 # run with the current firewall settings
#   HARD_TIMEOUT=180 ./steering-test.sh
#   CERT=/path/to/nstenantcert.crt ./steering-test.sh   # also probe TLS via tenant CA
#
# Requires: rights to start/stop system units and to run `systemd-run --system`
# (wheel + polkit is enough; it does not need an interactive sudo).

set -u

HARD_TIMEOUT="${HARD_TIMEOUT:-90}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
LOG="${LOG:-${TMPDIR:-/tmp}/netskope-steering-$(date +%Y%m%d-%H%M%S).log}"
CERT="${CERT:-/var/lib/netskope/ca-anchors/nstenantcert.crt}"
SW="${SW:-/run/current-system/sw/bin}"

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
asroot() { systemd-run --system --pipe --quiet --collect "$@" 2>&1; }

backed_out=0
backout() {
  [ "$backed_out" = 1 ] && return
  backed_out=1
  say "BACKOUT: stop-then-kill, then flush leftovers as root"

  # Order matters, and both halves are load-bearing:
  #   - `systemctl stop` alone does NOT stop this daemon promptly. Its shutdown path
  #     does network work that hangs when the network is down; 30s after stop it was
  #     still running with its rules installed.
  #   - `kill -s KILL` alone makes systemd restart it, because the unit is
  #     Restart=always. Marking it stopping first is what prevents that.
  systemctl --user stop stagentui stagentapp >>"$LOG" 2>&1 &
  systemctl stop --no-block stagentd >>"$LOG" 2>&1
  systemctl kill -s KILL stagentd >>"$LOG" 2>&1

  # A killed client cleans up nothing, so undo its plumbing directly.
  for _ in 1 2 3 4 5; do
    $SW/ip rule list 2>/dev/null | grep -q "fwmark 0x5" || break
    asroot $SW/ip rule del fwmark 0x5 table 9 >/dev/null
  done
  asroot $SW/ip route flush table 9 >/dev/null
  asroot $SW/ip link del sta0 >/dev/null
  asroot $SW/systemctl restart firewall.service >/dev/null   # also undoes any test rules
  asroot $SW/resolvectl flush-caches >/dev/null

  say "post-cleanup: stagentd=$(systemctl is-active stagentd) sta0=$($SW/ip -o link show sta0 2>/dev/null | wc -l) fwmark-rules=$($SW/ip rule list | grep -c fwmark)"
  for i in 1 2 3 4 5 6 7 8; do
    timeout 4 getent hosts example.com >/dev/null 2>&1 && { say "RECOVERED after $((i * 2))s"; return; }
    sleep 2
  done
  say "STILL BROKEN -- restarting NetworkManager"
  asroot $SW/systemctl restart NetworkManager.service >/dev/null
  for i in 1 2 3 4 5 6; do
    timeout 4 getent hosts example.com >/dev/null 2>&1 && { say "RECOVERED after NM restart"; return; }
    sleep 2
  done
  say "STILL BROKEN after NM restart -- inspect $LOG"
}
trap 'backout; exit 0' INT TERM
trap backout EXIT

# Probes chosen to tell the failure modes apart rather than just say "down":
#   dns/tcp   -- is steered traffic getting through at all
#   tls       -- fails on its own once steering is live, if the tenant CA is untrusted
#   TLSca     -- same request trusting the tenant CA; 1 proves traffic really is
#                going through the tenant's gateway
#   ping      -- unsteered control. Staying up while dns/tcp die means the *return
#                path* is being dropped (hello, strict rpfilter), not the link.
probe_round() {
  local dns=0 tcp=0 tls=0 tlsca icmp=0
  timeout 3 getent hosts example.com >/dev/null 2>&1 && dns=1
  timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null && tcp=1
  timeout 6 curl -sS -o /dev/null https://example.com 2>/dev/null && tls=1
  # "-" not 0 when the certificate cannot be read: statePath is typically 0700, so a
  # non-root run cannot open it, and reporting 0 there reads as "not intercepted" when
  # the probe simply never ran. That misreading cost real debugging time once.
  if [ -r "$CERT" ]; then
    tlsca=0
    timeout 6 curl -sS -o /dev/null --cacert "$CERT" https://example.com 2>/dev/null && tlsca=1
  else
    tlsca="-"
  fi
  timeout 3 ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && icmp=1
  echo "$dns $tcp $tls $tlsca $icmp"
}

say "log: $LOG"
if [ -r "$CERT" ]; then
  say "tenant CA readable ($CERT): TLSca probe active -- 1 means traffic really is"
  say "  going through the tenant's gateway, which is the proof steering is carrying it"
else
  say "NOTE: cannot read $CERT, so the TLSca probe is skipped and reports '-'."
  say "  Without it, connectivity holding up is NOT by itself proof that traffic is"
  say "  being steered -- check the client log for 'Enable NS packet filter' too."
  say "  Run as root, or: CERT=/path/to/readable/copy $0"
fi
say "=== baseline (steering off) ==="
say "probe[dns tcp tls TLSca icmp]: $(probe_round)"

say "=== starting stagentd + tray (hard timeout ${HARD_TIMEOUT}s) ==="
systemctl start stagentd >>"$LOG" 2>&1 || { say "daemon start failed"; exit 1; }
sleep 2
# The daemon alone never steers: with no per-user agent registered it has no user
# session ("Failed to get Active User Session ID") and builds no tunnel.
systemctl --user start stagentapp stagentui >>"$LOG" 2>&1 || say "tray start nonzero"

start=$(date +%s); fails=0; steering=0
while :; do
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -ge "$HARD_TIMEOUT" ] && { say "hard timeout reached"; break; }

  read -r dns tcp tls tlsca icmp <<<"$(probe_round)"
  sta=$($SW/ip -o link show sta0 2>/dev/null | wc -l)
  say "t+${elapsed}s dns=$dns tcp=$tcp tls=$tls TLSca=$tlsca icmp=$icmp sta0=$sta"

  if [ "$sta" = 1 ] && [ "$steering" = 0 ]; then
    steering=1
    say "STEERING ENGAGED"
    say "  | sta0: $($SW/ip -o addr show sta0 2>/dev/null | tr '\n' ';' | cut -c1-200)"
    say "  | ip rule: $($SW/ip rule list 2>/dev/null | tr '\n' ' ')"
    say "  | table 9: $($SW/ip route show table 9 2>/dev/null | head -3 | tr '\n' ' ')"
    say "  | rpfilter: $(asroot $SW/iptables -t mangle -S nixos-fw-rpfilter | tr '\n' ' ' | cut -c1-160)"
  fi

  if [ "$((dns + tcp))" = 0 ]; then
    fails=$((fails + 1)); say "  ... dead round $fails/$FAIL_THRESHOLD"
    [ "$fails" -ge "$FAIL_THRESHOLD" ] && { say "CONNECTIVITY LOST"; break; }
  else
    fails=0
  fi
  sleep 3
done

say "=== end; steering was $([ "$steering" = 1 ] && echo ENGAGED || echo NEVER-ENGAGED) ==="
exit 0
