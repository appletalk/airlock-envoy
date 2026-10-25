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

lists "comments, blanks, tabs, no final newline" 'a example.com:443\na 10.0.0.1:6443\na client t' \
  'client a t\n# a comment\n\n a\texample.com:443   # trailing\na 10.0.0.1:6443'
lists "include expands, duplicates collapse" \
  "$A\na example.com:443\nb example.com:443\nb example.org:443\nc api.anthropic.com:443\nc platform.claude.com:443\nc example.com:443\nc example.org:443\nc client t" \
  'a @anthropic example.com:443 example.com:443\nb example.com:443 example.org:443\nc @a @b\nclient c t\n'
lists "highest port, IPv4 edges"       'a example.com:65535\na 1.0.0.0:1\na 223.255.255.255:443\na client t' \
  'a example.com:65535 1.0.0.0:1 223.255.255.255:443\nclient a t\n'
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
  'a web\nb example.com:443\nb web\nb client t' 'a web\nb @a example.com:443\nclient b t\n'
lists "internal lines are listed while some listener has web" \
  'a web\na client t\ninternal-name corp.example\ninternal-name lab.example.net\ninternal-net 198.51.100.0/24\ninternal-net 2001:db8:1::/48' \
  'internal-name corp.example lab.example.net corp.example\ninternal-net 198.51.100.0/24 2001:db8:1::/48\na web\nclient a t\n'
lists "internal lines without any web listener change nothing" 'a example.com:443\na client t' \
  'internal-name corp.example\ninternal-net 10.0.0.0/8\na example.com:443\nclient a t\n'
lists "IPv6 CIDR forms" \
  'a web\na client t\ninternal-net ::/0\ninternal-net fd00:99::/32\ninternal-net 2001:db8:1:2:3:4:5:6/128\ninternal-net ::ffff:0:0/96\ninternal-net 1::/16\ninternal-net 0.0.0.0/0' \
  'a web\nclient a t\ninternal-net ::/0 fd00:99::/32 2001:db8:1:2:3:4:5:6/128 ::ffff:0:0/96 1::/16 0.0.0.0/0\n'

# Plain HTTP: the http lines, http:// destinations, one mode per host.
refuses "http without rules"           "want: http"            'http x.example\n'
refuses "http, unknown rules"          "unknown rules"         'http x.example rules nope\n'
refuses "http, unknown option"         "unknown http option"   'http x.example rules any header x\n'
refuses "http, bad credential name"    "bad credential name"   'http x.example rules any credential 1x\n'
refuses "http, uppercase credential"   "only lowercase"        'http x.example rules any credential Gh\n'
refuses "http host a loopback address" "bad http host"         'http 127.0.0.1:6443 rules kubernetes-read\n'
refuses "http host a link-local address" "bad http host"       'http 169.254.169.254 rules any\n'
refuses "http host an IPv4 octet over 255" "bad http host"     'http 10.0.0.256:6443 rules any\n'
refuses "http, bad ca name"            "bad ca name"           'http x.example rules any ca 1x\n'
refuses "http, ca without a name"      "ca needs a name"       'http x.example rules any ca\n'
refuses "an address both by plain HTTP and CONNECT" "lists 10.0.0.1 both" \
  'http 10.0.0.1:6443 rules kubernetes-read\na http://10.0.0.1 10.0.0.1:6443\nclient a t\n'
refuses "http host with a path"        "only lowercase"        'http x.example/p rules any\n'
refuses "http defined twice"           "defined twice"         'http x.example rules any\nhttp x.example rules git\n'
refuses "http:// with no http line"    "has no 'http x.example"  'a http://x.example\n'
refuses "http:// before its http line" "has no 'http x.example"  'a http://x.example\nhttp x.example rules any\n'
refuses "a host as http:// and CONNECT" "use one"              'http x.example rules any\na x.example:443 http://x.example\n'
refuses "...also through an include"   "use one"               'http x.example rules any\na http://x.example\nb @a x.example:8443\n'
lists "http destinations, through an include" \
  'a http://x.example:443 rules git credential gh\nb http://x.example:443 rules git credential gh\nb http://y.example:8443 rules any\nb client t' \
  'http x.example rules git credential gh\nhttp y.example:8443 rules any\na http://x.example\nb @a http://y.example\nclient b t\n'

