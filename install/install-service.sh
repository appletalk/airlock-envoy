#!/bin/bash
# Install or update the airlock-envoy service: system account, units, airlock-envoy-apply,
# and through it the config and a box-facing socket per listener
# (airlock-envoy-proxy@<listener>.socket) from /etc/airlock-envoy/site.conf, if there is one.
# Run install-envoy.sh first. Usage, as root:  install/install-service.sh
# Who may connect to which socket is the site file's (client <listener> <user>), one user per
# listener. Run it from a clean clone that no box mounts: as root it installs code and the
# built-in allowlist from here.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
if [ $# -gt 0 ]; then
  echo "install-service.sh: WARNING: it takes no client user any more (ignored: $*). Each listener names its" >&2
  echo "    own in the site file: client <listener> <user> (airlock-envoy-apply --help)" >&2
fi
[ -x /usr/local/bin/envoy ] || { echo "install Envoy first: install/install-envoy.sh <version>" >&2; exit 1; }
for t in setfacl getfacl systemd-sysusers setpriv; do
  command -v "$t" >/dev/null || { echo "missing $t (Ubuntu/Debian: apt install acl)" >&2; exit 1; }
done
[ -x /usr/lib/systemd/systemd-socket-proxyd ] || { echo "missing /usr/lib/systemd/systemd-socket-proxyd" >&2; exit 1; }
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
# Earlier versions' one global client: each listener's own drop-in (airlock-envoy-apply) has
# its user now.
rm -f /etc/systemd/system/airlock-envoy-proxy@.socket.d/client.conf
rmdir /etc/systemd/system/airlock-envoy-proxy@.socket.d 2>/dev/null || true

systemctl daemon-reload
systemctl enable airlock-envoy.service
# Renders the config from the site file, restarts Envoy, and starts or removes the box sockets
# (each with its user's drop-in; sockets from an earlier version, in /run/airlock-envoy/ itself,
# go); with the kill switch on, it starts nothing.
/usr/local/sbin/airlock-envoy-apply --restart
# The hand-written config from before site files.
rm -f /etc/airlock-envoy/tunnel-anthropic.yaml
shopt -s nullglob
for s in /run/airlock-envoy/*/*.sock; do
  ls -l "$s"
  getfacl -cp "$s" | grep -E '^(user|group|other)'
done
shopt -u nullglob
# The box sockets' directory must belong to root (claude-airlock refuses it otherwise, and
# rightly: its owner could swap the socket); each socket's start makes it so. With no socket
# started yet (none in the site file, or the kill switch on since boot): nothing to check.
if [ -e /run/airlock-envoy ]; then
  d="$(stat -c %U:%G:%a /run/airlock-envoy)"
  [ "$d" = root:root:755 ] || { echo "/run/airlock-envoy is $d, not root:root:755; remove it and rerun" >&2; exit 1; }
fi
systemctl --no-pager --lines=0 status airlock-envoy.service || true
if ! compgen -G '/run/airlock-envoy/*/*.sock' >/dev/null && [ ! -e /etc/airlock-envoy/stopped ]; then
  echo "==> No box sockets yet: give the site file a listener and its user (client <listener> <user>)"
fi
echo "==> For a box: airlock egress proxy /run/airlock-envoy/<user>/<listener>.sock   (as <user>, in the project)"
echo "    Listeners and their users: /etc/airlock-envoy/site.conf, then airlock-envoy-apply (see --help)."
echo "    Envoy restarts and updates keep the sockets; only open connections drop."
echo "    To cut egress: airlock-envoy-apply --stop (holds across applies and reboots; --start lifts it)"
