#!/bin/bash
# Install or update the airlock-envoy service: system account, units, airlock-envoy-apply,
# and through it the config and a box-facing socket per listener
# (airlock-envoy-proxy@<listener>.socket) from /etc/airlock-envoy/site.conf, if there is one.
# Run install-envoy.sh first. Usage, as root:
#   install/install-service.sh                         the site file in /etc, if any
#   install/install-service.sh --site FILE [--yes]     with FILE as the site file: checked by
#       this version, shown and confirmed (--yes skips), and installed with it. For a site
#       file this version needs (a new format) where the one in /etc is the old version's.
# Who may connect to which socket is the site file's (client <listener> <user>), one user per
# listener. Run it from a clean clone that no box mounts: as root it installs code and the
# built-in allowlist from here.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
site="" site_set=0 yes=0 ignored=()
while [ $# -gt 0 ]; do
  case "$1" in
    --site) { [ $# -ge 2 ] && [ -n "$2" ]; } || { echo "install-service.sh: --site needs a file" >&2; exit 1; }
            [ "$site_set" = 0 ] || { echo "install-service.sh: --site given twice" >&2; exit 1; }
            site=$2 site_set=1; shift ;;
    --yes) yes=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "install-service.sh: unknown option $1 (--site FILE, --yes)" >&2; exit 1 ;;
    *) ignored+=("$1") ;;
  esac
  shift
