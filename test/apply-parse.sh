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
  'a web\ninternal-net ::/0\ninternal-net fd00:10::/32\ninternal-net 2001:db8:1:2:3:4:5:6/128\ninternal-net ::ffff:0:0/96\ninternal-net 1::/16\ninternal-net 0.0.0.0/0' \
  'a web\ninternal-net ::/0 fd00:10::/32 2001:db8:1:2:3:4:5:6/128 ::ffff:0:0/96 1::/16 0.0.0.0/0\n'

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
printf 'x @anthropic metrics.example.net:443 logs.example.net:443 10.0.0.10:6443\ny example.org:8443 x-y.example.com:443\n' > "$work/site"
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