# Variants: another definition of a host (its own rules, credential, projects), one per listener.
refuses "variant: bad name"            "bad variant"           'http x.example@1v rules any\n'
refuses "variant: empty"               "bad variant"           'http x.example@ rules any\n'
refuses "variant: defined twice"       "defined twice"         'http x.example@v rules any\nhttp x.example@v rules git\n'
refuses "variant: not defined"         "has no 'http x.example@w" 'http x.example@v rules any\na http://x.example@w\n'
refuses "two definitions of a host in one listener" "lists x.example twice" 'http x.example rules any\nhttp x.example@v rules git\na http://x.example http://x.example@v\n'
refuses "...also through an include"   "lists x.example twice" 'http x.example rules any\nhttp x.example@v rules git\na http://x.example\nb @a http://x.example@v\n'
refuses "a variant and CONNECT to its host" "use one"          'http x.example@v rules any\na x.example:443 http://x.example@v\n'
lists "variants: each listener its own definition of the host" \
  'a http://x.example:443 rules github-api credential c1\na client t\nb http://x.example:443 variant board rules github-issues credential c2 projects PVT_kwDOAB12cd,PVT_x-Y_9\nb client u' \
  'http x.example rules github-api credential c1\nhttp x.example@board rules github-issues credential c2 projects PVT_kwDOAB12cd,PVT_x-Y_9\na http://x.example\nb http://x.example@board\nclient a t\nclient b u\n'
# projects: Projects v2 node IDs, on the GitHub presets only; mixed case only there.
refuses "projects: not a PVT_ ID"      "bad project ID"        'http x.example rules github-api projects PR_kw12\n'
refuses "projects: a quote"            "bad project ID"        'http x.example rules github-api projects PVT_a"b\n'
refuses "projects: an empty ID"        "bad project ID"        'http x.example rules github-api projects PVT_\n'
refuses "projects: with other rules"   "projects only with"    'http x.example rules any projects PVT_abc\n'
refuses "projects: none given"         "projects needs"        'http x.example rules github-api projects\n'
refuses "projects: a glob is not expanded" "bad project ID '*'"  'http x.example rules github-api projects *\n'
refuses "projects: a trailing comma"   "bad project ID ''"     'http x.example rules github-api projects PVT_a,\n'
refuses "projects: a double comma"     "bad project ID ''"     'http x.example rules github-api projects PVT_a,,PVT_b\n'
refuses "mixed case elsewhere on an http line" "only lowercase" 'http X.example rules github-api projects PVT_abc\n'
refuses "mixed case on a listener line" "only lowercase"       'a PVT_abc.example:443\n'
# repos: <owner>/<repo> or <owner>/*, on the git, forgejo and GitHub presets; kept lowercase.
refuses "repos: with other rules"      "repos only with"       'http x.example rules any repos a/b\n'
refuses "repos: with kubernetes-read"  "repos only with"       'http x.example rules kubernetes-read repos a/b\n'
refuses "repos: and projects on one line" "can't be on one line" 'http x.example rules github-api projects PVT_a repos a/b\n'
refuses "repos: none given"            "repos needs"           'http x.example rules git repos\n'
refuses "repos: given twice"           "repos given twice"     'http x.example rules git repos a/b repos a/c\n'
refuses "repos: no slash"              "bad repo 'acme'"       'http x.example rules git repos acme\n'
refuses "repos: a wildcard owner"      "bad repo '*/r'"        'http x.example rules git repos */r\n'
refuses "repos: just a wildcard"       "bad repo '*'"          'http x.example rules git repos *\n'
refuses "repos: an empty repo"         "bad repo 'acme/'"      'http x.example rules git repos acme/\n'
refuses "repos: a deeper path"         "bad repo 'acme/r/x'"   'http x.example rules git repos acme/r/x\n'
refuses "repos: a partial glob"        "bad repo 'acme/r*'"    'http x.example rules git repos acme/r*\n'
refuses "repos: a dot segment"         "bad repo 'acme/..'"    'http x.example rules git repos acme/..\n'
refuses "repos: a single dot"          "bad repo 'acme/.'"     'http x.example rules git repos acme/.\n'
refuses "repos: a .git name"           "bad repo 'acme/r.GIT'" 'http x.example rules git repos acme/r.GIT\n'
refuses "repos: a wiki"                "bad repo 'acme/r.wiki'" 'http x.example rules git repos acme/r.wiki\n'
refuses "repos: an owner starting with -" "bad repo '-acme/r'" 'http x.example rules git repos -acme/r\n'
refuses "repos: an escape"             "bad repo 'acme/r%2e'"  'http x.example rules git repos acme/r%2e\n'
refuses "repos: a quote"               "bad repo 'acme/r\"'"   'http x.example rules git repos acme/r"\n'
refuses "repos: a trailing comma"      "bad repo ''"           'http x.example rules git repos a/b,\n'
refuses "repos: a double comma"        "bad repo ''"           'http x.example rules git repos a/b,,a/c\n'
refuses "repos: mixed case elsewhere on the line" "only lowercase" 'http X.example rules git repos a/b\n'
lists "repos: lowercased, deduplicated, <owner>/* kept" \
  'b http://x.example:443 rules git-read repos acme/*,octo-cat/hello.world\nb client t' \
  'http x.example rules git-read repos ACME/*,Octo-Cat/Hello.World,octo-cat/hello.world\nb http://x.example\nclient b t\n'
