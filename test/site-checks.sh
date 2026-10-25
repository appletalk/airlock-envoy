#!/bin/bash
# Site listeners: from a --network none client, each box listener reaches exactly its own
# destinations. Needs Envoy running with test/site.conf (test/run-envoy.sh test/site.conf).
# Each check has one exact expectation; exits non-zero if any check fails.
#   DIR  the directory with the sockets (default ./run)
#   LOG  a command printing the access log (default: cat run/access.jsonl)
set -u
cd "$(dirname "$0")/.." || exit
DIR="${DIR:-$PWD/run}"
LOG="${LOG:-cat run/access.jsonl}"
WEBLOG="${WEBLOG:-cat run/web.jsonl}"
readlog() { bash -c "$LOG"; }
readweblog() { bash -c "$WEBLOG"; }
start=$(( $(readlog | wc -l) + 1 ))
webstart=$(( $(readweblog | wc -l) + 1 ))
podman run --rm --network none --userns keep-id --user "$(id -u):$(id -g)" \
  -v "$DIR/t-site.sock:/run/proxy/t-site.sock${SOCK_MOUNT_OPTS-:z}" \
  -v "$DIR/t-other.sock:/run/proxy/t-other.sock${SOCK_MOUNT_OPTS-:z}" \
  -v "$DIR/t-anthropic.sock:/run/proxy/anthropic.sock${SOCK_MOUNT_OPTS-:z}" \
  -v "$DIR/t-web.sock:/run/proxy/t-web.sock${SOCK_MOUNT_OPTS-:z}" \
  -v "$DIR/t-http.sock:/run/proxy/t-http.sock${SOCK_MOUNT_OPTS-:z}" \
  --entrypoint bash localhost/airlock-envoy-spike-client:test -c '
for s in t-site:3128 anthropic:3129 t-other:3130 t-web:3131 t-http:3132; do
  socat -lf /dev/null TCP-LISTEN:${s#*:},bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:/run/proxy/${s%:*}.sock &
done
listening() { for p in 0C38 0C39 0C3A 0C3B 0C3C; do grep -q ":$p 00000000:0000 0A" /proc/net/tcp || return 1; done; }
until listening; do sleep 0.01; done   # 127.0.0.1:3128-3132
# The checks run concurrently (each is a network round trip or several); settle waits for the
# batch and prints the results in the order they were declared.
res=/tmp/checks n=0 pids=() fails=0
mkdir -p "$res"
slot() { n=$((n + 1)); printf -v f "%s/%03d" "$res" "$n"; }   # sets f, in this shell
note() { slot; echo "$1" > "$f"; }
verdict() {  # verdict <name> <expected pattern> <result>
  if [[ "$3" == $2 ]]; then echo "ok   $1: $3"; else echo "FAIL $1: $3 (wanted $2)"; fi
}
check() {  # check <listener port> <name> <expected result pattern> <curl args...>
  local port=$1 name=$2 want=$3 f; shift 3; slot
  { r="$(curl -x "http://127.0.0.1:$port" -s -o /dev/null --max-time 10 -w "proxy=%{http_connect} http=%{http_code}" "$@") exit=$?"
    verdict "$name" "$want" "$r" > "$f"; } &
  pids+=($!)
}
tls() {  # tls <sni or ""> [port] [host]: CONNECT host:443 (HTTP/1.1), then a TLS handshake
  python3 -I - "$1" "${2:-3128}" "${3:-one.one.one.one}" <<"PY"
import socket, ssl, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[2])), timeout=10)
h = sys.argv[3].encode()
s.sendall(b"CONNECT " + h + b":443 HTTP/1.1\r\nHost: " + h + b":443\r\n\r\n")
head = b""
while b"\r\n\r\n" not in head:
    c = s.recv(1)
    if not c: break
    head += c
status = head.split(b"\r\n")[0].decode(errors="replace")
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
try:
    ctx.wrap_socket(s, server_hostname=sys.argv[1] or None); print(status, "handshake")
except (OSError, ssl.SSLError):
    print(status, "closed")
