#!/bin/bash
# airlock-envoy-apply's site file parser: what it refuses, and what a valid file expands to.
# Runs as any user, without Envoy (--list). Exits non-zero if any case fails.
set -u
cd "$(dirname "$0")/.." || exit
apply=install/airlock-envoy-apply
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0

refuses() {  # refuses <name> <expected message part> <site text>
  printf '%b' "$3" > "$work/site"
  if out="$("$apply" --list "$work/site" 2>&1)"; then
    echo "FAIL $1: accepted"; fails=$((fails+1))
  elif [[ "$out" == *"$2"* ]]; then echo "ok   $1"
  else echo "FAIL $1: wrong message: $out"; fails=$((fails+1)); fi
}
lists() {  # lists <name> <expected --list lines for the site's own listeners> <site text>
  printf '%b' "$3" > "$work/site"
  if ! out="$("$apply" --list "$work/site" 2>&1)"; then echo "FAIL $1: refused: $out"; fails=$((fails+1)); return; fi
  out="$(grep -v '^anthropic ' <<< "$out")"
  if [ "$out" = "$(printf '%b' "$2")" ]; then echo "ok   $1"
  else echo "FAIL $1: got:"; echo "$out"; fails=$((fails+1)); fi
}

A='a api.anthropic.com:443\na platform.claude.com:443'
refuses "uppercase host"               "only lowercase"        'a Example.com:443\n'
refuses "wildcard"                     "only lowercase"        'a *.example.com:443\n'
refuses "CRLF line ending"             "only lowercase"        'a example.com:443\r\n'
refuses "IPv6 literal"                 "only lowercase"        'a [fd00::1]:443\n'
refuses "URL"                          "only lowercase"        'a https://example.com/\n'
refuses "no port"                      "bad destination"       'a example.com\n'
refuses "port 0"                       "bad destination"       'a example.com:0\n'
refuses "port 65536"                   "bad destination"       'a example.com:65536\n'
refuses "port with a leading zero"     "bad destination"       'a example.com:0443\n'
refuses "single-label host"            "bad destination"       'a localhost:443\n'
refuses "label starting with -"        "bad destination"       'a -x.example.com:443\n'
refuses "empty label"                  "bad destination"       'a example..com:443\n'
refuses "numeric top-level label"      "bad destination"       'a example.123:443\n'
refuses "IPv4 octet over 255"          "bad destination"       'a 10.0.0.256:443\n'
refuses "IPv4 with a leading zero"     "bad destination"       'a 10.0.0.010:443\n'
refuses "IPv4 with three octets"       "bad destination"       'a 10.0.1:443\n'
refuses "loopback address"             "bad destination"       'a 127.0.0.1:8080\n'
refuses "0.0.0.0"                      "bad destination"       'a 0.0.0.0:443\n'
refuses "multicast address"            "bad destination"       'a 224.0.0.1:443\n'
refuses "link-local address"           "bad destination"       'a 169.254.169.254:80\n'
refuses "a bare @"                     "bad include"           'a @\n'
refuses "@ with a port"                "bad include"           'a @x:443\n'
refuses "listener name with a dot"     "bad listener name"     'a.b example.com:443\n'
refuses "listener name starting with a digit" "bad listener name" '1a example.com:443\n'
refuses "listener name over 32"        "bad listener name"     'abcdefghijabcdefghijabcdefghijabc example.com:443\n'
refuses "listener named admin"         "reserved"              'admin example.com:443\n'
refuses "redefining the built-in"      "built in"              'anthropic example.com:443\n'
refuses "a listener with nothing"      "lists nothing"         'a\n'
refuses "include of an unknown"        "not a listener defined above" 'a @b\n'
refuses "include of one defined below" "not a listener defined above" 'a @b\nb example.com:443\n'
refuses "self include"                 "includes itself"       'a example.com:443\na @a\n'
refuses "extending after an include"   "already included by b" 'a example.com:443\nb @a\na example.org:443\n'
refuses "a host as listener name"      "bad listener name"     'example.com:443\n'
refuses "line number in the message"   "site:3:"               '# c\na example.com:443\na Bad.com:443\n'

lists "comments, blanks, tabs, no final newline" 'a example.com:443\na 10.0.0.1:6443' \
  '# a comment\n\n a\texample.com:443   # trailing\na 10.0.0.1:6443'
