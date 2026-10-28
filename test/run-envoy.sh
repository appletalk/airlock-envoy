#!/bin/bash
# Run Envoy for the spike: rootless podman; ./run stands in for both /run/airlock-envoy-internal
# (sockets, admin) and /var/log/airlock-envoy (access log).
# Usage: test/run-envoy.sh [SITE]     the rendered config: SITE's listeners (each one's socket here)
#        test/run-envoy.sh capture    the log-only capture tunnel (configs/tunnel-capture.yaml)
# Stop: podman stop airlock-envoy-spike airlock-envoy-web-spike
# A site with web also gets the web Envoy (airlock-envoy-web-spike), on ./run/web; its kernel
# filter (the unit's IPAddressDeny) is systemd's, so it is not part of this run.
# The capture config listens on loopback TCP, so it gets the host network.
set -euo pipefail
# The log flushes every 100 ms here (1 s in the service), so the checks need not wait long.
cd "$(dirname "$0")/.."
image=docker.io/envoyproxy/envoy:v1.40.2@sha256:8de97e654644827d62afdbf7e1d3dc9fee01a8690d410dd1c63a30dc6b6cecbb

for c in airlock-envoy-spike airlock-envoy-web-spike; do
  if podman container exists "$c"; then echo "$c is already running; stop it first" >&2; exit 1; fi
done
mkdir -p run run/web run/credentials
# Test credentials for the site's http destinations (Envoy reads them as SDS files).
for c in t-cred:SITE-TEST-TOKEN-1 t-gh:dummy-not-a-github-token; do
  printf 'resources:\n- "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret\n  name: "%s"\n  generic_secret: { secret: { inline_string: "Bearer %s" } }\n' "${c%%:*}" "${c#*:}" \
    > "run/credentials/${c%%:*}.yaml"
done
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
  -v ./run/web:/run/airlock-envoy-web:z -v ./run/credentials:/etc/airlock-envoy/credentials:z \
  "$image" -c /run/airlock-envoy-internal/envoy.yaml --disable-hot-restart --file-flush-interval-msec 100 --log-level warn >/dev/null
for _ in $(seq 50); do
  up=1; [ -S run/admin.sock ] || up=0
  if [ "$web" = 1 ]; then
    while read -r w; do [ -S "run/web/${w##*/}" ] || up=0; done < <(grep -o '/run/airlock-envoy-web/[a-z0-9-]*[.]sock' run/web/envoy-web.yaml)
  fi
  # The sockets exist from the start; Envoy serves only once its clusters and secrets are in.
  if [ "$up" = 1 ] && [ "$(curl -s --unix-socket run/admin.sock http://localhost/ready 2>/dev/null)" = LIVE ]; then exit 0; fi
  sleep 0.1
done
echo "Envoy did not come up:" >&2
podman logs airlock-envoy-spike >&2 || true
[ "$web" = 0 ] || podman logs airlock-envoy-web-spike >&2 || true
exit 1
