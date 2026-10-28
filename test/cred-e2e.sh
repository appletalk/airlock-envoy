#!/bin/bash
# Pass credentials end to end: a rendered config with a pass credential run by a real Envoy, a
# TLS upstream that echoes the Authorization it gets, and airlock-envoy-cred (a copy with its
# paths under a scratch directory, as in cred-backends.sh) locking and unlocking it while
# Envoy runs. Runs as any user, no podman or root. Needs envoy, python3, openssl, curl.
# Checks read "<condition> && ok ... || fail ...": ok always succeeds.
# shellcheck disable=SC2015
set -u
cd "$(dirname "$0")/.." || exit
repo=$PWD
for t in envoy python3 openssl curl; do command -v "$t" >/dev/null || { echo "skipped: no $t"; exit 3; }; done
work="$(mktemp -d)"
pids=()
# shellcheck disable=SC2329  # run by the trap
cleanup() { kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "kept $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails+1)); }
UP=18543 PX=18101
cd "$work" || exit

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.pem -days 2 -subj /CN=test-ca 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout srv.key -out srv.csr -subj /CN=api.example.com 2>/dev/null
printf 'subjectAltName=DNS:api.example.com\n' > san.ext
openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out srv.pem -days 2 -extfile san.ext 2>/dev/null
cat > up.py <<'PY'
import http.server, ssl, sys
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        b = ("authorization=%s\n" % self.headers.get("authorization")).encode()
        with open("upstream.log", "a") as f: f.write(b.decode())
        self.send_response(200); self.send_header("x-airlock-envoy", "locked")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain("srv.pem", "srv.key")
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
python3 up.py "$UP" 2>up.err & pids+=($!)

# The tool and apply, their paths moved here (see cred-backends.sh).
E=$work/etc R=$work/run
mkdir -p "$E/credentials" "$E/ca" bin
# shellcheck disable=SC2016  # the $ in the patterns is the tool's own text
sed -e "s#^DIR=/etc/airlock-envoy/credentials#DIR=$E/credentials#" -e "s#^PASS_DIR=/etc/airlock-envoy/pass#PASS_DIR=$E/pass#" \
    -e "s#^ENVOY_YAML=/etc/airlock-envoy/envoy.yaml#ENVOY_YAML=$work/rendered.yaml#" -e "s#^RUN=/run/airlock-envoy-cred#RUN=$R#" \
    -e 's#chown "root:$grp" "$tmp"; ##' -e 's# -o root -g root##g' -e 's# -o root -g "$grp"##g' \
    "$repo/install/airlock-envoy-cred" > bin/airlock-envoy-cred
sed -e "s#^PASS_DIR=/etc/airlock-envoy/pass#PASS_DIR=$E/pass#" -e "s#^PASS_SEC=/run/airlock-envoy-cred/secrets#PASS_SEC=$R/secrets#" \
    "$repo/install/airlock-envoy-apply" > bin/airlock-envoy-apply
cp "$repo/install/git-protect.lua" "$repo/install/github-graphql.lua" bin/
# shellcheck disable=SC2016  # a script's text
printf '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > bin/id
printf '#!/bin/sh\nexit 0\n' > bin/systemctl
chmod +x bin/*
grep -qF "PASS_SEC=$R/secrets" bin/airlock-envoy-apply && grep -qF "RUN=$R" bin/airlock-envoy-cred || { echo "FAIL the test copies"; exit 1; }
export PATH="$work/bin:$PATH"
cred() { airlock-envoy-cred "$@"; }

cred add gh --pass work/gh >/dev/null
cat > site <<EOF
http api.example.com:$UP rules github-api ca test credential gh
b http://api.example.com
client b t
EOF
airlock-envoy-apply --render site > rendered.yaml || { echo "FAIL render"; exit 1; }
grep -q "path: \"$R/secrets/gh.yaml\"" rendered.yaml && grep -q 'name: credential-locked' rendered.yaml \
  && ok "render: the pass credential read from the tmpfs, the locked check after the injector" || fail "render"
sed -e "s#/run/airlock-envoy-internal/#$work/#" -e "s#/etc/airlock-envoy/ca/test.pem#$work/ca.pem#" \
    -e "s#address: \"api.example.com\", port_value#address: \"127.0.0.1\", port_value#" \
    -e "s#path: /var/log/airlock-envoy/access.jsonl#path: $work/access.jsonl#" rendered.yaml > envoy.yaml
envoy -c envoy.yaml --disable-hot-restart -l warn --base-id-path "$work/base-id" > envoy.log 2>&1 & pids+=($!)
for _ in $(seq 50); do [ -S b.sock ] && break; sleep 0.1; done
[ -S b.sock ] || { echo "FAIL envoy did not start"; cat envoy.log; exit 1; }
python3 -I - "$PX" "$work/b.sock" <<'PY' & pids+=($!)
import socket, sys, threading
ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); ls.bind(("127.0.0.1", int(sys.argv[1]))); ls.listen(16)
def pump(a, b):
    try:
        while (d := a.recv(65536)): b.sendall(d)
    except OSError: pass
    finally:
        try: b.shutdown(socket.SHUT_WR)
        except OSError: pass
while True:
    c, _ = ls.accept(); u = socket.socket(socket.AF_UNIX); u.connect(sys.argv[2])
    threading.Thread(target=pump, args=(c, u), daemon=True).start(); threading.Thread(target=pump, args=(u, c), daemon=True).start()
PY
sleep 0.3
get() { curl -s -i --max-time 5 -x "http://127.0.0.1:$PX" http://api.example.com/repos/o/r; }
settle() { sleep 1.5; }   # Envoy takes a credential file within a second of the rename

out="$(get)"
[[ "$out" == "HTTP/1.1 423"* ]] && [[ "$out" == *"x-airlock-envoy: locked"* ]] \
  && [[ "$out" == *"airlock-envoy: credential gh is locked on this host: stop, and ask the operator to unlock it on the host (airlock-envoy-cred unlock); do not retry"* ]] \
  && [ ! -s upstream.log ] && ok "locked: 423 with the marker and the message, nothing upstream" || fail "locked: $out"

printf 'gh %s\n' "$(printf LIVE-TOKEN-1 | base64 -w0)" | cred receive >/dev/null; settle
out="$(get)"
[[ "$out" == "HTTP/1.1 200"* ]] && [[ "$out" == *"authorization=Bearer LIVE-TOKEN-1"* ]] \
  && ok "unlocked: the token reaches upstream, no restart" || fail "unlocked: $out"
[[ "$out" != *"x-airlock-envoy"* ]] && ok "unlocked: upstream's own x-airlock-envoy header is removed (it can't fake a lock)" || fail "marker from upstream passed"
out="$(curl -s -i --max-time 5 -x "http://127.0.0.1:$PX" -H 'authorization: airlock-envoy-locked gh' http://api.example.com/repos/o/r)"
[[ "$out" == *"authorization=Bearer LIVE-TOKEN-1"* ]] && ok "a box's own Authorization is replaced by the credential" || fail "box authorization: $out"

cred lock >/dev/null; settle
out="$(get)"; n="$(grep -c LIVE-TOKEN upstream.log)"
[[ "$out" == "HTTP/1.1 423"* ]] && [ "$n" = 2 ] && ok "locked again: 423 from the next request, no restart" || fail "relock: $out ($n)"
[[ "$out" != *LIVE-TOKEN* ]] && ok "the 423 never carries the credential" || fail "423 leaked the token"

printf 'gh %s\n' "$(printf LIVE-TOKEN-2 | base64 -w0)" | cred receive >/dev/null; settle
[[ "$(get)" == *"authorization=Bearer LIVE-TOKEN-2"* ]] && ok "unlocked again: the new token" || fail "second unlock"
python3 -I -c "import json,sys; [print(json.loads(l)['status']) for l in open(sys.argv[1])]" access.jsonl 2>/dev/null | grep -qx 423 \
  && ok "the access log records the 423s" || fail "no 423 in the access log"

echo "failures: $fails"
exit "$fails"
