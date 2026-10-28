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
refuses "repos: an owner over 40"      "bad repo"              "http x.example rules git repos $(printf 'o%.0s' $(seq 41))/r\\n"
refuses "repos: a repo over 100"       "bad repo"              "http x.example rules git repos o/$(printf 'r%.0s' $(seq 101))\\n"
refuses "repos: over 64"               "over 64 repos"         "http x.example rules git repos $(for i in $(seq 65); do printf 'o/r%s,' "$i"; done | sed 's/,$//')\\n"
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
# A route's regex; for a scoped route (one per repo: <name>-1, -2, ...), all of them joined.
rrx() { grep -A3 -E "name: \"$1(-[0-9]+)?\"" <<< "$r" | sed -n 's/.*regex: "\(.*\)" }$/\1/p' | sed 's/\\\\/\\/g' | paste -sd '|'; }
order="$(grep -o 'name: "api.example.com-[a-z0-9-]*"' <<< "$r" | sed 's/^name: "api.example.com-//; s/"$//' | tr '\n' ' ')"
rfail=""
for p in /repos/octo-cat/hello.world /repos/Octo-Cat/HELLO.World/pulls/1 /repos/octo-cat/hello.world/issues/2/comments \
         /repos/acme/anything /repos/ACME/x.y-z_1/actions/runs; do
  [[ "$p" =~ ^($(rrx api.example.com-read))$ ]] || rfail+=" not-read:$p"
done
for p in /repos/octo-cat/hello.worlds /repos/octo-cat/helloXworld /repos/octo-cat/hello.worldXgit /repos/octo-cat/hello.world-x/pulls /repos/other/hello.world \
         /repos/acme /repos/acmex/r /repos/acme/r%2fx /repos/acme/r%2e%2e /repositories/1 /search/issues /users/x/repos /orgs/acme/repos \
         /user/repos /gists /graphql; do
  [[ "$p" =~ ^($(rrx api.example.com-read))$ ]] && rfail+=" read:$p"
done
for p in /repos/acme/r/%2e%2e/%2e%2e/other/x /repos/acme/r/%2E%2E /repos/acme/r/contents/a%2ex; do
  [[ "$p" =~ ^($(rrx api.example.com-escaped-unreserved))$ ]] || rfail+=" escaped-unreserved-through:$p"
done
[[ /repos/acme/r/contents/a%20b =~ ^($(rrx api.example.com-escaped-unreserved))$ ]] && rfail+=" escaped-space-refused"
for p in /repos/acme/r/c%6fmpare/a...b:c /repos/acme/r/c%6Fmpare /repos/acme/r/%4A /repos/acme/r/%41 /repos/acme/r/x%5Fy /repos/acme/r/x%7e /repos/acme/r/x%2D /repos/acme/r/x%39 /repos/acme/r/x%7A; do
  [[ "$p" =~ ^($(rrx api.example.com-escaped-unreserved))$ ]] || rfail+=" escaped-unreserved-through:$p"
done
for p in /repos/acme/r/contents/a%2Bb /repos/acme/r/contents/%C3%A9 /repos/acme/r/contents/a%40b /repos/acme/r/contents/a%3Fb; do
  [[ "$p" =~ ^($(rrx api.example.com-escaped-unreserved))$ ]] && rfail+=" escaped-reserved-refused:$p"
done
[[ /repos/acme/r/COMPARE/main...other:main =~ ^($(rrx api.example.com-compare-across))$ ]] || rfail+=" compare-upper-through"
for p in /repos/acme/r/compare/main...other:main /repos/acme/r/compare/main...other:r:main /repos/acme/r/compare/main...other%3Amain; do
  [[ "$p" =~ ^($(rrx api.example.com-compare-across))$ ]] || rfail+=" compare-across-through:$p"
done
[[ /repos/acme/r/compare/main...dev =~ ^($(rrx api.example.com-compare-across))$ ]] && rfail+=" compare-same-repo-refused"
[[ /api/v1/repos/me/r/compare/main...other:main =~ ^($(rrx fj.example.com-compare-across))$ ]] || rfail+=" fj-compare-across-through"
[[ /repos/acme/r/pulls =~ ^($(rrx api.example.com-create))$ ]] || rfail+=" create"
[[ /repos/other/r/pulls =~ ^($(rrx api.example.com-create))$ ]] && rfail+=" create-other"
[[ /repos/other/r/issues/1/comments =~ ^($(rrx api.example.com-issue-sub))$ ]] && rfail+=" comment-other"
[[ /repos/other/r/issues/comments/1 =~ ^($(rrx api.example.com-edit-comment))$ ]] && rfail+=" edit-comment-other"
for p in /octo-cat/hello.world/info/refs /Octo-Cat/Hello.World.git/info/refs; do
  [[ "$p" =~ ^($(rrx git.example.com-info-refs))$ ]] || rfail+=" not-git:$p"
done
for p in /octo-cat/hello.world.wiki.git/info/refs /octo-cat/hello.worldXgit/info/refs /octo-cat/other/info/refs /octo-cat/hello.world.git.git/info/refs /x/octo-cat/hello.world/info/refs; do
  [[ "$p" =~ ^($(rrx git.example.com-info-refs))$ ]] && rfail+=" git:$p"
done
[[ /octo-cat/other/git-receive-pack =~ ^($(rrx git.example.com-pack))$ ]] && rfail+=" push-other"
[[ /api/v1/repos/me/r/pulls/1 =~ ^($(rrx fj.example.com-read))$ ]] || rfail+=" fj-read"
for p in /api/v1/repos/search /api/v1/repos/me/rr /api/v1/users/me/repos /api/v1/orgs/me/repos /api/v1/repos/issues/search /api/v1/admin/users; do
  [[ "$p" =~ ^($(rrx fj.example.com-read))$ ]] && rfail+=" fj-read:$p"
done
if [ -z "$rfail" ] && [ "$order" = "escaped-unreserved compare-across graphql-other user rate-limit read-1 read-2 create-1 create-2 issue-sub-1 issue-sub-2 edit-1 edit-2 edit-comment-1 edit-comment-2 reviewers-1 reviewers-2 refused " ] \
   && ! grep -q 'github-graphql: { rules' <<< "$r" && grep -q '^layered_runtime:' <<< "$r" \
   && grep -q 're2: { max_program_size: { error_level: 1000, warn_level: 1000 } }' <<< "$r" \
   && grep -A2 'name: "api.example.com-graphql-other"' <<< "$r" | grep -qF 'regex: "(?i)/graphql.*"' \
   && grep -A2 'name: "fj.example.com-wiki"' <<< "$r" | grep -qF 'regex: "/[^/]+/[^/]+\\.wiki(\\.git)?/.*"' \
   && [ "$(grep -o 'name: "fj.example.com-[a-z-]*"' <<< "$r" | head -5 | tr '\n' ' ')" = 'name: "fj.example.com-query-token" name: "fj.example.com-query-access-token" name: "fj.example.com-query-sudo" name: "fj.example.com-form-body" name: "fj.example.com-escaped-unreserved" ' ]; then
  echo "ok   repos: reads and writes only in the listed repos (any case, dots literal, .git optional for git, no escapes), only /user and /rate_limit outside them, GraphQL refused, deny routes kept first"
else echo "FAIL repos rendering (route order: $order):$rfail"; fails=$((fails+1)); fi
# Outside a repo only exact paths (a prefix /user would take /user/repos), and the two refusals
# first take every method.
xfail=""
for rt in api.example.com-user:/user api.example.com-rate-limit:/rate_limit fj.example.com-user:/api/v1/user fj.example.com-version:/api/v1/version; do
  grep -A2 "name: \"${rt%%:*}\"" <<< "$r" | grep -qx "                  path: \"${rt#*:}\"" || xfail+=" ${rt%%:*}"
