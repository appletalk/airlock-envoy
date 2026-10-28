#!/bin/bash
# End-to-end install test in a systemd-booted container: install-envoy.sh (in the image build,
# re-run whenever it, the release key or the version changes) and install-service.sh run as
# root inside it, then an unprivileged client tunnels through the
# socket, then site listeners are added, changed and removed with airlock-envoy-apply.
# Usage: test/install-test.sh ubuntu[-22.04|-24.04|-26.04]|debian|arch [envoy version]
# (rootless podman; plain ubuntu = 24.04)
# OLD_REPO (optional): an earlier checkout, installed first, to test the upgrade from it.
# ck takes its condition as a string to eval, so single quotes and later-used variables are meant.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
# One user namespace for the whole run: podman works inside it, and entering the container
# with nsenter takes ~2 ms where each podman exec takes ~160 ms (the test makes ~130 calls).
[ -n "${_CONTAINERS_USERNS_CONFIGURED:-}" ] || exec podman unshare "$0" "$@"
cd "$(dirname "$0")/.."
distro="${1:?ubuntu[-VERSION], debian or arch}"
ver="${2:-1.40.2}"
apt_prep='apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv curl gpg acl socat jq ca-certificates openssl logrotate python3 >/dev/null'
case "$distro" in
  ubuntu|ubuntu-24.04) base=docker.io/library/ubuntu:24.04; prep="$apt_prep"; init=/sbin/init ;;
  ubuntu-22.04) base=docker.io/library/ubuntu:22.04; prep="$apt_prep"; init=/sbin/init ;;
  ubuntu-26.04) base=docker.io/library/ubuntu:26.04; prep="$apt_prep"; init=/sbin/init ;;
  debian) base=docker.io/library/debian:13; prep="$apt_prep"; init=/sbin/init ;;
  arch)   base=docker.io/library/archlinux:latest
          prep='pacman -Syu --noconfirm --quiet curl gnupg acl socat jq openssl logrotate python >/dev/null'
          init=/usr/lib/systemd/systemd ;;
  *) echo "ubuntu[-22.04|-24.04|-26.04], debian or arch" >&2; exit 2 ;;
esac
img="localhost/airlock-envoy-install-test:$distro"
name="airlock-envoy-install-test-$distro"
# install-envoy.sh runs in the build: a cached layer until the script, the key or the version
# changes, so the ~60 MB download is not repeated on every run.
podman build -q -t "$img" -f - . >/dev/null <<EOF
FROM $base
RUN $prep && useradd -m client && useradd -m other
COPY install/install-envoy.sh install/envoy-release-key.asc /tmp/install-envoy/
RUN /tmp/install-envoy/install-envoy.sh $ver && rm -r /tmp/install-envoy
CMD ["$init"]
EOF
podman rm -f "$name" >/dev/null 2>&1 || true
# AIRLOCK_REPO (optional): a claude-airlock checkout, to run its real socket check.
airlock_mount=()
[ -n "${AIRLOCK_REPO:-}" ] && airlock_mount=(-v "$AIRLOCK_REPO:/airlock:ro")
[ -n "${OLD_REPO:-}" ] && airlock_mount+=(-v "$OLD_REPO:/old:ro")
podman run -d --name "$name" --systemd=always -v ./:/repo:ro "${airlock_mount[@]}" "$img" >/dev/null
# On a failure, Envoy's journal first: the container goes with the trap.
# shellcheck disable=SC2329  # run by the trap
cleanup() {
  local rc=$?
  [ "$rc" = 0 ] || podman exec "$name" journalctl -u airlock-envoy -u airlock-envoy-logrotate -u airlock-envoy-mint --no-pager -n 60 2>/dev/null || true
  podman rm -f "$name" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT
pid="$(podman inspect -f '{{.State.Pid}}' "$name")"
# Root in the container (all its namespaces, no supplementary groups, a clean environment).
# setsid: no controlling terminal, so a confirmation prompt (which opens /dev/tty) is refused as
# on a host with none, instead of waiting on the terminal the test was started from.
x() {
  setsid -w nsenter -t "$pid" -m -u -i -n -p -C -r -w setpriv --clear-groups \
    env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 "$@"
}
for _ in $(seq 100); do
  # is-system-running exits non-zero for "degraded" (a container always has some failed
  # unit), so match its output, not its status (pipefail made this wait out every time).
  case "$(x systemctl is-system-running 2>/dev/null || true)" in running|degraded) break ;; esac
  sleep 0.05
