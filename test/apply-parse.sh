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

# A file shaped like a real site renders to a config Envoy accepts.
printf 'x @anthropic metrics.example.net:443 logs.example.net:443 10.0.0.10:6443\ny example.org:8443 x-y.example.com:443\n' > "$work/site"
"$apply" --render "$work/site" > "$work/envoy.yaml"
if envoy="$(command -v envoy)"; then
  # Envoy picks the format by extension, and validate mode opens the access log.
  sed 's#path: /var/log/airlock-envoy/access.jsonl#path: /dev/null#' "$work/envoy.yaml" > "$work/validate.yaml"
  if "$envoy" --mode validate -c "$work/validate.yaml" >/dev/null 2>&1; then
    echo "ok   rendered config validates (envoy --mode validate)"
  else echo "FAIL rendered config does not validate"; fails=$((fails+1)); fi
else
  echo "skip rendered config validation: no envoy on PATH"
fi
echo "failures: $fails"
exit "$fails"