done
for rt in api.example.com-escaped-unreserved api.example.com-compare-across fj.example.com-escaped-unreserved fj.example.com-compare-across; do
  grep -A3 "name: \"$rt\"" <<< "$r" | grep -q ':method' && xfail+=" $rt-method"
  grep -A3 "name: \"$rt\"" <<< "$r" | grep -q 'direct_response: { status: 403' || xfail+=" $rt-not-403"
done
if [ -z "$xfail" ]; then echo "ok   repos: /user, /rate_limit, /api/v1/user, /api/v1/version exact; the escape and compare refusals take every method"
else echo "FAIL repos: outside-repo routes or refusals:$xfail"; fails=$((fails+1)); fi
# Scoped forgejo git routes keep the preset's long flag (no request timeout or stream cap: a
# large clone or push), the rendered config is valid YAML, and every letter folds (z too).
if grep -A4 'name: "fj.example.com-info-refs-1"' <<< "$r" | grep -q 'timeout: 0s, idle_timeout: 300s }' \
   && grep -A4 'name: "fj.example.com-pack-1"' <<< "$r" | grep -q 'timeout: 0s, idle_timeout: 300s }' \
   && grep -A4 'name: "fj.example.com-read-1"' <<< "$r" | grep -q 'timeout: 120s'; then
  echo "ok   repos: scoped git routes stay long, API routes capped"
else echo "FAIL repos: scoped git routes lost the long flag"; fails=$((fails+1)); fi
if ! python3 -c 'import yaml' 2>/dev/null; then echo "skip repos: rendered YAML parse (no PyYAML)"
elif python3 -I -c 'import sys, yaml; yaml.safe_load(sys.stdin)' <<< "$r" 2>/dev/null; then echo "ok   repos: the rendered config parses as YAML"
else echo "FAIL repos: the rendered config is not valid YAML"; fails=$((fails+1)); fi
printf 'http z.example.com rules git repos Zeta/Fuzz\nb http://z.example.com\nclient b t\n' > "$work/site"
r="$("$apply" --render "$work/site")"
if [[ /ZETA/FUZZ.git/info/refs =~ ^($(rrx z.example.com-info-refs))$ ]] && [[ /zeta/fuzz/info/refs =~ ^($(rrx z.example.com-info-refs))$ ]] \
   && ! [[ /zeta/fuzy/info/refs =~ ^($(rrx z.example.com-info-refs))$ ]]; then echo "ok   repos: every letter matches in either case"
else echo "FAIL repos: letter case folding"; fails=$((fails+1)); fi

# A preset route with no repo part stops the render and --check (the guard in
# preset_rules_scoped), instead of rendering on without it. A stub Envoy for --check, and a
# control copy without the broken route that passes it.
mkdir -p "$work/guard" "$work/control"; cp install/github-graphql.lua "$work/guard/"; cp install/github-graphql.lua "$work/control/"
printf '#!/bin/sh\nexit 0\n' > "$work/envoy-stub"; chmod +x "$work/envoy-stub"
sed "s|^ENVOY=/usr/local/bin/envoy\$|ENVOY=$work/envoy-stub|" "$apply" > "$work/control/apply"
sed 's|^reviewers POST regex /repos/\[^/\]+/\[^/\]+/pulls/\[0-9\]+/requested_reviewers$|reviewers POST exact /no-repo-part|' "$work/control/apply" > "$work/guard/apply"
chmod +x "$work/control/apply" "$work/guard/apply"
printf 'http api.example.com rules github-api repos a/b\nb http://api.example.com\nclient b %s\n' "$(id -un)" > "$work/site"
if grep -q '^reviewers POST exact /no-repo-part$' "$work/guard/apply" && "$work/control/apply" --check "$work/site" >/dev/null 2>&1 \
   && ! out="$("$work/guard/apply" --render "$work/site" 2>&1 >/dev/null)" && [[ "$out" == *"no repo part"* ]] \
   && ! out="$("$work/guard/apply" --check "$work/site" 2>&1 >/dev/null)" && [[ "$out" == *"no repo part"* ]]; then
  echo "ok   repos: a route with no repo part to scope stops the render and the check (a control copy passes)"
else echo "FAIL repos: the no-repo-part guard did not stop the render or the check"; fails=$((fails+1)); fi

# Several definitions of one host on a listener: each with repos, no repo in two, rules shared
# (the two GitHub presets may mix). One virtual host; each repo's routes carry their own
# definition's credential and upstream; the first one's refusals and /user stand for all.
refuses "two definitions, one without repos" "give both repos" 'http x.example@a rules git repos o/a\nhttp x.example@b rules git\nl http://x.example@a http://x.example@b\n'
refuses "...the first without repos"   "give both repos"       'http x.example@a rules git\nhttp x.example@b rules git repos o/a\nl http://x.example@a http://x.example@b\n'
refuses "two definitions, the same repo" "also in http://x.example@a" 'http x.example@a rules git repos o/a\nhttp x.example@b rules git repos O/A\nl http://x.example@a http://x.example@b\n'
refuses "two definitions, a repo under the other's owner/*" "also in" 'http x.example@a rules git repos o/*\nhttp x.example@b rules git repos p/b,o/b\nl http://x.example@a http://x.example@b\n'
refuses "...and owner/* after a repo of that owner" "also in" 'http x.example@a rules git repos o/b\nhttp x.example@b rules git repos o/*\nl http://x.example@a http://x.example@b\n'
refuses "two definitions, other rules" "share their rules" 'http x.example@a rules git repos o/a\nhttp x.example@b rules github-api repos o/b\nl http://x.example@a http://x.example@b\n'
refuses "...git and git-read"           "share their rules"     'http x.example@a rules git repos o/a\nhttp x.example@b rules git-read repos o/b\nl http://x.example@a http://x.example@b\n'
refuses "...through an include"         "also in"               'http x.example@a rules git repos o/a\nhttp x.example@b rules git repos o/a\nl http://x.example@a\nm @l http://x.example@b\n'
refuses "two definitions, other ports"  "another port, ca"      'http x.example:8443@a rules git repos o/a\nhttp x.example@b rules git repos o/b\nl http://x.example@a http://x.example@b\n'
refuses "two definitions, other cas"    "another port, ca"      'http x.example@a rules git ca c1 repos o/a\nhttp x.example@b rules git ca c2 repos o/b\nl http://x.example@a http://x.example@b\n'
refuses "two definitions, a credential and none" "another port, ca" 'http x.example@a rules git repos o/a\nhttp x.example@b rules git credential c repos o/b\nl http://x.example@a http://x.example@b\n'
lists "two definitions of a host, disjoint repos (the GitHub presets mix)" \
  'l http://x.example:443 variant a rules github-api credential c1 repos o/*\nm http://x.example:443 variant a rules github-api credential c1 repos o/*\nm http://x.example:443 variant b rules github-issues credential c2 repos p/a,o2/b\nm client t' \
  'http x.example@a rules github-api credential c1 repos o/*\nhttp x.example@b rules github-issues credential c2 repos p/a,o2/b\nl http://x.example@a\nm @l http://x.example@b\nclient m t\n'
