#!/bin/bash
# Spike test 2: from a --network none client, the allowlist passes and everything else fails.
# Needs Envoy running with the built-in config (test/run-envoy.sh, or the installed service).
# Each check has one exact expectation, so a weaker allowlist fails a check instead of passing
# it by accident. Exits non-zero if any check fails.
#   SOCK  the proxy socket (default ./run/anthropic.sock; service: /run/airlock-envoy/anthropic.sock,
#         with SOCK_MOUNT_OPTS= so a system socket is not SELinux-relabelled)
#   LOG   a command printing the access log (default: cat run/access.jsonl;
#         service: "sudo cat /var/log/airlock-envoy/access.jsonl")
set -u
cd "$(dirname "$0")/.." || exit
SOCK="${SOCK:-$PWD/run/anthropic.sock}"
LOG="${LOG:-cat run/access.jsonl}"
readlog() { bash -c "$LOG"; }
# Only log lines written during this run count: the log appends across runs, and connection
# IDs restart at 0 whenever Envoy starts.
start=$(( $(readlog | wc -l) + 1 ))
tag="t2-$$-$(date +%s)"
podman run --rm --network none --userns keep-id --user "$(id -u):$(id -g)" -e "TAG=$tag" \
  -v "$SOCK:/run/proxy/anthropic.sock${SOCK_MOUNT_OPTS-:z}" \
  localhost/airlock-envoy-spike-client:test bash -c '
