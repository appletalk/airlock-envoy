#!/bin/bash
# Run Envoy for the spike: rootless podman; ./run stands in for both /run/airlock-envoy-internal
# (sockets, admin) and /var/log/airlock-envoy (access log).
# Usage: test/run-envoy.sh [SITE]     the rendered config: built-in listeners plus SITE's
#        test/run-envoy.sh capture    the log-only capture tunnel (configs/tunnel-capture.yaml)
# Stop: podman stop airlock-envoy-spike
# The capture config listens on loopback TCP, so it gets the host network.
set -euo pipefail
cd "$(dirname "$0")/.."
image=docker.io/envoyproxy/envoy:v1.39.4@sha256:63dd445d23d7d419d1bba8b2b9b1b8fdb80f38ae1516fb5d2dcd8856713b7eac

if podman container exists airlock-envoy-spike; then
  echo "airlock-envoy-spike is already running; stop it first" >&2; exit 1
fi
mkdir -p run
net=pasta
if [ "${1:-}" = capture ]; then
  cp configs/tunnel-capture.yaml run/envoy.yaml
  net=host
else
  install/airlock-envoy-apply --render "${1:-/dev/null}" > run/envoy.yaml
fi
rm -f run/*.sock
# The access log names hosts and server names: keep it private. Envoy appends to it.
[ -e run/access.jsonl ] || install -m 0600 /dev/null run/access.jsonl
chmod 0600 run/access.jsonl
podman run -d --rm --name airlock-envoy-spike --network "$net" \
  --cap-drop all --security-opt no-new-privileges --read-only \
  -e ENVOY_UID=0 -v ./run:/run/airlock-envoy-internal:z -v ./run:/var/log/airlock-envoy:z \
  "$image" -c /run/airlock-envoy-internal/envoy.yaml --disable-hot-restart --file-flush-interval-msec 1000 --log-level warn >/dev/null
for _ in $(seq 50); do
  [ -S run/admin.sock ] && exit 0
  sleep 0.1
done
echo "Envoy did not come up:" >&2
podman logs airlock-envoy-spike >&2 || true
exit 1
