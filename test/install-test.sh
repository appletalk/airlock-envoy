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
ver="${2:-1.39.4}"
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
RUN $prep && useradd -m client
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
S=/run/airlock-envoy/anthropic.sock
tunnel() {  # tunnel [socket [host...]]: through a box socket as the client, each CONNECT's status
  local sock="${1:-$S}"; shift || true
  [ $# -gt 0 ] || set -- api.anthropic.com example.com
  x runuser -u client -- bash -c 'socat TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:"$0" &
    until grep -q ":0C38 00000000:0000 0A" /proc/net/tcp; do sleep 0.01; done   # 127.0.0.1:3128 listening
    r=; for h in "$@"; do r="$r $(curl -s -o /dev/null -w "%{http_connect}" -x http://127.0.0.1:3128 "https://$h/")"; done
    kill %1; wait; echo ${r# }' "$sock" "$@" 2>/dev/null
}
if [ -n "${OLD_REPO:-}" ]; then
  echo "== $distro: the earlier install (OLD_REPO)"
  x /old/install/install-service.sh client >/dev/null
  r="$(tunnel)"
  ck "the earlier install works: got '$r'" '[ "$r" = "200 403" ]'
  old_ino="$(x stat -c %i "$S")"
  # A site file the new version rejects: the upgrade stops before changing anything.
  x sh -c 'echo "bad Example.com:443" > /etc/airlock-envoy/site.conf && chmod 0640 /etc/airlock-envoy/site.conf'
  unit="$(x sha256sum /etc/systemd/system/airlock-envoy.service)"
  ck "an upgrade with a rejected site file fails and leaves the earlier install as it was" \
     '! x /repo/install/install-service.sh client >/dev/null 2>&1 && [ "$(x sha256sum /etc/systemd/system/airlock-envoy.service)" = "$unit" ] && ! x test -e /usr/local/sbin/airlock-envoy-apply'
  x systemctl restart airlock-envoy
  r="$(tunnel)"
  ck "...and it still works after an Envoy restart: got '$r'" '[ "$r" = "200 403" ]'
  x rm /etc/airlock-envoy/site.conf
fi
echo "== $distro: install-service.sh client"
x /repo/install/install-service.sh client
echo "== $distro: checks"
if [ -n "${OLD_REPO:-}" ]; then
  ck "upgrade keeps the box socket (same inode) and drops the old config file" \
     '[ "$(x stat -c %i "$S")" = "$old_ino" ] && ! x test -e /etc/airlock-envoy/tunnel-anthropic.yaml'
fi
ck "envoy and the box socket active" '[ "$(x systemctl is-active airlock-envoy airlock-envoy-proxy@anthropic.socket | tr "\n" " ")" = "active active " ]'
# With an ACL the group bits show the mask, so check the ACL itself.
ck "box socket owned by airlock-envoy; ACL: owner rw, client rw, group/other none" \
   '[ "$(x stat -c %U "$S")" = airlock-envoy ] && [ "$(x getfacl -cp "$S" | grep -E "^(user|group|other)" | LC_ALL=C sort | tr "\n" " ")" = "group::--- other::--- user::rw- user:client:rw- " ]'
ck "box socket dir root:root 0755 (only root can rename in it)" '[ "$(x stat -c %U:%G:%a /run/airlock-envoy)" = root:root:755 ]'
ck "envoy's own dir airlock-envoy 0700" '[ "$(x stat -c %U:%a /run/airlock-envoy-internal)" = airlock-envoy:700 ]'
ck "client cannot reach envoy's own socket" '! x runuser -u client -- socat -u /dev/null UNIX-CONNECT:/run/airlock-envoy-internal/anthropic.sock 2>/dev/null'
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
   '[ "$(x systemctl is-active airlock-envoy-proxy@anthropic.socket)" = active ] && [ "$(x stat -c %i "$S")" = "$ino" ] && [ "$r" = "200 403" ]'
ck "running install-service.sh again keeps the socket and its ACL" \
   'x /repo/install/install-service.sh client >/dev/null && [ "$(x stat -c %i "$S")" = "$ino" ] && x getfacl -p "$S" | grep -q "^user:client:rw"'
x systemctl restart airlock-envoy-proxy@anthropic.socket   # returns after the ACL's ExecStartPost
ck "recreating the box socket re-applies the ACL" 'x getfacl -p "$S" | grep -q "^user:client:rw"'
# --stop takes no lock: an apply holding it (say, waiting at its prompt) does not delay it.
x sh -c 'flock /run/airlock-envoy-apply.lock sh -c "touch /root/held; sleep 1" & until [ -e /root/held ]; do sleep 0.01; done
  airlock-envoy-apply --stop >/dev/null; echo "rc=$?" > /root/stop.rc; rm -f /root/held; wait'
ck "--stop works while another apply holds the lock" '[ "$(x cat /root/stop.rc)" = rc=0 ]'
ck "the kill switch, --stop, cuts egress (no connect, Envoy down)" '! x runuser -u client -- socat -u /dev/null UNIX-CONNECT:"$S" 2>/dev/null && sleep 0.3 && [ "$(x systemctl is-active airlock-envoy)" != active ]'
x airlock-envoy-apply >/dev/null
x systemctl start airlock-envoy-proxy@anthropic.socket airlock-envoy 2>/dev/null || true
# As after a reboot with the switch on: no socket was ever made, so no /run/airlock-envoy.
x rm -rf /run/airlock-envoy
rc=0; x /repo/install/install-service.sh client >/dev/null 2>&1 || rc=$?
ck "while it is on: an apply, a systemctl start (as at boot) and install-service.sh (rc=$rc, after a reboot) start nothing" \
   '[ "$rc" = 0 ] && [ "$(x systemctl is-active airlock-envoy airlock-envoy-proxy@anthropic.socket | tr "\n" " ")" = "inactive inactive " ] && ! x test -e "$S"'
# A --start that fails after Envoy is up (here: a directory where the box socket goes)
# also leaves the switch on.
x mkdir -p /run/airlock-envoy/anthropic.sock
ck "a --start that fails after Envoy started keeps the switch on: marker back, Envoy down" \
   '! x airlock-envoy-apply --start >/dev/null 2>&1 && x test -e /etc/airlock-envoy/stopped && [ "$(x systemctl is-active airlock-envoy)" = inactive ]'
x rm -rf /run/airlock-envoy
rc=0; out="$(x airlock-envoy-apply --status 2>&1)" || rc=$?
ck "--status with the switch on and no socket files: rc=$rc, says so, lists the socket as gone" \
   '[ "$rc" = 0 ] && [[ "$out" == *"Kill switch: ON"* && "$out" == *"anthropic.sock"*"(no socket file)"* ]]'
x airlock-envoy-apply --start >/dev/null
p="$(x systemctl show -p MainPID --value airlock-envoy)"
x airlock-envoy-apply --start >/dev/null
ck "--start with the switch already off restarts nothing" '[ "$(x systemctl show -p MainPID --value airlock-envoy)" = "$p" ]'
r="$(tunnel)"
ck "--start brings it back with the ACL: got '$r'" '[ "$r" = "200 403" ] && x getfacl -p "$S" | grep -q "^user:client:rw" && ! x test -e /etc/airlock-envoy/stopped'
# Not the kill switch: a crash. Envoy cannot start; a burst of box connections (more than the
# socket's trigger limit, 20 in 2 s) is closed, and the box socket stays up: the relay only
# Wants= Envoy. Once Envoy is back the same socket works, so running boxes need no relaunch.
ino="$(x stat -c %i "$S")"
x mv /etc/airlock-envoy/envoy.yaml /etc/airlock-envoy/envoy.yaml.away
x systemctl restart airlock-envoy 2>/dev/null || true
x runuser -u client -- sh -c 'for _ in $(seq 25); do socat -u /dev/null UNIX-CONNECT:"$0" 2>/dev/null; done' "$S" || true
r="$(tunnel)"
down="$(x systemctl is-active airlock-envoy airlock-envoy-proxy@anthropic.socket | tr "\n" " " || true)"
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
x systemctl stop airlock-envoy airlock-envoy-proxy@anthropic.service
r="$(tunnel)"
ck "a box connection starts a stopped Envoy through the relay: got '$r'" '[ "$r" = "200 403" ] && [ "$(x systemctl is-active airlock-envoy)" = active ]'
x systemctl stop airlock-envoy-proxy@anthropic.socket
x airlock-envoy-apply >/dev/null
r="$(tunnel)"
ck "a box socket stopped by hand is not the kill switch: an apply starts it again: got '$r'" '[ "$r" = "200 403" ]'

echo "== $distro: site listeners"
E=/run/airlock-envoy/extra.sock
pid() { x systemctl show -p MainPID --value airlock-envoy; }
ino="$(x stat -c %i "$S")"
x sh -c 'printf "%s\n" "# test site" "extra @anthropic example.com:443" > /etc/airlock-envoy/site.conf'
x airlock-envoy-apply >/dev/null
r="$(tunnel "$E" api.anthropic.com example.com example.org)"
ck "a site listener: its own socket, the include and its host pass, others refused: got '$r'" '[ "$r" = "200 200 403" ]'
ck "its socket has the client's ACL, in the root-owned directory" \
   '[ "$(x getfacl -cp "$E" | grep -E "^(user|group|other)" | LC_ALL=C sort | tr "\n" " ")" = "group::--- other::--- user::rw- user:client:rw- " ]'
r="$(tunnel)"
ck "the anthropic socket is unchanged (same inode) and still refuses example.com: got '$r'" '[ "$(x stat -c %i "$S")" = "$ino" ] && [ "$r" = "200 403" ]'
x sh -c 'flock /run/airlock-envoy-apply.lock sh -c "touch /root/held; sleep 1" & until [ -e /root/held ]; do sleep 0.01; done
  airlock-envoy-apply >/dev/null 2>&1; echo "rc=$?" > /root/lock.rc; rm -f /root/held; wait'
ck "a second apply while one runs is refused" '[ "$(x cat /root/lock.rc)" = rc=1 ]'
p="$(pid)"
out="$(x airlock-envoy-apply)"
ck "applying again with no change leaves Envoy running (no restart)" '[ "$(pid)" = "$p" ] && [[ "$out" == *"no change"* ]]'
out="$(x airlock-envoy-apply --status)"
ck "--status: Envoy active, kill switch off, the extra socket for the client, applied" \
   '[[ "$out" == *"Envoy: active"* && "$out" == *"Kill switch: off"* && "$out" == *"/run/airlock-envoy/extra.sock"*"for: client"* && "$out" == *"Applied: yes"* ]]'
out="$(x runuser -u client -- airlock-envoy-apply --status 2>&1)"
ck "--status as the client: sockets shown, the rest needs root" '[[ "$out" == *"/run/airlock-envoy/extra.sock"* && "$out" == *"Kill switch: unknown (run as root)"* && "$out" != *"Applied"* ]]'
x sh -c 'printf "%s\n" "extra @anthropic example.com:443 example.net:443" > /etc/airlock-envoy/site.conf'
out="$(x airlock-envoy-apply --status)"
ck "--status: a site file changed but not applied shows as not applied" '[[ "$out" == *"Applied: NO"* ]]'
x sh -c 'printf "%s\n" "extra @anthropic example.com:443" > /etc/airlock-envoy/site.conf'
cfg="$(x sha256sum /etc/airlock-envoy/envoy.yaml)"
x sh -c 'echo "extra Example.com:443" > /etc/airlock-envoy/site.conf'
ck "a bad site file is refused and changes nothing" '! x airlock-envoy-apply >/dev/null 2>&1 && [ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ] && [ "$(pid)" = "$p" ]'
x sh -c 'printf "%s\n" "extra @anthropic example.org:443" > /home/client/site.conf && chown client /home/client/site.conf'
# A valid site.conf, the one already applied, so only the file's ownership can refuse it.
x sh -c 'printf "%s\n" "extra @anthropic example.com:443" > /etc/airlock-envoy/site.conf'
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
x sh -c 'printf "%s\n" "extra @anthropic example.com:443 example.net:443" > /etc/airlock-envoy/site.conf'
x runuser -u client -- ln -sf /etc/airlock-envoy/site.conf /home/client/link
ck "a symlink to the /etc site file, named, still needs the confirmation" \
   '! x airlock-envoy-apply /home/client/link >/dev/null 2>&1 && [ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ]'
x cp -p /root/site.conf.keep /etc/airlock-envoy/site.conf
x airlock-envoy-apply --yes /home/client/site.conf >/dev/null
r="$(tunnel "$E" example.org example.com)"
ck "with --yes it is installed as site.conf (root:airlock-envoy 0640) and applied: got '$r'" \
   '[ "$(x sha256sum /home/client/site.conf | cut -d" " -f1)" = "$(x sha256sum /etc/airlock-envoy/site.conf | cut -d" " -f1)" ] && [ "$(x stat -c %U:%G:%a /etc/airlock-envoy/site.conf)" = root:airlock-envoy:640 ] && [ "$r" = "200 403" ]'
x sh -c ': > /etc/airlock-envoy/site.conf'
x airlock-envoy-apply >/dev/null
ck "a listener removed from the site file loses its socket, unit stopped and disabled" \
   '! x test -e "$E" && [ "$(x systemctl is-active airlock-envoy-proxy@extra.socket)" != active ] && [ "$(x systemctl is-enabled airlock-envoy-proxy@extra.socket 2>/dev/null)" != enabled ]'
r="$(tunnel)"
ck "anthropic still works after the removal (same inode): got '$r'" '[ "$(x stat -c %i "$S")" = "$ino" ] && [ "$r" = "200 403" ]'
x sh -c 'printf "%s\n" "extra @anthropic example.com:443" > /etc/airlock-envoy/site.conf'
x airlock-envoy-apply >/dev/null
x /repo/install/install-service.sh client >/dev/null
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
x sh -c 'printf "%s\n" "nostart @anthropic example.org:443" > /home/client/site2.conf'
cfg="$(x sha256sum /etc/airlock-envoy/envoy.yaml)"; site="$(x sha256sum /etc/airlock-envoy/site.conf)"
ck "a config Envoy will not start with: apply fails and says so" '! x airlock-envoy-apply --yes /home/client/site2.conf >/dev/null 2>&1'
r="$(tunnel "$E" example.com)"
ck "...and the previous config, site file and running Envoy are back: got '$r'" \
   '[ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ] && [ "$(x sha256sum /etc/airlock-envoy/site.conf)" = "$site" ] && [ "$(x systemctl is-active airlock-envoy)" = active ] && [ "$r" = 200 ] && ! x test -e /run/airlock-envoy/nostart.sock'
# A --start that fails (same wrapper) leaves the kill switch on, nothing half started.
x airlock-envoy-apply --stop >/dev/null
x sh -c 'printf "%s\n" "nostart @anthropic example.org:443" > /etc/airlock-envoy/site.conf'
t0=$SECONDS
ck "a failed --start keeps the kill switch on: marker back, Envoy and every box socket down" \
   '! x airlock-envoy-apply --start >/dev/null 2>&1 && x test -e /etc/airlock-envoy/stopped && [ "$(x systemctl is-active airlock-envoy airlock-envoy-proxy@anthropic.socket airlock-envoy-proxy@extra.socket | tr "\n" " ")" = "inactive inactive inactive " ]'
ck "...and it failed fast ($((SECONDS - t0)) s): the socket wait stops when Envoy exits" '[ $((SECONDS - t0)) -lt 8 ]'
x sh -c 'printf "%s\n" "extra @anthropic example.com:443" > /etc/airlock-envoy/site.conf'
x mv -f /usr/local/bin/envoy.real /usr/local/bin/envoy
x airlock-envoy-apply --start >/dev/null
r="$(tunnel "$E" example.com)"
ck "...and a good --start then brings it all back: got '$r'" '[ "$r" = 200 ] && ! x test -e /etc/airlock-envoy/stopped'

if [ -n "${AIRLOCK_REPO:-}" ]; then
  # claude-airlock's own socket check, extracted from the checkout and run as the client.
  r="$(x runuser -u client -- bash -c 'eval "$(sed -n "/^_airlock_socket_check() {/,/^}/p" /airlock/bin/claude-airlock)"
    WORKSPACE=/nonexistent AIRLOCK_MOUNT_DENY=".ssh .gnupg" _airlock_socket_check '"$S"' 2>&1')"
  ck "claude-airlock's socket check accepts it: '$r'" '[ "$r" = "$S" ]'
fi
echo "failures: $fails"
exit "$fails"