printf 'http api.example.com@org rules github-api credential c-org repos example-org/*\nhttp api.example.com@me rules github-issues credential c-me repos alice/tools\nhttp git.example.com@org rules git credential g-org repos example-org/*\nhttp git.example.com@me rules git credential g-me repos alice/tools\nb http://api.example.com@org http://api.example.com@me http://git.example.com@org http://git.example.com@me\nclient b t\n' > "$work/site"
r="$("$apply" --render "$work/site")"
mfail=""
# The route that takes a path (the first match, as Envoy does), and its injected credential.
takes() {  # takes <method> <path> <vhost>: route name and credential, or "refused" ("refused-ro" for a read-only repo)
  local name="" rx m cred cl ci
  while IFS= read -r name; do
    rx="$(grep -A3 "name: \"$name\"" <<< "$r" | sed -n 's/.*\(regex\|path\|prefix\): "\(.*\)"\( }\)\{0,1\}$/\1 \2/p' | head -1)"
    m="$(grep -A4 "name: \"$name\"" <<< "$r" | sed -n 's/.*":method", string_match: { safe_regex: { regex: "\([^"]*\)".*/\1/p' | head -1)"
    [ -z "$m" ] || [[ "$1" =~ ^($m)$ ]] || continue
    # Query or other header matchers aren't modelled: such a route never takes the path here.
    grep -A4 "name: \"$name\"" <<< "$r" | sed -n '2,4p' | grep -q 'query_parameters\|name: "[a-z-]*", string_match\|present_match' && continue
    case "${rx%% *}" in
      regex) rx=${rx#* }; rx=${rx//\\\\/\\}
        if [[ "$rx" == "(?i)"* ]]; then
          shopt -s nocasematch; [[ "$2" =~ ^(${rx#"(?i)"})$ ]]; ci=$?; shopt -u nocasematch; [ "$ci" = 0 ] || continue
        else [[ "$2" =~ ^($rx)$ ]] || continue; fi ;;
      path) [ "$2" = "${rx#* }" ] || continue ;;
      prefix) [[ "$2" == "${rx#* }"* ]] || continue ;;
      *) continue ;;
    esac
    if sed -n "/name: \"$name\"/,/- name:/p" <<< "$r" | grep -q direct_response; then
      if sed -n "/name: \"$name\"/,/- name:/p" <<< "$r" | grep -q 'this repo is read only'; then echo refused-ro; else echo refused; fi
      return
    fi
    cred="$(sed -n "/name: \"$name\"/,/- name:/p" <<< "$r" | grep -o '"inject-[a-z-]*"' | head -1)"
    cl="$(sed -n "/name: \"$name\"/,/- name:/p" <<< "$r" | grep -o 'cluster: "[^"]*"' | head -1)"
    echo "$name $cl $cred"; return
  done < <(sed -n "/- name: \"http-$3\"/,/- name: \"http-\|- name: \"b\"/p" <<< "$r" | grep -o '^              - name: "[^"]*"' | sed 's/.*name: "//; s/"$//')
  echo none
}
[[ "$(takes GET /repos/example-org/x api.example.com_org)" == *'cluster: "http-api.example.com_org" "inject-c-org"' ]] || mfail+=" org-read"
[[ "$(takes GET /repos/Alice/Tools/issues api.example.com_org)" == *'cluster: "http-api.example.com_me" "inject-c-me"' ]] || mfail+=" me-read"
[[ "$(takes POST /repos/alice/tools/issues api.example.com_org)" == *'cluster: "http-api.example.com_me" "inject-c-me"' ]] || mfail+=" me-issue"
[ "$(takes POST /repos/alice/tools/pulls api.example.com_org)" = refused ] || mfail+=" me-pull-not-refused"
[[ "$(takes POST /repos/example-org/x/pulls api.example.com_org)" == *'"inject-c-org"' ]] || mfail+=" org-pull"
[[ "$(takes GET /user api.example.com_org)" == 'api.example.com_org-user cluster: "http-api.example.com_org" "inject-c-org"' ]] || mfail+=" user"
[ "$(takes GET /repos/alice/other api.example.com_org)" = refused ] || mfail+=" unlisted"
[ "$(takes POST /graphql api.example.com_org)" = refused ] || mfail+=" graphql"
[ "$(takes POST /GraphQL api.example.com_org)" = refused ] || mfail+=" graphql-case"
[ "$(takes GET /repos/alice/tools/c%6fmpare api.example.com_org)" = refused ] || mfail+=" escape"
[[ "$(takes GET /alice/tools.git/info/refs git.example.com_org)" == *'cluster: "http-git.example.com_me" "inject-g-me"' ]] || mfail+=" me-git"
[[ "$(takes POST /example-org/x/git-receive-pack git.example.com_org)" == *'cluster: "http-git.example.com_org" "inject-g-org"' ]] || mfail+=" org-push"
[ "$(grep -c 'domains: \["api.example.com", "api.example.com:80"\]' <<< "$r")" = 1 ] || mfail+=" one-vhost"
[ "$(grep -c 'escaped-unreserved"' <<< "$r")" = 2 ] || mfail+=" refusals-once"
[ "$(grep -c 'name: "[^"]*-user"' <<< "$r")" = 1 ] || mfail+=" user-once"
[ "$(grep -c 'name: "deny-connect-http-api.example.com"' <<< "$r")" = 1 ] || mfail+=" deny-connect-once"
grep -q 'cluster_name: "http-api.example.com_me"' <<< "$r" || mfail+=" me-cluster"
[ "$("$apply" --clients b "$work/site" | grep -v '^#')" = "$(printf 'api.example.com 443 github-api yes\ngit.example.com 443 git yes')" ] || mfail+=" manifest"
if [ -z "$mfail" ]; then echo "ok   several definitions of a host: one virtual host, each repo its own credential, refusals and /user once (the first's), one manifest line"
else echo "FAIL several definitions of a host:$mfail"; fails=$((fails+1)); fi

# repos-read: repos the box may only read, on the same line as repos (or alone). Not on
# git-read (read only already), nor where repos isn't; a repo in one list only.
refuses "repos-read: with git-read"     "read only already"      'http x.example rules git-read repos-read a/b\n'
refuses "repos-read: with other rules"  "repos-read only with"   'http x.example rules any repos-read a/b\n'
refuses "repos-read: with kubernetes-read" "repos-read only with" 'http x.example rules kubernetes-read repos-read a/b\n'
refuses "repos-read: none given"        "repos-read needs"       'http x.example rules git repos-read\n'
refuses "repos-read: given twice"       "repos-read given twice" 'http x.example rules git repos-read a/b repos-read a/c\n'
refuses "repos-read: a bad name"        "bad repo 'acme/..'"     'http x.example rules git repos-read acme/..\n'
refuses "repos-read: and projects"      "can't be on one line"   'http x.example rules github-api projects PVT_a repos-read a/b\n'
refuses "repos-read: a repo in both lists" "overlap"             'http x.example rules git repos a/b repos-read A/B\n'
refuses "repos-read: under an owner/* in repos" "overlap"        'http x.example rules git repos a/* repos-read a/b\n'
refuses "repos-read: an owner/* over a repo in repos" "overlap"  'http x.example rules git repos a/b repos-read a/*\n'
refuses "repos-read: over 64 with repos" "over 64 repos"         "http x.example rules git repos $(for i in $(seq 40); do printf 'o/r%s,' "$i"; done | sed 's/,$//') repos-read $(for i in $(seq 25); do printf 'p/r%s,' "$i"; done | sed 's/,$//')\\n"
refuses "repos-read: two definitions, one repo in each" "also in" 'http x.example@a rules git repos o/a\nhttp x.example@b rules git repos-read o/a\nl http://x.example@a http://x.example@b\n'
refuses "...an owner/* read-only, a repo of it in another" "also in" 'http x.example@a rules git repos-read o/*\nhttp x.example@b rules git repos o/b\nl http://x.example@a http://x.example@b\n'
lists "repos-read: lowercased, with repos or alone, a second definition with only repos-read" \
  'b http://x.example:443 variant a rules git credential c repos acme/r repos-read octo-cat/hello.world,zed/*\nb http://x.example:443 variant b rules git credential d repos-read o/b\nb client t' \
  'http x.example@a rules git credential c repos acme/r repos-read Octo-Cat/Hello.World,zed/*\nhttp x.example@b rules git credential d repos-read o/b\nb http://x.example@a http://x.example@b\nclient b t\n'
# What repos-read lets through: reads and git fetch with the line's credential; writes and
# push refused with their own message; other repos as before. On GitHub, git and Forgejo,
# and in a further definition of a host (its refusals are its own, not the first's).
printf 'http api.example.com rules github-api credential c-ro repos alice/tools repos-read bob/lib,ro-org/*\nhttp git.example.com@w rules git credential g-w repos alice/tools\nhttp git.example.com@r rules git credential g-r repos-read bob/lib\nhttp fj.example.com rules forgejo credential f-ro repos-read me/r\nb http://api.example.com http://git.example.com@w http://git.example.com@r http://fj.example.com\nclient b t\n' > "$work/site"
r="$("$apply" --render "$work/site")"
ofail=""
[[ "$(takes GET /repos/bob/lib/pulls/1 api.example.com)" == 'api.example.com-read-ro-1 cluster: "http-api.example.com" "inject-c-ro"' ]] || ofail+=" api-read"
[[ "$(takes HEAD /repos/Bob/Lib api.example.com)" == 'api.example.com-read-ro-1 '* ]] || ofail+=" api-head"
[[ "$(takes GET /repos/ro-org/any.thing/contents/x api.example.com)" == 'api.example.com-read-ro-2 '* ]] || ofail+=" api-owner-read"
for mp in "POST /repos/bob/lib/issues" "POST /repos/bob/lib/pulls" "PATCH /repos/bob/lib/issues/1" "POST /repos/bob/lib/issues/1/comments" \
          "PATCH /repos/bob/lib/issues/comments/1" "POST /repos/bob/lib/pulls/1/requested_reviewers" "POST /repos/ro-org/x/issues" \
          "DELETE /repos/bob/lib" "PUT /repos/bob/lib/pulls/1/merge" "POST /repos/BOB/LIB.git/issues"; do
  # shellcheck disable=SC2086  # method and path
  [ "$(takes $mp api.example.com)" = refused-ro ] || ofail+=" api-write[$mp]"
done
[[ "$(takes POST /repos/alice/tools/issues api.example.com)" == 'api.example.com-create-1 '* ]] || ofail+=" api-write-listed"
[ "$(takes POST /repos/carol/x/issues api.example.com)" = refused ] || ofail+=" api-other"
[ "$(takes GET /repos/bob/lib/compare/a...x:b api.example.com)" = refused ] || ofail+=" api-compare-across"
[ "$(takes GET /repos/bob/lib/%2e%2e/%2e%2e/carol/x api.example.com)" = refused ] || ofail+=" api-escape"
[ "$(takes POST /graphql api.example.com)" = refused ] || ofail+=" api-graphql"
[[ "$(takes GET /user api.example.com)" == 'api.example.com-user '* ]] || ofail+=" api-user"
[[ "$(takes GET /bob/lib.git/info/refs git.example.com_w)" == 'git.example.com_r-info-refs-ro-1 cluster: "http-git.example.com_r" "inject-g-r"' ]] || ofail+=" git-info-refs"
[[ "$(takes POST /bob/lib/git-upload-pack git.example.com_w)" == 'git.example.com_r-pack-ro-1 cluster: "http-git.example.com_r" "inject-g-r"' ]] || ofail+=" git-fetch"
[ "$(takes POST /bob/lib.git/git-receive-pack git.example.com_w)" = refused-ro ] || ofail+=" git-push"
[[ "$(takes POST /alice/tools.git/git-receive-pack git.example.com_w)" == 'git.example.com_w-pack-1 '*'"inject-g-w"' ]] || ofail+=" git-push-listed"
[ "$(takes POST /carol/x/git-receive-pack git.example.com_w)" = refused ] || ofail+=" git-other"
[[ "$(takes GET /api/v1/repos/me/r/pulls fj.example.com)" == 'fj.example.com-read-ro-1 '*'"inject-f-ro"' ]] || ofail+=" fj-read"
[[ "$(takes POST /me/r.git/git-upload-pack fj.example.com)" == 'fj.example.com-pack-ro-1 '* ]] || ofail+=" fj-fetch"
[ "$(takes POST /me/r.git/git-receive-pack fj.example.com)" = refused-ro ] || ofail+=" fj-push"
[ "$(takes POST /api/v1/repos/me/r/issues/1/comments fj.example.com)" = refused-ro ] || ofail+=" fj-comment"
[ "$(takes GET /me/r.wiki.git/info/refs fj.example.com)" = refused ] || ofail+=" fj-wiki"
[ "$(takes GET /me/r/issues fj.example.com)" = refused ] || ofail+=" fj-web-ui"
grep -q 'name: "fj.example.com-query-token"' <<< "$r" || ofail+=" fj-token"
# The read-only routes keep the git timeouts (fetch streams long) and the API's caps.
grep -A4 'name: "git.example.com_r-pack-ro-1"' <<< "$r" | grep -q 'timeout: 0s, idle_timeout: 300s }' || ofail+=" git-timeout"
grep -A4 'name: "fj.example.com-pack-ro-1"' <<< "$r" | grep -q 'timeout: 0s, idle_timeout: 300s }' || ofail+=" fj-long"
grep -A4 'name: "api.example.com-read-ro-1"' <<< "$r" | grep -q 'max_stream_duration: 300s' || ofail+=" api-cap"
grep -q 'this repo is read only on api.example.com (repos-read): reads and git fetch only' <<< "$r" || ofail+=" message"
[ "$("$apply" --clients b "$work/site" | grep -v '^#')" = "$(printf 'api.example.com 443 github-api yes\ngit.example.com 443 git yes\nfj.example.com 443 forgejo yes')" ] || ofail+=" manifest"
if ! python3 -c 'import yaml' 2>/dev/null; then :
elif ! python3 -I -c 'import sys, yaml; yaml.safe_load(sys.stdin)' <<< "$r" 2>/dev/null; then ofail+=" yaml"; fi
# repos-read alone still raises RE2's program size limit for the long per-repo regexes.
printf 'http x.example rules git repos-read o/r\nb http://x.example\nclient b t\n' > "$work/site"
"$apply" --render "$work/site" | grep -q max_program_size || ofail+=" runtime-layer"
if [ -z "$ofail" ]; then echo "ok   repos-read: reads and fetch with the line's credential, writes and push refused as read only (GitHub, git, Forgejo, a further definition), the rest as before"
else echo "FAIL repos-read rendering:$ofail"; fails=$((fails+1)); fi

# protect: branches a push may not touch, on the git and forgejo rules; kept lowercase.
refuses "protect: with git-read"        "refuse every push already" 'http x.example rules git-read protect main\n'
refuses "protect: with github-api"      "protect only with"      'http x.example rules github-api protect main\n'
refuses "protect: with any"             "protect only with"      'http x.example rules any protect main\n'
refuses "protect: none given"           "protect needs"          'http x.example rules git protect\n'
refuses "protect: given twice"          "protect given twice"    'http x.example rules git protect main protect dev\n'
refuses "protect: a trailing comma"     "bad branch ''"          'http x.example rules git protect main,\n'
refuses "protect: a bare *"             "bad branch '*'"         'http x.example rules git protect *\n'
refuses "protect: * inside"             "bad branch 'a*'"        'http x.example rules git protect a*\n'
refuses "protect: * not last"           "bad branch 'a/*/b'"     'http x.example rules git protect a/*/b\n'
refuses "protect: .."                   "bad branch 'a..b'"      'http x.example rules git protect a..b\n'
refuses "protect: a part starting with ." "bad branch 'a/.b'"    'http x.example rules git protect a/.b\n'
refuses "protect: .lock"                "bad branch 'a.LOCK'"    'http x.example rules git protect a.LOCK\n'
refuses "protect: starting with -"      "bad branch '-a'"        'http x.example rules git protect -a\n'
refuses "protect: a refs/heads/ path"   "the name alone: main"   'http x.example rules git protect refs/heads/main\n'
refuses "...in another case"            "the name alone: Main"   'http x.example rules git protect REFS/Heads/Main\n'
refuses "protect: a refs/tags/ path"    "branch names, not refs/" 'http x.example rules git protect refs/tags/v1\n'
refuses "protect: refs/heads/ alone"    "branch names, not refs/" 'http x.example rules git protect refs/heads/\n'
refuses "protect: a colon"              "bad branch 'ma:n'"      'http x.example rules git protect ma:n\n'
refuses "protect: an empty part"        "bad branch 'a//b'"      'http x.example rules git protect a//b\n'
refuses "protect: over 32"              "over 32 protected"      "http x.example rules git protect $(for i in $(seq 33); do printf 'b%s,' "$i"; done | sed 's/,$//')\\n"
lists "protect: lowercased, deduplicated, prefix/* kept, with repos and per variant" \
  'b http://x.example:443 variant a rules git repos o/a protect main,release/*\nb http://x.example:443 variant b rules git repos o/b\nb http://f.example:443 rules forgejo protect staging\nb client t' \
  'http x.example@a rules git repos o/a protect Main,release/*,MAIN\nhttp x.example@b rules git repos o/b\nhttp f.example rules forgejo protect Staging\nb http://x.example@a http://x.example@b http://f.example\nclient b t\n'
# mcp: exact endpoints, required; tools or deny-tools per endpoint, never both.
refuses "mcp: no endpoints"             "the mcp rules need endpoints" 'http m.example rules mcp\n'
refuses "mcp: endpoints with other rules" "only with the mcp rules" 'http m.example rules any endpoints /mcp\n'
refuses "mcp: tools with other rules"   "only with the mcp rules" 'http m.example rules any tools /mcp:a\n'
refuses "mcp: endpoints given twice"    "endpoints given twice" 'http m.example rules mcp endpoints /a endpoints /b\n'
refuses "mcp: an endpoint twice"        "endpoint /a given twice" 'http m.example rules mcp endpoints /a,/a\n'
refuses "mcp: a trailing comma"         "bad endpoint ''"       'http m.example rules mcp endpoints /a,\n'
refuses "mcp: a relative endpoint"      "bad endpoint 'mcp'"    'http m.example rules mcp endpoints mcp\n'
refuses "mcp: a .. part"                "bad endpoint '/a/../b'" 'http m.example rules mcp endpoints /a/../b\n'
refuses "mcp: a . part"                 "bad endpoint '/a/./b'" 'http m.example rules mcp endpoints /a/./b\n'
refuses "mcp: an empty part"            "bad endpoint '/a//b'"  'http m.example rules mcp endpoints /a//b\n'
refuses "mcp: a query"                  "bad endpoint '/a?b'"   'http m.example rules mcp endpoints /a?b\n'
refuses "mcp: an escape"                "bad endpoint '/a%%2fb'" 'http m.example rules mcp endpoints /a%%2fb\n'
refuses "mcp: a wildcard"               "bad endpoint '/a/*'"   'http m.example rules mcp endpoints /a/*\n'
refuses "mcp: over 200 characters"      "bad endpoint"          "http m.example rules mcp endpoints /$(head -c 200 /dev/zero | tr '\0' a)\\n"
refuses "mcp: over 32 endpoints"        "over 32 endpoints"     "http m.example rules mcp endpoints $(for i in $(seq 33); do printf '/e%s,' "$i"; done | sed 's/,$//')\\n"
refuses "mcp: a tool on no endpoint"    "/b (in tools or deny-tools) is not one of the line's endpoints" 'http m.example rules mcp endpoints /a tools /b:x\n'
refuses "mcp: a tool without endpoint"  "bad tools entry 'x'"   'http m.example rules mcp endpoints /a tools x\n'
refuses "mcp: a bad tool name"          "bad deny-tools entry '/a:x~y'" 'http m.example rules mcp endpoints /a deny-tools /a:x~y\n'
refuses "mcp: a tool name with /"       "bad deny-tools entry '/a:x/y'" 'http m.example rules mcp endpoints /a deny-tools /a:x/y\n'
refuses "mcp: a tool name over 128"     "bad tools entry"       "http m.example rules mcp endpoints /a tools /a:$(head -c 129 /dev/zero | tr '\0' a)\\n"
refuses "mcp: tools and deny-tools on one endpoint" "both tools and deny-tools" 'http m.example rules mcp endpoints /a tools /a:x deny-tools /a:y\n'
refuses "mcp: deny-tools given twice"   "deny-tools given twice" 'http m.example rules mcp endpoints /a deny-tools /a:x deny-tools /a:y\n'
lists "mcp: endpoints in order, tools per endpoint (case kept), / and a trailing slash" \
  'b http://m.example:443 rules mcp credential t endpoints /Alpha/mcp,/beta/mcp/,/ tools /beta/mcp/:Read_A,/beta/mcp/:read.b deny-tools /Alpha/mcp:write-x\nb client t' \
  'http m.example rules mcp credential t endpoints /Alpha/mcp,/beta/mcp/,/ tools /beta/mcp/:Read_A,/beta/mcp/:read.b,/beta/mcp/:Read_A deny-tools /Alpha/mcp:write-x\nb http://m.example\nclient b t\n'
# What mcp renders: the query refusal first, then per endpoint POST (with the check only where
# the endpoint has a list), its two refusals, GET, DELETE and the other methods, then the
# refusal of every other path; the check's filters only on a listener that has a list.
printf 'http m.example rules mcp credential t endpoints /a/mcp,/b/mcp deny-tools /a/mcp:w\nhttp n.example rules mcp endpoints /mcp\nb http://m.example\nc http://n.example\nclient b t\nclient c u\n' > "$work/site"
r="$("$apply" --render "$work/site")"
mfail=""
order="$(grep -o 'name: "m.example-[a-z0-9-]*"' <<< "$r" | sed 's/^name: "m.example-//; s/"$//' | tr '\n' ' ')"
[ "$order" = "query ep1-post ep1-post-too-large ep1-post-refused ep1-stream ep1-delete ep1-body ep1-method ep2-post ep2-post-too-large ep2-post-refused ep2-stream ep2-delete ep2-body ep2-method refused " ] || mfail+=" order:$order"
sed -n '/name: "m.example-ep1-post"/,/name: "m.example-ep1-post-too-large"/p' <<< "$r" | grep -q 'mcp-tools: { mode: "deny", tools: "w", endpoint: "/a/mcp" }' || mfail+=" ep1-meta"
sed -n '/name: "m.example-ep2-post"/,/name: "m.example-ep2-post-too-large"/p' <<< "$r" | grep -q 'mcp-' && mfail+=" ep2-checked"
sed -n '/name: "m.example-ep1-post"/,/name: "m.example-ep1-post-too-large"/p' <<< "$r" | grep -q '"inject-t"' || mfail+=" ep1-cred"
sed -n '/name: "n.example-ep1-post"/,/name: "n.example-ep1-post-too-large"/p' <<< "$r" | grep -q 'inject' && mfail+=" no-cred-injects"
[ "$(sed -n '/^  - name: "b"$/,/^  - name: "c"$/p' <<< "$r" | grep -c 'name: mcp-tools$')" = 1 ] || mfail+=" filter-on-b"
sed -n '/^  - name: "c"$/,$p' <<< "$r" | grep -q 'name: mcp-tools$' && mfail+=" filter-on-c"
grep -A2 'name: "m.example-ep1-stream"' <<< "$r" | grep -q 'timeout: 0s, idle_timeout: 900s }' || mfail+=" get-timeouts"
grep -A1 'name: "m.example-ep1-post-too-large"' <<< "$r" | grep -q 'start: 1048577' || mfail+=" too-large"
grep -A2 'name: "m.example-refused"' <<< "$r" | grep -q 'not an endpoint of this line on m.example (its endpoints: /a/mcp, /b/mcp)' || mfail+=" refused-text"
if [ -z "$mfail" ]; then echo "ok   mcp rendering: exact endpoints, the check only where listed, the refusals and timeouts"
else echo "FAIL mcp rendering:$mfail"; fails=$((fails+1)); fi
# What protect renders: per pack route, a push-guard route first (receive-pack, the check on)
# and the pack route narrowed to fetch; one check filter per definition, before the
# credential; the check listener, its cluster and the reply mapping only where used.
printf 'http x.example@a rules git credential c-a repos o/a,o/b repos-read o/ro protect main\nhttp x.example@b rules git credential c-b repos o/c\nhttp f.example rules forgejo credential c-f protect main,dev\nhttp g.example rules git credential c-g\nb http://x.example@a http://x.example@b http://f.example\nc http://g.example\nclient b t\nclient c u\n' > "$work/site"
r="$("$apply" --render "$work/site")"
pfail=""
order="$(grep -o 'name: "x.example_[ab]-[a-z0-9-]*"' <<< "$r" | sed 's/^name: "//; s/"$//' | tr '\n' ' ')"
[[ "$order" == *"x.example_a-push-guard-1 x.example_a-pack-1 x.example_a-push-guard-2 x.example_a-pack-2 x.example_a-pack-ro-1"* ]] || pfail+=" order"
[[ "$order" != *"x.example_b-push-guard"* ]] || pfail+=" guard-on-unprotected-definition"
[[ "$order" != *"push-guard-ro"* ]] || pfail+=" guard-on-read-only"
[[ "$(takes POST /o/a/git-receive-pack x.example_a)" == 'x.example_a-push-guard-1 '*'"inject-c-a"' ]] || pfail+=" guard-takes-push"
[[ "$(takes POST /o/A.git/git-upload-pack x.example_a)" == 'x.example_a-pack-1 '* ]] || pfail+=" pack-takes-fetch"
[[ "$(takes POST /o/c/git-receive-pack x.example_a)" == 'x.example_b-pack-1 '*'"inject-c-b"' ]] || pfail+=" unprotected-push"
[ "$(takes POST /o/ro/git-receive-pack x.example_a)" = refused-ro ] || pfail+=" read-only-push"
[[ "$(takes POST /f/r/git-receive-pack f.example)" == 'f.example-push-guard '* ]] || pfail+=" forgejo-guard"
f_a="$(grep -A6 'name: "x.example_a-push-guard-1"' <<< "$r" | grep -o '"protect-[0-9a-f]*"' | tr -d '"')"
f_f="$(grep -A6 'name: "f.example-push-guard"' <<< "$r" | grep -o '"protect-[0-9a-f]*"' | tr -d '"')"
[ -n "$f_a" ] && [ -n "$f_f" ] && [ "$f_a" != "$f_f" ] || pfail+=" filter-per-definition"
grep -A2 'name: "x.example_a-pack-1"' <<< "$r" | grep -q protect- && pfail+=" filter-on-fetch"
grep -A18 "name: \"$f_a\"" <<< "$r" | grep -q 'key: x-airlock-protect, value: "main"' || pfail+=" header-protect"
grep -A18 "name: \"$f_f\"" <<< "$r" | grep -q 'key: x-airlock-protect, value: "main dev"' || pfail+=" header-protect-f"
grep -A18 "name: \"$f_a\"" <<< "$r" | grep -q 'key: x-airlock-listener, value: "b"' || pfail+=" header-listener"
grep -A18 "name: \"$f_a\"" <<< "$r" | grep -q 'failure_mode_allow: false' || pfail+=" fail-closed"
grep -A18 "name: \"$f_a\"" <<< "$r" | grep -q 'max_request_bytes: 65536, allow_partial_message: true' || pfail+=" body-prefix"
# Before the injectors (the check never sees the credential) and the GraphQL check.
fl="$(sed -n '/^  - name: "b"$/,/^  - name: "c"$/p' <<< "$r" | grep -o '^          - name: "*[a-z0-9.-]*' | sed 's/.*name: "*//' | tr '\n' ' ')"
[[ "$fl" == *"protect-"*"inject-c-a"* ]] || pfail+=" filter-order($fl)"
[ "$(grep -c '^  - name: protect-check$' <<< "$r")" = 2 ] || pfail+=" check-listener-and-cluster"
[ "$(grep -c 'local_reply_config:' <<< "$r")" = 1 ] || pfail+=" mapping-only-on-b"
sed -n '/^  - name: "c"$/,/^  - name: /p' <<< "$r" | sed '$d' | grep -q 'protect-\|local_reply_config' && pfail+=" listener-c-touched"
grep -q 'status_on_error: { code: ServiceUnavailable }' <<< "$r" || pfail+=" error-not-503"
printf 'http g.example rules git credential c-g\nc http://g.example\nclient c u\n' > "$work/site"
"$apply" --render "$work/site" | grep -q 'protect\|local_reply_config\|ext_authz' && pfail+=" unused-rendered"
if [ -z "$pfail" ]; then echo "ok   protect: a push-guard per pack route, fetch apart, a check filter per definition before the credential, the check listener and reply mapping only where used"
else echo "FAIL protect rendering:$pfail"; fails=$((fails+1)); fi

# Pass credentials (airlock-envoy-cred add): read from the tmpfs, the locked check after the
# injectors, upstream's x-airlock-envoy removed; only on listeners that use one. A copy of
# apply with its pass directory here (which credentials are pass ones is root's to read).
mkdir -p "$work/pass" "$work/pcopy"
sed "s#^PASS_DIR=/etc/airlock-envoy/pass#PASS_DIR=$work/pass#" "$apply" > "$work/pcopy/apply"; chmod +x "$work/pcopy/apply"
cp install/github-graphql.lua install/git-protect.lua "$work/pcopy/"
: > "$work/pass/c-pass"
printf 'http api.example.com rules github-api credential c-pass repos o/a\nhttp g.example.com rules git credential c-file\nhttp k.example.com rules git credential c-k\nb http://api.example.com http://g.example.com\nc http://k.example.com\nclient b t\nclient c u\n' > "$work/site"
r="$("$work/pcopy/apply" --render "$work/site")"
cfail=""
grep -q 'path: "/run/airlock-envoy-cred/secrets/c-pass.yaml", watched_directory: { path: "/run/airlock-envoy-cred/secrets" }' <<< "$r" || cfail+=" pass-path"
grep -q 'path: "/etc/airlock-envoy/credentials/c-file.yaml", watched_directory: { path: "/etc/airlock-envoy/credentials" }' <<< "$r" || cfail+=" file-path"
lb="$(sed -n '/^  - name: "b"$/,/^  - name: "c"$/p' <<< "$r")"; lc="$(sed -n '/^  - name: "c"$/,/^  - name: /p' <<< "$r" | sed '$d')"
fl="$(grep -o '^          - name: "*[a-z0-9.-]*' <<< "$lb" | sed 's/.*name: "*//' | tr '\n' ' ')"
[[ "$fl" == *"inject-c-pass inject-c-file credential-locked envoy.filters.http.router"* ]] || cfail+=" order($fl)"
[ "$(grep -c 'response_headers_to_remove: \[x-airlock-envoy\]' <<< "$lb")" = 2 ] || cfail+=" strip-on-b"
grep -q 'credential-locked\|x-airlock-envoy' <<< "$lc" && cfail+=" listener-c-touched"
grep -q 'a:sub(1, 21) == "airlock-envoy-locked "' <<< "$lb" || cfail+=" check"
[ "$("$apply" --render "$work/site" | grep -c '/run/airlock-envoy-cred')" = 0 ] || cfail+=" no-pass-dir-renders-file"
if [ -z "$cfail" ]; then echo "ok   pass credentials: read from the tmpfs, the locked check after the injectors, upstream's marker removed, only where used"
else echo "FAIL pass credential rendering:$cfail"; fails=$((fails+1)); fi

# Every Lua filter's code starts by turning LuaJIT's compiler off: the units set
# MemoryDenyWriteExecute, and the first compiled trace panics Envoy (credential-locked lacked
# it and crashed a host every 15-25 minutes). All five filters rendered at once (a pass
# credential for the locked check), then apply refusing a filter without it, from a file and
# from its own inline code.
mkdir -p "$work/jcopy"
sed "s#^PASS_DIR=/etc/airlock-envoy/pass#PASS_DIR=$work/pass#" "$apply" > "$work/jcopy/apply"; chmod +x "$work/jcopy/apply"
cp install/*.lua "$work/jcopy/"
: > "$work/pass/c-pass"
printf 'http api.example.com rules github-api credential c-pass\nhttp git.example.com rules git credential c-g protect main\nhttp mcp.example.com rules mcp credential c-m endpoints /a/mcp deny-tools /a/mcp:x\nb http://api.example.com http://git.example.com http://mcp.example.com\nclient b t\n' > "$work/site"
jfail=""
r="$("$work/jcopy/apply" --render "$work/site")" || jfail+=" render"
names="$(grep -B3 'lua\.v3\.Lua' <<< "$r" | sed -n 's/^ *- name: \(.*\)$/\1/p' | sort | tr '\n' ' ')"
[ "$names" = "credential-locked git-protect github-graphql mcp-nobody mcp-tools " ] || jfail+=" filters($names)"
firsts="$(awk '/lua\.v3\.Lua/ { w = 1; next } w && /inline_string: \|/ { s = 1; next }
  w && s { l = $0; sub(/^ +/, "", l); if (l == "" || l ~ /^--/) next; print l; w = s = 0 }' <<< "$r" | sed 's/ *--.*//' | sort -u)"
[ "$firsts" = "if jit then jit.off() end" ] || jfail+=" first-lines($firsts)"
sed -i '/^if jit then jit.off() end/d' "$work/jcopy/mcp-tools.lua"
out="$("$work/jcopy/apply" --render "$work/site" 2>&1)" && jfail+=" file-without-accepted"
[[ "$out" == *"internal: a Lua filter without jit.off() first"*"starts with:"* ]] || jfail+=" file-message($out)"
cp install/mcp-tools.lua "$work/jcopy/"
sed -i '/name: credential-locked/,/function envoy_on_request/{/if jit then jit.off() end/d}' "$work/jcopy/apply"
out="$("$work/jcopy/apply" --render "$work/site" 2>&1)" && jfail+=" inline-without-accepted"
[[ "$out" == *"internal: a Lua filter without jit.off() first"* ]] || jfail+=" inline-message($out)"
"$work/jcopy/apply" --list "$work/site" >/dev/null || jfail+=" list-needs-no-render"
cp "$apply" "$work/jcopy/apply.orig"; sed "s#^PASS_DIR=/etc/airlock-envoy/pass#PASS_DIR=$work/pass#" "$apply" > "$work/jcopy/apply"
# jit.on later, a block comment hiding the line, per-route Lua: each refused too.
printf 'if jit then jit.off() end\nfunction envoy_on_request(h) end\nif jit then jit.on() end\n' > "$work/jcopy/mcp-tools.lua"
out="$("$work/jcopy/apply" --render "$work/site" 2>&1)" && jfail+=" jit-on-accepted"
[[ "$out" == *"jit.on"* ]] || jfail+=" jit-on-message"
printf -- '--[[\nif jit then jit.off() end\n]]\nfunction envoy_on_request(h) end\n' > "$work/jcopy/mcp-tools.lua"
out="$("$work/jcopy/apply" --render "$work/site" 2>&1)" && jfail+=" block-comment-accepted"
[[ "$out" == *"block comment before jit.off()"* ]] || jfail+=" block-comment-message($out)"
cp install/mcp-tools.lua "$work/jcopy/"
"$work/jcopy/apply" --render "$work/site" >/dev/null || jfail+=" restored-copy-refused"
if [ -z "$jfail" ]; then echo "ok   Lua filters: all five start with jit.off(); apply refuses to render one without it (a file or its own code)"
else echo "FAIL Lua jit.off:$jfail"; fails=$((fails+1)); fi

# GitHub App credentials: tokens per line (a write token for repos, a read one for repos-read),
# each route its own, mint.conf what airlock-envoy-mint mints; only named repos of one owner, on
# GitHub rules. A copy of apply with its Apps directory here.
mkdir -p "$work/apps" "$work/acopy"
sed "s#^MINT_APPS=/etc/airlock-envoy-mint/apps#MINT_APPS=$work/apps#" "$apply" > "$work/acopy/apply"; chmod +x "$work/acopy/apply"
cp install/github-graphql.lua install/git-protect.lua "$work/acopy/"
printf 'key pass\n' > "$work/apps/gh-app"
arefuses() {  # arefuses <name> <expected message part> <site text>: as refuses, with the Apps copy
  printf '%b' "$3" > "$work/site"
  if out="$("$work/acopy/apply" --render-mint "$work/site" 2>&1)"; then echo "FAIL $1: accepted"; fails=$((fails+1))
  elif [[ "$out" == *"$2"* ]]; then echo "ok   $1"
  else echo "FAIL $1: wrong message: $out"; fails=$((fails+1)); fi
}
arefuses "app: owner/*"                 "name each repo"        'http api.example.com rules github-api credential gh-app repos o/*\nb http://api.example.com\nclient b t\n'
arefuses "app: owner/* in repos-read"   "name each repo"        'http api.example.com rules github-api credential gh-app repos o/a repos-read q/*\nb http://api.example.com\nclient b t\n'
arefuses "app: two owners"              "one owner per line"    'http api.example.com rules github-api credential gh-app repos o/a,p/b\nb http://api.example.com\nclient b t\n'
arefuses "...across repos and repos-read" "one owner per line"  'http api.example.com rules github-api credential gh-app repos o/a repos-read p/b\nb http://api.example.com\nclient b t\n'
arefuses "app: no repos"                "name its repos"        'http api.example.com rules github-api credential gh-app\nb http://api.example.com\nclient b t\n'
arefuses "app: forgejo rules"           "only with the git"     'http fj.example.com rules forgejo credential gh-app repos o/a\nb http://fj.example.com\nclient b t\n'
arefuses "app: any rules"               "only with the git"     'http x.example.com rules any credential gh-app\nb http://x.example.com\nclient b t\n'
printf 'http api.example.com@w rules github-api credential gh-app repos o/Tools,o/site repos-read o/docs\nhttp api.example.com@i rules github-issues credential gh-app repos o/issues repos-read o/notes\nhttp github.com@w rules git credential gh-app repos o/tools repos-read o/lib protect main\nhttp mirror.example.com rules git-read credential gh-app repos o/mirror\nhttp g.example.com rules git credential plain-cred\nb http://api.example.com@w http://api.example.com@i http://github.com@w http://mirror.example.com http://g.example.com\nclient b t\n' > "$work/site"
m="$("$work/acopy/apply" --render-mint "$work/site")"; r="$("$work/acopy/apply" --render "$work/site")"
afail=""
tok() { printf 'tok-%s-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-12)" "$2"; }
want="token $(tok api.example.com@w rw) app gh-app owner o repos tools,site perms contents=read,issues=write,pull_requests=write format token
token $(tok api.example.com@w ro) app gh-app owner o repos docs perms contents=read,issues=read,pull_requests=read format token
token $(tok api.example.com@i rw) app gh-app owner o repos issues perms contents=read,issues=write format token
token $(tok api.example.com@i ro) app gh-app owner o repos notes perms contents=read,issues=read format token
token $(tok github.com@w rw) app gh-app owner o repos tools perms contents=write format basic
token $(tok github.com@w ro) app gh-app owner o repos lib perms contents=read format basic
token $(tok mirror.example.com rw) app gh-app owner o repos mirror perms contents=read format basic"
[ "$m" = "$want" ] || afail+=" mint.conf($m)"
inj() { grep -A7 "name: \"$1\"" <<< "$r" | grep -o 'inject-[a-z0-9-]*' | head -1; }
[ "$(inj api.example.com_w-read-1)" = "inject-$(tok api.example.com@w rw)" ] || afail+=" read-rw"
[ "$(inj api.example.com_w-read-ro-1)" = "inject-$(tok api.example.com@w ro)" ] || afail+=" read-ro"
[ "$(inj api.example.com_w-create-1)" = "inject-$(tok api.example.com@w rw)" ] || afail+=" create-rw"
[ "$(inj api.example.com_w-user)" = "inject-$(tok api.example.com@w rw)" ] || afail+=" user-rw"
[ "$(inj github.com_w-push-guard-1)" = "inject-$(tok github.com@w rw)" ] || afail+=" push-guard"
[ "$(inj g.example.com-pack)" = "inject-plain-cred" ] || afail+=" plain-cred"
grep -q "path: \"/run/airlock-envoy-mint/tokens/$(tok api.example.com@w ro).yaml\", watched_directory: { path: \"/run/airlock-envoy-mint/tokens\" }" <<< "$r" || afail+=" token-path"
! grep -q 'inject-gh-app' <<< "$r" || afail+=" app-name-injected"
grep -q 'airlock-envoy-unavailable ' <<< "$r" && grep -q 'name: credential-locked' <<< "$r" || afail+=" locked-check"
[ -z "$("$apply" --render-mint "$work/site")" ] || afail+=" mint-conf-without-app-dir"
if [ -z "$afail" ]; then echo "ok   app credentials: a token per line and access, each route its own, mint.conf with each line's repos and permissions"
else echo "FAIL app credential rendering:$afail"; fails=$((fails+1)); fi

# The render stops if a further definition would refuse other paths than the first (it couldn't
# stand for it): a copy whose parser lets git and github-api share a host.
# shellcheck disable=SC2016  # $1 and $2 are the script's text, not this shell's
sed 's|^  \[ "\$1" = "\$2" \] && return 0$|  return 0|' "$apply" > "$work/guard/apply-family"; chmod +x "$work/guard/apply-family"
printf 'http x.example@a rules github-api repos o/a\nhttp x.example@b rules git repos o/b\nl http://x.example@a http://x.example@b\nclient l t\n' > "$work/site"
if grep -q '^  return 0$' "$work/guard/apply-family" && ! out="$("$work/guard/apply-family" --render "$work/site" 2>&1 >/dev/null)" && [[ "$out" == *"refuses other paths"* ]]; then
  echo "ok   several definitions: one whose refusals differ from the first's stops the render"
else echo "FAIL several definitions: differing refusals rendered: $out"; fails=$((fails+1)); fi

# Refusals name the listener and what would change them, so a box can report the cause.
printf 'http api.example.com rules github-api credential c\nmine example.com:443 http://api.example.com\nclient mine t\n' > "$work/site"
r="$("$apply" --render "$work/site")"
if grep -q 'airlock-envoy: host not in allowlist of listener mine (the host.s admin adds host:port to that listener in /etc/airlock-envoy/site.conf)' <<< "$r" \
   && grep -q 'airlock-envoy: not a plain-HTTP host of this profile (listener mine: ' <<< "$r" \
   && grep -q 'airlock-envoy: refused by the github-api rules (listener mine): this method and path are not allowed on api.example.com' <<< "$r" \
   && grep -q 'airlock-envoy: refused by the github-api rules (listener mine): this path is refused on api.example.com' <<< "$r"; then
  echo "ok   refusals name the listener and what to change (CONNECT, plain HTTP, a preset's deny and catch-all)"
else echo "FAIL refusal messages"; fails=$((fails+1)); fi

# Without repos, nothing changes: the presets' own routes.
printf 'http api.example.com rules github-api credential c1\nb http://api.example.com\nclient b t\n' > "$work/site"
r="$("$apply" --render "$work/site")"
if grep -q 'name: "api.example.com-graphql"' <<< "$r" && grep -A2 'name: "api.example.com-read"' <<< "$r" | grep -q 'prefix: "/"' \
   && ! grep -q 'layered_runtime' <<< "$r"; then
  echo "ok   no repos: GraphQL checked, reads anywhere, no runtime layer (as before)"
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

# A host entry on another port: the CONNECT route matches host:port exactly, and the upstream
# is dialled on that port (the site checks use a host that never resolves, so only this pins it).
printf 'b port-test.invalid:8443\nclient b t\n' > "$work/site"
r="$("$apply" --render "$work/site")"
c="$(sed -n '/^  - name: "upstream-port-test.invalid/,/^  - name: /p' <<< "$r")"
if grep -q 'string_match: { exact: "port-test.invalid:8443" }' <<< "$r" \
   && grep -q 'address: "port-test.invalid", port_value: 8443' <<< "$c" && grep -q 'type: LOGICAL_DNS' <<< "$c" \
   && ! grep -q 'port_value: 443 ' <<< "$c"; then
  echo "ok   a host entry on port 8443: exact host:port route, upstream dialled on 8443"
else echo "FAIL host entry on another port"; fails=$((fails+1)); fi

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

# A file shaped like a real site renders to a config Envoy accepts, scoped routes at their
# largest included: 64 repos with the longest names (40 + 100 characters).
long="$(for i in $(seq 10 73); do printf '%s,' "o$i$(printf 'x%.0s' $(seq 37))/r$i$(printf 'y%.0s' $(seq 97))"; done)"
printf 'http api.example.com rules github-api\nhttp issues.example.com rules github-issues repos %s\nhttp g.example.com rules git protect main,release/*\nhttp fj.example.com rules forgejo repos a/* protect main\nx http://fj.example.com\nx @anthropic metrics.example.net:443 logs.example.net:443 10.0.0.10:6443 http://api.example.com\ny example.org:8443 x-y.example.com:443 http://issues.example.com http://g.example.com\nclient x t\nclient y u\n' "${long%,}" > "$work/site"
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