fails=0
p=(-x http://127.0.0.1:3128 -s -o /dev/null --max-time 10 -w "proxy=%{http_connect} http=%{http_code}")
check() {  # check <name> <expected result pattern> <curl args...>
  local name=$1 want=$2; shift 2
  r="$(curl "${p[@]}" "$@") exit=$?"
  if [[ "$r" == $want ]]; then echo "ok   $name: $r"
  else echo "FAIL $name: $r (wanted $want)"; fails=$((fails+1)); fi
}
echo "uid $(id -u); interfaces: $(ls /sys/class/net | tr "\n" " ")"
# Allowed: the proxy answers 200 and TLS completes (the HTTP status is the site'"'"'s own).
check "api.anthropic.com:443"          "proxy=200 http=[1-5]* exit=0" https://api.anthropic.com/
check "platform.claude.com:443"        "proxy=200 http=[1-5]* exit=0" https://platform.claude.com/
check "claude.ai:443"                  "proxy=200 http=[1-5]* exit=0" https://claude.ai/
r="$(curl -s -o /dev/null --max-time 10 -w "http=%{http_code}" https://api.anthropic.com/) exit=$?"
if [[ "$r" == http=[1-5]??" exit=0" ]]; then echo "ok   HTTPS_PROXY from the environment: $r"
else echo "FAIL HTTPS_PROXY from the environment: $r"; fails=$((fails+1)); fi
# Refused at CONNECT: the proxy itself answers 403 (curl exit 56).
check "example.com:443"                "proxy=403 http=000 exit=56" https://example.com/
check "api.anthropic.com:8443"         "proxy=403 http=000 exit=56" https://api.anthropic.com:8443/
check "IP literal 1.1.1.1:443"         "proxy=403 http=000 exit=56" https://1.1.1.1/
check "[::1]:443"                      "proxy=403 http=000 exit=56" "https://[::1]/"
check "uppercase API.ANTHROPIC.COM"    "proxy=403 http=000 exit=56" https://API.ANTHROPIC.COM/
# Refused without CONNECT: the deny-http route answers 403.
check "plain http through the proxy"   "proxy=000 http=403 exit=0"  http://example.com/
# Allowed CONNECT name, another TLS server name: the tunnel opens, then closes in the TLS
# handshake (curl exit 35). The log check below confirms it was the SNI listener.
check "CONNECT api, SNI www.anthropic" "proxy=200 http=000 exit=35" --connect-to www.anthropic.com:443:api.anthropic.com:443 https://www.anthropic.com/
check "CONNECT api, SNI console"       "proxy=200 http=000 exit=35" --connect-to console.anthropic.com:443:api.anthropic.com:443 https://console.anthropic.com/
r=$(curl --noproxy "*" -s -o /dev/null --max-time 5 https://160.79.104.10/); e=$?
if [ "$e" -eq 7 ]; then echo "ok   direct connect to an IP, no proxy: exit=$e (no route)"
else echo "FAIL direct connect to an IP: exit=$e"; fails=$((fails+1)); fi
if getent hosts api.anthropic.com >/dev/null; then echo "FAIL DNS resolved"; fails=$((fails+1))
else echo "ok   DNS: no answer"; fi
# 40 tunnels at once, each with its own wrong SNI of a different length: all must be closed in
# the handshake. The log check below proves each SNI line names its own tunnel (concurrency
# once broke this); the different lengths let it detect swapped IDs too.
for i in $(seq 40); do
  h="$TAG-$(head -c "$i" /dev/zero | tr "\0" x).invalid"
  { curl "${p[@]}" --connect-to "$h:443:api.anthropic.com:443" "https://$h/"; echo " exit=$?"; } > "/tmp/c$i" &
done
wait
n=$(cat /tmp/c[0-9]* | grep -c "^proxy=200 http=000 exit=35$")
if [ "$n" -eq 40 ]; then echo "ok   40 concurrent wrong-SNI tunnels all refused"
else echo "FAIL concurrent wrong-SNI tunnels: $n of 40 refused as expected"; fails=$((fails+1)); fi
exit "$fails"
'
fails=$?
# The SNI refusals must be in the audit log: flag NR, the SNI the client sent, and the
# connection ID of the HTTP line that allowed the CONNECT.
sleep 1.5
log() { readlog | tail -n "+$start"; }
for sni in www.anthropic.com console.anthropic.com; do
  line="$(log | jq -c --arg s "$sni" 'select(.sni == $s and .flags == "NR")' | tail -1)"
  conn="$(jq -r '.connection' <<<"${line:-null}")"
  if [ -n "$line" ] && log | jq -e --arg c "$conn" 'select(.listener == "anthropic" and (.connection | tostring) == $c and .route == "allow-api.anthropic.com")' >/dev/null; then
    echo "ok   log: SNI $sni refused (NR), joined to HTTP connection $conn"
  else
    echo "FAIL log: no NR line for SNI $sni joined to its CONNECT"; fails=$((fails+1))
  fi
done
# Concurrent tunnels: 40 NR lines with this run's SNIs, 40 distinct connection IDs, each ID an
# allowed CONNECT of this run, and the CONNECT's bytes_in (the ClientHello, which grows with
# the SNI) minus the SNI's length the same for every pair. A shared, reused or swapped ID
# breaks one of these.
read -r nlines nids nmatched nsizes < <(log | jq -s -r --arg t "$tag-" '
  (map(select(.listener == "anthropic" and .route == "allow-api.anthropic.com" and .log_type == "DownstreamEnd"))
    | map({ key: (.connection | tostring), value: .bytes_in }) | from_entries) as $http
  | [ .[] | select((.sni // "") | startswith($t)) | select(.flags == "NR") ] as $sni
  | [ $sni[] | select($http[.connection] != null) ] as $joined
  | [ ($sni | length), ([ $sni[].connection ] | unique | length), ($joined | length),
      ([ $joined[] | $http[.connection] - (.sni | length) ] | unique | length) ]
  | @tsv')
if [ "$nlines" -eq 40 ] && [ "$nids" -eq 40 ] && [ "$nmatched" -eq 40 ] && [ "$nsizes" -eq 1 ]; then
  echo "ok   log: 40 concurrent SNI refusals, each joined to its own CONNECT (IDs and ClientHello sizes agree)"
else
  echo "FAIL log: concurrent SNI lines=$nlines distinct IDs=$nids joined=$nmatched size offsets=$nsizes (want 40/40/40/1)"; fails=$((fails+1))
fi
echo "failures: $fails"
exit "$fails"
