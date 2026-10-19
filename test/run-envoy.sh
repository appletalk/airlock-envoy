#!/bin/bash
# Run Envoy for the spike: rootless podman; ./run stands in for both /run/airlock-envoy-internal
# (sockets, admin) and /var/log/airlock-envoy (access log).
# Usage: test/run-envoy.sh [SITE]     the rendered config: built-in listeners plus SITE's
#        test/run-envoy.sh capture    the log-only capture tunnel (configs/tunnel-capture.yaml)
# Stop: podman stop airlock-envoy-spike airlock-envoy-web-spike
# A site with web also gets the web Envoy (airlock-envoy-web-spike), on ./run/web; its kernel
# filter (the unit's IPAddressDeny) is systemd's, so it is not part of this run.
# The capture config listens on loopback TCP, so it gets the host network.
set -euo pipefail
# The log flushes every 100 ms here (1 s in the service), so the checks need not wait long.
cd "$(dirname "$0")/.."
image=docker.io/envoyproxy/envoy:v1.39.4@sha256:63dd445d23d7d419d1bba8b2b9b1b8fdb80f38ae1516fb5d2dcd8856713b7eac

for c in airlock-envoy-spike airlock-envoy-web-spike; do
  if podman container exists "$c"; then echo "$c is already running; stop it first" >&2; exit 1; fi
done
mkdir -p run run/web
web=0
net=pasta
if [ "${1:-}" = capture ]; then
  cp configs/tunnel-capture.yaml run/envoy.yaml
  net=host
else
  install/airlock-envoy-apply --render "${1:-/dev/null}" > run/envoy.yaml
  if grep -q 'name: "web-egress-' run/envoy.yaml; then
    web=1
    install/airlock-envoy-apply --render-web "${1:-/dev/null}" > run/web/envoy-web.yaml
  fi
fi
rm -f run/*.sock run/web/*.sock
# The access log names hosts and server names: keep it private. Envoy appends to it.
for f in access.jsonl web.jsonl; do
  [ -e "run/$f" ] || install -m 0600 /dev/null "run/$f"
  chmod 0600 "run/$f"
done
if [ "$web" = 1 ]; then
  podman run -d --rm --name airlock-envoy-web-spike --network pasta \
    --cap-drop all --security-opt no-new-privileges --read-only \
    -e ENVOY_UID=0 -v ./run/web:/run/airlock-envoy-web:z -v ./run:/var/log/airlock-envoy:z \
    "$image" -c /run/airlock-envoy-web/envoy-web.yaml --disable-hot-restart --file-flush-interval-msec 100 --log-level warn >/dev/null
fi
podman run -d --rm --name airlock-envoy-spike --network "$net" \
  --cap-drop all --security-opt no-new-privileges --read-only \
  -e ENVOY_UID=0 -v ./run:/run/airlock-envoy-internal:z -v ./run:/var/log/airlock-envoy:z \
  -v ./run/web:/run/airlock-envoy-web:z \
  "$image" -c /run/airlock-envoy-internal/envoy.yaml --disable-hot-restart --file-flush-interval-msec 100 --log-level warn >/dev/null
for _ in $(seq 50); do
  up=1; [ -S run/admin.sock ] || up=0
  if [ "$web" = 1 ]; then
    while read -r w; do [ -S "run/web/${w##*/}" ] || up=0; done < <(grep -o '/run/airlock-envoy-web/[a-z0-9-]*[.]sock' run/web/envoy-web.yaml)
  fi
  [ "$up" = 0 ] || exit 0
  sleep 0.1
done
echo "Envoy did not come up:" >&2
podman logs airlock-envoy-spike >&2 || true
[ "$web" = 0 ] || podman logs airlock-envoy-web-spike >&2 || true
exit 1
