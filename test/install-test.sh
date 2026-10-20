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
ver="${2:-1.40.0}"
apt_prep='apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv curl gpg acl socat jq ca-certificates >/dev/null'
case "$distro" in
  ubuntu|ubuntu-24.04) base=docker.io/library/ubuntu:24.04; prep="$apt_prep"; init=/sbin/init ;;
  ubuntu-22.04) base=docker.io/library/ubuntu:22.04; prep="$apt_prep"; init=/sbin/init ;;
  ubuntu-26.04) base=docker.io/library/ubuntu:26.04; prep="$apt_prep"; init=/sbin/init ;;
  debian) base=docker.io/library/debian:13; prep="$apt_prep"; init=/sbin/init ;;
  arch)   base=docker.io/library/archlinux:latest
          prep='pacman -Syu --noconfirm --quiet curl gnupg acl socat jq >/dev/null'
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
  [ "$rc" = 0 ] || podman exec "$name" journalctl -u airlock-envoy --no-pager -n 25 2>/dev/null || true
  podman rm -f "$name" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT
pid="$(podman inspect -f '{{.State.Pid}}' "$name")"
# Root in the container (all its namespaces, no supplementary groups, a clean environment).
x() {
  nsenter -t "$pid" -m -u -i -n -p -C -r -w setpriv --clear-groups \
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
  site
fi
echo "== $distro: install-service.sh"
out="$(x /repo/install/install-service.sh client 2>&1)"
printf '%s\n' "$out"
ck "install-service.sh warns that it takes no client user any more, and goes on" '[[ "$out" == *"takes no client user any more (ignored: client)"* ]]'
echo "== $distro: checks"
if [ -n "${OLD_REPO:-}" ]; then
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
ck "plain HTTP: airlock-envoy-cred root 0755, the GraphQL check installed, credentials dir root:airlock-envoy 0750" \
   '[ "$(x stat -c %U:%G:%a /usr/local/sbin/airlock-envoy-cred)" = root:root:755 ] && x test -r /usr/local/share/airlock-envoy/github-graphql.lua && [ "$(x stat -c %U:%G:%a /etc/airlock-envoy/credentials)" = root:airlock-envoy:750 ]'
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
site "extra @anthropic example.com:443" "client extra client"
x airlock-envoy-apply >/dev/null
ck "plain HTTP dropped: a running socket's manifest is updated by the apply (no hosts)" 'x test -f "$EM" && ! x grep -qv "^#" "$EM"'

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
ck "two clients for a listener, a user that doesn't exist, or one credential for two users: refused, nothing changed" \
   '[ "$bad" = 0 ] && [ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ] && [ "$(x sha256sum /etc/systemd/system/airlock-envoy-proxy@o-x.socket.d/client.conf)" = "$dropin" ] && [ "$(TUSER=other tunnel "$O" example.org)" = 200 ]'
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