# What repos lets through, against the rendered regexes (letters as [aA]: RE2 and bash agree).
printf 'http api.example.com rules github-api credential c1 repos Octo-Cat/Hello.World,acme/*\nhttp git.example.com rules git credential c2 repos octo-cat/hello.world\nhttp fj.example.com rules forgejo credential c3 repos me/r\nb http://api.example.com http://git.example.com http://fj.example.com\nclient b t\n' > "$work/site"
r="$("$apply" --render "$work/site")"
rrx() { grep -A3 "name: \"$1\"" <<< "$r" | sed -n 's/.*regex: "\(.*\)" }$/\1/p' | head -1 | sed 's/\\\\/\\/g'; }
order="$(grep -o 'name: "api.example.com-[a-z-]*"' <<< "$r" | sed 's/^name: "api.example.com-//; s/"$//' | tr '\n' ' ')"
rfail=""
for p in /repos/octo-cat/hello.world /repos/Octo-Cat/HELLO.World/pulls/1 /repos/octo-cat/hello.world/issues/2/comments \
         /repos/acme/anything /repos/ACME/x.y-z_1/actions/runs; do
  [[ "$p" =~ ^($(rrx api.example.com-read))$ ]] || rfail+=" not-read:$p"
done
for p in /repos/octo-cat/hello.worlds /repos/octo-cat/helloXworld /repos/octo-cat/hello.world-x/pulls /repos/other/hello.world \
         /repos/acme /repos/acmex/r /repos/acme/r%2fx /repos/acme/r%2e%2e /repositories/1 /search/issues /users/x/repos /orgs/acme/repos \
         /user/repos /gists /graphql; do
  [[ "$p" =~ ^($(rrx api.example.com-read))$ ]] && rfail+=" read:$p"
done
for p in /repos/acme/r/%2e%2e/%2e%2e/other/x /repos/acme/r/%2E%2E /repos/acme/r/contents/a%2ex; do
  [[ "$p" =~ ^($(rrx api.example.com-escaped-dot))$ ]] || rfail+=" escaped-dot-through:$p"
done
[[ /repos/acme/r/contents/a%20b =~ ^($(rrx api.example.com-escaped-dot))$ ]] && rfail+=" escaped-space-refused"
[[ /repos/acme/r/pulls =~ ^($(rrx api.example.com-create))$ ]] || rfail+=" create"
[[ /repos/other/r/pulls =~ ^($(rrx api.example.com-create))$ ]] && rfail+=" create-other"
[[ /repos/other/r/issues/1/comments =~ ^($(rrx api.example.com-issue-sub))$ ]] && rfail+=" comment-other"
[[ /repos/other/r/issues/comments/1 =~ ^($(rrx api.example.com-edit-comment))$ ]] && rfail+=" edit-comment-other"
for p in /octo-cat/hello.world/info/refs /Octo-Cat/Hello.World.git/info/refs; do
  [[ "$p" =~ ^($(rrx git.example.com-info-refs))$ ]] || rfail+=" not-git:$p"
