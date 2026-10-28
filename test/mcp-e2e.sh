#!/bin/bash
# The mcp rules end to end: a rendered config with a pass credential run by a real Envoy, a
# stand-in MCP server over TLS (test/mcp-up.py) that logs what reaches it, and a client (curl)
# the way a box sends: plain HTTP through the listener. Covers the endpoints (JSON and event
# stream answers, the session header both ways, the GET stream, DELETE), what Envoy refuses
# with nothing upstream, tools and deny-tools, a locked credential, a POST stream past the
# plain-HTTP limits and the GET stream's idle close (its timeout shortened here).
# Runs as any user, no podman or root. Needs envoy, python3, openssl, curl. Takes a little over
# two minutes (the long stream); LONG=<seconds> shortens it while working on this.
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
UP=18643 PX=18201 LONG=${LONG:-130}
cd "$work" || exit

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.pem -days 2 -subj /CN=test-ca 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout srv.key -out srv.csr -subj /CN=mcp.example.com 2>/dev/null
printf 'subjectAltName=DNS:mcp.example.com\n' > san.ext
openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out srv.pem -days 2 -extfile san.ext 2>/dev/null
python3 -I "$repo/test/mcp-up.py" "$UP" srv.pem srv.key 2>up.err & pids+=($!)

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
cp "$repo/install/git-protect.lua" "$repo/install/github-graphql.lua" "$repo/install/mcp-tools.lua" bin/
# shellcheck disable=SC2016  # a script's text
printf '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > bin/id
printf '#!/bin/sh\nexit 0\n' > bin/systemctl
chmod +x bin/*
grep -qF "PASS_SEC=$R/secrets" bin/airlock-envoy-apply && grep -qF "RUN=$R" bin/airlock-envoy-cred || { echo "FAIL the test copies"; exit 1; }
export PATH="$work/bin:$PATH"
cred() { airlock-envoy-cred "$@"; }

cred add mcp-token --pass work/mcp >/dev/null
cat > site <<EOF
http mcp.example.com:$UP rules mcp ca test credential mcp-token endpoints /alpha/mcp,/beta/mcp,/mcp
     deny-tools /alpha/mcp:write_thing,/alpha/mcp:other.tool tools /beta/mcp:echo,/beta/mcp:read_a
b http://mcp.example.com
client b t
EOF
# One line in the site file (the continuation above is for reading only).
sed -i -e ':a' -e 'N' -e '$!ba' -e 's/\n     / /' site
airlock-envoy-apply --render site > rendered.yaml || { echo "FAIL render"; exit 1; }
grep -q 'name: credential-locked' rendered.yaml && grep -q 'name: mcp-tools' rendered.yaml \
  && grep -A1 'name: "mcp.example.com-ep1-stream"' rendered.yaml >/dev/null \
  && grep -A2 'name: "mcp.example.com-ep1-stream"' rendered.yaml | grep -q 'timeout: 0s, idle_timeout: 900s }' \
  && grep -A9 'name: "mcp.example.com-ep1-post"' rendered.yaml | grep -q 'timeout: 0s, idle_timeout: 600s, max_stream_duration: { max_stream_duration: 1800s }' \
  && ! grep -A12 'name: "mcp.example.com-ep3-post"' rendered.yaml | grep -q 'mcp-tools' \
  && ok "render: the tool check on the listed endpoints only; POST 10 min idle, 30 min cap; GET 15 min idle, no cap" || fail "render"
# The GET stream's idle timeout shortened to 3 s, so the test can watch it close.
sed -e "s#/run/airlock-envoy-internal/#$work/#" -e "s#/etc/airlock-envoy/ca/test.pem#$work/ca.pem#" \
    -e "s#address: \"mcp.example.com\", port_value#address: \"127.0.0.1\", port_value#" \
    -e "s#path: /var/log/airlock-envoy/access.jsonl#path: $work/access.jsonl#" \
    -e 's#timeout: 0s, idle_timeout: 900s }#timeout: 0s, idle_timeout: 3s }#' rendered.yaml > envoy.yaml
# Envoy as the units run it: under MemoryDenyWriteExecute (test/mdwe-exec.py), so a Lua filter
# that lets LuaJIT compile panics here as on a host; one worker, so a few hundred requests make
# its code hot.
# REQUIRE_MDWE=1 (CI) makes a kernel without it a failure, not a skip.
mdwe=(python3 -I "$repo/test/mdwe-exec.py") under="under MemoryDenyWriteExecute"
"${mdwe[@]}" true 2>/dev/null; rc=$?
if [ "$rc" = 3 ] && [ -z "${REQUIRE_MDWE:-}" ]; then
  echo "skip MemoryDenyWriteExecute: the kernel lacks PR_SET_MDWE (Linux 6.3+); Envoy runs without it"; mdwe=() under="WITHOUT MemoryDenyWriteExecute"
elif [ "$rc" != 0 ]; then echo "FAIL test/mdwe-exec.py true: exit $rc"; exit 1; fi
"${mdwe[@]}" envoy -c envoy.yaml --concurrency 1 --disable-hot-restart -l warn --base-id-path "$work/base-id" > envoy.log 2>&1 & pids+=($!)
envoy_pid=$!
for _ in $(seq 50); do [ -S b.sock ] && break; sleep 0.1; done
[ -S b.sock ] || { echo "FAIL envoy did not start"; cat envoy.log; exit 1; }
python3 -I - "$PX" "$work/b.sock" <<'PY' & pids+=($!)
import socket, sys, threading
ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); ls.bind(("127.0.0.1", int(sys.argv[1]))); ls.listen(64)
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
touch upstream.log
U=http://mcp.example.com
SID=sess-0123456789
c() { curl -s -i --max-time 10 -x "http://127.0.0.1:$PX" "$@"; }
rpc() {  # rpc <path> <json> [curl args]: a POST as an MCP client sends it, with the session
  local p=$1 b=$2; shift 2
  c -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
    -H "mcp-session-id: $SID" -H 'mcp-protocol-version: 2025-06-18' "$@" --data-binary "$b" "$U$p"
}
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "${3:-{\}}"; }
lines() { wc -l < upstream.log; }
# refused <name> <status> <curl args...>: Envoy answers status itself (its own text), and
# nothing reaches the stand-in.
refused() {
  local name=$1 st=$2 n out; shift 2
  n=$(lines); out="$(c -H 'expect:' "$@")"
  if [[ "$out" == "HTTP/1.1 $st"* ]] && { [ "$st" = 423 ] || [[ "$out" == *"airlock-envoy: "* ]] || [[ "$*" == *"-I"* ]]; } \
     && [[ "$out" != *"upstream reached"* ]] && [ "$(lines)" = "$n" ]; then ok "refused, nothing upstream: $name"
  else fail "$name: $(head -c 400 <<< "$out") (upstream lines $n -> $(lines))"; fi
}
# rpc_refused <name> <path> <json> <expected JSON-RPC reply part>: a 200 JSON-RPC error from
# Envoy, nothing upstream.
rpc_refused() {
  local n out; n=$(lines); out="$(rpc "$2" "$3")"
  if [[ "$out" == "HTTP/1.1 200"* ]] && [[ "$out" == *"$4"* ]] && [[ "$out" == *"content-type: application/json"* ]] && [ "$(lines)" = "$n" ]; then ok "tool check refused, nothing upstream: $1"
  else fail "$1: $(head -c 500 <<< "$out") (upstream lines $n -> $(lines))"; fi
}
init='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'

# ---- locked: 423 on every endpoint and method, nothing upstream ------------------------------
refused "locked: POST initialize" 423 -H 'content-type: application/json' --data-binary "$init" "$U/alpha/mcp"
refused "locked: GET stream" 423 -H "mcp-session-id: $SID" "$U/alpha/mcp"
refused "locked: DELETE" 423 -X DELETE -H "mcp-session-id: $SID" "$U/mcp"
refused "locked: POST on an endpoint without a tool list" 423 -H 'content-type: application/json' --data-binary "$init" "$U/mcp"
out="$(c -H 'content-type: application/json' --data-binary "$init" "$U/beta/mcp")"
[[ "$out" == *"x-airlock-envoy: locked"* ]] && [[ "$out" == *"credential mcp-token is locked on this host"* ]] \
  && ok "locked: the marker and the message" || fail "locked message: $out"

printf 'mcp-token %s\n' "$(printf MCP-LIVE-TOKEN | base64 -w0)" | cred receive >/dev/null; sleep 1.5

# ---- a POST stream past the plain-HTTP limits (120 s, 5 min cap): started now, read at the end
{ s=$EPOCHSECONDS
  rpc /mcp "$(call 90 slow "{\"seconds\":$LONG,\"every\":20}")" --max-time $((LONG + 60)) -N > long.out
  echo "exit=$? secs=$((EPOCHSECONDS - s))" >> long.out; } &
long_pid=$!

# ---- a listed endpoint: the protocol -------------------------------------------------------
out="$(rpc /alpha/mcp "$init" -H 'mcp-session-id;' -H 'cookie: a=b' -H 'authorization: Bearer BOX-OWN' -H 'x-forwarded-for: 1.2.3.4')"
[[ "$out" == "HTTP/1.1 200"* ]] && [[ "${out,,}" == *"mcp-session-id: $SID"* ]] && [[ "$out" == *'"serverInfo"'* ]] \
  && ok "initialize: 200, the session ID back to the client" || fail "initialize: $out"
last() { tail -1 upstream.log; }
python3 -I -c 'import json,sys; h=json.loads(sys.argv[1])["headers"]; sys.exit(not (h.get("authorization")=="Bearer MCP-LIVE-TOKEN" and "cookie" not in h and "x-forwarded-for" not in h and h.get("mcp-protocol-version")=="2025-06-18" and "text/event-stream" in h.get("accept","") and h.get("host")=="mcp.example.com"))' "$(last)" \
  && ok "upstream got the credential (not the box's), MCP-Protocol-Version, Accept, Host; no cookie or forwarding header" || fail "initialize headers upstream: $(last)"
out="$(rpc /alpha/mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}')"
[[ "$out" == "HTTP/1.1 202"* ]] && ok "notifications/initialized: 202" || fail "initialized: $out"
python3 -I -c 'import json,sys; sys.exit(json.loads(sys.argv[1])["headers"].get("mcp-session-id")!=sys.argv[2])' "$(last)" "$SID" \
  && ok "the session ID from the client reaches upstream" || fail "session upstream: $(last)"
out="$(rpc /alpha/mcp '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
[[ "$out" == "HTTP/1.1 200"* ]] && [[ "$out" == *'"name": "write_thing"'* ]] && ok "tools/list" || fail "tools/list: $out"
out="$(rpc /alpha/mcp "$(call 2 echo)")"
[[ "$out" == "HTTP/1.1 200"* ]] && [[ "$out" == *"content-type: application/json"* ]] && [[ "$out" == *'"called echo"'* ]] \
  && ok "tools/call, a JSON answer" || fail "tools/call json: $out"
out="$(rpc /alpha/mcp "$(call 3 echo '{"sse":true,"seconds":2,"every":0.5}')" -N)"
[[ "$out" == "HTTP/1.1 200"* ]] && [[ "$out" == *"content-type: text/event-stream"* ]] && [ "$(grep -c '^data: .*notifications/progress' <<< "$out")" = 4 ] \
  && [[ "$out" == *'data: {"jsonrpc": "2.0", "id": 3, "result"'*'"called echo"'* ]] && ok "tools/call, an event-stream answer streamed through" || fail "tools/call sse: $out"
out="$(c -H 'content-type: application/json' --data-binary '{"jsonrpc":"2.0","id":4,"method":"tools/list"}' "$U/alpha/mcp")"
[[ "$out" == "HTTP/1.1 400"* ]] && [[ "$out" == *"no or wrong session"* ]] && ok "without the session ID: upstream's 400 passes through" || fail "no session: $out"
out="$(rpc /mcp "[$(call 5 echo),{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/list\"}]")"
[[ "$out" == "HTTP/1.1 200"* ]] && [[ "$out" == *'"id": 5'*'"id": 6'* ]] && ok "a batch on an endpoint without a tool list" || fail "batch: $out"
out="$(rpc /mcp "$(call 7 write_thing)")"
[[ "$out" == *'"called write_thing"'* ]] && ok "deny-tools of one endpoint do not apply to another" || fail "other endpoint: $out"

# GET: the server's event stream (Last-Event-ID passes), and its idle close (3 s here, 15 min
# as rendered). /beta/mcp has no stream: upstream's 405 passes through.
s=$EPOCHREALTIME
out="$(curl -s -i -N --max-time 30 -x "http://127.0.0.1:$PX" -H 'accept: text/event-stream' -H "mcp-session-id: $SID" -H 'last-event-id: 5' "$U/alpha/mcp")"; e=$?
el=$(awk -v a="$s" -v b="$EPOCHREALTIME" 'BEGIN { printf "%d", b - a }')
[[ "$out" == "HTTP/1.1 200"* ]] && [[ "$out" == *"content-type: text/event-stream"* ]] && [[ "$out" == *"last-event-id=5"* ]] \
  && ok "GET: the event stream, Last-Event-ID reaches upstream" || fail "GET stream: $out"
[ "$e" != 28 ] && [ "$el" -ge 3 ] && [ "$el" -le 8 ] && ok "GET: closed after the idle timeout with nothing sent (${el} s, curl exit $e)" || fail "GET idle close: ${el} s, curl exit $e"
out="$(c -H "mcp-session-id: $SID" "$U/beta/mcp")"
[[ "$out" == "HTTP/1.1 405"* ]] && [[ "$out" != *"airlock-envoy"* ]] && ok "GET: a server's 405 passes through" || fail "GET 405: $out"
out="$(c -X DELETE -H "mcp-session-id: $SID" "$U/alpha/mcp")"
[[ "$out" == "HTTP/1.1 200"* ]] && [[ "$(last)" == *'"method": "DELETE"'* ]] && ok "DELETE ends the session" || fail "DELETE: $out"

# ---- refused by Envoy: everything but the endpoints and their three methods ------------------
for p in / /alpha /alpha/ /alpha/mcp/ /alpha/mcp/x /alpha/mcpx /alpha/mcp.json /ALPHA/mcp /Alpha/MCP /beta /mcp/ /mcp/sse /sse /messages \
         /.well-known/oauth-protected-resource /.well-known/oauth-protected-resource/alpha/mcp /.well-known/oauth-authorization-server \
         /health /healthz /x/alpha/mcp; do
  refused "GET $p" 403 -H "mcp-session-id: $SID" "$U$p"
done
refused "POST to a prefix of an endpoint" 403 -H 'content-type: application/json' --data-binary "$init" "$U/alpha"
refused "POST to an endpoint with a trailing segment" 403 -H 'content-type: application/json' --data-binary "$init" "$U/alpha/mcp/x"
out="$(c "$U/.well-known/oauth-protected-resource")"
[[ "$out" == *"not an endpoint of this line on mcp.example.com (its endpoints: /alpha/mcp, /beta/mcp, /mcp)"* ]] \
  && ok "the refusal says why and names the endpoints" || fail "refusal text: $out"
for m in PUT PATCH OPTIONS TRACE; do refused "$m on an endpoint" 403 -X "$m" -H "mcp-session-id: $SID" "$U/alpha/mcp"; done
refused "HEAD on an endpoint" 403 -I -H "mcp-session-id: $SID" "$U/alpha/mcp"
refused "a query string" 403 -H 'content-type: application/json' -H "mcp-session-id: $SID" --data-binary "$(call 8 echo)" "$U/mcp?x=1"
refused "a query string on GET" 403 -H "mcp-session-id: $SID" "$U/alpha/mcp?token=x"
refused "a form body" 403 -H "mcp-session-id: $SID" -d 'a=b' "$U/mcp"
refused "text/plain" 403 -H 'content-type: text/plain' -H "mcp-session-id: $SID" --data-binary "$(call 9 echo)" "$U/mcp"
refused "a compressed body" 403 -H 'content-type: application/json' -H 'content-encoding: gzip' -H "mcp-session-id: $SID" --data-binary "$(call 10 echo)" "$U/mcp"
refused "a chunked body" 403 -H 'content-type: application/json' -H 'transfer-encoding: chunked' -H "mcp-session-id: $SID" --data-binary "$(call 11 echo)" "$U/mcp"
# From the cold review: a charset other than utf-8 (a server decoding utf-7 reads +ACI- as a
# quote, so this body is a call of write_thing to it and of echo to the check); a body on GET
# or DELETE, which the tool check never reads.
utf7='{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"echo","zz":"+ACI-,+ACI-name+ACI-:+ACI-write_thing"}}'
for ct in 'application/json; charset=utf-7' 'application/json;charset=UTF-7' 'application/json; charset=cp037' 'application/json; x=1' 'application/json; charset=utf-8; charset=utf-7'; do
  refused "Content-Type $ct" 403 -H "content-type: $ct" -H "mcp-session-id: $SID" --data-binary "$utf7" "$U/alpha/mcp"
done
for ct in 'application/json; charset=utf-8' 'application/json; charset="UTF-8"'; do
  out="$(c -H "content-type: $ct" -H "mcp-session-id: $SID" --data-binary "$(call 41 echo)" "$U/alpha/mcp")"
  [[ "$out" == *'"called echo"'* ]] && ok "Content-Type $ct passes" || fail "Content-Type $ct: $out"
done
refused "a body on GET" 403 -X GET -H 'content-type: application/json' -H "mcp-session-id: $SID" --data-binary "$(call 42 write_thing)" "$U/alpha/mcp"
refused "a chunked body on GET" 403 -X GET -H 'transfer-encoding: chunked' -H "mcp-session-id: $SID" --data-binary "$(call 43 write_thing)" "$U/mcp"
refused "a chunked body on DELETE" 403 -X DELETE -H 'transfer-encoding: chunked' -H "mcp-session-id: $SID" --data-binary "$(call 45 write_thing)" "$U/mcp"
rpc_refused "a __proto__ key" /alpha/mcp '{"jsonrpc":"2.0","id":37,"__proto__":{"method":"tools/call","params":{"name":"write_thing"}}}' '"code":-32700'
refused "a body on DELETE" 403 -X DELETE -H 'content-type: application/json' -H "mcp-session-id: $SID" --data-binary "$(call 44 write_thing)" "$U/mcp"
out="$(c -X DELETE -H 'content-length: 0' -H "mcp-session-id: $SID" "$U/mcp")"
[[ "$out" == "HTTP/1.1 200"* ]] && ok "DELETE with Content-Length 0 passes" || fail "DELETE content-length 0: $out"
head -c 1048577 /dev/zero | tr '\0' ' ' > big
refused "a body over 1 MiB" 413 -H 'content-type: application/json' -H "mcp-session-id: $SID" --data-binary @big "$U/mcp"
printf '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"echo","arguments":{"x":"%s"}}}' "$(head -c 1048000 /dev/zero | tr '\0' a)" > fits
out="$(rpc /alpha/mcp @fits)"
[[ "$out" == *'"called echo"'* ]] && ok "a body just under 1 MiB passes the tool check" || fail "1 MiB body: $(head -c 300 <<< "$out")"

# ---- the tool check ------------------------------------------------------------------------
rpc_refused "deny-tools: the denied tool" /alpha/mcp "$(call 20 write_thing)" \
  '{"jsonrpc":"2.0","id":20,"error":{"code":-32001,"message":"airlock-envoy: refused on /alpha/mcp: tool write_thing is refused on this endpoint (deny-tools)"}}'
rpc_refused "deny-tools: in another case" /alpha/mcp "$(call '"s-21"' WRITE_THING)" '"id":"s-21","error"'
rpc_refused "deny-tools: a batch with one denied, refused whole" /alpha/mcp "[$(call 22 echo),$(call 23 other.tool)]" \
  '[{"jsonrpc":"2.0","id":22,"error":{"code":-32001,"message":"airlock-envoy: refused on /alpha/mcp: a batch holding a refused message: tool other.tool is refused on this endpoint (deny-tools)"}},{"jsonrpc":"2.0","id":23,'
rpc_refused "deny-tools: unparseable" /alpha/mcp '{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"x",}}' '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,'
rpc_refused "deny-tools: a duplicate name" /alpha/mcp '{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"echo","name":"write_thing"}}' '"id":null,"error":{"code":-32700,"message":"airlock-envoy: refused on /alpha/mcp: the key name twice in one object"}}'
# Keys a Go server matches in any case (and by folding non-ASCII letters): refused.
rpc_refused "a key in another case" /alpha/mcp '{"jsonrpc":"2.0","id":28,"Method":"tools/call","Params":{"Name":"write_thing"}}' '"error":{"code":-32700,"message":"airlock-envoy: refused on /alpha/mcp: the key Method (not method)"}}'
rpc_refused "a second method in another case" /alpha/mcp '{"jsonrpc":"2.0","id":29,"method":"ping","Method":"tools/call","params":{"name":"write_thing"}}' '"code":-32700'
rpc_refused "tools: a second name in another case" /beta/mcp '{"jsonrpc":"2.0","id":34,"method":"tools/call","params":{"name":"echo","Name":"write_thing"}}' '"code":-32700'
rpc_refused "a non-ASCII key" /alpha/mcp '{"jsonrpc":"2.0","id":35,"method":"tools/call","paramſ":{"name":"write_thing"},"params":{"name":"echo"}}' '"code":-32700'
rpc_refused "a method with a trailing space" /alpha/mcp '{"jsonrpc":"2.0","id":36,"method":"tools/call ","params":{"name":"write_thing"}}' '"id":36,"error"'
out="$(rpc /alpha/mcp "[$(call 26 echo),$(call 27 read_a)]")"
[[ "$out" == *'"id": 26'*'"id": 27'* ]] && ok "deny-tools: a batch of allowed calls passes" || fail "allowed batch: $out"
out="$(rpc /beta/mcp "$(call 30 read_a)")"
[[ "$out" == *'"called read_a"'* ]] && ok "tools: a listed tool passes" || fail "tools listed: $out"
rpc_refused "tools: an unlisted tool" /beta/mcp "$(call 31 write_thing)" '"id":31,"error":{"code":-32001,"message":"airlock-envoy: refused on /beta/mcp: tool write_thing is not allowed on this endpoint (tools)"}}'
rpc_refused "tools: a listed tool in another case" /beta/mcp "$(call 32 ECHO)" '"id":32,"error"'
out="$(rpc /beta/mcp '{"jsonrpc":"2.0","id":33,"method":"tools/list"}')"
[[ "$out" == *'"tools"'* ]] && ok "tools: other methods pass" || fail "tools other method: $out"

# ---- the rate limit of the tool check (10 a second, bursts of 20, per listener) -------------
sleep 2   # the bucket full again (10 a second, up to 20) after the checks above
rl=()
for i in $(seq 40); do rpc /beta/mcp '{"jsonrpc":"2.0","id":1,"method":"ping"}' -o /dev/null -w '%{http_code}\n' > "code$i" & rl+=($!); done
wait "${rl[@]}"
cat code[0-9]* > codes
n429=$(grep -c '^429$' codes); n200=$(grep -c '^200$' codes)
[ "$n429" -ge 10 ] && [ "$n200" -ge 10 ] && [ $((n200 + n429)) = 40 ] && ok "rate limit: 40 at once, $n200 passed, $n429 refused (429)" || fail "rate limit: $(sort codes | uniq -c | tr '\n' ' ')"

# ---- every Lua filter hot: credential-locked and mcp-nobody on 400 GETs, mcp-tools on bodies
# whose parse loops run thousands of times (one worker, so LuaJIT would compile them by now)
for _ in $(seq 400); do c -o /dev/null -w '%{http_code}\n' -H "mcp-session-id: $SID" "$U/beta/mcp"; done > hot.codes
[ "$(grep -c '^405$' hot.codes)" = 400 ] && ok "400 GETs through credential-locked and mcp-nobody" || fail "hot GETs: $(sort hot.codes | uniq -c | tr '\n' ' ')"
sleep 2
printf '{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"echo","arguments":{"x":[%s1]}}}' "$(printf '1,%.0s' $(seq 20000))" > hot.json
for _ in $(seq 8); do rpc /alpha/mcp @hot.json -o /dev/null -w '%{http_code}\n'; done > hot2.codes
[ "$(grep -c '^200$' hot2.codes)" = 8 ] && ok "8 bodies of 20000 numbers through mcp-tools" || fail "hot bodies: $(sort hot2.codes | uniq -c | tr '\n' ' ')"

# ---- no credential anywhere it shouldn't be ------------------------------------------------
! grep -q MCP-LIVE-TOKEN access.jsonl envoy.log && ok "the credential is in no log" || fail "token in a log"
! grep -q 'BOX-OWN' upstream.log && ok "the box's own Authorization never reached upstream" || fail "box authorization upstream"

wait "$long_pid"
out="$(cat long.out)"
secs=$(sed -n 's/.*secs=\([0-9]*\).*/\1/p' long.out)
[[ "$out" == "HTTP/1.1 200"* ]] && [[ "$out" == *"content-type: text/event-stream"* ]] && [[ "$out" == *'"id": 90, "result"'*'"called slow"'* ]] \
  && [[ "$out" == *"exit=0 "* ]] && [ "${secs:-0}" -ge "$LONG" ] \
  && ok "a POST answer streamed for $secs s (past the plain-HTTP 120 s), progress through to the result" || fail "long stream: $(tail -c 600 long.out)"

kill -0 "$envoy_pid" 2>/dev/null && ! grep -q 'PANIC\|runtime code generation failed' envoy.log \
  && ok "Envoy still running, no Lua panic ($under)" || fail "Envoy died or panicked: $(grep -m2 'PANIC\|code generation' envoy.log)"
echo "failures: $fails"
exit "$fails"