lists "include expands, duplicates collapse" \
  "$A\na example.com:443\nb example.com:443\nb example.org:443\nc api.anthropic.com:443\nc platform.claude.com:443\nc example.com:443\nc example.org:443" \
  'a @anthropic example.com:443 example.com:443\nb example.com:443 example.org:443\nc @a @b\n'
lists "highest port, IPv4 edges"       'a example.com:65535\na 1.0.0.0:1\na 223.255.255.255:443' \
  'a example.com:65535 1.0.0.0:1 223.255.255.255:443\n'
lists "empty site file: built-in only" '' ''

# web and what counts as internal for it.
refuses "web as a listener name"       "is a destination"      'web example.com:443\n'
refuses "web with a port"              "bad destination"       'a web:443\n'
refuses "internal-name with nothing"   "internal-name lists nothing" 'internal-name\n'
refuses "internal-net with nothing"    "internal-net lists nothing"  'internal-net\n'
refuses "internal name with a port"    "bad internal name"     'internal-name corp.example:443\n'
refuses "internal name with a leading dot" "bad internal name" 'internal-name .corp.example\n'
refuses "internal name, numeric label" "bad internal name"     'internal-name corp.123\n'
refuses "CIDR outside internal-net"    "only lowercase"        'a 10.0.0.0/8\n'
refuses "internal-net without a prefix" "bad internal network" 'internal-net 10.0.0.0\n'
refuses "internal-net IPv4 /33"        "bad internal network"  'internal-net 10.0.0.0/33\n'
refuses "internal-net IPv4 octet 256"  "bad internal network"  'internal-net 10.0.0.256/32\n'
refuses "internal-net prefix leading zero" "bad internal network" 'internal-net 10.0.0.0/08\n'
refuses "internal-net IPv6 /129"       "bad internal network"  'internal-net fd00::/129\n'
refuses "internal-net IPv6 two ::"     "bad internal network"  'internal-net fd00::1::/64\n'
refuses "internal-net IPv6 nine groups" "bad internal network" 'internal-net 1:2:3:4:5:6:7:8:9/64\n'
refuses "internal-net IPv6 seven groups, no ::" "bad internal network" 'internal-net 1:2:3:4:5:6:7/64\n'
refuses "internal-net IPv6 five hex digits" "bad internal network" 'internal-net fd000::/16\n'
refuses "internal-net IPv6 leading single colon" "bad internal network" 'internal-net :fd00::/16\n'
refuses "internal-net IPv6 :::"        "bad internal network"  'internal-net fd00:::1/64\n'
refuses "internal-net IPv6 uppercase"  "only lowercase"        'internal-net FD00::/8\n'
refuses "internal-net IPv6 zone"       "only lowercase"        'internal-net fe80::1%eth0/64\n'
refuses "internal-net a host name"     "bad internal network"  'internal-net example.com/32\n'
lists "web expands through an include, after the exact entries" \
  'a web\nb example.com:443\nb web' 'a web\nb @a example.com:443\n'
lists "internal lines are listed while some listener has web" \
  'a web\ninternal-name corp.example\ninternal-name lab.example.net\ninternal-net 198.51.100.0/24\ninternal-net 2001:db8:1::/48' \
  'internal-name corp.example lab.example.net corp.example\ninternal-net 198.51.100.0/24 2001:db8:1::/48\na web\n'
lists "internal lines without any web listener change nothing" 'a example.com:443' \
  'internal-name corp.example\ninternal-net 10.0.0.0/8\na example.com:443\n'
lists "IPv6 CIDR forms" \
  'a web\ninternal-net ::/0\ninternal-net fd00:99::/32\ninternal-net 2001:db8:1:2:3:4:5:6/128\ninternal-net ::ffff:0:0/96\ninternal-net 1::/16\ninternal-net 0.0.0.0/0' \
  'a web\ninternal-net ::/0 fd00:99::/32 2001:db8:1:2:3:4:5:6/128 ::ffff:0:0/96 1::/16 0.0.0.0/0\n'