done
for p in /octo-cat/hello.world.wiki.git/info/refs /octo-cat/other/info/refs /octo-cat/hello.world.git.git/info/refs /x/octo-cat/hello.world/info/refs; do
  [[ "$p" =~ ^($(rrx git.example.com-info-refs))$ ]] && rfail+=" git:$p"
done
[[ /octo-cat/other/git-receive-pack =~ ^($(rrx git.example.com-pack))$ ]] && rfail+=" push-other"
[[ /api/v1/repos/me/r/pulls/1 =~ ^($(rrx fj.example.com-read))$ ]] || rfail+=" fj-read"
for p in /api/v1/repos/search /api/v1/repos/me/rr /api/v1/users/me/repos /api/v1/orgs/me/repos /api/v1/repos/issues/search /api/v1/admin/users; do
  [[ "$p" =~ ^($(rrx fj.example.com-read))$ ]] && rfail+=" fj-read:$p"
done
if [ -z "$rfail" ] && [ "$order" = "escaped-dot graphql-other read user rate-limit create issue-sub edit edit-comment reviewers refused " ] \
   && ! grep -q 'github-graphql: { rules' <<< "$r" \
   && grep -A2 'name: "api.example.com-graphql-other"' <<< "$r" | grep -qF 'regex: "(?i)/graphql.*"' \
   && grep -A2 'name: "fj.example.com-wiki"' <<< "$r" | grep -qF 'regex: "/[^/]+/[^/]+\\.wiki(\\.git)?/.*"' \
   && [ "$(grep -o 'name: "fj.example.com-[a-z-]*"' <<< "$r" | head -5 | tr '\n' ' ')" = 'name: "fj.example.com-query-token" name: "fj.example.com-query-access-token" name: "fj.example.com-query-sudo" name: "fj.example.com-form-body" name: "fj.example.com-escaped-dot" ' ]; then
  echo "ok   repos: reads and writes only in the listed repos (any case, dots literal, .git optional for git, no escapes), only /user and /rate_limit outside them, GraphQL refused, deny routes kept first"
else echo "FAIL repos rendering (route order: $order):$rfail"; fails=$((fails+1)); fi
# Without repos, nothing changes: the presets' own routes.
printf 'http api.example.com rules github-api credential c1\nb http://api.example.com\nclient b t\n' > "$work/site"
r="$("$apply" --render "$work/site")"
if grep -q 'name: "api.example.com-graphql"' <<< "$r" && grep -A2 'name: "api.example.com-read"' <<< "$r" | grep -q 'prefix: "/"'; then
  echo "ok   no repos: GraphQL checked, reads anywhere (as before)"
else echo "FAIL no repos: the preset changed"; fails=$((fails+1)); fi

printf 'http x.example@board rules github-issues credential c2 projects PVT_aB,PVT_cD\nb http://x.example@board\nclient b t\n' > "$work/site"
r="$("$apply" --render "$work/site")"
if grep -q 'name: "http-x.example_board"' <<< "$r" && grep -q 'host_rewrite_literal: "x.example"' <<< "$r" && grep -q 'domains: \["x.example", "x.example:80"\]' <<< "$r" \
   && grep -q 'sni: "x.example"' <<< "$r" && grep -q 'filter_metadata: { github-graphql: { rules: "github-issues", projects: "PVT_aB PVT_cD" } }' <<< "$r" \
   && [ "$("$apply" --clients b "$work/site" | grep -v '^#')" = "x.example 443 github-issues yes" ]; then
  echo "ok   a variant renders to its host (Host, SNI, SAN, domains), its own cluster, its projects; the manifest names the host"
else echo "FAIL variant rendering"; fails=$((fails+1)); fi
if grep -q 'tls_params: { tls_minimum_protocol_version: TLSv1_2, tls_maximum_protocol_version: TLSv1_3 }' <<< "$r"; then
  echo "ok   upstream TLS offers 1.3 (Envoy's client default stops at 1.2; a 1.3-only host refused every handshake)"
else echo "FAIL upstream TLS does not offer 1.3"; fails=$((fails+1)); fi

