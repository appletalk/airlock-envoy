#!/bin/bash
# End-to-end install test in a systemd-booted container: install-envoy.sh and
# install-service.sh run as root inside it, then an unprivileged client tunnels through the
# socket. Usage: test/install-test.sh ubuntu[-22.04|-24.04|-26.04]|debian|arch [envoy version]
# (rootless podman; plain ubuntu = 24.04)
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
podman run -d --name "$name" --systemd=always -v ./:/repo:ro "${airlock_mount[@]}" "$img" >/dev/null
trap 'podman rm -f "$name" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 50); do
  podman exec "$name" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break
  sleep 0.2
done
x() { podman exec "$name" "$@"; }

echo "== $distro: install-envoy.sh $ver"
x /repo/install/install-envoy.sh "$ver"
echo "== $distro: install-service.sh client"
x /repo/install/install-service.sh client
echo "== $distro: checks"
fails=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
S=/run/airlock-envoy/anthropic.sock
tunnel() {  # through the box socket as the client: "<CONNECT api> <CONNECT example.com>"
  x runuser -u client -- bash -c 'socat TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:'"$S"' & sleep 0.3
    a=$(curl -s -o /dev/null -w "%{http_connect}" -x http://127.0.0.1:3128 https://api.anthropic.com/)
    b=$(curl -s -o /dev/null -w "%{http_connect}" -x http://127.0.0.1:3128 https://example.com/)
    kill %1; echo "$a $b"' 2>/dev/null
}
ck "envoy and the box socket active" '[ "$(x systemctl is-active airlock-envoy airlock-envoy-proxy@anthropic.socket | tr "\n" " ")" = "active active " ]'
# With an ACL the group bits show the mask, so check the ACL itself.
ck "box socket owned by airlock-envoy; ACL: owner rw, client rw, group/other none" \
   '[ "$(x stat -c %U "$S")" = airlock-envoy ] && [ "$(x getfacl -cp "$S" | grep -E "^(user|group|other)" | LC_ALL=C sort | tr "\n" " ")" = "group::--- other::--- user::rw- user:client:rw- " ]'
ck "box socket dir root:root 0755 (only root can rename in it)" '[ "$(x stat -c %U:%G:%a /run/airlock-envoy)" = root:root:755 ]'
ck "envoy's own dir airlock-envoy 0700" '[ "$(x stat -c %U:%a /run/airlock-envoy-internal)" = airlock-envoy:700 ]'
ck "client cannot reach envoy's own socket" '! x runuser -u client -- socat -u /dev/null UNIX-CONNECT:/run/airlock-envoy-internal/anthropic.sock 2>/dev/null'
ck "airlock-envoy is a system account (uid < 1000)" '[ "$(x id -u airlock-envoy)" -lt 1000 ]'
ck "config root:airlock-envoy 0640" '[ "$(x stat -c %U:%G:%a /etc/airlock-envoy/tunnel-anthropic.yaml)" = root:airlock-envoy:640 ]'
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
x systemctl start airlock-envoy-proxy@anthropic.socket
r="$(tunnel)"
ck "starting the socket again brings it back with the ACL: got '$r'" '[ "$r" = "200 403" ] && x getfacl -p "$S" | grep -q "^user:client:rw"'
if [ -n "${AIRLOCK_REPO:-}" ]; then
  # claude-airlock's own socket check, extracted from the checkout and run as the client.
  r="$(x runuser -u client -- bash -c 'eval "$(sed -n "/^_airlock_socket_check() {/,/^}/p" /airlock/bin/claude-airlock)"
    WORKSPACE=/nonexistent AIRLOCK_MOUNT_DENY=".ssh .gnupg" _airlock_socket_check '"$S"' 2>&1')"
  ck "claude-airlock's socket check accepts it: '$r'" '[ "$r" = "$S" ]'
fi
echo "failures: $fails"
exit "$fails"
