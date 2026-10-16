#!/bin/bash
# End-to-end install test in a systemd-booted container: install-envoy.sh and
# install-service.sh run as root inside it, then an unprivileged client tunnels through the
# socket, then site listeners are added, changed and removed with airlock-envoy-apply.
# Usage: test/install-test.sh ubuntu[-22.04|-24.04|-26.04]|debian|arch [envoy version]
# (rootless podman; plain ubuntu = 24.04)
# OLD_REPO (optional): an earlier checkout, installed first, to test the upgrade from it.
# ck takes its condition as a string to eval, so single quotes and later-used variables are meant.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
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
podman build -q -t "$img" -f - . >/dev/null <<EOF
FROM $base
RUN $prep && useradd -m client
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
for _ in $(seq 50); do
  podman exec "$name" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break
  sleep 0.2
done
x() { podman exec "$name" "$@"; }

echo "== $distro: install-envoy.sh $ver"
x /repo/install/install-envoy.sh "$ver"
fails=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
S=/run/airlock-envoy/anthropic.sock
tunnel() {  # tunnel [socket [host...]]: through a box socket as the client, each CONNECT's status
  local sock="${1:-$S}"; shift || true
  [ $# -gt 0 ] || set -- api.anthropic.com example.com
  x runuser -u client -- bash -c 'socat TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:"$0" & sleep 0.3
    r=; for h in "$@"; do r="$r $(curl -s -o /dev/null -w "%{http_connect}" -x http://127.0.0.1:3128 "https://$h/")"; done
    kill %1; echo ${r# }' "$sock" "$@" 2>/dev/null
}
if [ -n "${OLD_REPO:-}" ]; then
  echo "== $distro: the earlier install (OLD_REPO)"
  x /old/install/install-service.sh client >/dev/null
  r="$(tunnel)"
  ck "the earlier install works: got '$r'" '[ "$r" = "200 403" ]'
  old_ino="$(x stat -c %i "$S")"
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
ck "airlock-envoy-apply root 0755" '[ "$(x stat -c %U:%G:%a /usr/local/sbin/airlock-envoy-apply)" = root:root:755 ]'
ck "access log not readable by client" '! x runuser -u client -- cat /var/log/airlock-envoy/access.jsonl >/dev/null 2>&1'
r="$(tunnel)"
ck "client tunnels to api.anthropic.com (200), example.com refused (403): got '$r'" '[ "$r" = "200 403" ]'
ck "another user cannot connect" '! x runuser -u nobody -- socat -u /dev/null UNIX-CONNECT:"$S" 2>/dev/null'
sleep 1.5
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
x systemctl restart airlock-envoy-proxy@anthropic.socket; sleep 0.5
ck "recreating the box socket re-applies the ACL" 'x getfacl -p "$S" | grep -q "^user:client:rw"'
x systemctl stop 'airlock-envoy-proxy@*.socket' airlock-envoy
ck "documented kill switch cuts egress (no connect, envoy stays down)" '! x runuser -u client -- socat -u /dev/null UNIX-CONNECT:"$S" 2>/dev/null && sleep 1 && [ "$(x systemctl is-active airlock-envoy)" != active ]'
x airlock-envoy-apply >/dev/null
ck "an apply leaves the kill switch in place (Envoy and the box socket stay stopped)" \
   '[ "$(x systemctl is-active airlock-envoy airlock-envoy-proxy@anthropic.socket | tr "\n" " ")" = "inactive inactive " ]'
x systemctl start airlock-envoy-proxy@anthropic.socket
r="$(tunnel)"
ck "starting the socket again brings it back with the ACL: got '$r'" '[ "$r" = "200 403" ] && x getfacl -p "$S" | grep -q "^user:client:rw"'

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
p="$(pid)"
out="$(x airlock-envoy-apply)"
ck "applying again with no change leaves Envoy running (no restart)" '[ "$(pid)" = "$p" ] && [[ "$out" == *"no change"* ]]'
cfg="$(x sha256sum /etc/airlock-envoy/envoy.yaml)"
x sh -c 'echo "extra Example.com:443" > /etc/airlock-envoy/site.conf'
ck "a bad site file is refused and changes nothing" '! x airlock-envoy-apply >/dev/null 2>&1 && [ "$(x sha256sum /etc/airlock-envoy/envoy.yaml)" = "$cfg" ] && [ "$(pid)" = "$p" ]'
x sh -c 'printf "%s\n" "extra @anthropic example.org:443" > /home/client/site.conf'
ck "a site file from elsewhere needs a confirmation (no terminal, no --yes: refused)" \
   '! x airlock-envoy-apply /home/client/site.conf >/dev/null 2>&1 && ! x grep -q example.org /etc/airlock-envoy/site.conf'
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
x mv -f /usr/local/bin/envoy.real /usr/local/bin/envoy

if [ -n "${AIRLOCK_REPO:-}" ]; then
  # claude-airlock's own socket check, extracted from the checkout and run as the client.
  r="$(x runuser -u client -- bash -c 'eval "$(sed -n "/^_airlock_socket_check() {/,/^}/p" /airlock/bin/claude-airlock)"
    WORKSPACE=/nonexistent AIRLOCK_MOUNT_DENY=".ssh .gnupg" _airlock_socket_check '"$S"' 2>&1')"
  ck "claude-airlock's socket check accepts it: '$r'" '[ "$r" = "$S" ]'
fi
echo "failures: $fails"
exit "$fails"