# forgejo: git routes have no request timeout or stream cap (long), the API routes do.
printf 'http g.example.com rules forgejo credential fj\nb http://g.example.com\nclient b t\n' > "$work/site"
r="$("$apply" --render "$work/site")"
if grep -A4 'name: "g.example.com-pack"' <<< "$r" | grep -q 'timeout: 0s, idle_timeout: 300s }' \
   && grep -A4 'name: "g.example.com-read"' <<< "$r" | grep -q 'timeout: 120s, idle_timeout: 300s, max_stream_duration' \
   && grep -q '"inject-fj"' <<< "$r" && ! grep -q 'github-graphql' <<< "$r"; then
  echo "ok   forgejo: git routes long, API routes capped, credential injected, no GraphQL check"
else echo "FAIL forgejo rendering"; fails=$((fails+1)); fi

# kubernetes-read on an address: exec, attach, port-forward and proxy refused before the reads,
# upgrades refused first; the address as SAN (no SNI), a static upstream, the ca file alone.
printf 'http 10.0.0.1:6443 rules kubernetes-read credential kube ca k3s\nhttp x.example rules git\nb http://10.0.0.1 http://x.example\nclient b t\n' > "$work/site"
r="$("$apply" --render "$work/site")"
c="$(sed -n '/^  - name: "http-10.0.0.1"$/,/^  - name: /p' <<< "$r")"
order="$(grep -o 'name: "10.0.0.1-[a-z-]*"' <<< "$r" | sed 's/^name: "10.0.0.1-//; s/"$//' | tr '\n' ' ')"
if [ "$order" = "upgrade escaped pod-stream node-proxy legacy-proxy access-review whoami read version refused " ] \
   && grep -A4 'name: "10.0.0.1-read"' <<< "$r" | grep -q 'timeout: 0s, idle_timeout: 300s }' \
   && grep -A4 'name: "10.0.0.1-version"' <<< "$r" | grep -q 'timeout: 120s, idle_timeout: 300s, max_stream_duration' \
   && grep -q 'type: STATIC' <<< "$c" && ! grep -q 'sni:' <<< "$c" && ! grep -q 'dns_lookup_family' <<< "$c" \
   && grep -q 'trusted_ca: { filename: /etc/airlock-envoy/ca/k3s.pem }' <<< "$c" \
   && grep -q 'san_type: IP_ADDRESS, matcher: { exact: "10.0.0.1" }' <<< "$c" \
   && grep -A40 'name: "http-x.example"' <<< "$r" | grep -q 'trusted_ca: { filename: /etc/ssl/certs/ca-certificates.crt }' \
   && grep -A40 'name: "http-x.example"' <<< "$r" | grep -q 'sni: "x.example"' \
   && grep -q 'domains: \["10.0.0.1", "10.0.0.1:80"\]' <<< "$r" && grep -q 'name: "deny-connect-http-10.0.0.1"' <<< "$r" \
   && grep -q 'key_matcher: { prefix: "impersonate-", ignore_case: true }' <<< "$r" \
   && [ "$("$apply" --clients b "$work/site" | grep -v '^#' | head -1)" = "10.0.0.1 6443 kubernetes-read yes" ]; then
  echo "ok   kubernetes-read on an address: upgrades, escapes, exec/attach/port-forward/proxy refused before reads (long: watch, logs -f); IP SAN, no SNI, own ca; impersonation stripped"
else echo "FAIL kubernetes-read rendering (route order: $order)"; fails=$((fails+1)); fi
# What the kubernetes-read paths let through, against the rendered regexes (RE2 and ERE agree
# on these): reads and the two reviews yes, the streaming and proxy subresources no.
krx() { grep -A3 "name: \"10.0.0.1-$1\"" <<< "$r" | sed -n 's/.*regex: "\(.*\)" }$/\1/p' | head -1 | sed 's/\\\\/\\/g'; }
deny="$(krx escaped)|$(krx pod-stream)|$(krx node-proxy)|$(krx legacy-proxy)"
kfail=""
for p in /api/v1/namespaces/a/pods/b/exec /api/v1/namespaces/a/pods/b/attach /api/v1/namespaces/a/pods/b/portforward \
         /api/v1/namespaces/a/pods/b/proxy/x /api/v1/namespaces/a/services/b:80/proxy/ /api/v1/nodes/n1/proxy/metrics /api/v1/proxy/namespaces/a \
         /api/v1/namespaces/a/pods/b/%70roxy/ /api/v1/namespaces/a/pods/b/%65xec /api/v1/nodes/n/%70roxy /api/%2e%2e/x; do
  [[ "$p" =~ ^($deny)$ ]] || kfail+=" not-denied:$p"
