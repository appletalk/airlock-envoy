#!/bin/bash
# Install or update the airlock-envoy service: system account, config, Envoy unit, and the
# box-facing socket for each listener (airlock-envoy-proxy@<listener>.socket).
# Run install-envoy.sh first. Usage, as root:  install/install-service.sh <client user>
# <client user> is the account whose airlock boxes may connect (your login). Run it from a
# clean clone that no box mounts: as root it installs code and the egress allowlist from here.
set -euo pipefail
client="${1:?usage: install-service.sh <client user>}"
listeners=(anthropic)
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
# The ACL and drop-in use the numeric uid, never the name: a name with a space or a
# systemd specifier in it could otherwise grant a different account.
uid="$(id -u -- "$client" 2>/dev/null)" || { echo "no such user: $client" >&2; exit 1; }
[[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" != 0 ] || { echo "refusing client uid '$uid'" >&2; exit 1; }
[ -x /usr/local/bin/envoy ] || { echo "install Envoy first: install/install-envoy.sh <version>" >&2; exit 1; }
for t in setfacl getfacl systemd-sysusers; do
  command -v "$t" >/dev/null || { echo "missing $t (Ubuntu/Debian: apt install acl)" >&2; exit 1; }
done
[ -x /usr/lib/systemd/systemd-socket-proxyd ] || { echo "missing /usr/lib/systemd/systemd-socket-proxyd" >&2; exit 1; }
setfacl_bin="$(command -v setfacl)"
repo="$(cd "$(dirname "$0")/.." && pwd)"

install -D -m 0644 "$repo/systemd/airlock-envoy.sysusers.conf" /etc/sysusers.d/airlock-envoy.conf
systemd-sysusers airlock-envoy.conf
# A pre-existing login account of that name would own the sockets and the log, and
# claude-airlock refuses sockets owned by login accounts anyway.
uid_min="$(awk '$1 == "UID_MIN" { print $2 }' /etc/login.defs 2>/dev/null)"
[ "$(id -u airlock-envoy)" -lt "${uid_min:-1000}" ] \
  || { echo "airlock-envoy exists as a login account (uid $(id -u airlock-envoy)); remove it or rename it" >&2; exit 1; }

install -d -m 0750 -o root -g airlock-envoy /etc/airlock-envoy
install -m 0640 -o root -g airlock-envoy "$repo/configs/tunnel-anthropic.yaml" /etc/airlock-envoy/tunnel-anthropic.yaml

for u in airlock-envoy.service airlock-envoy-proxy@.socket airlock-envoy-proxy@.service; do
  install -m 0644 "$repo/systemd/$u" "/etc/systemd/system/$u"
done
# The client's ACL, re-applied by systemd whenever it (re)creates a box socket.
install -d -m 0755 /etc/systemd/system/airlock-envoy-proxy@.socket.d
printf '[Socket]\nExecStartPost=%s -m u:%s:rw /run/airlock-envoy/%%i.sock\n' "$setfacl_bin" "$uid" \
  > /etc/systemd/system/airlock-envoy-proxy@.socket.d/client.conf
chmod 0644 /etc/systemd/system/airlock-envoy-proxy@.socket.d/client.conf

systemctl daemon-reload
systemctl enable airlock-envoy.service
systemctl restart airlock-envoy.service
for l in "${listeners[@]}"; do
  s="/run/airlock-envoy/$l.sock"
  systemctl enable "airlock-envoy-proxy@$l.socket"
  if systemctl is-active --quiet "airlock-envoy-proxy@$l.socket"; then
    # Keep the existing socket (running boxes hold it); set its whole ACL in one call.
    "$setfacl_bin" --set "u::rw,g::-,o::-,u:$uid:rw" "$s"
  else
    systemctl start "airlock-envoy-proxy@$l.socket"
  fi
  ls -l "$s"
  getfacl -cp "$s" | grep -E '^(user|group|other)'
done
# The box sockets' directory must belong to root (claude-airlock refuses it otherwise, and
# rightly: its owner could swap the socket). systemd does not re-own an existing directory.
d="$(stat -c %U:%G:%a /run/airlock-envoy)"
[ "$d" = root:root:755 ] || { echo "/run/airlock-envoy is $d, not root:root:755; remove it and rerun" >&2; exit 1; }
systemctl --no-pager --lines=0 status airlock-envoy.service || true
echo "==> For a box: airlock socket add /run/airlock-envoy/anthropic.sock   (as uid $uid, in the project)"
echo "    Envoy restarts and updates keep that socket; only open connections drop."
echo "    To cut egress: systemctl stop 'airlock-envoy-proxy@*.socket' airlock-envoy"
echo "    (stopping Envoy alone is undone by the next box connection; boxes need a relaunch after)"