PY
}
rawhello() {  # rawhello <sni> <port> <host>: CONNECT, then a hand-built ClientHello carrying any
  # server name, an IP literal included (TLS libraries refuse to send one; an attacker would)
  python3 -I - "$1" "$2" "$3" <<"PY"
import os, socket, struct, sys
sni, port, host = sys.argv[1].encode(), int(sys.argv[2]), sys.argv[3].encode()
s = socket.create_connection(("127.0.0.1", port), timeout=10)
s.sendall(b"CONNECT " + host + b":443 HTTP/1.1\r\nHost: " + host + b":443\r\n\r\n")
head = b""
while b"\r\n\r\n" not in head:
    c = s.recv(1)
    if not c: break
    head += c
status = head.split(b"\r\n")[0].decode(errors="replace")
ext = struct.pack("!HH", 0, len(sni) + 5) + struct.pack("!HBH", len(sni) + 3, 0, len(sni)) + sni
body = b"\x03\x03" + os.urandom(32) + b"\x00" + struct.pack("!H", 4) + b"\x13\x01\xc0\x2f" + b"\x01\x00" + struct.pack("!H", len(ext)) + ext
hs = b"\x01" + len(body).to_bytes(3, "big") + body
s.sendall(b"\x16\x03\x01" + struct.pack("!H", len(hs)) + hs)
try:
    print(status, "data" if s.recv(1) else "closed")
except OSError:
    print(status, "closed")
PY
}
tlscheck() {  # tlscheck <name> <expected> <sni or ""> [port] [host]
  local f; slot
  { verdict "$1" "$2" "$(tls "$3" "${4:-}" "${5:-}")" > "$f"; } &
  pids+=($!)
}
settle() {
  wait "${pids[@]}"; pids=()
  cat "$res"/*; fails=$((fails + $(cat "$res"/* | grep -c "^FAIL"))); rm -f "$res"/*
}
OK="proxy=200 http=[1-5]* exit=0" NO="proxy=403 http=000 exit=56"
note "== t-site: @anthropic, example.com, 1.1.1.1:443, port-test.invalid:8443, one.one.one.one"
check 3128 "included api.anthropic.com"          "$OK" https://api.anthropic.com/
check 3128 "example.com"                         "$OK" https://example.com/
check 3128 "address entry 1.1.1.1:443"           "$OK" https://1.1.1.1/
# The port is part of an entry. The host is under .invalid (RFC 6761: never resolves), so the
# allowed tunnel opens and then closes with no upstream, and no odd port leaves the machine;
# the render test (apply-parse.sh) pins the port the upstream would be dialled on.
check 3128 "host on port 8443: allowed, no upstream"  "proxy=200 http=000 exit=35" https://port-test.invalid:8443/
check 3128 "same host, port 443 not listed"      "$NO" https://port-test.invalid/
check 3128 "1.0.0.1, an address not listed"      "$NO" https://1.0.0.1/
check 3128 "1.1.1.1 on port 80"                  "$NO" http://1.1.1.1/ -p
check 3128 "example.org, the other profile'"'"'s" "$NO" https://example.org/
# Tunnels that open and are then closed: a wrong SNI (curl 35, in the TLS handshake), or no TLS
# at all (curl 52, empty reply).
check 3128 "CONNECT example.com, SNI www.example.com"   "proxy=200 http=000 exit=35" --connect-to www.example.com:443:example.com:443 https://www.example.com/
check 3128 "CONNECT 1.1.1.1, SNI one.one.one.one"       "proxy=200 http=000 exit=35" --connect-to one.one.one.one:443:1.1.1.1:443 https://one.one.one.one/
check 3128 "CONNECT 1.1.1.1, plain HTTP inside"         "proxy=200 http=000 exit=52" -p http://1.1.1.1:443/
check 3128 "CONNECT example.com, plain HTTP inside"     "proxy=200 http=000 exit=52" -p http://example.com:443/
# TLS with no SNI to a host entry: closed by the SNI listener. This server would accept it
# (1.1.1.1, the same server, does above), so a missing SNI rule shows as a handshake.
check 3128 "one.one.one.one with its SNI"                "$OK" https://one.one.one.one/
tlscheck "CONNECT one.one.one.one, TLS with its SNI (control)" "HTTP/1.1 200 OK handshake" one.one.one.one
tlscheck "CONNECT one.one.one.one, TLS without SNI"            "HTTP/1.1 200 OK closed" ""
note "== anthropic: built in only"
check 3129 "api.anthropic.com"                   "$OK" https://api.anthropic.com/
check 3129 "example.com (t-site only)"           "$NO" https://example.com/
check 3129 "1.1.1.1 (t-site only)"               "$NO" https://1.1.1.1/
note "== t-other: example.org only"
check 3130 "example.org"                         "$OK" https://example.org/
check 3130 "api.anthropic.com (not included)"    "$NO" https://api.anthropic.com/
check 3130 "example.com (t-site only)"           "$NO" https://example.com/
check 3128 "api.github.com (t-site has no web)"  "$NO" https://api.github.com/
note "== t-web: example.org and web; internal-name example.org example.net (public, marked internal)"
check 3131 "web: example.com"                    "$OK" https://example.com/
check 3131 "web: api.github.com"                 "$OK" https://api.github.com/zen
check 3131 "exact entry inside an internal name: example.org" "$OK" https://example.org/
check 3131 "internal name, subdomain: www.example.org"        "$NO" https://www.example.org/
check 3131 "internal name: example.net"          "$NO" https://example.net/
check 3131 "internal name, upper case: EXAMPLE.NET" "$NO" https://EXAMPLE.NET/
check 3131 "built-in internal name: printer.local" "$NO" https://printer.local/
check 3131 "built-in internal name: localhost"   "$NO" https://localhost/
check 3131 "an IPv4 literal (1.1.1.1)"           "$NO" https://1.1.1.1/
check 3131 "an IPv6 literal"                     "$NO" "https://[2606:4700:4700::1111]/"
check 3131 "a single-label name"                 "$NO" https://intranet/
check 3131 "a public host on port 8443"          "$NO" https://example.com:8443/
check 3131 "plain HTTP request (answered by Envoy)" "proxy=000 http=403 exit=0" http://example.com/
check 3131 "api.anthropic.com (not included, so web)" "$OK" https://api.anthropic.com/
# Past the CONNECT check, the web Envoy checks the TLS server name itself.
check 3131 "CONNECT example.com, SNI example.net (internal)" "proxy=200 http=000 exit=35" --connect-to example.net:443:example.com:443 https://example.net/
check 3131 "CONNECT example.com, plain HTTP inside"          "proxy=200 http=000 exit=52" -p http://example.com:443/
tlscheck "CONNECT example.com, TLS with its SNI (control)"   "HTTP/1.1 200 OK handshake" example.com 3131 example.com
tlscheck "CONNECT example.com, TLS without SNI"              "HTTP/1.1 200 OK closed" "" 3131 example.com
# A server name that is an IP literal (a documentation address, never a real one here): the
# web Envoy must give it no chain, so nothing is dialled (the web log checks that below).
slot; { verdict "CONNECT example.com, raw ClientHello with SNI 192.0.2.1" "HTTP/1.1 200 OK closed" "$(rawhello 192.0.2.1 3131 example.com)" > "$f"; } &
pids+=($!)
slot; { verdict "CONNECT example.com, raw ClientHello with SNI www.example.net (internal)" "HTTP/1.1 200 OK closed" "$(rawhello www.example.net 3131 example.com)" > "$f"; } &
pids+=($!)
slot; { verdict "CONNECT example.com, raw ClientHello with SNI example.com (control)" "HTTP/1.1 200 OK data" "$(rawhello example.com 3131 example.com)" > "$f"; } &
pids+=($!)
note "== t-http: plain HTTP (httpbin under github-api rules + t-cred, github.com git, api.github.com for gh)"
P="proxy=000"
check 3132 "GET under the read rule"                      "$P http=200 exit=0" http://httpbin.org/anything/read
slot; { r="$(curl -s -x http://127.0.0.1:3132 -H "Authorization: Bearer FROM-THE-BOX" -H "Host: example.com" http://httpbin.org/anything/x)"
  verdict "the credential replaces the box one; Host stays pinned" "*SITE-TEST-TOKEN-1*httpbin.org*" \
    "$(echo "$r" | grep -o "\"Authorization\": \"[^\"]*\"") $(echo "$r" | grep -o "\"Host\": \"[^\"]*\"")" > "$f"; } &
pids+=($!)
check 3132 "POST outside the rules"                       "$P http=403 exit=0" -X POST http://httpbin.org/anything/x
check 3132 "DELETE outside the rules"                     "$P http=403 exit=0" -X DELETE http://httpbin.org/repos/o/r
check 3132 "PATCH a pull (allowed) reaches the host"      "$P http=404 exit=0" -X PATCH http://httpbin.org/repos/o/r/pulls/1
check 3132 "GET /graphql refused"                         "$P http=403 exit=0" http://httpbin.org/graphql
check 3132 "HEAD /graphql refused"                        "$P http=403 exit=0" -I http://httpbin.org/graphql
check 3132 "GET /graphql/ refused"                        "$P http=403 exit=0" http://httpbin.org/graphql/
check 3132 "GET /GraphQL refused"                         "$P http=403 exit=0" http://httpbin.org/GraphQL
check 3132 "POST /GRAPHQL refused"                        "$P http=403 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"{ viewer { login } }\"}" http://httpbin.org/GRAPHQL
check 3132 "POST /graphql?query=<a merge> refused"        "$P http=403 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"{ viewer { login } }\"}" "http://httpbin.org/graphql?query=mutation%7BmergePullRequest(input:%7B%7D)%7Bid%7D%7D"
check 3132 "POST /graphql as a form refused"              "$P http=403 exit=0" -H "Content-Type: application/x-www-form-urlencoded" --data "{\"query\":\"{ viewer { login } }\"}" http://httpbin.org/graphql
check 3132 "POST /repos/o/r/merges refused"               "$P http=403 exit=0" -X POST http://httpbin.org/repos/o/r/merges
check 3132 "POST a pull review refused"                   "$P http=403 exit=0" -X POST http://httpbin.org/repos/o/r/pulls/1/reviews
check 3132 "PUT a pull merge refused"                     "$P http=403 exit=0" -X PUT http://httpbin.org/repos/o/r/pulls/1/merge
check 3132 "PATCH through dot segments to merges refused" "$P http=403 exit=0" --path-as-is -X PATCH http://httpbin.org/repos/o/r/pulls/1/../../merges
check 3132 "an escaped slash in the path refused"         "$P http=400 exit=0" -X PATCH http://httpbin.org/repos/o/r/pulls%2F1
check 3132 "GraphQL mergePullRequest refused"             "$P http=403 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"mutation { mergePullRequest(input: {}) { clientMutationId } }\"}" http://httpbin.org/graphql
check 3132 "GraphQL aliased merge refused"                "$P http=403 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"mutation { createIssue: mergePullRequest(input: {}) { clientMutationId } }\"}" http://httpbin.org/graphql
check 3132 "GraphQL createIssue passes to the host"       "$P http=404 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"mutation { createIssue(input: {}) { clientMutationId } }\"}" http://httpbin.org/graphql
check 3132 "GraphQL query passes to the host"             "$P http=404 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"{ viewer { login } }\"}" http://httpbin.org/graphql
check 3132 "GraphQL body that is not JSON refused"        "$P http=403 exit=0" --data "mutation { mergePullRequest }" http://httpbin.org/graphql
check 3132 "CONNECT to a plain-HTTP host refused"         "$NO" https://httpbin.org/
check 3132 "plain HTTP to a host not in the profile"      "$P http=403 exit=0" http://example.com/
check 3132 "plain HTTP to the host on port 443"           "$P http=403 exit=0" http://httpbin.org:443/anything/x
check 3132 "git rules: a non-git path on github.com"      "$P http=403 exit=0" http://github.com/octocat
slot; { r="$(curl -s --unix-socket /run/proxy/t-http.sock -H "Host: httpbin.org:80" http://httpbin.org/anything/origin | grep -o "\"Host\": \"[^\"]*\"")"
  verdict "origin-form (as gh sends) with Host httpbin.org:80: the upstream sees Host httpbin.org" "*\"Host\": \"httpbin.org\"*" "$r" > "$f"; } &
pids+=($!)
slot; { r="$(cd /tmp && rm -rf hw && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.http://github.com/.insteadOf GIT_CONFIG_VALUE_0=git@github.com: \
    http_proxy=http://127.0.0.1:3132 git clone -q --depth 1 git@github.com:octocat/Hello-World.git hw 2>&1 && git -C hw rev-parse --short HEAD)"
  verdict "git clone of an ssh remote, rewritten to plain HTTP in the box environment" "7fd1a60" "$r" > "$f"; } &
pids+=($!)
slot; { mkdir -p /tmp/ghc; r="$(GH_CONFIG_DIR=/tmp/ghc GH_TOKEN=dummy sh -c "gh config set http_unix_socket /run/proxy/t-http.sock >/dev/null 2>&1; gh api /zen 2>&1" | tr "\n" " ")"
  verdict "gh over the socket reaches GitHub with the injected (dummy) credential" "*Bad credentials*" "$r" > "$f"; } &
pids+=($!)
slot; { r="$(curl -s -x http://127.0.0.1:3132 -H "X-Envoy-Upstream-Rq-Timeout-Ms: 1" -H "X-Envoy-Box: marker-e" -H "X-Forwarded-For: 10.9.9.9" -H "X-Forwarded-Host: marker-h" \
    -H "Forwarded: for=marker-f" -H "Sudo: marker-s" -H "X-HTTP-Method-Override: DELETE" -H "X-Method-Override: DELETE" \
    -H "Cookie: c=marker-c" -H "Cookie2: marker-c2" -H "Signature: keyId=marker-k" -H "Signature-Input: sig=marker-si" \
    -H "Proxy-Authorization: Basic marker-pa" -H "X-WEBAUTH-USER: marker-w" -H "X-Webauth: marker-w2" -H "Remote-User: marker-ru" \
    -H "X-Remote-User: marker-xru" -H "X-Auth-Request-User: marker-ar" -H "X-authentik-username: marker-ak" \
    http://httpbin.org/anything/headers | tr -d "\n")"
  if [[ "$r" == *"\"url\""* && "$r" != *X-Envoy* && "$r" != *10.9.9.9* && "$r" != *marker-* && "$r" != *Override* ]]; then r="none reached the host"; fi
  verdict "box-sent x-envoy-*, forwarding, method-override and other authentication headers stripped" "none reached the host" "${r:0:300}" > "$f"; } &
pids+=($!)
slot; { r="$(head -c 70000 /dev/zero | tr "\0" a | sed "s/^/{\"query\":\"{ viewer { login } }\",\"v\":\"/; s/\$/\"}/" | \
    curl -s -o /dev/null -w "http=%{http_code}" -x http://127.0.0.1:3132 -H "Content-Type: application/json" -H "Expect: 100-continue" --data-binary @- http://httpbin.org/graphql)"
  verdict "a GraphQL body over 64 KiB is refused before the check reads it" "http=413" "$r" > "$f"; } &
pids+=($!)
# github-issues (httpbingo): issues pass to the host (its 404), PR writes are refused here.
check 3132 "issues: GraphQL createIssue passes"            "$P http=404 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"mutation { createIssue(input: {}) { clientMutationId } }\"}" http://httpbingo.org/graphql
check 3132 "issues: GraphQL replaceActorsForAssignable passes" "$P http=404 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"mutation { replaceActorsForAssignable(input: {}) { clientMutationId } }\"}" http://httpbingo.org/graphql
check 3132 "issues: GraphQL createPullRequest refused"     "$P http=403 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"mutation { createPullRequest(input: {}) { clientMutationId } }\"}" http://httpbingo.org/graphql
check 3132 "issues: GraphQL updatePullRequest refused"     "$P http=403 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"mutation { updatePullRequest(input: {}) { clientMutationId } }\"}" http://httpbingo.org/graphql
check 3132 "issues: REST issue create passes"              "$P http=404 exit=0" -X POST http://httpbingo.org/repos/o/r/issues
check 3132 "issues: REST issue edit passes"                "$P http=404 exit=0" -X PATCH http://httpbingo.org/repos/o/r/issues/1
check 3132 "issues: REST pull create refused"              "$P http=403 exit=0" -X POST http://httpbingo.org/repos/o/r/pulls
check 3132 "issues: REST pull edit refused"                "$P http=403 exit=0" -X PATCH http://httpbingo.org/repos/o/r/pulls/1
check 3132 "issues: REST reviewers refused"                "$P http=403 exit=0" -X POST http://httpbingo.org/repos/o/r/pulls/1/requested_reviewers
check 3132 "a header name with an underscore refused"     "$P http=400 exit=0" -H "X_HTTP_Method_Override: DELETE" http://httpbin.org/anything/u
slot; { r="$(curl -s -x http://127.0.0.1:3132 -H "X-Request-Id: box-marker-id" http://httpbin.org/anything/rid | tr -d "\n")"
  if [[ "$r" == *"\"url\""* && "$r" != *Request-Id* && "$r" != *box-marker-id* ]]; then r="no x-request-id upstream"; fi
  verdict "no x-request-id upstream, the box one stripped and none generated" "no x-request-id upstream" "${r:0:300}" > "$f"; } &
pids+=($!)
check 3132 "issues: createIssue naming a project refused"  "$P http=403 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"mutation { createIssue(input: {title: \\\"t\\\", projectV2Ids: [\\\"PVT_x\\\"]}) { clientMutationId } }\"}" http://httpbingo.org/graphql
check 3132 "issues: Projects item write on the pinned project passes" "$P http=404 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"mutation { archiveProjectV2Item(input: {projectId: \\\"PVT_test1\\\", itemId: \\\"i\\\"}) { clientMutationId } }\"}" http://httpbingo.org/graphql
check 3132 "issues: Projects item delete refused, on the pinned project too" "$P http=403 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"mutation { deleteProjectV2Item(input: {projectId: \\\"PVT_test1\\\", itemId: \\\"i\\\"}) { deletedItemId } }\"}" http://httpbingo.org/graphql
check 3132 "issues: Projects item write on another project refused" "$P http=403 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"mutation { archiveProjectV2Item(input: {projectId: \\\"PVT_other\\\", itemId: \\\"i\\\"}) { clientMutationId } }\"}" http://httpbingo.org/graphql
slot; { r="$(curl -s -x http://127.0.0.1:3132 http://httpbingo.org/anything/v | tr -d " \n" | grep -o "Authorization\":\[\"[^\"]*")
    $(curl -s -x http://127.0.0.1:3130 http://httpbingo.org/anything/v | tr -d " \n" | grep -o "Authorization\":\[\"[^\"]*")"
  verdict "variants: one host, each listener its own credential (t-http t-cred, t-other t-gh)" "*SITE-TEST-TOKEN-1*dummy-not-a-github-token*" "$(echo $r)" > "$f"; } &
pids+=($!)
check 3130 "variants: t-other has the full rules (PR create passes)" "$P http=404 exit=0" -X POST http://httpbingo.org/repos/o/r/pulls
# forgejo (httpbin.org@fj on t-other): allowed requests reach the host (its 404), the rest 403 here.
for c in "git info/refs:GET:/o/r.git/info/refs:404" "git receive-pack:POST:/o/r.git/git-receive-pack:404" \
         "api read:GET:/api/v1/repos/o/r:404" "pr create:POST:/api/v1/repos/o/r/pulls:404" \
         "pr edit:PATCH:/api/v1/repos/o/r/pulls/1:404" "pr comment:POST:/api/v1/repos/o/r/issues/1/comments:404" \
         "reviewers:POST:/api/v1/repos/o/r/pulls/1/requested_reviewers:404" \
         "merge:POST:/api/v1/repos/o/r/pulls/1/merge:403" "review (approve):POST:/api/v1/repos/o/r/pulls/1/reviews:403" \
         "contents write:PUT:/api/v1/repos/o/r/contents/f:403" "contents create:POST:/api/v1/repos/o/r/contents/f:403" \
         "branch delete:DELETE:/api/v1/repos/o/r/branches/b:403" "branch protection:POST:/api/v1/repos/o/r/branch_protections:403" \
         "hooks:POST:/api/v1/repos/o/r/hooks:403" "repo settings:PATCH:/api/v1/repos/o/r:403" "repo delete:DELETE:/api/v1/repos/o/r:403" \
         "tokens:POST:/api/v1/users/u/tokens:403" "keys:POST:/api/v1/user/keys:403" "admin:POST:/api/v1/admin/users:403" \
         "web UI:GET:/user/settings:403" "api internal:GET:/api/internal/x:403" "release:POST:/api/v1/repos/o/r/releases:403" \
         "pr via dot segments to merge:POST:/api/v1/repos/o/r/pulls/../pulls/1/merge:403" \
         "token in the query:GET:/api/v1/repos/o/r?token=x:403" "access_token in the query:POST:/o/r.git/git-receive-pack?access_token=x:403" \
         "sudo in the query:GET:/api/v1/user?sudo=someone:403" "wiki push:POST:/o/r.wiki.git/git-receive-pack:403" \
         "wiki fetch:GET:/o/r.wiki/info/refs:403"; do
  IFS=: read -r cn cm cp cw <<< "$c"
  check 3130 "forgejo: $cn" "$P http=$cw exit=0" --path-as-is -X "$cm" "http://httpbin.org$cp"
done
check 3130 "forgejo: a form body (token= could ride in it) refused" "$P http=403 exit=0" --data "token=x&body=hi" http://httpbin.org/api/v1/repos/o/r/issues/1/comments
check 3130 "forgejo: a JSON comment passes" "$P http=404 exit=0" -H "Content-Type: application/json" --data "{}" http://httpbin.org/api/v1/repos/o/r/issues/1/comments
# repos (t-other: GitHub scoped to octocat/hello-world and octo-org/*; a 401 is GitHub
# refusing the dummy credential, so the request got there; a 403 is Envoy).
for c in "listed repo:GET:/repos/octocat/hello-world:401" "listed repo, other case:GET:/repos/OctoCat/Hello-World/pulls:401" \
         "an owner/* repo:GET:/repos/octo-org/anything:401" "who the token is:GET:/user:401" "rate limit:GET:/rate_limit:401" \
         "repos of the token:GET:/user/repos:403" "orgs of the token:GET:/user/orgs:403" \
         "issue create, listed repo:POST:/repos/octocat/hello-world/issues:401" \
         "unlisted repo:GET:/repos/octocat/spoon-knife:403" "issue create, unlisted repo:POST:/repos/octocat/spoon-knife/issues:403" \
         "a name extending a listed one:GET:/repos/octocat/hello-worlds:403" "repo by id:GET:/repositories/1296269:403" \
         "search:GET:/search/repositories?q=x:403" "repos of a user:GET:/users/octocat/repos:403" "repos of an org:GET:/orgs/octo-org/repos:403" \
         "gists:GET:/gists/public:403" "GraphQL query:POST:/graphql:403" \
         "dot segments out of a listed repo:GET:/repos/octocat/hello-world/../../octocat/spoon-knife:403" \
         "escaped dots out of a listed repo:GET:/repos/octocat/hello-world/%2e%2e/%2e%2e/octocat/spoon-knife:403" \
         "escaped dots, upper case:GET:/repos/octocat/hello-world/%2E%2E/%2E%2E/octocat/spoon-knife:403" \
         "an escaped dot in a file name (403 refused, 401 decoded by Envoy to a.b; either is safe):GET:/repos/octocat/hello-world/contents/a%2eb:40[13]" \
         "compare in the repo:GET:/repos/octocat/hello-world/compare/master...master:401" \
         "compare across the fork network:GET:/repos/octocat/hello-world/compare/master...octocat:spoon-knife:master:403" \
         "compare across, upper case:GET:/repos/octocat/hello-world/COMPARE/master...octocat:spoon-knife:master:403" \
         "compare across, an escaped letter:GET:/repos/octocat/hello-world/c%6fmpare/master...octocat:spoon-knife:master:403"; do
  cw=${c##*:} c=${c%:*}; cn=${c%%:*} c=${c#*:}; cm=${c%%:*} cp=${c#*:}   # the path may hold a colon
  check 3130 "repos, GitHub API: $cn" "$P http=$cw exit=0" --path-as-is -X "$cm" -H "Content-Type: application/json" "http://api.github.com$cp"
done
slot; { r="$(cd /tmp && rm -rf hwr && http_proxy=http://127.0.0.1:3130 git clone -q --depth 1 http://github.com/octocat/Hello-World.git hwr 2>&1 && git -C hwr rev-parse --short HEAD)"
  verdict "repos, git: a listed repo clones" "7fd1a60" "$r" > "$f"; } &
pids+=($!)
slot; { r="$(cd /tmp && rm -rf skr && http_proxy=http://127.0.0.1:3130 git clone -q --depth 1 http://github.com/octocat/Spoon-Knife.git skr 2>&1 | tr "\n" " ")"
  verdict "repos, git: an unlisted repo is refused" "*403*" "$r" > "$f"; } &
pids+=($!)
# repos on the forgejo rules (t-site: httpbin.org@fjrepo, o/r): allowed requests reach the
# host (its 404), the rest 403 here.
for c in "listed repo:GET:/api/v1/repos/o/r:404" "listed repo, other case:GET:/api/v1/repos/O/R/pulls/1:404" \
         "who the token is:GET:/api/v1/user:404" "version:GET:/api/v1/version:404" \
         "repos of the token user:GET:/api/v1/user/repos:403" "under version:GET:/api/v1/version/x:403" \
         "git fetch, listed repo:GET:/o/r.git/info/refs:404" "git push, listed repo:POST:/o/r.git/git-receive-pack:404" \
         "unlisted repo:GET:/api/v1/repos/o/other:403" "repo search:GET:/api/v1/repos/search:403" \
         "repos of a user:GET:/api/v1/users/o/repos:403" "comment, unlisted repo:POST:/api/v1/repos/o/other/issues/1/comments:403" \
         "git fetch, unlisted repo:GET:/o/other.git/info/refs:403" "wiki of a listed repo:GET:/o/r.wiki.git/info/refs:403" \
         "token in the query, listed repo:GET:/api/v1/repos/o/r?token=x:403" \
         "escaped dots out of a listed repo:GET:/api/v1/repos/o/r/%2e%2e/%2e%2e/o/other:403" \
         "compare across repos:GET:/api/v1/repos/o/r/compare/main...other:main:403"; do
  cw=${c##*:} c=${c%:*}; cn=${c%%:*} c=${c#*:}; cm=${c%%:*} cp=${c#*:}   # the path may hold a colon
  check 3128 "repos, forgejo: $cn" "$P http=$cw exit=0" --path-as-is -X "$cm" -H "Content-Type: application/json" "http://httpbin.org$cp"
done
# Several definitions of one host (t-site: httpbingo git, anything/a with t-cred, anything/b
# with t-gh): each repo carries the credential of its own definition; another repo is refused.
slot; { r="$(curl -s -x http://127.0.0.1:3128 http://httpbingo.org/anything/a/info/refs | grep -o "SITE-TEST-TOKEN-1\|dummy-not-a-github-token" | sort -u | tr "\n" " ")
    $(curl -s -x http://127.0.0.1:3128 http://httpbingo.org/anything/B.git/info/refs | grep -o "SITE-TEST-TOKEN-1\|dummy-not-a-github-token" | sort -u | tr "\n" " ")"
  verdict "several definitions: each repo its own credential (a: t-cred, b: t-gh)" "SITE-TEST-TOKEN-1 dummy-not-a-github-token " "$(echo $r) " > "$f"; } &
pids+=($!)
check 3128 "several definitions: a repo in neither refused" "$P http=403 exit=0" http://httpbingo.org/anything/c/info/refs
check 3128 "several definitions: push to a listed repo passes the rules" "$P http=200 exit=0" -X POST http://httpbingo.org/anything/a/git-receive-pack
check 3132 "github-api: GraphQL requestReviewsByLogin passes" "$P http=404 exit=0" -H "Content-Type: application/json" --data "{\"query\":\"mutation { requestReviewsByLogin(input: {}) { clientMutationId } }\"}" http://httpbin.org/graphql
settle
# Alone: 40 GraphQL requests at once on one listener, 20 to each of two GitHub-rule hosts; one
# bucket per listener (bursts of 20) answers about half with 429 before the check runs (fewer
# when the machine is busy and they spread over the refill; a bucket per route would give none).
note "== GraphQL rate limit per listener"
slot; { r="$(for h in $(printf "httpbingo.org httpbin.org %.0s" $(seq 20)); do curl -s -o /dev/null -w "%{http_code}\n" -x http://127.0.0.1:3132 -H "Content-Type: application/json" --data "{\"query\":\"{ viewer { login } }\"}" "http://$h/graphql" & done; wait)"
  n429=$(grep -c 429 <<< "$r"); n404=$(grep -c 404 <<< "$r")
  verdict "40 at once over two hosts: one bucket, some limited (429), the rest through (404)" "limited through*" "$([ "$n429" -ge 5 ] && echo limited) $([ "$n404" -ge 10 ] && echo through) ($n429 x 429, $n404 x 404)" > "$f"; } &
pids+=($!)
settle
# Alone, after the rest: it holds t-other at its cap.
note "== connection caps: one listener at its cap does not starve another"
# 128 connections straight on the socket, from one process (a socat fork each was 15 s).
python3 -I -c "
import socket, sys, time
held = []
for _ in range(128):
    c = socket.socket(socket.AF_UNIX); c.connect(\"/run/proxy/t-other.sock\"); held.append(c)
open(\"/tmp/held\", \"w\").close()
time.sleep(30)" &
holder=$!
until [ -e /tmp/held ]; do sleep 0.01; done
sleep 0.3   # for Envoy to accept them all
check 3130 "t-other, 129th connection while 128 are open" "proxy=000 http=000 exit=56" https://example.org/
check 3129 "anthropic, meanwhile"                        "$OK" https://api.anthropic.com/
settle
kill "$holder"
exit "$fails"
'
fails=$?
logchecks() {
  log() { readlog | tail -n "+$start"; }
  lc() {  # lc <name> <jq filter that must match at least one line of this run>
    if log | jq -e "select($2)" >/dev/null 2>&1 && [ -n "$(log | jq -c "select($2)")" ]; then echo "ok   log: $1"
    else echo "FAIL log: $1"; fi
  }
  lc "t-site allowed the address entry by its route" '.listener == "t-site" and .route == "allow-1.1.1.1" and .status == 200'
  lc "t-site allowed the port-8443 host" '.listener == "t-site" and .route == "allow-port-test.invalid:8443" and .status == 200'
  lc "t-site refused the same host on 443" '.listener == "t-site" and .authority == "port-test.invalid:443" and .route == "deny-connect"'
  lc "t-anthropic refused example.com" '.listener == "t-anthropic" and .authority == "example.com:443" and .route == "deny-connect"'
  lc "t-other refused api.anthropic.com" '.listener == "t-other" and .authority == "api.anthropic.com:443" and .route == "deny-connect"'
  lc "an SNI sent to the address entry: refused by RBAC, with the SNI" '.sni == "one.one.one.one" and .route == "tls-no-sni" and .details == "rbac_access_denied_matched_policy[server-name-sent]"'
  lc "wrong SNI on a host entry: NR, with the SNI" '.sni == "www.example.com" and .flags == "NR"'
  # Each refused tunnel joins to the t-site CONNECT that opened it.
  n=$(log | jq -s -r '
    (map(select(.listener == "t-site" and .log_type == "DownstreamEnd")) | map({ key: (.connection | tostring), value: .route }) | from_entries) as $http
    | [ .[] | select((.sni == "one.one.one.one" and .route == "tls-no-sni") or .sni == "www.example.com" or (.flags == "NR" and .sni == null))
        | $http[.connection] ] | map(select(. == "allow-1.1.1.1" or . == "allow-example.com" or . == "allow-one.one.one.one")) | length')
  if [ "$n" -eq 5 ]; then echo "ok   log: the 5 refused tunnels (2 SNI, 2 no TLS, 1 no SNI) each join to their t-site CONNECT"
  else echo "FAIL log: $n of 5 refused tunnels joined to a t-site CONNECT"; fi
  lc "t-http logged the method, host and path of a plain-HTTP request" '.listener == "t-http" and .method == "GET" and .authority == "httpbin.org" and .path == "/anything/read" and .route == "httpbin.org-read" and .status == 200'
  lc "t-http (with web) refused CONNECT to its plain-HTTP host by that host's own route" '.listener == "t-http" and .authority == "httpbin.org:443" and .route == "deny-connect-http-httpbin.org"'
  lc "t-http logged the GraphQL refusal" '.listener == "t-http" and .path == "/graphql" and .status == 403 and .method == "POST"'
  if log | grep -q "SITE-TEST-TOKEN\|dummy-not-a-github-token"; then echo "FAIL log: a credential value is in the access log"
  else echo "ok   log: no credential value in the access log"; fi
  lc "t-web sent example.com to the web Envoy" '.listener == "t-web" and .authority == "example.com:443" and .route == "allow-web" and .status == 200'
  lc "t-web allowed example.org by its exact entry" '.listener == "t-web" and .authority == "example.org:443" and .route == "allow-example.org"'
  lc "t-web refused www.example.org as internal" '.listener == "t-web" and .authority == "www.example.org:443" and .route == "deny-web-internal-sub-example.org"'
  lc "t-web refused the IPv4 literal" '.listener == "t-web" and .authority == "1.1.1.1:443" and .route == "deny-connect"'
  wlog() { readweblog | tail -n "+$webstart"; }
  wl() {  # wl <name> <jq filter that must match a line of the web log>
    if [ -n "$(wlog | jq -c "select($2)" 2>/dev/null)" ]; then echo "ok   web log: $1"; else echo "FAIL web log: $1"; fi
  }
  wl "example.com dialled by the web chain, logged under t-web" '.listener == "t-web" and .sni == "example.com" and .route == "web" and .upstream != null'
  wl "SNI example.net refused, nothing dialled" '.sni == "example.net" and .route == "deny-internal-name" and .upstream == null'
  wl "SNI 192.0.2.1 (raw ClientHello) got no chain, nothing dialled" '.sni == "192.0.2.1" and .route == null and .flags == "NR" and .upstream == null'
  wl "SNI www.example.net (subdomain of an internal name) refused at the web Envoy" '.sni == "www.example.net" and .route == "deny-internal-name" and .upstream == null'
  if [ -n "$(wlog | jq -c 'select(.upstream != null and (.upstream | startswith("[")))' 2>/dev/null)" ]; then
    echo "FAIL web log: an IPv6 upstream (web is IPv4 only)"
  else echo "ok   web log: no IPv6 upstream (web is IPv4 only)"; fi
  wl "no SNI got no chain, nothing dialled" '.sni == null and .route == null and .flags == "NR" and .upstream == null'
  if [ -n "$(wlog | jq -c 'select(.upstream != null and (.upstream | test("^(10|127|172\\.(1[6-9]|2[0-9]|3[01])|192\\.168)\\.")))' 2>/dev/null)" ]; then
    echo "FAIL web log: the web Envoy dialled a private address"
  else echo "ok   web log: no private address dialled"; fi
}
# The log is flushed periodically (every 100 ms under run-envoy.sh, every second in the
# service): retry the log checks until all pass or 4 s have gone by; report the last attempt.
deadline=$((SECONDS + 4))
until out="$(logchecks)"; ! grep -q "^FAIL" <<<"$out" || [ "$SECONDS" -ge "$deadline" ]; do sleep 0.1; done
printf '%s\n' "$out"; fails=$((fails + $(grep -c "^FAIL" <<<"$out")))
# A credential swapped in place (what airlock-envoy-cred does): the next request carries it,
# with Envoy still the same process.
if [ -f "$DIR/credentials/t-cred.yaml" ]; then
  sed 's/SITE-TEST-TOKEN-1/SITE-TEST-TOKEN-2/' "$DIR/credentials/t-cred.yaml" > "$DIR/credentials/.t-cred.new"
  mv -f "$DIR/credentials/.t-cred.new" "$DIR/credentials/t-cred.yaml"
  r=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    r="$(podman run --rm --network none --userns keep-id --user "$(id -u):$(id -g)" -v "$DIR/t-http.sock:/run/proxy/t-http.sock${SOCK_MOUNT_OPTS-:z}" \
      --entrypoint sh localhost/airlock-envoy-spike-client:test -c 'socat -lf /dev/null TCP-LISTEN:3132,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:/run/proxy/t-http.sock & sleep 0.2; curl -s -x http://127.0.0.1:3132 http://httpbin.org/anything/rot' | grep -o "SITE-TEST-TOKEN-[0-9]")"
    [ "$r" = SITE-TEST-TOKEN-2 ] && break; sleep 0.3
  done
  if [ "$r" = SITE-TEST-TOKEN-2 ]; then echo "ok   a credential swapped in place is used from the next request"
  else echo "FAIL a credential swapped in place: got '$r'"; fails=$((fails + 1)); fi
  sed 's/SITE-TEST-TOKEN-2/SITE-TEST-TOKEN-1/' "$DIR/credentials/t-cred.yaml" > "$DIR/credentials/.t-cred.new"
  mv -f "$DIR/credentials/.t-cred.new" "$DIR/credentials/t-cred.yaml"
fi
echo "failures: $fails"
exit "$fails"
