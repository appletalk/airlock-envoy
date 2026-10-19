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
  -v "$DIR/anthropic.sock:/run/proxy/anthropic.sock${SOCK_MOUNT_OPTS-:z}" \
  -v "$DIR/t-web.sock:/run/proxy/t-web.sock${SOCK_MOUNT_OPTS-:z}" \
  --entrypoint bash localhost/airlock-envoy-spike-client:test -c '
for s in t-site:3128 anthropic:3129 t-other:3130 t-web:3131; do
  socat -lf /dev/null TCP-LISTEN:${s#*:},bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:/run/proxy/${s%:*}.sock &
done
listening() { for p in 0C38 0C39 0C3A 0C3B; do grep -q ":$p 00000000:0000 0A" /proc/net/tcp || return 1; done; }
until listening; do sleep 0.01; done   # 127.0.0.1:3128-3131
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
note "== t-site: @anthropic, example.com, 1.1.1.1:443, tls-v1-2.badssl.com:1012, one.one.one.one"
check 3128 "included api.anthropic.com"          "$OK" https://api.anthropic.com/
check 3128 "example.com"                         "$OK" https://example.com/
check 3128 "address entry 1.1.1.1:443"           "$OK" https://1.1.1.1/
check 3128 "host on port 1012"                   "$OK" https://tls-v1-2.badssl.com:1012/
check 3128 "same host, port 443 not listed"      "$NO" https://tls-v1-2.badssl.com/
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
# Python will not send an IP literal as the server name (RFC 6066); openssl will, as an
# attacker would.
slot; { verdict "CONNECT example.com, SNI 10.44.0.10 (openssl)" "closed" \
  "$(echo | timeout 10 openssl s_client -proxy 127.0.0.1:3131 -connect example.com:443 -servername 10.44.0.10 2>&1 | grep -q "BEGIN CERTIFICATE" && echo handshake || echo closed)" > "$f"; } &
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
  lc "t-site allowed the port-1012 host" '.listener == "t-site" and .route == "allow-tls-v1-2.badssl.com:1012" and .status == 200'
  lc "anthropic refused example.com" '.listener == "anthropic" and .authority == "example.com:443" and .route == "deny-connect"'
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
  lc "t-web sent example.com to the web Envoy" '.listener == "t-web" and .authority == "example.com:443" and .route == "allow-web" and .status == 200'
  lc "t-web allowed example.org by its exact entry" '.listener == "t-web" and .authority == "example.org:443" and .route == "allow-example.org"'
  lc "t-web refused www.example.org as internal" '.listener == "t-web" and .authority == "www.example.org:443" and .route == "deny-web-internal-sub-example.org"'
  lc "t-web refused the IPv4 literal" '.listener == "t-web" and .authority == "1.1.1.1:443" and .route == "deny-connect"'
  wlog() { readweblog | tail -n "+$webstart"; }
  wl() {  # wl <name> <jq filter that must match a line of the web log>
    if [ -n "$(wlog | jq -c "select($2)" 2>/dev/null)" ]; then echo "ok   web log: $1"; else echo "FAIL web log: $1"; fi
  }
  wl "example.com dialled by the web chain" '.sni == "example.com" and .route == "web" and .upstream != null'
  wl "SNI example.net refused, nothing dialled" '.sni == "example.net" and .route == "deny-internal-name" and .upstream == null'
  # Some openssl builds drop an IP literal from the server name; either way nothing is dialled.
  if [ -n "$(wlog | jq -c 'select(.sni == "10.44.0.10" and (.route != null or .upstream != null))' 2>/dev/null)" ]; then
    echo "FAIL web log: SNI 10.44.0.10 got a chain or an upstream"
  else echo "ok   web log: SNI 10.44.0.10 got no chain, nothing dialled"; fi
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
echo "failures: $fails"
exit "$fails"
