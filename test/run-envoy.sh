#!/bin/bash
# Run Envoy for the spike: rootless podman, sockets, admin and access log in ./run.
# Usage: test/run-envoy.sh <config name in configs/>    stop: podman stop airlock-envoy-spike
# The capture config listens on loopback TCP, so it gets the host network.
set -euo pipefail
cd "$(dirname "$0")/.."
cfg="${1:?config name, e.g. tunnel-anthropic.yaml}"
[[ "$cfg" == */* ]] && { echo "give a file name in configs/, not a path" >&2; exit 2; }
[ -f "configs/$cfg" ] || { echo "no such config: configs/$cfg" >&2; exit 2; }
image=docker.io/envoyproxy/envoy:v1.39.4@sha256:63dd445d23d7d419d1bba8b2b9b1b8fdb80f38ae1516fb5d2dcd8856713b7eac

net=pasta
[ "$cfg" = tunnel-capture.yaml ] && net=host
if podman container exists airlock-envoy-spike; then
  echo "airlock-envoy-spike is already running; stop it first" >&2; exit 1
fi
mkdir -p run
rm -f run/anthropic.sock run/admin.sock
# The access log names hosts and server names: keep it private. Envoy appends to it.
[ -e run/access.jsonl ] || install -m 0600 /dev/null run/access.jsonl
chmod 0600 run/access.jsonl
podman run -d --rm --name airlock-envoy-spike --network "$net" \
  --cap-drop all --security-opt no-new-privileges --read-only \
  -e ENVOY_UID=0 -v ./configs:/etc/envoy:ro,z -v ./run:/run/envoy:z \
  "$image" -c "/etc/envoy/$cfg" --disable-hot-restart --file-flush-interval-msec 1000 --log-level warn >/dev/null
for _ in $(seq 50); do
  [ -S run/admin.sock ] && exit 0
  sleep 0.1
done
echo "Envoy did not come up:" >&2
podman logs airlock-envoy-spike >&2 || true
exit 1