# Plain HTTP: the http lines, http:// destinations, one mode per host.
refuses "http without rules"           "want: http"            'http x.example\n'
refuses "http, unknown rules"          "unknown rules"         'http x.example rules nope\n'
refuses "http, unknown option"         "unknown http option"   'http x.example rules any header x\n'
refuses "http, bad credential name"    "bad credential name"   'http x.example rules any credential 1x\n'
refuses "http, uppercase credential"   "only lowercase"        'http x.example rules any credential Gh\n'
refuses "http host an IP address"      "bad http host"         'http 10.0.0.1 rules any\n'
refuses "http host with a path"        "only lowercase"        'http x.example/p rules any\n'
refuses "http defined twice"           "defined twice"         'http x.example rules any\nhttp x.example rules git\n'
refuses "http:// with no http line"    "has no 'http x.example"  'a http://x.example\n'
refuses "http:// before its http line" "has no 'http x.example"  'a http://x.example\nhttp x.example rules any\n'
refuses "a host as http:// and CONNECT" "use one"              'http x.example rules any\na x.example:443 http://x.example\n'
refuses "...also through an include"   "use one"               'http x.example rules any\na http://x.example\nb @a x.example:8443\n'
lists "http destinations, through an include" \
  'a http://x.example:443 rules git credential gh\nb http://x.example:443 rules git credential gh\nb http://y.example:8443 rules any' \
  'http x.example rules git credential gh\nhttp y.example:8443 rules any\na http://x.example\nb @a http://y.example\n'

# Variants: another definition of a host (its own rules, credential, projects), one per listener.
refuses "variant: bad name"            "bad variant"           'http x.example@1v rules any\n'
refuses "variant: empty"               "bad variant"           'http x.example@ rules any\n'
refuses "variant: defined twice"       "defined twice"         'http x.example@v rules any\nhttp x.example@v rules git\n'
refuses "variant: not defined"         "has no 'http x.example@w" 'http x.example@v rules any\na http://x.example@w\n'
refuses "two definitions of a host in one listener" "lists x.example twice" 'http x.example rules any\nhttp x.example@v rules git\na http://x.example http://x.example@v\n'
refuses "...also through an include"   "lists x.example twice" 'http x.example rules any\nhttp x.example@v rules git\na http://x.example\nb @a http://x.example@v\n'
refuses "a variant and CONNECT to its host" "use one"          'http x.example@v rules any\na x.example:443 http://x.example@v\n'
lists "variants: each listener its own definition of the host" \
  'a http://x.example:443 rules github-api credential c1\nb http://x.example:443@board rules github-issues credential c2 projects PVT_kwDOAB12cd,PVT_x-Y_9' \
  'http x.example rules github-api credential c1\nhttp x.example@board rules github-issues credential c2 projects PVT_kwDOAB12cd,PVT_x-Y_9\na http://x.example\nb http://x.example@board\n'
# projects: Projects v2 node IDs, on the GitHub presets only; mixed case only there.
refuses "projects: not a PVT_ ID"      "bad project ID"        'http x.example rules github-api projects PR_kw12\n'
refuses "projects: a quote"            "bad project ID"        'http x.example rules github-api projects PVT_a"b\n'
refuses "projects: an empty ID"        "bad project ID"        'http x.example rules github-api projects PVT_\n'
refuses "projects: with other rules"   "projects only with"    'http x.example rules any projects PVT_abc\n'
refuses "projects: none given"         "projects needs"        'http x.example rules github-api projects\n'
refuses "projects: a glob is not expanded" "bad project ID '*'"  'http x.example rules github-api projects *\n'
refuses "mixed case elsewhere on an http line" "only lowercase" 'http X.example rules github-api projects PVT_abc\n'
refuses "mixed case on a listener line" "only lowercase"       'a PVT_abc.example:443\n'
printf 'http x.example@board rules github-issues credential c2 projects PVT_aB,PVT_cD\nb http://x.example@board\n' > "$work/site"
r="$("$apply" --render "$work/site")"
if grep -q 'name: "http-x.example_board"' <<< "$r" && grep -q 'host_rewrite_literal: "x.example"' <<< "$r" && grep -q 'domains: \["x.example", "x.example:80"\]' <<< "$r" \
   && grep -q 'sni: "x.example"' <<< "$r" && grep -q 'filter_metadata: { github-graphql: { rules: "github-issues", projects: "PVT_aB PVT_cD" } }' <<< "$r" \
   && [ "$("$apply" --clients b "$work/site" | grep -v '^#')" = "x.example 443 github-issues yes" ]; then
  echo "ok   a variant renders to its host (Host, SNI, SAN, domains), its own cluster, its projects; the manifest names the host"