done
if [ ${#ignored[@]} -gt 0 ]; then
  echo "install-service.sh: WARNING: it takes no client user any more (ignored: ${ignored[*]}). Each listener names its" >&2
  echo "    own in the site file: client <listener> <user> (airlock-envoy-apply --help)" >&2
fi
[ -x /usr/local/bin/envoy ] || { echo "install Envoy first: install/install-envoy.sh <version>" >&2; exit 1; }
for t in setfacl getfacl systemd-sysusers setpriv curl; do
  command -v "$t" >/dev/null || { echo "missing $t (Ubuntu/Debian: apt install acl curl)" >&2; exit 1; }
done
# The timer runs /usr/sbin/logrotate (on Arch /usr/sbin is /usr/bin).
[ -x /usr/sbin/logrotate ] || { echo "missing logrotate (Ubuntu/Debian: apt install logrotate; Arch: pacman -S logrotate)" >&2; exit 1; }
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
# else is installed: a file it rejects then leaves the running install as it was. A --site
# file is read once, into a copy only root can change, and that copy is what is checked and
# installed: the file itself may be writable by more than root (a checkout), so a person
# confirms what it changes.
if [ -n "$site" ]; then
  # Opened once, not through a link, and a regular file: whoever can write the checkout can't
  # swap in a device, a pipe or root's own files between a check and the read. 1 MiB at most.
  [ ! -L "$site" ] || { echo "install-service.sh: $site is a symlink; name the file itself" >&2; exit 1; }
  exec 4< "$site" || { echo "install-service.sh: cannot read $site" >&2; exit 1; }
  [ -f /proc/self/fd/4 ] || { echo "install-service.sh: $site is not a regular file" >&2; exit 1; }
  site_copy="$(umask 077; mktemp /tmp/airlock-envoy-site.XXXXXX)"
  trap 'rm -f "$site_copy"' EXIT
  head -c 1048577 <&4 > "$site_copy"; exec 4<&-
  [ "$(stat -c %s "$site_copy")" -le 1048576 ] || { echo "install-service.sh: $site is over 1 MiB" >&2; exit 1; }
  # Messages name FILE, not the copy.
  if ! out="$("$repo/install/airlock-envoy-apply" --check "$site_copy" 2>&1)"; then
    printf '%s\n' "${out//"$site_copy"/"$site"}" >&2
    echo "$site was rejected (above); the installed service is unchanged" >&2; exit 1
  fi
  printf '%s\n' "${out//"$site_copy"/"$site"}"
  if [ "$yes" = 0 ]; then
    { exec 3</dev/tty; } 2>/dev/null || { echo "no terminal to confirm on; check the change above, then rerun with --yes" >&2; exit 1; }
    read -r -u 3 -p "Install this version with $site as /etc/airlock-envoy/site.conf? [y/N] " a || a=
    [[ "$a" == [yY]* ]] || { echo "not installed; the installed service is unchanged" >&2; exit 1; }
  fi
else
  "$repo/install/airlock-envoy-apply" --check >/dev/null \
    || { echo "the site file was rejected (above); the installed service is unchanged" >&2; exit 1; }
fi

install -d -m 0750 -o root -g airlock-envoy /etc/airlock-envoy
install -m 0755 -o root -g root "$repo/install/airlock-envoy-apply" /usr/local/sbin/airlock-envoy-apply.new
mv -f /usr/local/sbin/airlock-envoy-apply.new /usr/local/sbin/airlock-envoy-apply
install -m 0755 -o root -g root "$repo/install/airlock-envoy-cred" /usr/local/sbin/airlock-envoy-cred.new
mv -f /usr/local/sbin/airlock-envoy-cred.new /usr/local/sbin/airlock-envoy-cred
# Log rotation (airlock-envoy-logrotate.timer runs logrotate with this, every 15 minutes).
# Not in /etc/logrotate.d: its own timer and state, apart from the distribution's daily run.
install -m 0644 -o root -g root "$repo/install/logrotate.conf" /etc/airlock-envoy/logrotate.conf.new
mv -f /etc/airlock-envoy/logrotate.conf.new /etc/airlock-envoy/logrotate.conf
# The GitHub GraphQL write check the github-api rules inline into the config.
install -D -m 0644 -o root -g root "$repo/install/github-graphql.lua" /usr/local/share/airlock-envoy/github-graphql.lua
# The push check of protected branches (protect), inlined likewise.
install -D -m 0644 -o root -g root "$repo/install/git-protect.lua" /usr/local/share/airlock-envoy/git-protect.lua
# Credentials for plain-HTTP destinations (airlock-envoy-cred): root writes, Envoy reads.
install -d -m 0750 -o root -g airlock-envoy /etc/airlock-envoy/credentials
# CAs for plain-HTTP hosts with their own (airlock-envoy-cred ca): not secret, root writes.
install -d -m 0750 -o root -g airlock-envoy /etc/airlock-envoy/ca

# airlock-envoy-web is enabled and started by airlock-envoy-apply, only while a listener lists web.
# airlock-envoy-cred-expire.timer is started by airlock-envoy-cred unlock, and stopped when it locks.
for u in airlock-envoy.service airlock-envoy-web.service airlock-envoy-proxy@.socket airlock-envoy-proxy@.service \
         airlock-envoy-logrotate.service airlock-envoy-logrotate.timer \
         airlock-envoy-cred-expire.service airlock-envoy-cred-expire.timer; do
  install -m 0644 "$repo/systemd/$u" "/etc/systemd/system/$u"
done
# Earlier versions' one global client: each listener's own drop-in (airlock-envoy-apply) has
# its user now.
rm -f /etc/systemd/system/airlock-envoy-proxy@.socket.d/client.conf
rmdir /etc/systemd/system/airlock-envoy-proxy@.socket.d 2>/dev/null || true

systemctl daemon-reload
systemctl enable airlock-envoy.service
systemctl enable --now airlock-envoy-logrotate.timer
# The --site file, as checked, goes in now: the units it needs are in place.
if [ -n "$site" ]; then
  # The one it replaces is kept (site.conf.prev): an earlier version reads only that format.
  [ ! -f /etc/airlock-envoy/site.conf ] || cp -p /etc/airlock-envoy/site.conf /etc/airlock-envoy/site.conf.prev
  install -m 0640 -o root -g airlock-envoy "$site_copy" /etc/airlock-envoy/site.conf.new
  mv -f /etc/airlock-envoy/site.conf.new /etc/airlock-envoy/site.conf
fi
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