done
for p in /api/v1/namespaces/a/pods/b/log /api/v1/namespaces/a/pods /apis/apps/v1/deployments /api/v1/namespaces/proxy/configmaps/exec /openapi/v3; do
  [[ "$p" =~ ^($deny)$ ]] && kfail+=" denied:$p"
  [[ "$p" =~ ^($(krx read))$ ]] || kfail+=" not-read:$p"
done
[[ /apis/authorization.k8s.io/v1/selfsubjectaccessreviews =~ ^($(krx access-review))$ ]] || kfail+=" review"
[[ /apis/authorizationxk8s.io/v1/selfsubjectaccessreviews =~ ^($(krx access-review))$ ]] && kfail+=" review-dot"
[[ /apis/authorization.k8s.io/v1/subjectaccessreviews =~ ^($(krx access-review))$ ]] && kfail+=" sar"
[[ /healthz =~ ^($(krx read))$ ]] && kfail+=" healthz"
if [ -z "$kfail" ]; then echo "ok   kubernetes-read paths: streams, proxies and escaped forms refused, reads and self reviews through, dots literal"
else echo "FAIL kubernetes-read paths:$kfail"; fails=$((fails+1)); fi

lists "kubernetes-read on an address, its ca listed" 'b http://10.0.0.1:6443 rules kubernetes-read credential kube ca k3s\nb client t' \
  'http 10.0.0.1:6443 rules kubernetes-read credential kube ca k3s\nb http://10.0.0.1\nclient b t\n'

# Client manifests: each listener's plain-HTTP hosts (an include's too), nothing else.
printf 'http x.example rules git credential gh\nhttp y.example:8443 rules any\na http://x.example example.com:443\nb @a http://y.example web\nc example.org:443\nclient b t\nclient c t\n' > "$work/site"
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
printf 'http api.example.com rules github-api credential c1\nhttp g.example.com rules git credential c2\np @anthropic web http://api.example.com http://g.example.com 10.0.0.1:6443\nclient p t\n' > "$work/site"
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
printf 'p @anthropic web\nq web\nr example.org:443\nclient p t\nclient q t\nclient r t\n' > "$work/site"
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
printf 'a web\ninternal-net 198.51.100.0/24 2001:db8:1::/48\nclient a t\n' > "$work/site"
printf 'nameserver 127.0.0.53\nnameserver fe80::1%%eth0\noptions edns0\n' > "$work/resolv"
want='[Service]
IPAddressDeny=198.51.100.0/24
IPAddressDeny=2001:db8:1::/48
IPAddressAllow=127.0.0.53/32
IPAddressAllow=fe80::1/128'
got="$(RESOLV_CONF="$work/resolv" "$apply" --render-web-dropin "$work/site" | grep -v '^#')"
if [ "$got" = "$want" ]; then echo "ok   web drop-in: site networks denied, resolvers allowed exactly"
else echo "FAIL web drop-in, got:"; echo "$got"; fails=$((fails+1)); fi

# Box listeners: idle connections close after 60 s; the other ways to authenticate are
# stripped with the rest (site-checks.sh sends them through a live Envoy).
printf 'http g.example.com rules forgejo credential fj\nb http://g.example.com\nclient b t\n' > "$work/site"
r="$("$apply" --render "$work/site")"
if grep -q 'common_http_protocol_options: { headers_with_underscores_action: REJECT_REQUEST, idle_timeout: 60s }' <<< "$r" \
   && grep -q 'key_matcher: { prefix: "x-webauth", ignore_case: true }' <<< "$r" && grep -q 'key_matcher: { prefix: "x-authentik-", ignore_case: true }' <<< "$r" \
   && grep -q 'key_matcher: { prefix: "x-auth-request-", ignore_case: true }' <<< "$r" \
   && grep -qF 'regex: "(?i)cookie2?|signature(-input)?|proxy-authorization|(x-)?remote-user" }' <<< "$r"; then
  echo "ok   box listeners: 60 s idle timeout; cookies, signatures, proxy and forward-auth identity headers stripped"
else echo "FAIL box listener idle timeout or header strip"; fails=$((fails+1)); fi