done
echo "== $distro: Envoy $ver installed by install-envoy.sh in the image build: $(x envoy --version | grep -o '/[0-9.]*/' | tr -d /)"
fails=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
# client's Claude-only listener: in every site file below (see site), so it stays put.
S=/run/airlock-envoy/client/c-anthropic.sock
site() {  # site <line>...: /etc/airlock-envoy/site.conf: client's c-anthropic, then these lines
  x sh -c 'printf "%s\n" "c-anthropic @anthropic" "client c-anthropic client" "$@" > /etc/airlock-envoy/site.conf' sh "$@"
}
TUSER=client
UPGRADE_SITE=()
xsum() { x sha256sum "$1" | cut -d' ' -f1; }   # inside the container (a redirect would be the host's)
tunnel() {  # tunnel [socket [host...]]: through a box socket as $TUSER, each CONNECT's status
  local sock="${1:-$S}"; shift || true
  [ $# -gt 0 ] || set -- api.anthropic.com example.com
  x runuser -u "$TUSER" -- bash -c 'socat TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:"$0" &
    until grep -q ":0C38 00000000:0000 0A" /proc/net/tcp; do sleep 0.01; done   # 127.0.0.1:3128 listening
    r=; for h in "$@"; do r="$r $(curl -s -o /dev/null -w "%{http_connect}" -x http://127.0.0.1:3128 "https://$h/")"; done
    kill %1; wait; echo ${r# }' "$sock" "$@" 2>/dev/null
}
if [ -n "${OLD_REPO:-}" ]; then
  echo "== $distro: the earlier install (OLD_REPO)"
  OLD_S=/run/airlock-envoy/anthropic.sock   # one global client, sockets in /run/airlock-envoy/ itself
  x /old/install/install-service.sh client >/dev/null
  r="$(tunnel "$OLD_S")"
  ck "the earlier install works: got '$r'" '[ "$r" = "200 403" ]'
  old_ino="$(x stat -c %i "$OLD_S")"
  # A site file the new version rejects: the upgrade stops before changing anything.
  x sh -c 'echo "bad Example.com:443" > /etc/airlock-envoy/site.conf && chmod 0640 /etc/airlock-envoy/site.conf'
  unit="$(x sha256sum /etc/systemd/system/airlock-envoy.service)"
  oldapply="$(x sha256sum /usr/local/sbin/airlock-envoy-apply 2>/dev/null || echo none)"
  ck "an upgrade with a rejected site file fails and leaves the earlier install as it was" \
     '! x /repo/install/install-service.sh >/dev/null 2>&1 && [ "$(x sha256sum /etc/systemd/system/airlock-envoy.service)" = "$unit" ] && [ "$(x sha256sum /usr/local/sbin/airlock-envoy-apply 2>/dev/null || echo none)" = "$oldapply" ]'
  # The earlier version's site files have no client lines: this one refuses them the same way.
  x sh -c 'echo "extra @anthropic example.com:443" > /etc/airlock-envoy/site.conf'
  out="$(x /repo/install/install-service.sh 2>&1)" && rc=0 || rc=$?
  ck "...and so does one without client lines (valid before): it says so, the earlier install stays (same socket)" \
     '[ "$rc" != 0 ] && [[ "$out" == *"listener extra has no client"* ]] && [ "$(x sha256sum /etc/systemd/system/airlock-envoy.service)" = "$unit" ] && [ "$(x stat -c %i "$OLD_S")" = "$old_ino" ]'
  x systemctl restart airlock-envoy
  r="$(tunnel "$OLD_S")"
  ck "...and it still works after an Envoy restart: got '$r'" '[ "$r" = "200 403" ]'
  # The way through: --site with a file in this version's format, checked by it and installed
  # with it. A person confirms (no terminal here, so --yes); a file it rejects changes nothing.
  x sh -c 'printf "%s\n" "c-anthropic @anthropic" "client c-anthropic client" > /root/new-site.conf'
  x sh -c 'echo "c-anthropic @anthropic" > /root/bad-site.conf'
  ck "--site: a file this version rejects, or no confirmation (no terminal, no --yes): refused, the earlier install as it was" \
     '! x /repo/install/install-service.sh --site /root/bad-site.conf --yes >/dev/null 2>&1 && ! x /repo/install/install-service.sh --site /root/new-site.conf >/dev/null 2>&1 && [ "$(x sha256sum /etc/systemd/system/airlock-envoy.service)" = "$unit" ] && [ "$(x stat -c %i "$OLD_S")" = "$old_ino" ]'
  x ln -sf /root/new-site.conf /root/link-site.conf
  x mkfifo /root/fifo-site.conf
  ck "--site refuses a symlink, a FIFO (no hang), an empty name, an unknown option, --site twice; nothing changed" \
     '! x /repo/install/install-service.sh --site /root/link-site.conf --yes >/dev/null 2>&1 && ! timeout 10 x /repo/install/install-service.sh --site /root/fifo-site.conf --yes >/dev/null 2>&1 && ! x /repo/install/install-service.sh --site "" --yes >/dev/null 2>&1 && ! x /repo/install/install-service.sh --site=/root/new-site.conf >/dev/null 2>&1 && ! x /repo/install/install-service.sh --site /root/new-site.conf --site /root/new-site.conf --yes >/dev/null 2>&1 && [ "$(x sha256sum /etc/systemd/system/airlock-envoy.service)" = "$unit" ] && [ "$(x stat -c %i "$OLD_S")" = "$old_ino" ]'
  out="$(x /repo/install/install-service.sh --site /root/bad-site.conf --yes 2>&1 || true)"
  ck "--site: a rejected file's errors name it, not the temp copy" '[[ "$out" == *"/root/bad-site.conf"* && "$out" != *"/tmp/airlock-envoy-site."* ]]'
  oldsite="$(xsum /etc/airlock-envoy/site.conf)"
  UPGRADE_SITE=(--site /root/new-site.conf --yes)
fi
echo "== $distro: install-service.sh"
out="$(x /repo/install/install-service.sh client "${UPGRADE_SITE[@]}" 2>&1)"
printf '%s\n' "$out"
ck "install-service.sh warns that it takes no client user any more, and goes on" '[[ "$out" == *"takes no client user any more (ignored: client)"* ]]'
echo "== $distro: checks"
if [ -n "${OLD_REPO:-}" ]; then
  ck "upgrade with --site: the file installed as the site file (root:airlock-envoy 0640), as it was given; the old one kept as site.conf.prev" \
     '[ "$(x stat -c %U:%G:%a /etc/airlock-envoy/site.conf)" = root:airlock-envoy:640 ] && [ -n "$oldsite" ] && [ "$(xsum /etc/airlock-envoy/site.conf)" = "$(xsum /root/new-site.conf)" ] && [ "$(xsum /etc/airlock-envoy/site.conf.prev)" = "$oldsite" ]'
  ck "upgrade: the earlier flat socket, its manifest, unit and global client drop-in go, and the old config file" \
     '! x test -e "$OLD_S" && ! x test -e /run/airlock-envoy/anthropic.clients && ! x test -e /etc/systemd/system/airlock-envoy-proxy@.socket.d && [ "$(x systemctl is-enabled airlock-envoy-proxy@anthropic.socket 2>/dev/null)" != enabled ] && ! x test -e /etc/airlock-envoy/tunnel-anthropic.yaml'
else
  ck "a fresh install without a site file: Envoy runs, no box socket at all, and it says so" \
     '[ "$(x systemctl is-active airlock-envoy)" = active ] && ! x test -e /run/airlock-envoy && [[ "$out" == *"No box sockets yet"* ]]'
  site
  x airlock-envoy-apply >/dev/null
fi
ck "envoy and the box socket active" '[ "$(x systemctl is-active airlock-envoy airlock-envoy-proxy@c-anthropic.socket | tr "\n" " ")" = "active active " ]'
# With an ACL the group bits show the mask, so check the ACL itself.
ck "box socket owned by airlock-envoy; ACL: owner rw, client rw, group/other none" \
   '[ "$(x stat -c %U "$S")" = airlock-envoy ] && [ "$(x getfacl -cp "$S" | grep -E "^(user|group|other)" | LC_ALL=C sort | tr "\n" " ")" = "group::--- other::--- user::rw- user:client:rw- " ]'
ck "box socket dir root:root 0755 (only root can rename in it)" '[ "$(x stat -c %U:%G:%a /run/airlock-envoy)" = root:root:755 ]'
ck "the user's dir in it: root 0700, an ACL letting the client alone enter (r-x), nobody else" \
   '[ "$(x stat -c %U:%G "/run/airlock-envoy/client")" = root:root ] && [ "$(x getfacl -cp /run/airlock-envoy/client | grep -v "^$" | LC_ALL=C sort | tr "\n" " ")" = "group::--- mask::r-x other::--- user::rwx user:client:r-x " ]'
ck "the socket's drop-in: root 0644, names the client by uid ($(x id -u client))" \
   '[ "$(x stat -c %U:%G:%a /etc/systemd/system/airlock-envoy-proxy@c-anthropic.socket.d/client.conf)" = root:root:644 ] && x grep -qx "ListenStream=$S" /etc/systemd/system/airlock-envoy-proxy@c-anthropic.socket.d/client.conf && x grep -q "u:$(x id -u client):rw- $S\$" /etc/systemd/system/airlock-envoy-proxy@c-anthropic.socket.d/client.conf'
ck "envoy's own dir airlock-envoy 0700" '[ "$(x stat -c %U:%a /run/airlock-envoy-internal)" = airlock-envoy:700 ]'
ck "client cannot reach envoy's own socket" '! x runuser -u client -- socat -u /dev/null UNIX-CONNECT:/run/airlock-envoy-internal/c-anthropic.sock 2>/dev/null'
ck "airlock-envoy is a system account (uid < 1000)" '[ "$(x id -u airlock-envoy)" -lt 1000 ]'
ck "config and applied list root:airlock-envoy 0640" '[ "$(x stat -c %U:%G:%a /etc/airlock-envoy/envoy.yaml /etc/airlock-envoy/allowed | tr "\n" " ")" = "root:airlock-envoy:640 root:airlock-envoy:640 " ]'
x mv /etc/airlock-envoy/envoy.yaml /etc/airlock-envoy/envoy.yaml.away
ck "Envoy fails to start without its config (the socket wait does not pass on nothing)" '! x systemctl restart airlock-envoy 2>/dev/null'
x mv /etc/airlock-envoy/envoy.yaml.away /etc/airlock-envoy/envoy.yaml
x systemctl reset-failed airlock-envoy; x systemctl restart airlock-envoy
ck "airlock-envoy-apply root 0755" '[ "$(x stat -c %U:%G:%a /usr/local/sbin/airlock-envoy-apply)" = root:root:755 ]'
ck "access log not readable by client" '! x runuser -u client -- cat /var/log/airlock-envoy/access.jsonl >/dev/null 2>&1'
r="$(tunnel)"
ck "client tunnels to api.anthropic.com (200), example.com refused (403): got '$r'" '[ "$r" = "200 403" ]'
ck "another user cannot connect" '! x runuser -u nobody -- socat -u /dev/null UNIX-CONNECT:"$S" 2>/dev/null'
# Envoy flushes the log every second: wait for both decisions rather than a fixed time.
x sh -c 'for _ in $(seq 60); do grep -q allow-api.anthropic.com "$0" && grep -q deny-connect "$0" && exit 0; sleep 0.05; done' /var/log/airlock-envoy/access.jsonl || true
ck "decisions in the access log" '[ "$(x grep -c "allow-api.anthropic.com" /var/log/airlock-envoy/access.jsonl)" -ge 1 ] && [ "$(x grep -c "deny-connect" /var/log/airlock-envoy/access.jsonl)" -ge 1 ]'
ino="$(x stat -c %i "$S")"
x systemctl restart airlock-envoy
r="$(tunnel)"
ck "envoy restart keeps the box socket (same inode) and it works at once: got '$r'" '[ "$(x stat -c %i "$S")" = "$ino" ] && [ "$r" = "200 403" ]'
# Log rotation: the installed timer and unit, logrotate with the real Envoy. Forced (-f, by a
# drop-in on the unit's command): the audit log moves to access.jsonl-<time> as airlock-envoy
# 0600, postrotate has Envoy reopen, and the next decisions land in a new access.jsonl; a second
# forced rotation compresses the first (delaycompress).
ck "logrotate timer enabled and active" '[ "$(x systemctl is-enabled airlock-envoy-logrotate.timer) $(x systemctl is-active airlock-envoy-logrotate.timer)" = "enabled active" ]'
x systemctl stop airlock-envoy-logrotate.timer   # no timer run during the forced ones below
x mkdir -p /etc/systemd/system/airlock-envoy-logrotate.service.d
x sh -c 'printf "[Service]\nExecStart=\nExecStart=/usr/sbin/logrotate -f --state /var/lib/airlock-envoy/logrotate.status /etc/airlock-envoy/logrotate.conf\n" > /etc/systemd/system/airlock-envoy-logrotate.service.d/test.conf'
# Eight forced runs inside a few seconds pass systemd's default start limit (5 in 10 s), which
# the 15-minute timer never nears: reset it before each run, as for Envoy's restart burst below.
rotate() { x systemctl reset-failed airlock-envoy-logrotate.service 2>/dev/null; x systemctl start airlock-envoy-logrotate.service; }
x systemctl daemon-reload; rotate
rot1="$(x sh -c 'ls /var/log/airlock-envoy/ | grep -E "^access\.jsonl-[0-9]{8}T[0-9]{6}Z$" | head -1')"
ck "logrotate rotated the audit log to access.jsonl-<time>, as airlock-envoy 0600: '$rot1'" \
   '[ -n "$rot1" ] && [ "$(x stat -c %U:%a "/var/log/airlock-envoy/$rot1")" = airlock-envoy:600 ] && [ "$(x systemctl show -p Result --value airlock-envoy-logrotate.service)" = success ]'
r="$(tunnel)"
x sh -c 'for _ in $(seq 60); do grep -q deny-connect "$0" 2>/dev/null && exit 0; sleep 0.05; done' /var/log/airlock-envoy/access.jsonl || true
ck "Envoy reopened its log: new decisions land in a new access.jsonl, 0600: got '$r'" \
   '[ "$r" = "200 403" ] && [ "$(x grep -c deny-connect /var/log/airlock-envoy/access.jsonl)" -ge 1 ] && [ "$(x stat -c %U:%a /var/log/airlock-envoy/access.jsonl)" = airlock-envoy:600 ]'
sleep 1   # the next rotation's name must differ by a second
rotate
plain="$(x sh -c 'ls /var/log/airlock-envoy/ | grep -cE "^access\.jsonl-[0-9]{8}T[0-9]{6}Z$"')"
ck "a second rotation compresses the first (delaycompress), the newest stays plain: $plain plain" \
   'x gzip -t "/var/log/airlock-envoy/$rot1.gz" && [ "$plain" = 1 ]'
# Retention is by age only: more forced rotations (each with a line to rotate) remove nothing.
for _ in 1 2 3 4 5; do tunnel >/dev/null; sleep 1.2; rotate; done
nrot="$(x sh -c 'ls /var/log/airlock-envoy/ | grep -cE "^access\.jsonl-[0-9]{8}T[0-9]{6}Z(\.gz)?$"')"
ck "seven rotations, seven rotated files kept (no count limit): $nrot" '[ "$nrot" = 7 ]'
# ...and by age: a rotated file made 31 days old goes at the next rotation, the others stay.
x touch -d '31 days ago' "/var/log/airlock-envoy/$rot1.gz"
tunnel >/dev/null; sleep 1.2; rotate
nrot2="$(x sh -c 'ls /var/log/airlock-envoy/ | grep -cE "^access\.jsonl-[0-9]{8}T[0-9]{6}Z(\.gz)?$"')"
ck "maxage 30: the 31-day-old rotated file is gone, the other seven stay (and the new one): $nrot2" \
   '! x test -e "/var/log/airlock-envoy/$rot1.gz" && [ "$nrot2" = 7 ]'
x rm -rf /etc/systemd/system/airlock-envoy-logrotate.service.d; x systemctl daemon-reload
x systemctl start airlock-envoy-logrotate.timer
# The relay restarts with Envoy; a burst of restarts must not fail it, or the box socket.
x runuser -u client -- sh -c "printf 'CONNECT api.anthropic.com:443 HTTP/1.1\r\nHost: api.anthropic.com:443\r\n\r\n' | timeout 2 socat - UNIX-CONNECT:$S >/dev/null" || true
for _ in 1 2 3 4 5 6 7 8; do x systemctl reset-failed airlock-envoy; x systemctl restart airlock-envoy; done
r="$(tunnel)"
ck "8 Envoy restarts in a row with a relay running: same box socket, still works: got '$r'" \
   '[ "$(x systemctl is-active airlock-envoy-proxy@c-anthropic.socket)" = active ] && [ "$(x stat -c %i "$S")" = "$ino" ] && [ "$r" = "200 403" ]'
ck "running install-service.sh again keeps the socket and its ACL" \
   'x /repo/install/install-service.sh >/dev/null && [ "$(x stat -c %i "$S")" = "$ino" ] && x getfacl -p "$S" | grep -q "^user:client:rw"'
x systemctl restart airlock-envoy-proxy@c-anthropic.socket   # returns after the ACL's ExecStartPost
ck "recreating the box socket re-applies the ACL" 'x getfacl -p "$S" | grep -q "^user:client:rw"'
M=/run/airlock-envoy/client/c-anthropic.clients
ck "the socket's client manifest: next to it, root 0644, readable by the client, no hosts (anthropic has none); the /etc copy root:airlock-envoy 0640" \
   '[ "$(x stat -c %U:%G:%a "$M")" = root:root:644 ] && x runuser -u client -- grep -q "^# airlock-envoy" "$M" && ! x grep -qv "^#" "$M" && [ "$(x stat -c %U:%G:%a /etc/airlock-envoy/clients /etc/airlock-envoy/clients/c-anthropic.clients | tr "\n" " ")" = "root:airlock-envoy:750 root:airlock-envoy:640 " ]'
# --stop takes no lock: an apply holding it (say, waiting at its prompt) does not delay it.
x sh -c 'flock /run/airlock-envoy-apply.lock sh -c "touch /root/held; sleep 1" & until [ -e /root/held ]; do sleep 0.01; done
  airlock-envoy-apply --stop >/dev/null; echo "rc=$?" > /root/stop.rc; rm -f /root/held; wait'
ck "--stop works while another apply holds the lock" '[ "$(x cat /root/stop.rc)" = rc=0 ]'
ck "the kill switch, --stop, cuts egress (no connect, Envoy down)" '! x runuser -u client -- socat -u /dev/null UNIX-CONNECT:"$S" 2>/dev/null && sleep 0.3 && [ "$(x systemctl is-active airlock-envoy)" != active ]'
ck "...and the client manifest goes with the socket" '! x test -e "$M"'
x airlock-envoy-apply >/dev/null
x systemctl start airlock-envoy-proxy@c-anthropic.socket airlock-envoy 2>/dev/null || true
# As after a reboot with the switch on: no socket was ever made, so no /run/airlock-envoy.
x rm -rf /run/airlock-envoy
rc=0; x /repo/install/install-service.sh >/dev/null 2>&1 || rc=$?
ck "while it is on: an apply, a systemctl start (as at boot) and install-service.sh (rc=$rc, after a reboot) start nothing" \
   '[ "$rc" = 0 ] && [ "$(x systemctl is-active airlock-envoy airlock-envoy-proxy@c-anthropic.socket | tr "\n" " ")" = "inactive inactive " ] && ! x test -e "$S"'
# A --start that fails after Envoy is up (here: a directory where the box socket goes)
# also leaves the switch on.
x mkdir -p "$S"
ck "a --start that fails after Envoy started keeps the switch on: marker back, Envoy down" \
   '! x airlock-envoy-apply --start >/dev/null 2>&1 && x test -e /etc/airlock-envoy/stopped && [ "$(x systemctl is-active airlock-envoy)" = inactive ]'
x rm -rf /run/airlock-envoy
rc=0; out="$(x airlock-envoy-apply --status 2>&1)" || rc=$?
ck "--status with the switch on and no socket files: rc=$rc, says so, lists the socket as gone" \
   '[ "$rc" = 0 ] && [[ "$out" == *"Kill switch: ON"* && "$out" == *"$S"*"(no socket file)"*"user: client"* ]]'
x airlock-envoy-apply --start >/dev/null
p="$(x systemctl show -p MainPID --value airlock-envoy)"
x airlock-envoy-apply --start >/dev/null
ck "--start with the switch already off restarts nothing" '[ "$(x systemctl show -p MainPID --value airlock-envoy)" = "$p" ]'
r="$(tunnel)"
ck "--start brings it back with the ACL: got '$r'" '[ "$r" = "200 403" ] && x getfacl -p "$S" | grep -q "^user:client:rw" && ! x test -e /etc/airlock-envoy/stopped'
ck "...and its client manifest" 'x test -f "$M"'
# Not the kill switch: a crash. Envoy cannot start; a burst of box connections (more than the
# socket's trigger limit, 20 in 2 s) is closed, and the box socket stays up: the relay only
# Wants= Envoy. Once Envoy is back the same socket works, so running boxes need no relaunch.
ino="$(x stat -c %i "$S")"
x mv /etc/airlock-envoy/envoy.yaml /etc/airlock-envoy/envoy.yaml.away
x systemctl restart airlock-envoy 2>/dev/null || true
x runuser -u client -- sh -c 'for _ in $(seq 25); do socat -u /dev/null UNIX-CONNECT:"$0" 2>/dev/null; done' "$S" || true
r="$(tunnel)"
down="$(x systemctl is-active airlock-envoy airlock-envoy-proxy@c-anthropic.socket | tr "\n" " " || true)"
ck "Envoy down (Envoy, box socket: $down): box connections are closed ($r), the box socket stays up" \
   '[[ "$down" != "active "* ]] && [[ "$down" == *" active " ]] && [ "$r" = "000 000" ]'
x mv /etc/airlock-envoy/envoy.yaml.away /etc/airlock-envoy/envoy.yaml
# Envoy keeps retrying (with back-off, no start limit), so it comes back by itself. Within
# this test it would also come back under the default limit, so check the setting too.
ck "Envoy has no start limit (StartLimitIntervalUSec=$(x systemctl show -p StartLimitIntervalUSec --value airlock-envoy))" \
   '[ "$(x systemctl show -p StartLimitIntervalUSec --value airlock-envoy)" = 0 ]'
for _ in $(seq 150); do [ "$(x systemctl is-active airlock-envoy || true)" = active ] && break; sleep 0.1; done
r="$(tunnel)"
ck "...Envoy comes back by itself and the same box socket works (no relaunch): got '$r'" \
   '[ "$(x systemctl is-active airlock-envoy)" = active ] && [ "$(x stat -c %i "$S")" = "$ino" ] && [ "$r" = "200 403" ]'
# Envoy and the relay stopped (not the kill switch): a box connection starts both.
x systemctl stop airlock-envoy airlock-envoy-proxy@c-anthropic.service
r="$(tunnel)"
ck "a box connection starts a stopped Envoy through the relay: got '$r'" '[ "$r" = "200 403" ] && [ "$(x systemctl is-active airlock-envoy)" = active ]'
x systemctl stop airlock-envoy-proxy@c-anthropic.socket
x airlock-envoy-apply >/dev/null
r="$(tunnel)"
ck "a box socket stopped by hand is not the kill switch: an apply starts it again: got '$r'" '[ "$r" = "200 403" ]'

echo "== $distro: site listeners"
E=/run/airlock-envoy/client/extra.sock
pid() { x systemctl show -p MainPID --value airlock-envoy; }
ino="$(x stat -c %i "$S")"
site "# test site" "extra @anthropic example.com:443" "client extra client"
x airlock-envoy-apply >/dev/null
r="$(tunnel "$E" api.anthropic.com example.com example.org)"
ck "a site listener: its own socket, the include and its host pass, others refused: got '$r'" '[ "$r" = "200 200 403" ]'
ck "its socket has the client's ACL, in the root-owned directory" \
   '[ "$(x getfacl -cp "$E" | grep -E "^(user|group|other)" | LC_ALL=C sort | tr "\n" " ")" = "group::--- other::--- user::rw- user:client:rw- " ]'
r="$(tunnel)"
ck "the c-anthropic socket is unchanged (same inode) and still refuses example.com: got '$r'" '[ "$(x stat -c %i "$S")" = "$ino" ] && [ "$r" = "200 403" ]'
x sh -c 'flock /run/airlock-envoy-apply.lock sh -c "touch /root/held; sleep 1" & until [ -e /root/held ]; do sleep 0.01; done
  airlock-envoy-apply >/dev/null 2>&1; echo "rc=$?" > /root/lock.rc; rm -f /root/held; wait'
ck "a second apply while one runs is refused" '[ "$(x cat /root/lock.rc)" = rc=1 ]'
p="$(pid)"
out="$(x airlock-envoy-apply)"
ck "applying again with no change leaves Envoy running (no restart)" '[ "$(pid)" = "$p" ] && [[ "$out" == *"no change"* ]]'
out="$(x airlock-envoy-apply --status)"
ck "--status: Envoy active, kill switch off, the extra socket for the client, applied" \
   '[[ "$out" == *"Envoy: active"* && "$out" == *"Kill switch: off"* && "$out" == *"$E"*"user: client, ACL: client"* && "$out" == *"Applied: yes"* ]]'
out="$(x runuser -u client -- airlock-envoy-apply --status 2>&1)"
ck "--status as the client: sockets shown, the rest needs root" '[[ "$out" == *"$E"* && "$out" == *"Kill switch: unknown (run as root)"* && "$out" != *"Applied"* ]]'
site "extra @anthropic example.com:443 example.net:443" "client extra client"
out="$(x airlock-envoy-apply --status)"
ck "--status: a site file changed but not applied shows as not applied" '[[ "$out" == *"Applied: NO"* ]]'
site "extra @anthropic example.com:443" "client extra client"
cfg="$(x sha256sum /etc/airlock-envoy/envoy.yaml)"
x sh -c 'echo "extra Example.com:443" > /etc/airlock-envoy/site.conf'
ck "a bad site file is refused and changes nothing" '! x airlock-envoy-apply >/dev/null 2>&1 && [ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ] && [ "$(pid)" = "$p" ]'
x sh -c 'printf "%s\n" "c-anthropic @anthropic" "client c-anthropic client" "extra @anthropic example.org:443" "client extra client" > /home/client/site.conf && chown client /home/client/site.conf'
# A valid site.conf, the one already applied, so only the file's ownership can refuse it.
site "extra @anthropic example.com:443" "client extra client"
x airlock-envoy-apply >/dev/null
x cp -p /etc/airlock-envoy/site.conf /root/site.conf.keep
x ln -sf /home/client/site.conf /etc/airlock-envoy/site.conf
ck "site.conf as a symlink to a file the client can edit is refused, by default and by name" \
   '! x airlock-envoy-apply >/dev/null 2>&1 && ! x airlock-envoy-apply /etc/airlock-envoy/site.conf >/dev/null 2>&1 && [ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ]'
x sh -c 'rm /etc/airlock-envoy/site.conf && cp -p /root/site.conf.keep /etc/airlock-envoy/site.conf && chmod 0664 /etc/airlock-envoy/site.conf'
ck "a group-writable site.conf is refused" '! x airlock-envoy-apply >/dev/null 2>&1 && [ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ]'
x chmod 0640 /etc/airlock-envoy/site.conf
ck "a site file from elsewhere needs a confirmation (no terminal, no --yes: refused)" \
   '! x airlock-envoy-apply /home/client/site.conf >/dev/null 2>&1 && ! x grep -q example.org /etc/airlock-envoy/site.conf'
# A named path that only resolves to /etc (a symlink its owner could repoint) is from elsewhere.
site "extra @anthropic example.com:443 example.net:443" "client extra client"
x runuser -u client -- ln -sf /etc/airlock-envoy/site.conf /home/client/link
ck "a symlink to the /etc site file, named, still needs the confirmation" \
   '! x airlock-envoy-apply /home/client/link >/dev/null 2>&1 && [ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ]'
x cp -p /root/site.conf.keep /etc/airlock-envoy/site.conf
x airlock-envoy-apply --yes /home/client/site.conf >/dev/null
r="$(tunnel "$E" example.org example.com)"
ck "with --yes it is installed as site.conf (root:airlock-envoy 0640) and applied: got '$r'" \
   '[ "$(x sha256sum /home/client/site.conf | cut -d" " -f1)" = "$(x sha256sum /etc/airlock-envoy/site.conf | cut -d" " -f1)" ] && [ "$(x stat -c %U:%G:%a /etc/airlock-envoy/site.conf)" = root:airlock-envoy:640 ] && [ "$r" = "200 403" ]'
site
x airlock-envoy-apply >/dev/null
ck "a listener removed from the site file loses its socket, unit stopped and disabled, and its client manifest (both copies)" \
   '! x test -e "$E" && [ "$(x systemctl is-active airlock-envoy-proxy@extra.socket)" != active ] && [ "$(x systemctl is-enabled airlock-envoy-proxy@extra.socket 2>/dev/null)" != enabled ] && ! x test -e /run/airlock-envoy/client/extra.clients && ! x test -e /etc/airlock-envoy/clients/extra.clients && ! x test -e /etc/systemd/system/airlock-envoy-proxy@extra.socket.d'
r="$(tunnel)"
ck "c-anthropic still works after the removal (same inode): got '$r'" '[ "$(x stat -c %i "$S")" = "$ino" ] && [ "$r" = "200 403" ]'
site "extra @anthropic example.com:443" "client extra client"
x airlock-envoy-apply >/dev/null
x /repo/install/install-service.sh >/dev/null
r="$(tunnel "$E" example.com)"
ck "install-service.sh again keeps site listeners and their sockets: got '$r'" '[ "$r" = 200 ] && x getfacl -p "$E" | grep -q "^user:client:rw"'
x systemctl restart airlock-envoy
r="$(tunnel "$E" example.com)"
ck "Envoy restart: the site listener works at once: got '$r'" '[ "$r" = 200 ]'
# A config Envoy validates but will not start with: a wrapper refuses any config that has a
# listener named "nostart". apply must put the previous config back and keep Envoy running.
x sh -c 'real="$(readlink -f /usr/local/bin/envoy)"; printf "%s\n" "#!/bin/sh" \
  "case \" \$* \" in *\" --mode validate \"*) ;; *) grep -q nostart /etc/airlock-envoy/envoy.yaml && exit 1 ;; esac" \
  "exec $real \"\$@\"" > /usr/local/bin/envoy.wrap && chmod 0755 /usr/local/bin/envoy.wrap && mv /usr/local/bin/envoy /usr/local/bin/envoy.real && mv /usr/local/bin/envoy.wrap /usr/local/bin/envoy'
x sh -c 'printf "%s\n" "nostart @anthropic example.org:443" "client nostart client" > /home/client/site2.conf'
cfg="$(x sha256sum /etc/airlock-envoy/envoy.yaml)"; sitesum="$(x sha256sum /etc/airlock-envoy/site.conf)"
ck "a config Envoy will not start with: apply fails and says so" '! x airlock-envoy-apply --yes /home/client/site2.conf >/dev/null 2>&1'
r="$(tunnel "$E" example.com)"
ck "...and the previous config, site file and running Envoy are back: got '$r'" \
   '[ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ] && [ "$(x sha256sum /etc/airlock-envoy/site.conf)" = "$sitesum" ] && [ "$(x systemctl is-active airlock-envoy)" = active ] && [ "$r" = 200 ] && ! x test -e /run/airlock-envoy/client/nostart.sock'
# A --start that fails (same wrapper) leaves the kill switch on, nothing half started.
x airlock-envoy-apply --stop >/dev/null
site "nostart @anthropic example.org:443" "client nostart client"
t0=$SECONDS
ck "a failed --start keeps the kill switch on: marker back, Envoy and every box socket down" \
   '! x airlock-envoy-apply --start >/dev/null 2>&1 && x test -e /etc/airlock-envoy/stopped && [ "$(x systemctl is-active airlock-envoy airlock-envoy-proxy@c-anthropic.socket airlock-envoy-proxy@extra.socket | tr "\n" " ")" = "inactive inactive inactive " ]'
ck "...and it failed fast ($((SECONDS - t0)) s): the socket wait stops when Envoy exits" '[ $((SECONDS - t0)) -lt 8 ]'
site "extra @anthropic example.com:443" "client extra client"
x mv -f /usr/local/bin/envoy.real /usr/local/bin/envoy
x airlock-envoy-apply --start >/dev/null
r="$(tunnel "$E" example.com)"
ck "...and a good --start then brings it all back: got '$r'" '[ "$r" = 200 ] && ! x test -e /etc/airlock-envoy/stopped'

# web: a second Envoy, its own unit, its kernel filter in a drop-in. The unit starts only where
# that filter is enforced; a rootless container usually can't enforce it, so first: does it?
enforced=0
x systemd-run --wait --pipe --quiet -p IPAddressDeny=127.0.0.2/32 /bin/bash -c 'timeout 3 bash -c "exec 3<>/dev/udp/127.0.0.2/9 && echo x >&3"' 2>&1 \
  | grep -q "Operation not permitted" && enforced=1
site "extra @anthropic example.com:443 web" "client extra client" "internal-name example.net" "internal-net 192.0.3.0/24 2001:db9::/32"
D=/etc/systemd/system/airlock-envoy-web.service.d/site.conf
if [ "$enforced" = 0 ]; then
  cfg="$(x sha256sum /etc/airlock-envoy/envoy.yaml)"
  ck "web: kernel filter not enforced here, so the web Envoy refuses to start and apply fails" '! x airlock-envoy-apply >/dev/null 2>&1'
  ck "...and nothing is left half set up: unit off, no web config or drop-in, main config unchanged" \
     '[ "$(x systemctl is-active airlock-envoy-web)" != active ] && [ "$(x systemctl is-enabled airlock-envoy-web 2>/dev/null)" != enabled ] && ! x test -e /etc/airlock-envoy/envoy-web.yaml && ! x test -e "$D" && [ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ]'
  ck "...and the journal says why" 'x journalctl -u airlock-envoy-web --no-pager | grep -q "kernel IP filter is not enforced"'
  # From here on, test the rest with the check skipped (root's drop-in, as documented).
  x sh -c 'mkdir -p /etc/systemd/system/airlock-envoy-web.service.d && printf "[Service]\nEnvironment=AIRLOCK_ENVOY_WEB_FILTER_CHECK=skip\n" > /etc/systemd/system/airlock-envoy-web.service.d/test-skip.conf && systemctl daemon-reload'
else
  echo "ok   web: this container enforces the kernel filter, so the self-check passes as is"
fi
x airlock-envoy-apply >/dev/null
ck "web: airlock-envoy-web active and enabled" '[ "$(x systemctl is-active airlock-envoy-web)" = active ] && [ "$(x systemctl is-enabled airlock-envoy-web)" = enabled ]'
ck "web: envoy-web.yaml root:airlock-envoy 0640, drop-in root:root 0644" \
   '[ "$(x stat -c %U:%G:%a /etc/airlock-envoy/envoy-web.yaml)" = root:airlock-envoy:640 ] && [ "$(x stat -c %U:%G:%a "$D")" = root:root:644 ]'
ns="$(x awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf)"
ck "web: the drop-in denies the site's networks and allows the resolver ($ns) exactly" \
   'x grep -qx "IPAddressDeny=192.0.3.0/24" "$D" && x grep -qx "IPAddressDeny=2001:db9::/32" "$D" && x grep -qE "^IPAddressAllow=$ns/(32|128)$" "$D"'
deny="$(x systemctl show -p IPAddressDeny --value airlock-envoy-web | tr " " "\n" | sort)"
# Against a fixed list (the reviewed one, as in apply-parse.sh), not the unit file it tests.
want="$(printf "%s\n" 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 ::/3 4000::/2 8000::/1 2001::/23 2001:db8::/32 2002::/16 3fff::/20 192.0.3.0/24 2001:db9::/32 | sort)"
ck "web: systemd applies exactly the unit's built-in list plus the site's ($(wc -l <<< "$deny") entries)" '[ -n "$deny" ] && [ "$deny" = "$want" ]'
ck "web: the main Envoy's sockets are out of the web unit's sight" \
   'x systemctl show -p InaccessiblePaths --value airlock-envoy-web | grep -q /run/airlock-envoy-internal'
ck "web: a socket for the profile in the web Envoy" 'x test -S /run/airlock-envoy-web/extra.sock'
E2=$E
r="$(tunnel "$E2" example.com example.org example.net git.example.net 1.1.1.1)"
ck "web: exact entry, web host, internal names, IP literal: got '$r'" '[ "$r" = "200 200 403 403 403" ]'
r="$(x runuser -u client -- bash -c 'socat TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:"$0" &
  until grep -q ":0C38 00000000:0000 0A" /proc/net/tcp; do sleep 0.01; done
  curl -s -o /dev/null -w "%{http_code}" -x http://127.0.0.1:3128 https://example.org/; kill %1; wait' "$E2" 2>/dev/null)"
ck "web: TLS really gets through (an HTTP status from example.org, not just the CONNECT): got '$r'" '[[ "$r" =~ ^[1-5][0-9][0-9]$ ]]'
r="$(tunnel "$S" example.org)"
ck "web: the c-anthropic listener has no web: got '$r'" '[ "$r" = 403 ]'
out="$(x airlock-envoy-apply --status)"
ck "web: --status shows the web Envoy and the config as applied" '[[ "$out" == *"Web Envoy: active"* && "$out" == *"Applied: yes"* ]]'
x airlock-envoy-apply --stop >/dev/null
ck "web: the kill switch stops the web Envoy too" '[ "$(x systemctl is-active airlock-envoy-web)" = inactive ]'
x airlock-envoy-apply --start >/dev/null
r="$(tunnel "$E2" example.org)"
ck "web: --start brings it back: got '$r'" '[ "$(x systemctl is-active airlock-envoy-web)" = active ] && [ "$r" = 200 ]'
# A web config Envoy validates but will not start with: the previous one comes back.
x sh -c 'real="$(readlink -f /usr/local/bin/envoy)"; printf "%s\n" "#!/bin/sh" \
  "case \" \$* \" in *\" --mode validate \"*) ;; *envoy-web.yaml*) grep -q nostartweb /etc/airlock-envoy/envoy-web.yaml && exit 1 ;; esac" \
  "exec $real \"\$@\"" > /usr/local/bin/envoy.wrap && chmod 0755 /usr/local/bin/envoy.wrap && mv /usr/local/bin/envoy /usr/local/bin/envoy.real && mv /usr/local/bin/envoy.wrap /usr/local/bin/envoy'
wcfg="$(x sha256sum /etc/airlock-envoy/envoy-web.yaml)"
x sh -c 'printf "%s\n" "internal-name nostartweb.example" >> /etc/airlock-envoy/site.conf'
ck "web: a web config Envoy will not start with: apply fails and says so" '! x airlock-envoy-apply >/dev/null 2>&1'
r="$(tunnel "$E2" example.org)"
ck "...and the previous web config is back and running: got '$r'" \
   '[ "$(x sha256sum /etc/airlock-envoy/envoy-web.yaml)" = "$wcfg" ] && [ "$(x systemctl is-active airlock-envoy-web)" = active ] && [ "$r" = 200 ]'
x mv -f /usr/local/bin/envoy.real /usr/local/bin/envoy
site "extra @anthropic example.com:443 web" "client extra client" "internal-name example.net" "internal-net 192.0.3.0/24 2001:db9::/32"
x airlock-envoy-apply >/dev/null
# Web dropped in the same apply as a main config Envoy won't start: the main Envoy rolls back
# to a config that still routes web, so web must still be there.
x sh -c 'real="$(readlink -f /usr/local/bin/envoy)"; printf "%s\n" "#!/bin/sh" \
  "case \" \$* \" in *\" --mode validate \"*) ;; *envoy.yaml*) grep -q nostart /etc/airlock-envoy/envoy.yaml && exit 1 ;; esac" \
  "exec $real \"\$@\"" > /usr/local/bin/envoy.wrap && chmod 0755 /usr/local/bin/envoy.wrap && mv /usr/local/bin/envoy /usr/local/bin/envoy.real && mv /usr/local/bin/envoy.wrap /usr/local/bin/envoy'
site "extra @anthropic example.com:443" "nostart @anthropic" "client extra client" "client nostart client"
ck "web dropped with a main config that won't start: apply fails" '! x airlock-envoy-apply >/dev/null 2>&1'
r="$(tunnel "$E2" example.org)"
ck "...and web is still up, as the rolled-back main config expects: got '$r'" \
   '[ "$(x systemctl is-active airlock-envoy-web)" = active ] && x test -e /etc/airlock-envoy/envoy-web.yaml && [ "$r" = 200 ]'
x mv -f /usr/local/bin/envoy.real /usr/local/bin/envoy
site "extra @anthropic example.com:443" "client extra client"
x airlock-envoy-apply >/dev/null
r="$(tunnel "$E2" example.com example.org)"
ck "web removed from the site file: unit stopped and disabled, config and drop-in gone: got '$r'" \
   '[ "$(x systemctl is-active airlock-envoy-web)" != active ] && [ "$(x systemctl is-enabled airlock-envoy-web 2>/dev/null)" != enabled ] && ! x test -e /etc/airlock-envoy/envoy-web.yaml && ! x test -e "$D" && [ "$r" = "200 403" ]'

# Plain HTTP with a credential: the helper, apply's checks, injection, and no secret in sight.
httpget() {  # httpget <socket> <url>: a plain-HTTP request through a box socket, as $TUSER
  x runuser -u "$TUSER" -- bash -c 'socat TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:"$0" &
    until grep -q ":0C38 00000000:0000 0A" /proc/net/tcp; do sleep 0.01; done
    curl -s -x http://127.0.0.1:3128 "$1"; kill %1; wait' "$1" "$2" 2>/dev/null
}
ck "plain HTTP: airlock-envoy-cred root 0755, the GraphQL check installed, credentials and ca dirs root:airlock-envoy 0750" \
   '[ "$(x stat -c %U:%G:%a /usr/local/sbin/airlock-envoy-cred)" = root:root:755 ] && x test -r /usr/local/share/airlock-envoy/github-graphql.lua && [ "$(x stat -c %U:%G:%a /etc/airlock-envoy/credentials)" = root:airlock-envoy:750 ] && [ "$(x stat -c %U:%G:%a /etc/airlock-envoy/ca)" = root:airlock-envoy:750 ]'
site "http httpbin.org rules any credential t-cred" "extra @anthropic example.com:443 http://httpbin.org" "client extra client"
cfg="$(x sha256sum /etc/airlock-envoy/envoy.yaml)"
out="$(x airlock-envoy-apply 2>&1)" && rc=0 || rc=$?
ck "plain HTTP: a credential that isn't set refuses the apply, nothing changed" \
   '[ "$rc" != 0 ] && [[ "$out" == *"credential t-cred is not set"* ]] && [ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ]'
ck "plain HTTP: the helper refuses a non-root caller, and a secret with a quote" \
   '! x runuser -u client -- /usr/local/sbin/airlock-envoy-cred list >/dev/null 2>&1 && ! printf "%s" "a\"b" | x airlock-envoy-cred set t-cred >/dev/null 2>&1'
out="$(printf 'INSTALL-TEST-SECRET-1\n' | x airlock-envoy-cred set t-cred 2>&1)"
ck "plain HTTP: set reads stdin, never echoes the secret, file root:airlock-envoy 0640" \
   '[[ "$out" != *INSTALL-TEST-SECRET* ]] && [ "$(x stat -c %U:%G:%a /etc/airlock-envoy/credentials/t-cred.yaml)" = root:airlock-envoy:640 ]'
ck "plain HTTP: list shows the name and format, not the value" \
   '[[ "$(x airlock-envoy-cred list)" == "t-cred  bearer  "* ]] && ! x airlock-envoy-cred list | grep -q INSTALL-TEST-SECRET'
x airlock-envoy-apply >/dev/null
r="$(httpget "$E" http://httpbin.org/anything/x | grep -o '"Authorization": "[^"]*"')"
ck "plain HTTP: the request carries the credential: got $r" '[ "$r" = "\"Authorization\": \"Bearer INSTALL-TEST-SECRET-1\"" ]'
EM=/run/airlock-envoy/client/extra.clients
ck "plain HTTP: the client manifest names the host, its port, rules and that a credential is set (not which)" \
   '[ "$(x runuser -u client -- grep -v "^#" "$EM")" = "httpbin.org 443 any yes" ] && ! x grep -q t-cred "$EM"'
x systemctl stop airlock-envoy-proxy@extra.socket
x systemctl start airlock-envoy-proxy@extra.socket
ck "plain HTTP: a socket started anew (as at boot) gets its manifest from the copy in /etc" '[ "$(x grep -v "^#" "$EM")" = "httpbin.org 443 any yes" ]'
dump="$(x curl -s --unix-socket /run/airlock-envoy-internal/admin.sock "http://localhost/config_dump?include_eds")"
ck "plain HTTP: Envoy's config dump doesn't show the secret (redacted; $(grep -c redacted <<< "$dump") marks)" \
   '[[ "$dump" == *credential_injector* && "$dump" == *redacted* && "$dump" != *INSTALL-TEST-SECRET* ]]'
ck "plain HTTP: nor does the access log" '! x grep -q INSTALL-TEST-SECRET /var/log/airlock-envoy/access.jsonl'
printf 'INSTALL-TEST-SECRET-2' | x airlock-envoy-cred set t-cred --format basic:x-access-token >/dev/null
want="Basic $(printf 'x-access-token:INSTALL-TEST-SECRET-2' | base64 -w0)"
r=""; for _ in 1 2 3 4 5 6 7 8 9 10; do r="$(httpget "$E" http://httpbin.org/anything/y | sed -n 's/.*"Authorization": "\([^"]*\)".*/\1/p')"; [ "$r" = "$want" ] && break; sleep 0.3; done
ck "plain HTTP: a new credential (basic format) is used without a restart" '[ "$r" = "$want" ]'
x airlock-envoy-cred revoke t-cred >/dev/null
r=""; for _ in 1 2 3 4 5 6 7 8 9 10; do r="$(httpget "$E" http://httpbin.org/anything/z | sed -n 's/.*"Authorization": "\([^"]*\)".*/\1/p')"; [ "$r" = airlock-envoy-revoked ] && break; sleep 0.3; done
ck "plain HTTP: revoke replaces it with a value that grants nothing: got $r" '[ "$r" = airlock-envoy-revoked ]'
# Pass credentials under the real units: locked at apply (made by the boot step), answered 423
# by Envoy itself, unlocked by receive (what unlock hands root through sudo) with the expiry
# timer started, locked again by the expiry service under its sandbox, locked after a reboot.
ck "pass: the expiry units are installed, the timer not enabled (unlock starts it)" \
   'x test -f /etc/systemd/system/airlock-envoy-cred-expire.service && [ "$(x systemctl is-enabled airlock-envoy-cred-expire.timer 2>/dev/null)" != enabled ] && [ "$(x systemctl is-active airlock-envoy-cred-expire.timer)" != active ]'
x airlock-envoy-cred add t-pass --pass work/t-pass >/dev/null
site "http httpbin.org rules any credential t-pass" "extra @anthropic example.com:443 http://httpbin.org" "client extra client"
x airlock-envoy-apply >/dev/null
r="$(httpget "$E" http://httpbin.org/anything/p)"
ck "pass: locked, Envoy answers 423 itself: got ${r:0:70}" '[[ "$r" == *"credential t-pass is locked on this host"* ]]'
x sh -c 'printf "t-pass %s\n" "$(printf PASS-SECRET-1 | base64 -w0)" | airlock-envoy-cred receive' >/dev/null
r=""; for _ in 1 2 3 4 5 6 7 8 9 10; do r="$(httpget "$E" http://httpbin.org/anything/q | sed -n 's/.*"Authorization": "\([^"]*\)".*/\1/p')"; [ "$r" = "Bearer PASS-SECRET-1" ] && break; sleep 0.3; done
ck "pass: unlocked, the token used without a restart, the expiry timer running: got $r" \
   '[ "$r" = "Bearer PASS-SECRET-1" ] && [ "$(x systemctl is-active airlock-envoy-cred-expire.timer)" = active ]'
ck "pass: the secret only in the tmpfs (root:airlock-envoy 0640), not in /etc or the log" \
   '[ "$(x stat -c %U:%G:%a /run/airlock-envoy-cred/secrets/t-pass.yaml)" = root:airlock-envoy:640 ] && ! x grep -rq PASS-SECRET-1 /etc/airlock-envoy /var/log/airlock-envoy'
# The deadline passed: the timer fires by itself (within 30 s of the unlock, then every 30 s)
# and the expiry service locks under its sandbox.
x sed -i 's/^deadline .*/deadline 1/' /run/airlock-envoy-cred/state
x sh -c 'for _ in $(seq 50); do grep -q "^locked" /run/airlock-envoy-cred/state && exit 0; sleep 1; done; exit 1' || true
r=""; for _ in 1 2 3 4 5 6 7 8 9 10; do r="$(httpget "$E" http://httpbin.org/anything/s)"; [[ "$r" == *"is locked"* ]] && break; sleep 0.3; done
ck "pass: the timer fires by itself, the expiry service locks at the deadline (its sandbox lets it) and stops the timer: got ${r:0:50}" \
   '[[ "$r" == *"credential t-pass is locked"* ]] && [ "$(x systemctl is-active airlock-envoy-cred-expire.timer)" != active ] && x grep -q "^locked" /run/airlock-envoy-cred/state'
x sh -c 'printf "t-pass %s\n" "$(printf PASS-SECRET-2 | base64 -w0)" | airlock-envoy-cred receive' >/dev/null
x rm -rf /run/airlock-envoy-cred
x systemctl restart airlock-envoy
r="$(httpget "$E" http://httpbin.org/anything/t)"
ck "pass: after a reboot (its tmpfs gone) Envoy starts, the credential locked, the timer stopped: got ${r:0:50}" \
   '[ "$(x systemctl is-active airlock-envoy)" = active ] && [[ "$r" == *"credential t-pass is locked"* ]] && [ "$(x systemctl is-active airlock-envoy-cred-expire.timer)" != active ]'
x airlock-envoy-cred lock >/dev/null
x rm -f /etc/airlock-envoy/pass/t-pass
# The GraphQL check under the real unit (MemoryDenyWriteExecute): LuaJIT must not try to
# compile, or its panic takes the whole Envoy down.
printf 'INSTALL-TEST-SECRET-3' | x airlock-envoy-cred set t-cred >/dev/null
site "http httpbin.org rules github-api credential t-cred" "extra @anthropic example.com:443 http://httpbin.org" "client extra client"
x airlock-envoy-apply >/dev/null
gql() {  # gql <json body>: POST /graphql through the box socket; the HTTP status
  x runuser -u client -- bash -c 'socat TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:/run/airlock-envoy/client/extra.sock &
    until grep -q ":0C38 00000000:0000 0A" /proc/net/tcp; do sleep 0.01; done
    curl -s -o /dev/null -w "%{http_code}" -x http://127.0.0.1:3128 -H "Content-Type: application/json" --data "$0" http://httpbin.org/graphql; kill %1; wait' "$1" 2>/dev/null
}
pid0="$(x systemctl show -p MainPID --value airlock-envoy)"
big="{\"query\":\"{ $(printf 'viewer { login } %.0s' $(seq 400)) }\"}"
r="$(gql "$big") $(gql '{"query":"mutation { mergePullRequest(input: {}) { clientMutationId } }"}') $(gql '{"query":"{ viewer { login } }"}')"
ck "github-api under the unit's MemoryDenyWriteExecute ($(x systemctl show -p MemoryDenyWriteExecute --value airlock-envoy)): a long query passes, a merge is refused, Envoy stays up: got $r" \
   '[ "$r" = "404 403 404" ] && [ "$(x systemctl show -p MainPID --value airlock-envoy)" = "$pid0" ] && [ "$(x systemctl is-active airlock-envoy)" = active ]'
# kubernetes-read against a stand-in API server: TLS on the container's own address with a
# certificate from a CA of the test's own (IP SAN only), echoing each request's head back.
KIP="$(x awk '/32 host LOCAL/ && p !~ /^127\./ { print p; exit } { p = $2 }' /proc/net/fib_trie)"
x sh -c 'mkdir -p /root/k && cd /root/k && printf "%s\n" "[req]" "distinguished_name=dn" "x509_extensions=v3" "[dn]" "[v3]" \
    "basicConstraints=critical,CA:TRUE" "keyUsage=critical,keyCertSign,cRLSign" "subjectKeyIdentifier=hash" > ca.cnf
  for c in ca other; do openssl req -x509 -config ca.cnf -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout $c.key -out $c.pem -days 2 -subj /CN=t-$c 2>/dev/null; done
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout srv.key -out srv.csr -subj /CN=kube 2>/dev/null
  printf "basicConstraints=CA:FALSE\nsubjectAltName=IP:%s\n" "$0" > ip.ext
  printf "basicConstraints=CA:FALSE\nsubjectAltName=DNS:kubernetes\n" > dns.ext
  openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out srv.pem -days 1 -extfile ip.ext 2>/dev/null
  openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out nosan.pem -days 1 -extfile dns.ext 2>/dev/null
  printf "%s\n" "#!/bin/bash" "h=" "while IFS= read -r l; do l=\${l%\$'"'"'\\r'"'"'}; [ -n \"\$l\" ] || break; h+=\"\$l\"\$'"'"'\\n'"'"'; done" \
    "printf '"'"'HTTP/1.1 200 OK\\r\\nContent-Type: text/plain\\r\\nContent-Length: %d\\r\\nConnection: close\\r\\n\\r\\n%s'"'"' \"\${#h}\" \"\$h\"" > echo.sh
  chmod 0755 echo.sh' "$KIP"
kecho() {  # kecho <cert>: the stand-in API server, with that certificate
  x systemctl stop t-kube-echo 2>/dev/null || true; x systemctl reset-failed t-kube-echo 2>/dev/null || true
  x systemd-run -q --collect --unit=t-kube-echo socat "OPENSSL-LISTEN:6443,reuseaddr,fork,cert=/root/k/$1,key=/root/k/srv.key,verify=0" EXEC:/root/k/echo.sh
  x sh -c 'for _ in $(seq 100); do grep -q ":192B 00000000:0000 0A" /proc/net/tcp && exit 0; sleep 0.05; done; exit 1'
}
kreq() {  # kreq <curl args...>: through extra's socket as client: the body, then the status
  x runuser -u client -- bash -c 'socat TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:/run/airlock-envoy/client/extra.sock &
    until grep -q ":0C38 00000000:0000 0A" /proc/net/tcp; do sleep 0.01; done
    curl -s -w "\n%{http_code}" -x http://127.0.0.1:3128 "$@"; kill %1; wait' bash "$@" 2>/dev/null
}
kecho srv.pem
printf 'KUBE-SECRET-1' | x airlock-envoy-cred set t-kube >/dev/null
site "http $KIP:6443 rules kubernetes-read credential t-kube ca t-k3s" "extra @anthropic example.com:443 http://$KIP" "client extra client"
cfg="$(x sha256sum /etc/airlock-envoy/envoy.yaml)"
out="$(x airlock-envoy-apply 2>&1)" && rc=0 || rc=$?
ck "kubernetes-read ($KIP): a ca that isn't set refuses the apply, nothing changed" \
   '[ "$rc" != 0 ] && [[ "$out" == *"ca t-k3s is not set"* ]] && [ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ]'
ck "kubernetes-read: airlock-envoy-cred ca refuses a leaf certificate and a key, takes the CA (root 0644, fingerprint shown)" \
   '! x sh -c "airlock-envoy-cred ca t-k3s < /root/k/srv.pem" >/dev/null 2>&1 && ! x sh -c "cat /root/k/ca.pem /root/k/ca.key | airlock-envoy-cred ca t-k3s" >/dev/null 2>&1 \
    && ! x test -e /etc/airlock-envoy/ca/t-k3s.pem && x sh -c "airlock-envoy-cred ca t-k3s < /root/k/ca.pem" | grep -q "Fingerprint=" \
    && [ "$(x stat -c %U:%G:%a /etc/airlock-envoy/ca/t-k3s.pem)" = root:root:644 ]'
x airlock-envoy-apply >/dev/null
r="$(kreq "http://$KIP/api/v1/namespaces/a/pods?limit=1" -H "Authorization: Bearer box-token" -H "Impersonate-User: admin" -H "Impersonate-Group: system:masters")"
ck "kubernetes-read: a read reaches the API server over TLS (own CA, IP SAN), with the token, not the box's, and no impersonation: got $(head -1 <<< "$r") / $(tail -1 <<< "$r")" \
   '[ "$(tail -1 <<< "$r")" = 200 ] && [ "$(head -1 <<< "$r")" = "GET /api/v1/namespaces/a/pods?limit=1 HTTP/1.1" ] && grep -qix "authorization: Bearer KUBE-SECRET-1" <<< "$r" \
    && grep -qix "host: $KIP" <<< "$r" \
    && ! grep -qi "box-token\|^impersonate" <<< "$r"'
st() { kreq "$@" | tail -1; }
r="$(st "http://$KIP/version") $(st -X POST -H "Content-Type: application/json" -d "{}" "http://$KIP/apis/authentication.k8s.io/v1/selfsubjectreviews") $(st -X POST -H "Content-Type: application/json" -d "{}" "http://$KIP/apis/authorization.k8s.io/v1/selfsubjectaccessreviews")"
ck "kubernetes-read: version, whoami and can-i through: got $r" '[ "$r" = "200 200 200" ]'
r="$(st "http://$KIP/api/v1/namespaces/a/pods/b/exec?command=sh") $(st -H "Connection: Upgrade" -H "Upgrade: websocket" "http://$KIP/api/v1/namespaces/a/pods/b/log") $(st "http://$KIP/api/v1/namespaces/a/services/b:80/proxy/") $(st "http://$KIP/api/v1/nodes/n/proxy/metrics")"
r="$r $(st "http://$KIP/api/v1/namespaces/a/pods/b/attach") $(st "http://$KIP/api/v1/namespaces/a/pods/b/portforward") $(st "http://$KIP/api/v1/namespaces/a/pods/b/proxy/") $(st "http://$KIP/api/v1/proxy/namespaces/a/pods/b")"
r="$r $(st -I "http://$KIP/api/v1/namespaces/a/pods/b/exec") $(st "http://$KIP/api/v1/namespaces/a/pods/b/%70roxy/") $(st "http://$KIP/api/v1/namespaces/a/pods/b/%65xec")"
r="$r $(st -X POST -H "Content-Type: application/json" -d "{}" "http://$KIP/api/v1/namespaces/a/configmaps") $(st -X DELETE "http://$KIP/api/v1/namespaces/a/pods/b") $(st -X PATCH -d "{}" "http://$KIP/api/v1/namespaces/a/pods/b") $(st "http://$KIP/healthz") $(st -X POST -d "{}" "http://$KIP/apis/authorization.k8s.io/v1/subjectaccessreviews")"
ck "kubernetes-read: exec, an upgrade, service and node proxy, attach, port-forward, pod and legacy proxy, HEAD on exec, escaped names, create, delete, patch, other paths and other reviews refused: got $r" \
   '[ "$r" = "403 403 403 403 403 403 403 403 403 403 403 403 403 403 403 403" ]'
ck "kubernetes-read: no CONNECT to the address the box reaches by plain HTTP" '[ "$(tunnel "$E" "$KIP:6443")" = 403 ]'
x sh -c "airlock-envoy-cred ca t-k3s < /root/k/other.pem" >/dev/null
x systemctl restart airlock-envoy
r="$(st "http://$KIP/version")"
ck "kubernetes-read: a server certificate from another CA is refused (503): got $r" '[ "$r" = 503 ]'
x sh -c "airlock-envoy-cred ca t-k3s < /root/k/ca.pem" >/dev/null
x systemctl restart airlock-envoy
kecho nosan.pem
r="$(st "http://$KIP/version")"
ck "kubernetes-read: a certificate from the right CA without the address (DNS SAN only) is refused (503): got $r" '[ "$r" = 503 ]'
kecho srv.pem
r="$(st "http://$KIP/version")"
ck "kubernetes-read: ...and with it back, through again: got $r" '[ "$r" = 200 ]'
x systemctl stop t-kube-echo
alog="$(x cat /var/log/airlock-envoy/access.jsonl)"
dump="$(x curl -s --unix-socket /run/airlock-envoy-internal/admin.sock "http://localhost/config_dump")"
ck "kubernetes-read: the token is in neither the access log (which has the requests) nor the config dump" \
   '[[ "$alog" == *"/api/v1/namespaces/a/pods"* && "$alog" != *KUBE-SECRET* && "$dump" == *credential_injector* && "$dump" != *KUBE-SECRET* ]]'
# GitHub App credentials under the real units: airlock-envoy-mint minting under its sandbox against
# a stand-in App API (test/fake-github-app.py, TLS on the container's address, the test's own CA;
# it also answers as the upstream, echoing the Authorization and whether the token is live); a pass
# key locked (423), unlocked (receive), locked again with its token revoked; the timer enabled
# while a line uses an App and disabled when none does.
ck "mint: airlock-envoy-mint a system account, its config dir root:airlock-envoy-mint 0750, the timer not enabled" \
   '[ "$(x id -u airlock-envoy-mint)" -lt 1000 ] && [ "$(x stat -c %U:%G:%a /etc/airlock-envoy-mint)" = root:airlock-envoy-mint:750 ] && x test -x /usr/local/sbin/airlock-envoy-mint && [ "$(x systemctl is-enabled airlock-envoy-mint.timer 2>/dev/null)" != enabled ]'
ck "mint: /run/airlock-envoy-mint root's (tmpfiles.d), keys/ root:airlock-envoy-mint 0750, only tokens/ minted/ installations/ the mint account's" \
   '[ "$(x stat -c %U:%G:%a /run/airlock-envoy-mint)" = root:root:755 ] && [ "$(x stat -c %U:%G:%a /run/airlock-envoy-mint/keys)" = root:airlock-envoy-mint:750 ] \
    && [ "$(x stat -c %U:%G:%a /run/airlock-envoy-mint/tokens)" = airlock-envoy-mint:airlock-envoy:2750 ] && [ "$(x stat -c %U:%G:%a /run/airlock-envoy-mint/.lock)" = root:airlock-envoy-mint:640 ]'
x sh -c 'cd /root/k && openssl genrsa -out app.pem 2048 2>/dev/null && openssl rsa -in app.pem -pubout -out app.pub 2>/dev/null \
  && printf "r\np\n" > api.log.repos && printf "{\"contents\": \"read\", \"issues\": \"write\", \"metadata\": \"read\", \"pull_requests\": \"write\"}" > api.log.perms'
x systemctl stop t-kube-echo 2>/dev/null || true
x systemd-run -q --collect --unit=t-gh-app -E FAKE_BIND="$KIP" python3 -I /repo/test/fake-github-app.py 8443 /root/k/srv.pem /root/k/srv.key /root/k/app.pub 12345 678 /root/k/api.log
x sh -c 'for _ in $(seq 100); do grep -q ":20FB 00000000:0000 0A" /proc/net/tcp && exit 0; sleep 0.05; done; exit 1'
x install -m 0644 /root/k/ca.pem /etc/airlock-envoy-mint/t-ca.pem
x sh -c "airlock-envoy-cred add-app t-app --app-id 12345 --installation-id 678 --key file --api https://$KIP:8443 --ca /etc/airlock-envoy-mint/t-ca.pem < /root/k/app.pem" >/dev/null
x airlock-envoy-cred add-app t-papp --app-id 12345 --org example-org --key pass:work/app --api "https://$KIP:8443" --ca /etc/airlock-envoy-mint/t-ca.pem >/dev/null
site "http $KIP:8443@a rules github-api ca t-k3s credential t-app repos example-org/r" "http $KIP:8443@p rules github-api ca t-k3s credential t-papp repos example-org/p" \
     "extra @anthropic example.com:443 http://$KIP@a http://$KIP@p" "client extra client"
x airlock-envoy-apply >/dev/null
r="$(kreq "http://$KIP/repos/example-org/r")"
ck "mint: the timer enabled, a token minted under the unit's sandbox, live in the upstream's request: got $(head -c 120 <<< "$r")" \
   '[ "$(x systemctl is-enabled airlock-envoy-mint.timer)" = enabled ] && [ "$(tail -1 <<< "$r")" = 200 ] && [[ "$r" == *"\"authorization\": \"token ghs_"*"\"live\": true"* ]]'
ck "mint: the token files the mint account's, group airlock-envoy 0640; no token under /etc" \
   '[ -z "$(x find /run/airlock-envoy-mint/tokens -name "*.yaml" ! -user airlock-envoy-mint)" ] && [ -z "$(x find /run/airlock-envoy-mint/tokens -name "*.yaml" ! -group airlock-envoy)" ] \
    && [ -z "$(x find /run/airlock-envoy-mint/tokens -name "*.yaml" ! -perm 0640)" ] && ! x grep -rq ghs_ /etc'
r="$(kreq "http://$KIP/repos/example-org/p")"
ck "mint: a pass-key App not unlocked: 423 from Envoy: got $(tail -1 <<< "$r")" '[ "$(tail -1 <<< "$r")" = 423 ] && [[ "$r" == *"credential t-papp is locked"* ]]'
x sh -c 'printf "t-papp %s\n" "$(base64 -w0 < /root/k/app.pem)" | airlock-envoy-cred receive' >/dev/null
r=""; for _ in 1 2 3 4 5 6 7 8 9 10; do r="$(kreq "http://$KIP/repos/example-org/p")"; [ "$(tail -1 <<< "$r")" = 200 ] && break; sleep 0.3; done
ck "mint: unlocked: the key root's, readable by the mint account only (0440), the installation found by org, minted under the sandbox, live: got $(tail -1 <<< "$r")" \
   '[ "$(tail -1 <<< "$r")" = 200 ] && [[ "$r" == *"\"live\": true"* ]] && [ "$(x stat -c %U:%G:%a /run/airlock-envoy-mint/keys/t-papp.pem)" = root:airlock-envoy-mint:440 ] \
    && [ "$(x cut -d" " -f1 /run/airlock-envoy-mint/installations/t-papp)" = 678 ]'
x airlock-envoy-cred lock >/dev/null
r=""; for _ in 1 2 3 4 5 6 7 8 9 10; do r="$(kreq "http://$KIP/repos/example-org/p")"; [ "$(tail -1 <<< "$r")" = 423 ] && break; sleep 0.3; done
x sh -c 'for _ in $(seq 50); do grep -q revoked /root/k/api.log && exit 0; sleep 0.2; done; exit 1' || true
ck "mint: locked again: 423, the key gone, its token revoked at the API" \
   '[ "$(tail -1 <<< "$r")" = 423 ] && ! x test -e /run/airlock-envoy-mint/keys/t-papp.pem && x grep -q "\"revoked\"" /root/k/api.log'
ck "mint: remove refuses an App a line uses" '! x airlock-envoy-cred remove t-app >/dev/null 2>&1 && x test -f /etc/airlock-envoy-mint/apps/t-app'
site "extra @anthropic example.com:443" "client extra client"
x airlock-envoy-apply >/dev/null
ck "plain HTTP dropped: a running socket's manifest is updated by the apply (no hosts)" 'x test -f "$EM" && ! x grep -qv "^#" "$EM"'
ck "mint: no line uses an App any more: its tokens revoked, the timer disabled, mint.conf gone" \
   '[ "$(x systemctl is-enabled airlock-envoy-mint.timer 2>/dev/null)" != enabled ] && ! x test -e /etc/airlock-envoy-mint/mint.conf && [ -z "$(x ls -A /run/airlock-envoy-mint/minted)" ]'
ck "mint: remove, no line using them and nothing left to revoke: both Apps gone (definition, key, cached installation)" \
   'x airlock-envoy-cred remove t-app >/dev/null && x airlock-envoy-cred remove t-papp >/dev/null \
    && ! x test -e /etc/airlock-envoy-mint/apps/t-app && ! x test -e /etc/airlock-envoy-mint/apps/t-app.pem && ! x test -e /etc/airlock-envoy-mint/apps/t-papp \
    && ! x test -e /run/airlock-envoy-mint/installations/t-papp'
x systemctl stop t-gh-app 2>/dev/null || true

echo "== $distro: per-user sockets"
# Two users, each with its own listeners: neither can see or reach the other's sockets, and a
# credential stays with one user's listeners.
O=/run/airlock-envoy/other/o-x.sock
printf 'OTHER-SECRET-1' | x airlock-envoy-cred set o-cred >/dev/null
site "http httpbin.org rules any credential t-cred" "http httpbin.org@o rules any credential o-cred" \
  "extra @anthropic example.com:443 http://httpbin.org" "client extra client" \
  "o-x @anthropic example.org:443 http://httpbin.org@o" "client o-x other"
x airlock-envoy-apply >/dev/null
r="$(TUSER=other tunnel "$O" api.anthropic.com example.org example.com)"
ck "other's listener: its socket in its own directory, its own list: got '$r'" '[ "$r" = "200 200 403" ]'
ck "...the directory root 0700 with other's ACL alone, the socket other's alone" \
   '[ "$(x getfacl -cp /run/airlock-envoy/other | grep -v "^$" | LC_ALL=C sort | tr "\n" " ")" = "group::--- mask::r-x other::--- user::rwx user:other:r-x " ] && [ "$(x getfacl -cp "$O" | grep -E "^(user|group|other)" | LC_ALL=C sort | tr "\n" " ")" = "group::--- other::--- user::rw- user:other:rw- " ]'
ck "client can't list other's directory" '! x runuser -u client -- ls /run/airlock-envoy/other >/dev/null 2>&1'
r="$(x runuser -u client -- stat "$O" 2>&1 || true)"
ck "...nor stat other's socket in it: '$r'" '[[ "$r" == *"Permission denied"* ]]'
ck "...nor connect to it" '! x runuser -u client -- socat -u /dev/null UNIX-CONNECT:"$O" 2>/dev/null'
ck "...and the other way round: other reaches none of client's sockets" \
   '! x runuser -u other -- ls /run/airlock-envoy/client >/dev/null 2>&1 && ! x runuser -u other -- socat -u /dev/null UNIX-CONNECT:"$S" 2>/dev/null && ! x runuser -u other -- socat -u /dev/null UNIX-CONNECT:"$E" 2>/dev/null'
ck "each user's directory holds its own sockets and manifests only" \
   '[ "$(x runuser -u other -- ls /run/airlock-envoy/other | tr "\n" " ")" = "o-x.clients o-x.sock " ] && [ "$(x runuser -u client -- ls /run/airlock-envoy/client | tr "\n" " ")" = "c-anthropic.clients c-anthropic.sock extra.clients extra.sock " ]'
ck "a manifest is readable by its user only" \
   'x runuser -u other -- grep -qx "httpbin.org 443 any yes" /run/airlock-envoy/other/o-x.clients && ! x runuser -u client -- cat /run/airlock-envoy/other/o-x.clients >/dev/null 2>&1'
rc_="$(httpget "$E" http://httpbin.org/anything/c | sed -n 's/.*"Authorization": "\([^"]*\)".*/\1/p')"
ro_="$(TUSER=other httpget "$O" http://httpbin.org/anything/o | sed -n 's/.*"Authorization": "\([^"]*\)".*/\1/p')"
ck "credentials per user: each user's requests carry its own credential (client: '$rc_', other: '$ro_')" \
   '[ "$rc_" = "Bearer INSTALL-TEST-SECRET-3" ] && [ "$ro_" = "Bearer OTHER-SECRET-1" ]'
x sh -c 'for _ in $(seq 60); do grep -q "\"listener\":\"o-x\"" "$0" && exit 0; sleep 0.05; done' /var/log/airlock-envoy/access.jsonl || true
ck "the access log names the user of each listener" \
   '[ "$(x jq -r "select(.listener == \"o-x\") | .user" /var/log/airlock-envoy/access.jsonl | sort -u)" = other ] && [ "$(x jq -r "select(.listener == \"extra\") | .user" /var/log/airlock-envoy/access.jsonl | sort -u)" = client ]'
out="$(x airlock-envoy-apply --status)"
ck "--status as root: each socket with its user" '[[ "$out" == *"$O"*"user: other, ACL: other"* && "$out" == *"$E"*"user: client, ACL: client"* ]]'
out="$(x runuser -u other -- airlock-envoy-apply --status 2>&1)"
# Without D-Bus (here) other learns of client's sockets not at all; with it, only their paths.
ck "--status as other: its own socket and user; none of client's ACLs" \
   '[[ "$out" == *"$O"*"user: other, ACL: other"* && "$out" != *"ACL: client"* ]] && { [[ "$out" != *"$S"* ]] || [[ "$out" == *"$S"*"is not yours to enter"* ]]; }'
if [ -n "${AIRLOCK_REPO:-}" ]; then
  r="$(x runuser -u other -- bash -c 'eval "$(sed -n "/^_airlock_socket_check() {/,/^}/p" /airlock/bin/claude-airlock)"
    WORKSPACE=/nonexistent AIRLOCK_MOUNT_DENY=".ssh .gnupg" _airlock_socket_check '"$O"' 2>&1; _airlock_socket_check '"$S"' 2>&1' || true)"
  ck "claude-airlock's socket check, as other: its own socket accepted, client's not found: '$(tr "\n" " " <<< "$r")'" \
     '[ "$(head -1 <<< "$r")" = "$O" ] && [[ "$(tail -1 <<< "$r")" == *"does not exist"* ]]'
  # Its manifest reader too: the manifest sits in the user's directory (root 0700 + ACL).
  r="$(x runuser -u other -- bash -c 'eval "$(sed -n -e "/^_airlock_hostname_ok() {/,/^}/p" -e "/^_airlock_client_manifest() {/,/^}/p" /airlock/bin/claude-airlock)"
    _airlock_client_manifest '"$O"' 2>&1 && printf "%s" "$_CLIENT_HOSTS"' || true)"
  ck "claude-airlock's manifest reader, as other, takes its manifest: '$r'" '[ "$r" = "httpbin.org any yes" ]'
fi
# The kill switch takes every user's sockets; --start brings each back where it was.
x airlock-envoy-apply --stop >/dev/null
ck "--stop: no socket left for either user" '! x test -e "$O" && ! x test -e "$S" && ! x test -e "$E"'
x airlock-envoy-apply --start >/dev/null
r="$(TUSER=other tunnel "$O" example.org) $(tunnel "$S" api.anthropic.com)"
ck "--start: both users' sockets back, each for its own user: got '$r'" '[ "$r" = "200 200" ] && x getfacl -p "$O" | grep -q "^user:other:rw"'
# As at boot: /run is empty; each socket's start makes its user's directory again.
x systemctl stop 'airlock-envoy-proxy@*.socket'
x rm -rf /run/airlock-envoy
x systemctl start airlock-envoy-proxy@o-x.socket airlock-envoy-proxy@c-anthropic.socket airlock-envoy-proxy@extra.socket
ck "sockets started with no /run/airlock-envoy (as at boot): directories made again, root's, ACLs and manifests in place" \
   '[ "$(x stat -c %U:%G:%a /run/airlock-envoy)" = root:root:755 ] && x getfacl -cp /run/airlock-envoy/other | grep -qx "user:other:r-x" && x getfacl -cp /run/airlock-envoy/client | grep -qx "user:client:r-x" && x test -f /run/airlock-envoy/other/o-x.clients && [ "$(TUSER=other tunnel "$O" example.org)" = 200 ]'
# Refused at apply, nothing changed: two clients for a listener, a user that doesn't exist, a
# credential two users would reach.
cfg="$(x sha256sum /etc/airlock-envoy/envoy.yaml)"
dropin="$(x sha256sum /etc/systemd/system/airlock-envoy-proxy@o-x.socket.d/client.conf)"
bad=0
for extra_lines in "client o-x client" "client o-x ghost" "o-y @anthropic http://httpbin.org" ; do
  site "http httpbin.org rules any credential t-cred" "http httpbin.org@o rules any credential o-cred" \
    "extra @anthropic example.com:443 http://httpbin.org" "client extra client" \
    "o-x @anthropic example.org:443 http://httpbin.org@o" "$([ "$extra_lines" = "client o-x ghost" ] || echo "client o-x other")" "$extra_lines" "$([[ "$extra_lines" != o-y* ]] || echo "client o-y other")"
  if x airlock-envoy-apply >/dev/null 2>&1; then bad=1; echo "  (accepted: $extra_lines)"; fi
done
ck "two clients for a listener, a new client that doesn't exist (a typo), or one credential for two users: refused, nothing changed (the applied client's socket stays)" \
   '[ "$bad" = 0 ] && [ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ] && [ "$(x sha256sum /etc/systemd/system/airlock-envoy-proxy@o-x.socket.d/client.conf)" = "$dropin" ] && [ "$(TUSER=other tunnel "$O" example.org)" = 200 ]'
# The site as it stands here, again (after each test below that changes it).
base_site() {
  site "http httpbin.org rules any credential t-cred" "http httpbin.org@o rules any credential o-cred" \
    "extra @anthropic example.com:443 http://httpbin.org" "client extra client" \
    "o-x @anthropic example.org:443 http://httpbin.org@o" "client o-x other"
}
back_to_base() { base_site; x airlock-envoy-apply >/dev/null; }
U=/etc/systemd/system/airlock-envoy-proxy@.socket
x cp "$U" /root/socket-unit.keep
x sh -c 'echo "ListenStream=/run/airlock-envoy/%i.sock" >> "$0"' "$U"
r1=0; x airlock-envoy-apply >/dev/null 2>&1 || r1=$?
x cp /root/socket-unit.keep "$U"
x sh -c 'mkdir -p "$0.d" && touch "$0.d/client.conf"' "$U"
r2=0; x airlock-envoy-apply >/dev/null 2>&1 || r2=$?
x sh -c 'rm -r "$0.d"' "$U"
ck "apply refuses the previous version's socket unit (a ListenStream in it, or its global client drop-in), nothing changed" \
   '[ "$r1" != 0 ] && [ "$r2" != 0 ] && [ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ] && [ "$(TUSER=other tunnel "$O" example.org)" = 200 ]'
# A move interrupted after Envoy runs the new config (here: apply fails right after, at the
# client manifests): the moved socket was stopped before, so the old user's box can't use the
# listener as it now is, the new user's credential included.
x sh -c 'rm -r /etc/airlock-envoy/clients && touch /etc/airlock-envoy/clients'
site "http httpbin.org@o rules any credential o-cred" "extra @anthropic example.com:443 http://httpbin.org@o" "client extra other" \
  "o-x @anthropic example.org:443" "client o-x client"
r=0; x airlock-envoy-apply >/dev/null 2>&1 || r=$?
x systemctl start sockets.target   # as at a boot before the next apply
ck "a move interrupted after the Envoy restart: the moved listeners' old sockets are stopped and disabled (a boot brings none back)" \
   '[ "$r" != 0 ] && ! x test -e "$O" && ! x test -e "$E" && [ "$(x systemctl is-active airlock-envoy-proxy@extra.socket)" != active ] && [ "$(x systemctl is-enabled airlock-envoy-proxy@extra.socket 2>/dev/null)" != enabled ]'
x rm -f /etc/airlock-envoy/clients
back_to_base
ck "...and an apply of the old site puts them back for their users" '[ "$(TUSER=other tunnel "$O" example.org)" = 200 ] && [ "$(tunnel "$E" example.com)" = 200 ]'
# A move whose main config Envoy won't start: the previous config comes back, and with it the
# moved socket for its old user (and web, which came with the move, goes again).
x sh -c 'real="$(readlink -f /usr/local/bin/envoy)"; printf "%s\n" "#!/bin/sh" \
  "case \" \$* \" in *\" --mode validate \"*) ;; *envoy.yaml*) grep -q nostart /etc/airlock-envoy/envoy.yaml && exit 1 ;; esac" \
  "exec $real \"\$@\"" > /usr/local/bin/envoy.wrap && chmod 0755 /usr/local/bin/envoy.wrap && mv /usr/local/bin/envoy /usr/local/bin/envoy.real && mv /usr/local/bin/envoy.wrap /usr/local/bin/envoy'
site "http httpbin.org@o rules any credential o-cred" "extra @anthropic example.com:443 http://httpbin.org@o web" "client extra other" \
  "o-x @anthropic example.org:443" "client o-x client" "nostart @anthropic" "client nostart client"
r=0; x airlock-envoy-apply >/dev/null 2>&1 || r=$?
rc_="$(httpget "$E" http://httpbin.org/anything/rb | sed -n 's/.*"Authorization": "\([^"]*\)".*/\1/p')"
ck "a move rolled back (main Envoy won't start): each socket back for its old user, its old credential ('$rc_'), web gone again" \
   '[ "$r" != 0 ] && [ "$rc_" = "Bearer INSTALL-TEST-SECRET-3" ] && [ "$(TUSER=other tunnel "$O" example.org)" = 200 ] && [ "$(x systemctl is-enabled airlock-envoy-proxy@extra.socket)" = enabled ] && ! x test -e /etc/airlock-envoy/envoy-web.yaml && [ "$(x systemctl is-active airlock-envoy-web)" != active ]'
x mv -f /usr/local/bin/envoy.real /usr/local/bin/envoy
back_to_base
# A client inside another user's subordinate uids (whose rootless containers could become
# it): refused, and its socket stops (fail closed).
uo="$(x id -u other)"
x sh -c 'cp /etc/subuid /root/subuid.keep; echo "client:$0:1" >> /etc/subuid' "$uo"
out="$(x airlock-envoy-apply 2>&1)" && r=0 || r=$?
ck "a client whose uid is in another user's /etc/subuid range: refused, its socket stopped, the others left" \
   '[ "$r" != 0 ] && [[ "$out" == *"lies in client"*"subordinate uids"* ]] && ! x test -e "$O" && [ "$(tunnel "$E" example.com)" = 200 ]'
x cp /root/subuid.keep /etc/subuid
back_to_base
# The same range written in hex (shadow reads base 0); a line that can't be read refuses the
# apply without stopping anything; the service account inside someone's range refuses all.
x sh -c 'printf "client:0x%x:1\n" "$0" >> /etc/subuid' "$uo"
out="$(x airlock-envoy-apply 2>&1)" && r=0 || r=$?
ck "a range in hex is read as shadow reads it: refused" '[ "$r" != 0 ] && [[ "$out" == *"lies in client"* ]]'
x cp /root/subuid.keep /etc/subuid; back_to_base
x sh -c 'echo "client:zz:1" >> /etc/subuid'
out="$(x airlock-envoy-apply 2>&1)" && r=0 || r=$?
ck "an /etc/subuid line that can't be read: refused, sockets left as they were" \
   '[ "$r" != 0 ] && [[ "$out" == *"cannot read these /etc/subuid lines"* ]] && [ "$(TUSER=other tunnel "$O" example.org)" = 200 ]'
x sh -c 'cp /root/subuid.keep /etc/subuid; echo "client:$0:1" >> /etc/subuid' "$(x id -u airlock-envoy)"
out="$(x airlock-envoy-apply 2>&1)" && r=0 || r=$?
ck "the airlock-envoy account inside another user's subordinate uids: refused" '[ "$r" != 0 ] && [[ "$out" == *"the airlock-envoy account"* ]]'
x cp /root/subuid.keep /etc/subuid; back_to_base
# A client above UID_MAX (a system range: DynamicUser, containers): refused. A user named like
# a socket file is fine.
x useradd -M -u 60100 big
site "extra @anthropic example.com:443" "client extra client" "b-x @anthropic" "client b-x big"
out="$(x airlock-envoy-apply 2>&1)" && r=0 || r=$?
ck "a client above UID_MAX: refused" '[ "$r" != 0 ] && [[ "$out" == *"uid 60100: only a login account"* ]]'
x userdel big
x useradd -M x.sock
site "extra @anthropic example.com:443" "client extra client" "xs @anthropic" "client xs x.sock"
r=0; x airlock-envoy-apply >/dev/null 2>&1 && x airlock-envoy-apply >/dev/null 2>&1 || r=$?
ck "a user named x.sock: its directory is not swept as a socket file (applies keep working)" '[ "$r" = 0 ] && x test -S /run/airlock-envoy/x.sock/xs.sock'
x userdel x.sock 2>/dev/null || true
back_to_base
# A deleted user: the apply refuses and stops its socket; a new account given its uid does not
# inherit it, not even when the socket is started by hand (or at boot).
x userdel other
out="$(x airlock-envoy-apply 2>&1)" && r=0 || r=$?
ck "a client deleted: the apply refuses and stops its socket" \
   '[ "$r" != 0 ] && [[ "$out" == *"client other of o-x: no such user"* && "$out" == *"Stopped listener o-x"* ]] && ! x test -e "$O"'
x useradd -M -u "$uo" mallory
r=0; x systemctl start airlock-envoy-proxy@o-x.socket 2>/dev/null || r=$?
ck "...its uid given to another account: the socket does not start for it" '[ "$r" != 0 ] && ! x test -e "$O"'
x userdel mallory
x useradd -M -u "$uo" other
x systemctl reset-failed airlock-envoy-proxy@o-x.socket 2>/dev/null || true
back_to_base
ck "...and the user back: the socket is back" '[ "$(TUSER=other tunnel "$O" example.org)" = 200 ]'
# A listener given to another user: its socket moves there; a user with no listener left loses
# its directory.
site "http httpbin.org@o rules any credential o-cred" "extra @anthropic example.com:443" "client extra client" \
  "o-x @anthropic example.org:443 http://httpbin.org@o" "client o-x client"
out="$(x airlock-envoy-apply)"
O2=/run/airlock-envoy/client/o-x.sock
r="$(tunnel "$O2" example.org)"
ck "a listener moved to client: its socket now in client's directory, for client: got '$r'" \
   '[ "$r" = 200 ] && [[ "$out" == *"its socket is now $O2"* ]] && x getfacl -cp "$O2" | grep -qx "user:client:rw-" && ! x getfacl -cp "$O2" | grep -q "user:other"'
ck "...and other, with no listener left, has no directory (nor the old socket or manifest)" '! x test -e /run/airlock-envoy/other'
site "extra @anthropic example.com:443" "client extra client"
x airlock-envoy-apply >/dev/null
ck "the moved listener removed: its socket, manifest and drop-in go" \
   '! x test -e "$O2" && ! x test -e /run/airlock-envoy/client/o-x.clients && ! x test -e /etc/systemd/system/airlock-envoy-proxy@o-x.socket.d && [ "$(tunnel "$S" api.anthropic.com)" = 200 ]'

if [ -n "${AIRLOCK_REPO:-}" ]; then
  # claude-airlock's own socket check, extracted from the checkout and run as the client.
  r="$(x runuser -u client -- bash -c 'eval "$(sed -n "/^_airlock_socket_check() {/,/^}/p" /airlock/bin/claude-airlock)"
    WORKSPACE=/nonexistent AIRLOCK_MOUNT_DENY=".ssh .gnupg" _airlock_socket_check '"$S"' 2>&1')"
  ck "claude-airlock's socket check accepts it: '$r'" '[ "$r" = "$S" ]'
fi
echo "failures: $fails"
exit "$fails"