else echo "FAIL variant rendering"; fails=$((fails+1)); fi

# Client manifests: each listener's plain-HTTP hosts (an include's too), nothing else.
printf 'http x.example rules git credential gh\nhttp y.example:8443 rules any\na http://x.example example.com:443\nb @a http://y.example web\nc example.org:443\n' > "$work/site"
m="$("$apply" --clients b "$work/site" | grep -v '^#')"
if [ "$m" = "$(printf 'x.example 443 git yes\ny.example 8443 any no')" ]; then echo "ok   client manifest: the include's host and its own, port, rules, credential yes/no"
else echo "FAIL client manifest: got: $m"; fails=$((fails+1)); fi
m="$("$apply" --clients c "$work/site")"
if [ -n "$m" ] && ! grep -qv '^#' <<< "$m"; then echo "ok   client manifest: a listener without plain HTTP gets comments only"
else echo "FAIL client manifest without plain HTTP: got: $m"; fails=$((fails+1)); fi
m="$("$apply" --clients anthropic "$work/site" | grep -v '^#')"
if [ -z "$m" ]; then echo "ok   client manifest: the built-in anthropic listener has none"
else echo "FAIL client manifest for anthropic: got: $m"; fails=$((fails+1)); fi
if ! "$apply" --clients nope "$work/site" >/dev/null 2>&1 && ! "$apply" --clients >/dev/null 2>&1; then echo "ok   client manifest: an unknown listener, or none named, is refused"
else echo "FAIL client manifest: an unknown listener was accepted"; fails=$((fails+1)); fi

# No log format may name a request field other than method, authority and path: a credential
# Envoy adds is a request header, and the log sees headers after the injection.
printf 'http api.example.com rules github-api credential c1\nhttp g.example.com rules git credential c2\np @anthropic web http://api.example.com http://g.example.com 10.0.0.1:6443\n' > "$work/site"
fields="$({ "$apply" --render "$work/site"; "$apply" --render-web "$work/site"; } | grep -o '%REQ([^)]*)%\|%RESP([^)]*)%\|%REQ_WITHOUT_QUERY([^)]*)%\|%DOWNSTREAM_PEER[A-Z_]*%' | sort -u | tr '\n' ' ')"
if [ "$fields" = "%REQ(:AUTHORITY)% %REQ(:METHOD)% %REQ(:PATH)% " ]; then echo "ok   logs name no request header (only method, authority, path)"
else echo "FAIL logs name request fields beyond method, authority, path: $fields"; fails=$((fails+1)); fi
r="$("$apply" --render "$work/site")"
if [ "$(grep -c 'github-graphql: { "@type"' <<< "$r")" = 1 ] && grep -q 'filter_metadata: { github-graphql: { rules: "github-api", projects: "" } }' <<< "$r" \
   && grep -q 'max_request_bytes: 65536 }' <<< "$r" && grep -q 'token_bucket: { max_tokens: 20' <<< "$r" && grep -q 'name: strip-box-headers' <<< "$r" \
   && grep -q '"inject-c1": {' <<< "$r" && grep -q 'name: "deny-connect-http-api.example.com"' <<< "$r" \
   && grep -q 'disabled: true' <<< "$r" && grep -q 'mergePullRequest\|ALLOWED' <<< "$r"; then
  echo "ok   plain-HTTP rendering: the GraphQL check (rate limit, 64 KiB, the preset's allowlist) on one route only, injectors per route, CONNECT refused, box headers stripped"
else echo "FAIL plain-HTTP rendering"; fails=$((fails+1)); fi