# Clients: one user per listener; a listener nothing includes needs one; the built-in has none.
refuses "client: too few words"        "want: client"          'a example.com:443\nclient a\n'
refuses "client: too many words"       "want: client"          'a example.com:443\nclient a t u\n'
refuses "client: uppercase user"       "only lowercase"        'a example.com:443\nclient a Bob\n'
refuses "client: user starting with a digit" "bad user name"   'a example.com:443\nclient a 1bob\n'
refuses "client: machine account (\$)" "only lowercase"        'a example.com:443\nclient a host$\n'
refuses "client: user over 32"         "bad user name"         'a example.com:443\nclient a abcdefghijabcdefghijabcdefghijabc\n'
refuses "client: bad listener name"    "bad listener name"     'client a.b t\n'
refuses "client: two for one listener" "already has a client (t, at" 'a example.com:443\nclient a t\nclient a u\n'
refuses "...even the same user twice"  "already has a client"  'a example.com:443\nclient a t\nclient a t\n'
refuses "client: for the built-in"     "built in and has no socket" 'client anthropic t\n'
refuses "client: for no listener"      "not a listener in this file" 'a example.com:443\nclient a t\nclient b t\n'
refuses "a listener nothing includes, without a client" "listener b has no client" 'a example.com:443\nclient a t\nb example.org:443\n'
refuses "a credential reachable by two users" "credential gh is reachable by t (listener a) and by u (listener b)" \
  'http x.example rules git credential gh\na http://x.example\nb http://x.example\nclient a t\nclient b u\n'
refuses "...also through an include"   "credential gh is reachable by" \
  'http x.example rules git credential gh\nbase http://x.example\na @base\nb @base\nclient a t\nclient b u\n'
lists "client before its listener; underscore and dot in a user name" 'a example.com:443\na client svc_x.y-1' \
  'client a svc_x.y-1\na example.com:443\n'
lists "an included listener without a client is a definition only (no client line)" \
  'base example.com:443\na example.com:443\na example.org:443\na client t' 'base example.com:443\na @base example.org:443\nclient a t\n'
lists "a credential shared by one user's listeners, and by another's through a variant" \
  'a http://x.example:443 rules git credential gh\na client t\nb http://x.example:443 rules git credential gh\nb client t\nc http://x.example:443 variant u rules git credential gh-u\nc client u' \
  'http x.example rules git credential gh\nhttp x.example@u rules git credential gh-u\na http://x.example\nb http://x.example\nc http://x.example@u\nclient a t\nclient b t\nclient c u\n'
printf 'http x.example rules git\nbase @anthropic web http://x.example 10.0.0.1:6443\nk-x @base\no-x @base example.org:443\nclient k-x k\nclient o-x o\n' > "$work/site"
r="$("$apply" --render "$work/site")"; w="$("$apply" --render-web "$work/site")"
if ! grep -q 'name: "base"' <<< "$r" && grep -q 'name: "k-x"' <<< "$r" && grep -q 'name: "o-x"' <<< "$r" \
   && [ "$(grep -c 'user: "k"' <<< "$r")" = 1 ] && [ "$(grep -c 'user: "o"' <<< "$r")" = 1 ] \
   && ! grep -q 'web-base' <<< "$r$w" && grep -q 'name: "web-k-x"' <<< "$w" && grep -q 'user: "o"' <<< "$w" \
   && grep -q 'max_active_downstream_connections: 256$' <<< "$r"; then
  echo "ok   render: a socket's listener per client (its user in the log), none for a definition; web per socket only"
else echo "FAIL render with clients"; fails=$((fails+1)); fi
r="$("$apply" --render /dev/null)"
if grep -q '^  listeners: \[\]$' <<< "$r" && grep -q '^  clusters: \[\]$' <<< "$r" && ! grep -q 'name: "anthropic"' <<< "$r"; then
  echo "ok   render: no site file, no sockets: no listeners at all (the built-in anthropic is a definition only)"
else echo "FAIL render with no sockets"; fails=$((fails+1)); fi
# A definition-only listener's own destinations, reached by no socket, get no upstream.
printf 'x example.org:443\nk @x\nclient k t\n' > "$work/site2"
r="$("$apply" --render "$work/site2")"
if grep -q 'upstream-example.org"' <<< "$r" && ! grep -q 'api.anthropic.com' <<< "$r"; then
  echo "ok   render: only destinations some socket reaches get an upstream (not the built-in's, unused here)"
