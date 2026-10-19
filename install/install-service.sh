#!/bin/bash
# Install or update the airlock-envoy service: system account, units, airlock-envoy-apply,
# and through it the config and a box-facing socket per listener
# (airlock-envoy-proxy@<listener>.socket) from /etc/airlock-envoy/site.conf, if there is one.
# Run install-envoy.sh first. Usage, as root:  install/install-service.sh <client user>
# <client user> is the account whose airlock boxes may connect (your login). Run it from a
# clean clone that no box mounts: as root it installs code and the built-in allowlist from here.
set -euo pipefail
client="${1:?usage: install-service.sh <client user>}"
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
# The ACL and drop-in use the numeric uid, never the name: a name with a space or a
# systemd specifier in it could otherwise grant a different account.
uid="$(id -u -- "$client" 2>/dev/null)" || { echo "no such user: $client" >&2; exit 1; }
[[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" != 0 ] || { echo "refusing client uid '$uid'" >&2; exit 1; }
[ -x /usr/local/bin/envoy ] || { echo "install Envoy first: install/install-envoy.sh <version>" >&2; exit 1; }
for t in setfacl getfacl systemd-sysusers setpriv; do
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

# Check the site file, if there is one, with this repo's airlock-envoy-apply before anything
# else is installed: a file it rejects then leaves the running install as it was.
"$repo/install/airlock-envoy-apply" --check >/dev/null \
  || { echo "the site file was rejected (above); the installed service is unchanged" >&2; exit 1; }

install -d -m 0750 -o root -g airlock-envoy /etc/airlock-envoy
install -m 0755 -o root -g root "$repo/install/airlock-envoy-apply" /usr/local/sbin/airlock-envoy-apply.new
mv -f /usr/local/sbin/airlock-envoy-apply.new /usr/local/sbin/airlock-envoy-apply
install -m 0755 -o root -g root "$repo/install/airlock-envoy-cred" /usr/local/sbin/airlock-envoy-cred.new
mv -f /usr/local/sbin/airlock-envoy-cred.new /usr/local/sbin/airlock-envoy-cred
# The GitHub GraphQL write check the github-api rules inline into the config.
install -D -m 0644 -o root -g root "$repo/install/github-graphql.lua" /usr/local/share/airlock-envoy/github-graphql.lua
# Credentials for plain-HTTP destinations (airlock-envoy-cred): root writes, Envoy reads.
install -d -m 0750 -o root -g airlock-envoy /etc/airlock-envoy/credentials

# airlock-envoy-web is enabled and started by airlock-envoy-apply, only while a listener lists web.
for u in airlock-envoy.service airlock-envoy-web.service airlock-envoy-proxy@.socket airlock-envoy-proxy@.service; do
  install -m 0644 "$repo/systemd/$u" "/etc/systemd/system/$u"
done
# The client's ACL, re-applied by systemd whenever it (re)creates a box socket.
install -d -m 0755 /etc/systemd/system/airlock-envoy-proxy@.socket.d
printf '[Socket]\nExecStartPost=%s -m u:%s:rw /run/airlock-envoy/%%i.sock\n' "$setfacl_bin" "$uid" \
  > /etc/systemd/system/airlock-envoy-proxy@.socket.d/client.conf
chmod 0644 /etc/systemd/system/airlock-envoy-proxy@.socket.d/client.conf

systemctl daemon-reload
systemctl enable airlock-envoy.service
# Sockets that already exist keep their inode (running boxes hold them); set each one's whole
# ACL in one call, for when the client changed. New sockets get it from the drop-in.
shopt -s nullglob
for s in /run/airlock-envoy/*.sock; do
  "$setfacl_bin" --set "u::rw,g::-,o::-,u:$uid:rw" "$s"
done
shopt -u nullglob
# Renders the config (the built-in anthropic listener, plus the site file's), restarts Envoy,
# and starts or removes the box sockets; with the kill switch on, it starts nothing.
/usr/local/sbin/airlock-envoy-apply --restart
# The hand-written config from before site files.
rm -f /etc/airlock-envoy/tunnel-anthropic.yaml
shopt -s nullglob
for s in /run/airlock-envoy/*.sock; do
  ls -l "$s"
  getfacl -cp "$s" | grep -E '^(user|group|other)'
done
shopt -u nullglob
# The box sockets' directory must belong to root (claude-airlock refuses it otherwise, and
# rightly: its owner could swap the socket). systemd does not re-own an existing directory.
# With the kill switch on since boot, no socket has made it yet: nothing to check.
if [ -e /run/airlock-envoy ] || [ ! -e /etc/airlock-envoy/stopped ]; then
  d="$(stat -c %U:%G:%a /run/airlock-envoy)"
  [ "$d" = root:root:755 ] || { echo "/run/airlock-envoy is $d, not root:root:755; remove it and rerun" >&2; exit 1; }
fi
systemctl --no-pager --lines=0 status airlock-envoy.service || true
echo "==> For a box: airlock egress proxy /run/airlock-envoy/<listener>.sock   (as uid $uid, in the project)"
echo "    More listeners: /etc/airlock-envoy/site.conf, then airlock-envoy-apply (see --help)."
echo "    Envoy restarts and updates keep the sockets; only open connections drop."
echo "    To cut egress: airlock-envoy-apply --stop (holds across applies and reboots; --start lifts it)"