# The web Envoy, per profile: its own listener, socket and DNS cache; IPv4 only (A records);
# no resolv.conf search domains.
printf 'p @anthropic web\nq web\nr example.org:443\n' > "$work/site"
w="$("$apply" --render-web "$work/site")"
if [ "$(grep -c 'dns_lookup_family: V4_ONLY' <<< "$w")" = 2 ] && [ "$(grep -c 'no_default_search_domain: true' <<< "$w")" = 2 ] \
   && ! grep -qE 'dns_lookup_family: (ALL|AUTO|V6)' <<< "$w" \
   && grep -q 'path: /run/airlock-envoy-web/p.sock' <<< "$w" && grep -q 'path: /run/airlock-envoy-web/q.sock' <<< "$w" \
   && ! grep -q 'airlock-envoy-web/r.sock' <<< "$w" && grep -q 'listener: "q"' <<< "$w"; then
  echo "ok   web Envoy: a listener, socket and IPv4-only cache per web profile, no search domains"
else echo "FAIL web Envoy per-profile rendering"; fails=$((fails+1)); fi

# The web unit's built-in deny list, against a list kept here on purpose (checked against the
# IANA special-purpose registries for IPv4 and IPv6): an edit to the unit has to edit this too.
WEB_DENY_GOLDEN="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 ::/3 4000::/2 8000::/1 2001::/23 2001:db8::/32 2002::/16 3fff::/20"
got="$(sed -n 's/^IPAddressDeny=//p' systemd/airlock-envoy-web.service | tr ' ' '\n' | sort)"
if [ "$got" = "$(tr ' ' '\n' <<< "$WEB_DENY_GOLDEN" | sort)" ]; then echo "ok   web unit: the built-in deny list is exactly the reviewed one"
else echo "FAIL web unit: the built-in deny list differs from the reviewed one:"; diff <(tr ' ' '\n' <<< "$WEB_DENY_GOLDEN" | sort) <(printf '%s\n' "$got"); fails=$((fails+1)); fi

# The web drop-in: the site's networks denied, each resolver allowed by exact address.
printf 'a web\ninternal-net 198.51.100.0/24 2001:db8:1::/48\n' > "$work/site"
printf 'nameserver 127.0.0.53\nnameserver fe80::1%%eth0\noptions edns0\n' > "$work/resolv"
want='[Service]
IPAddressDeny=198.51.100.0/24
IPAddressDeny=2001:db8:1::/48
IPAddressAllow=127.0.0.53/32
IPAddressAllow=fe80::1/128'
got="$(RESOLV_CONF="$work/resolv" "$apply" --render-web-dropin "$work/site" | grep -v '^#')"
if [ "$got" = "$want" ]; then echo "ok   web drop-in: site networks denied, resolvers allowed exactly"
else echo "FAIL web drop-in, got:"; echo "$got"; fails=$((fails+1)); fi

# A file shaped like a real site renders to a config Envoy accepts.
printf 'http api.example.com rules github-api\nhttp issues.example.com rules github-issues\nhttp g.example.com rules git\nx @anthropic metrics.example.net:443 logs.example.net:443 10.0.0.10:6443 http://api.example.com\ny example.org:8443 x-y.example.com:443 http://issues.example.com http://g.example.com\n' > "$work/site"
"$apply" --render "$work/site" > "$work/envoy.yaml"
if envoy="$(command -v envoy)"; then
  # Envoy picks the format by extension, and validate mode opens the access log.
  sed 's#path: /var/log/airlock-envoy/access.jsonl#path: /dev/null#' "$work/envoy.yaml" > "$work/validate.yaml"
  if "$envoy" --mode validate -c "$work/validate.yaml" >/dev/null 2>&1; then
    echo "ok   rendered config validates (envoy --mode validate)"
  else echo "FAIL rendered config does not validate"; fails=$((fails+1)); fi
  printf 'w @anthropic web example.org:8443\ninternal-name corp.example\n' > "$work/site"
  "$apply" --render-web "$work/site" | sed 's#path: /var/log/airlock-envoy/web.jsonl#path: /dev/null#' > "$work/validate-web.yaml"
  "$apply" --render "$work/site" | sed 's#path: /var/log/airlock-envoy/access.jsonl#path: /dev/null#' > "$work/validate.yaml"
  if "$envoy" --mode validate -c "$work/validate-web.yaml" >/dev/null 2>&1 && "$envoy" --mode validate -c "$work/validate.yaml" >/dev/null 2>&1; then
    echo "ok   rendered web configs validate (both Envoys)"
  else echo "FAIL rendered web configs do not validate"; fails=$((fails+1)); fi
else
  echo "skip rendered config validation: no envoy on PATH"
fi
echo "failures: $fails"
exit "$fails"