else echo "FAIL render: unused destinations rendered"; fails=$((fails+1)); fi

# Users, at --check (before Envoy is needed): they must exist and be login accounts.
check_refuses() {  # check_refuses <name> <expected message part> <site text>
  printf '%b' "$3" > "$work/site"
  if out="$("$apply" --check "$work/site" 2>&1)"; then echo "FAIL $1: accepted"; fails=$((fails+1))
  elif [[ "$out" == *"$2"* ]]; then echo "ok   $1"
  else echo "FAIL $1: wrong message: $out"; fails=$((fails+1)); fi
}
check_refuses "client root"                "uid 0: only a login account"     'a example.com:443\nclient a root\n'
check_refuses "client nobody"              "uid 65534: only a login account"                       'a example.com:443\nclient a nobody\n'
check_refuses "client a system account"    "only a login account"               "a example.com:443\nclient a $(getent passwd | awk -F: '$3 > 0 && $3 < 1000 { print $1; exit }')\n"
check_refuses "client that does not exist" "client no-such-user-x of a: no such user" 'a example.com:443\nclient a no-such-user-x\n'
me="$(id -un)"; uid="$(id -u)"
if [ "$uid" -ge 1000 ]; then
  printf 'a example.com:443\nclient a %s\n' "$me" > "$work/site"
  acl="$(command -v setfacl)"
  want="[Socket]
ListenStream=/run/airlock-envoy/$me/a.sock
ExecStartPre=/bin/sh -c '[ \"\$\$(getent passwd $me | cut -d: -f3)\" = $uid ]'
ExecStartPre=/usr/bin/install -d -m 0755 -o root -g root /run/airlock-envoy
ExecStartPre=/usr/bin/mkdir -p -m 0700 /run/airlock-envoy/$me
ExecStartPre=$acl --set u::rwx,g::---,o::---,u:$uid:r-x /run/airlock-envoy/$me
ExecStartPost=$acl --set u::rw-,g::---,o::---,u:$uid:rw- /run/airlock-envoy/$me/a.sock
ExecStartPost=-/usr/bin/install -m 0644 -o root -g root /etc/airlock-envoy/clients/a.clients /run/airlock-envoy/$me/a.clients
ExecStopPost=/usr/bin/rm -f /run/airlock-envoy/$me/a.clients"
  got="$("$apply" --render-socket-dropin a "$work/site" | grep -v '^#')"
  if [ "$got" = "$want" ]; then echo "ok   socket drop-in: the uid still the name's at start, the user's directory and the socket, for that uid alone"
  else echo "FAIL socket drop-in, got:"; echo "$got"; fails=$((fails+1)); fi
  if ! "$apply" --render-socket-dropin anthropic "$work/site" >/dev/null 2>&1; then echo "ok   socket drop-in: none for a listener without a client"
  else echo "FAIL socket drop-in for the built-in"; fails=$((fails+1)); fi
else echo "skip socket drop-in: run as a login account (uid 1000 and up)"; fi

# A file shaped like a real site renders to a config Envoy accepts.
printf 'http api.example.com rules github-api\nhttp issues.example.com rules github-issues\nhttp g.example.com rules git\nx @anthropic metrics.example.net:443 logs.example.net:443 10.0.0.10:6443 http://api.example.com\ny example.org:8443 x-y.example.com:443 http://issues.example.com http://g.example.com\nclient x t\nclient y u\n' > "$work/site"
"$apply" --render "$work/site" > "$work/envoy.yaml"
if envoy="$(command -v envoy)"; then
  # Envoy picks the format by extension, and validate mode opens the access log.
  sed 's#path: /var/log/airlock-envoy/access.jsonl#path: /dev/null#' "$work/envoy.yaml" > "$work/validate.yaml"
  if "$envoy" --mode validate -c "$work/validate.yaml" >/dev/null 2>&1; then
    echo "ok   rendered config validates (envoy --mode validate)"
  else echo "FAIL rendered config does not validate"; fails=$((fails+1)); fi
  printf 'w @anthropic web example.org:8443\ninternal-name corp.example\nclient w t\n' > "$work/site"
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
