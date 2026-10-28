#!/bin/bash
# airlock-envoy-mint against a stand-in GitHub App API (test/fake-github-app.py: TLS, checks each
# JWT's RS256 signature with the App's public key, records what each token asked for). Runs as
# any user, no root: the tool's paths moved under a scratch directory, its clock a file.
# Needs python3, openssl, curl. Exits non-zero if any check fails.
# Checks read "<condition> && ok ... || fail ...": ok always succeeds.
# shellcheck disable=SC2015
set -u
cd "$(dirname "$0")/.." || exit
repo=$PWD
for t in python3 openssl curl; do command -v "$t" >/dev/null || { echo "skipped: no $t"; exit 3; }; done
work="$(mktemp -d)"
pids=()
# shellcheck disable=SC2329  # run by the trap
cleanup() { kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails+1)); }
PORT=18643
cd "$work" || exit

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.pem -days 2 -subj /CN=test-ca 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout srv.key -out srv.csr -subj /CN=localhost 2>/dev/null
printf 'subjectAltName=IP:127.0.0.1\n' > san.ext
openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out srv.pem -days 2 -extfile san.ext 2>/dev/null
openssl genrsa -out app.pem 2048 2>/dev/null; openssl rsa -in app.pem -pubout -out app.pub 2>/dev/null
openssl genrsa -out other.pem 2048 2>/dev/null
python3 -I "$repo/test/fake-github-app.py" "$PORT" srv.pem srv.key app.pub 12345 678 "$work/api.log" 2> api.err & pids+=($!)

E=$work/etc R=$work/run
# The runtime layout tmpfiles.d makes (here all the test user's).
mkdir -p "$E/apps" "$R/tokens" "$R/keys" "$R/minted" "$R/installations" bin; : > "$R/.lock"; chmod 0700 "$R/minted"
sed -e "s#^CONF=/etc/airlock-envoy-mint/mint.conf#CONF=$E/mint.conf#" -e "s#^APPS=/etc/airlock-envoy-mint/apps#APPS=$E/apps#" \
    -e "s#^RUN=/run/airlock-envoy-mint#RUN=$R#" -e "s#^GRACE=60 #GRACE=2 #" \
    "$repo/install/airlock-envoy-mint" > bin/airlock-envoy-mint
chmod +x bin/airlock-envoy-mint
for pat in "CONF=$E/mint.conf" "APPS=$E/apps" "RUN=$R" "GRACE=2 "; do grep -qF "$pat" bin/airlock-envoy-mint || { echo "FAIL the test copy lacks $pat"; exit 1; }; done
mint() { "$work/bin/airlock-envoy-mint" "$@"; }
printf 'kind github-app\napp_id 12345\ninstallation_id 678\napi https://127.0.0.1:%s\nkey file\nca %s\n' "$PORT" "$work/ca.pem" > "$E/apps/example-app"
cp app.pem "$E/apps/example-app.pem"
printf 'kind github-app\napp_id 12345\ninstallation_id 678\napi https://127.0.0.1:%s\nkey pass\nca %s\n' "$PORT" "$work/ca.pem" > "$E/apps/pass-app"
cat > "$E/mint.conf" <<'EOF'
# written by airlock-envoy-apply
token tok-git-rw app example-app owner example-org repos tools,site perms contents=write format basic
token tok-api-rw app example-app owner example-org repos tools,site perms pull_requests=write,issues=write,contents=read format token
token tok-api-ro app example-app owner example-org repos docs perms contents=read,issues=read,pull_requests=read format token
token tok-locked app pass-app owner example-org repos tools perms contents=read format token
EOF
for _ in $(seq 50); do curl -s --cacert ca.pem "https://127.0.0.1:$PORT/x" >/dev/null && break; sleep 0.1; done
val() { sed -n 's/^  generic_secret: { secret: { inline_string: "\(.*\)" } }$/\1/p' "$R/tokens/$1.yaml"; }
reqs() { python3 -I -c 'import json,sys; [print(json.dumps(r["request"], sort_keys=True)) for r in map(json.loads, open(sys.argv[1])) if r.get("status") == 201]' api.log; }
minted() { grep -c '"status": 201' api.log; }
# Age every token: its recorded expiry 10 minutes away (the JWT keeps the real clock).
age() { sed -i "1s/, expires [0-9]*, line/, expires $(( $(date +%s) + 600 )), line/" "$R"/tokens/*.yaml; }

# A run: a token per line, each for exactly its repos and permissions, in its format.
out="$(mint run 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(minted)" = 3 ] && ok "run: three tokens minted (the locked app's not), rc 0" || fail "run: rc $rc, $(minted) minted: $out"
reqs > reqs.txt
grep -qxF '{"permissions": {"contents": "write"}, "repositories": ["tools", "site"]}' reqs.txt \
  && grep -qxF '{"permissions": {"contents": "read", "issues": "write", "pull_requests": "write"}, "repositories": ["tools", "site"]}' reqs.txt \
  && grep -qxF '{"permissions": {"contents": "read", "issues": "read", "pull_requests": "read"}, "repositories": ["docs"]}' reqs.txt \
  && ok "each token asked for exactly its line's repos and permissions" || fail "requests: $(cat reqs.txt)"
! grep -q '"jwt"' api.log && ok "every JWT checked out (RS256 with the App's key, iss, iat, exp)" || fail "a JWT was refused: $(grep jwt api.log)"
g="$(val tok-git-rw)"; a="$(val tok-api-rw)"
[[ "$g" == "Basic "* ]] && [[ "$(base64 -d <<< "${g#Basic }")" == x-access-token:ghs_* ]] && [[ "$a" == "token ghs_"* ]] \
  && ok "formats: git basic x-access-token, the API token" || fail "formats: $g / $a"
[ "$(val tok-locked)" = "airlock-envoy-locked pass-app" ] && ok "a pass key not unlocked: its token locked" || fail "locked: $(val tok-locked)"
[ "$(stat -c %a "$R/tokens/tok-git-rw.yaml")" = 640 ] && [ "$(stat -c %a "$R/minted")" = 700 ] && ok "modes: tokens 0640, the revoke list 0700" || fail "modes"
! grep -rq "ghs_" "$work/etc" && ok "no token in /etc" || fail "a token in /etc"

# Within its life: nothing minted again.
mint run >/dev/null 2>&1
[ "$(minted)" = 3 ] && ok "a second run within the tokens' life mints nothing" || fail "re-minted early: $(minted)"
# Near expiry (15 minutes and under): minted again, the old one revoked.
old="$(val tok-api-rw)"
touch -d '-1 hour' "$R/minted/tok-api-rw"   # minted long ago, as it would be at renewal
age
mint run >/dev/null 2>&1
[ "$(minted)" = 6 ] && [ "$(val tok-api-rw)" != "$old" ] && ! grep -q "\"revoked\": \"${old#token }\"" api.log \
  && ok "near expiry: minted again; the replaced token not revoked yet (requests in flight)" || fail "renew: $(minted) minted"
mint run >/dev/null 2>&1
! grep -q "\"revoked\": \"${old#token }\"" api.log && ok "...nor by a run straight after (its grace counts from its retirement)" || fail "revoked within its grace"
sleep 3; mint run >/dev/null 2>&1
grep -q "\"revoked\": \"${old#token }\"" api.log && ! compgen -G "$R/minted/tok-api-rw.prev.*" >/dev/null && [ "$(minted)" = 6 ] \
  && ok "...revoked by the next run after its grace" || fail "the replaced token was not revoked after the grace"
# A changed line (other repos): minted again for it alone.
sed -i 's/repos docs perms/repos docs,wiki perms/' "$E/mint.conf"
mint run >/dev/null 2>&1
[ "$(minted)" = 7 ] && reqs | tail -n 1 | grep -qF '"repositories": ["docs", "wiki"]' && ok "a changed line: that token minted again" || fail "changed line: $(minted)"

# GitHub refusing: a token that still works is kept; one never minted says unavailable.
touch api.log.fail
age
cur="$(val tok-git-rw)"
mint run >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$(val tok-git-rw)" = "$cur" ] && ok "a failed re-mint keeps the current token (rc $rc)" || fail "failed re-mint replaced the token"
printf 'token tok-new app example-app owner example-org repos tools perms contents=read format token\n' >> "$E/mint.conf"
mint run >/dev/null 2>&1
[ "$(val tok-new)" = "airlock-envoy-unavailable example-app" ] && ok "never minted and refused: unavailable (Envoy says so), not empty" || fail "unavailable: $(val tok-new)"
rm -f api.log.fail
mint run >/dev/null 2>&1
[[ "$(val tok-new)" == "token ghs_"* ]] && ok "minted once GitHub agrees" || fail "after the refusal"

# A pass key: unlocked (the key in /run) mints; locked (the key gone) locks and revokes.
cp app.pem "$R/keys/pass-app.pem"
mint run >/dev/null 2>&1
t="$(val tok-locked)"
[[ "$t" == "token ghs_"* ]] && ok "a pass key unlocked: minted" || fail "pass unlocked: $t"
rm -f "$R/keys/pass-app.pem"
mint run >/dev/null 2>&1
[ "$(val tok-locked)" = "airlock-envoy-locked pass-app" ] && grep -q "\"revoked\": \"${t#token }\"" api.log && [ ! -f "$R/minted/tok-locked" ] \
  && ok "the key gone: locked, its token revoked" || fail "pass locked: $(val tok-locked)"

# The wrong key: GitHub refuses the JWT, nothing minted.
cp other.pem "$E/apps/example-app.pem"; age
n="$(minted)"; mint run >/dev/null 2>&1
[ "$(minted)" = "$n" ] && grep -q '"jwt": "bad signature"' api.log && ok "another key's JWT refused, nothing minted" || fail "wrong key"
cp app.pem "$E/apps/example-app.pem"

# Bad lines are refused, not half-read.
printf 'token bad name app example-app repos a perms contents=write format basic\ntoken tok-x app example-app owner example-org repos a/b perms contents=write format basic\ntoken tok-y app example-app owner example-org repos a perms contents=admin format basic\n' >> "$E/mint.conf"
out="$(mint run 2>&1)"
[ ! -e "$R/tokens/tok-x.yaml" ] && [ ! -e "$R/tokens/tok-y.yaml" ] && [ "$(grep -c "a bad line" <<< "$out")" = 3 ] && ok "bad lines (a space, owner/repo, an unknown access) refused" || fail "bad lines: $out"

# An App by org: the installation looked up with the App's JWT, then the id cached in /run.
printf 'kind github-app\napp_id 12345\norg example-org\napi https://127.0.0.1:%s\nkey file\nca %s\n' "$PORT" "$work/ca.pem" > "$E/apps/org-app"
cp app.pem "$E/apps/org-app.pem"
sed -i '/^token tok-[xy] \|^token bad /d' "$E/mint.conf"
printf 'token tok-org app org-app owner example-org repos tools perms contents=read format token\n' >> "$E/mint.conf"
mint run >/dev/null 2>&1
n="$(grep -c '"/orgs/example-org/installation"' api.log)"
[[ "$(val tok-org)" == "token ghs_"* ]] && [ "$n" = 1 ] && [ "$(cut -d' ' -f1 "$R/installations/org-app")" = 678 ] && ok "an App by org: its installation looked up, the id kept" || fail "org lookup: $n, $(val tok-org)"
age; mint run >/dev/null 2>&1
[ "$(grep -c '"/orgs/example-org/installation"' api.log)" = 1 ] && ok "...and not looked up again" || fail "org looked up again"
printf 'kind github-app\napp_id 12345\norg other-org\napi https://127.0.0.1:%s\nkey file\nca %s\n' "$PORT" "$work/ca.pem" > "$E/apps/lost-app"; cp app.pem "$E/apps/lost-app.pem"
printf 'token tok-lost app lost-app owner other-org repos tools perms contents=read format token\n' >> "$E/mint.conf"
# A cached id from the App's earlier definition (another org), and one from before the cache
# named what it was looked up for: neither is used.
printf '678 12345 example-org https://127.0.0.1:%s\n' "$PORT" > "$R/installations/lost-app"
mint run >/dev/null 2>&1; v1="$(val tok-lost)"
printf '678' > "$R/installations/lost-app"
mint run >/dev/null 2>&1; v2="$(val tok-lost)"
[ "$v1" = "airlock-envoy-unavailable lost-app" ] && [ "$v2" = "$v1" ] && [ "$(grep -c '"/orgs/other-org/installation"' api.log)" = 2 ] \
  && ok "an org the App isn't installed on: unavailable, a cached id for another definition not used" || fail "lost org: $v1 / $v2"
sed -i '/tok-lost/d' "$E/mint.conf"

# A failed install of a new token (the tokens directory not writable): the working token stays,
# untouched and unrevoked; the new one, never used, is revoked at once.
age; cur="$(val tok-git-rw)"; n="$(minted)"
chmod 0550 "$R/tokens"; mint run >/dev/null 2>&1; rc=$?; chmod 2750 "$R/tokens"
newtok="$(python3 -I -c 'import json,sys; t=[r["token"] for r in map(json.loads, open(sys.argv[1])) if r.get("status") == 201]; print(t[-1])' api.log)"
[ "$rc" != 0 ] && [ "$(val tok-git-rw)" = "$cur" ] && [ "$(minted)" -gt "$n" ] && ! grep -q "\"revoked\": \"$(base64 -d <<< "${cur#Basic }" | cut -d: -f2)\"" api.log \
  && grep -q "\"revoked\": \"$newtok\"" api.log && ok "a token that can't be installed: revoked at once; the working one kept, not revoked" || fail "failed install (rc $rc)"
# A changed line whose mint fails: the old line's token is not kept (unavailable), and is revoked.
sed -i 's/^\(token tok-api-ro .* perms contents=read,issues=read\),pull_requests=read /\1 /' "$E/mint.conf"
grep -q '^token tok-api-ro .* perms contents=read,issues=read format' "$E/mint.conf" || fail "the test's line change did not take"
old="$(val tok-api-ro)"; touch api.log.fail; mint run >/dev/null 2>&1; rm -f api.log.fail
[ "$(val tok-api-ro)" = "airlock-envoy-unavailable example-app" ] && compgen -G "$R/minted/tok-api-ro.prev.*" >/dev/null && ok "a changed line that fails to mint: unavailable, the old scope's token retired" || fail "changed line kept the old token: $(val tok-api-ro)"
sleep 3; mint run >/dev/null 2>&1
grep -q "\"revoked\": \"${old#token }\"" api.log && ok "...and revoked after its grace" || fail "the old scope's token not revoked"
# A line gone from mint.conf: its token revoked, its file and records removed.
gone="$(val tok-new)"; sed -i '/^token tok-new /d' "$E/mint.conf"; mint run >/dev/null 2>&1
grep -q "\"revoked\": \"${gone#token }\"" api.log && [ ! -e "$R/tokens/tok-new.yaml" ] && [ ! -e "$R/minted/tok-new" ] && ! compgen -G "$R/minted/tok-new.prev.*" >/dev/null \
  && ok "a line gone: its token revoked, its file and records gone" || fail "sweep"
# Locked while a run mints (the API slow): the run neither installs nor keeps the new token.
cp app.pem "$R/keys/pass-app.pem"; echo 2 > api.log.delay; n="$(minted)"
mint run >/dev/null 2>&1 & bg=$!; sleep 0.7; rm -f "$R/keys/pass-app.pem"; wait "$bg"; rm -f api.log.delay
lt="$(python3 -I -c 'import json,sys; t=[r["token"] for r in map(json.loads, open(sys.argv[1])) if r.get("status") == 201]; print(t[-1])' api.log)"
[ "$(minted)" -gt "$n" ] && [ "$(val tok-locked)" = "airlock-envoy-locked pass-app" ] && grep -q "\"revoked\": \"$lt\"" api.log \
  && ok "locked mid-run: the token minted meanwhile is revoked, not installed" || fail "locked mid-run: $(val tok-locked)"
# The owner: a line of another owner than the App's org is not minted.
printf 'token tok-other app org-app owner other-org repos tools perms contents=read format token\n' >> "$E/mint.conf"
mint run >/dev/null 2>&1
[ "$(val tok-other)" = "airlock-envoy-unavailable org-app" ] && ok "a line of another owner than the App's org: unavailable" || fail "owner: $(val tok-other)"
# ...and a token it had (the line's owner changed) is retired, then revoked.
sed -i 's/^token tok-other app org-app owner other-org/token tok-other app org-app owner example-org/' "$E/mint.conf"; mint run >/dev/null 2>&1; ot="$(val tok-other)"
sed -i 's/^token tok-other app org-app owner example-org/token tok-other app org-app owner other-org/' "$E/mint.conf"; mint run >/dev/null 2>&1; sleep 3; mint run >/dev/null 2>&1
grep -q "\"revoked\": \"${ot#token }\"" api.log && ok "...its token from before the change revoked" || fail "owner change: old token not revoked"
grep -v tok-other "$E/mint.conf" > "$work/c.tmp"; mv "$work/c.tmp" "$E/mint.conf"; mint run >/dev/null 2>&1
# A line moved to an App that doesn't exist: its old token retired, then revoked.
printf 'token tok-mv app example-app owner example-org repos tools perms contents=read format token\n' >> "$E/mint.conf"; mint run >/dev/null 2>&1; mv1="$(val tok-mv)"
sed -i 's/^token tok-mv app example-app/token tok-mv app no-such-app/' "$E/mint.conf"; mint run >/dev/null 2>&1; sleep 3; mint run >/dev/null 2>&1
[ "$(val tok-mv)" = "airlock-envoy-unavailable no-such-app" ] && grep -q "\"revoked\": \"${mv1#token }\"" api.log && ok "a line moved to a missing App: unavailable, its old token revoked" || fail "moved to a missing App"
sed -i '/tok-mv/d' "$E/mint.conf"; mint run >/dev/null 2>&1
# state: what root asks instead of reading these files.
[ "$(mint state tok-git-rw)" = minted ] && [ "$(mint state tok-locked)" = locked ] && [ "$(mint state no-such)" = missing ] \
  && mkfifo "$R/tokens/tok-fifo.yaml" && [ "$(timeout 5 "$work/bin/airlock-envoy-mint" state tok-fifo)" = missing ] && rm -f "$R/tokens/tok-fifo.yaml" \
  && ok "state: minted, locked, missing; a FIFO is missing, not read" || fail "state"
# mark: what root has the mint account do.
mint mark tok-git-rw locked example-app && [ "$(val tok-git-rw)" = "airlock-envoy-locked example-app" ] && ! mint mark 'x y' locked a 2>/dev/null \
  && ok "mark: sets locked; refuses a bad name" || fail "mark"
age; mint run >/dev/null 2>&1

# Replaced twice while GitHub won't revoke: both are queued, and both revoked once it will.
printf 'token tok-q app example-app owner example-org repos tools perms contents=read format token\n' >> "$E/mint.conf"
mint run >/dev/null 2>&1; q1="$(val tok-q)"
touch api.log.delfail
sed -i 's/^\(token tok-q .* perms contents=read\) format/\1,issues=read format/' "$E/mint.conf"; mint run >/dev/null 2>&1; q2="$(val tok-q)"
sed -i 's/^\(token tok-q .* perms contents=read,issues=read\) format/\1,pull_requests=read format/' "$E/mint.conf"; sleep 3; mint run >/dev/null 2>&1
rm -f api.log.delfail; sleep 3; mint run >/dev/null 2>&1
grep -q "\"revoked\": \"${q1#token }\"" api.log && grep -q "\"revoked\": \"${q2#token }\"" api.log && ! compgen -G "$R/minted/tok-q.prev.*" >/dev/null \
  && ok "replaced twice while revoking fails: both queued, both revoked later" || fail "a replaced token was lost: $(ls "$R/minted")"
# A run stopped after installing a token but before keeping its record: the next run settles it.
cur="$(val tok-q)"; printf 'example-app %s' "${cur#token }" > "$R/minted/.tok-q.new"; mv "$R/minted/tok-q" "$work/tok-q.rec"
mint run >/dev/null 2>&1
[ "$(cut -d' ' -f2 "$R/minted/tok-q")" = "${cur#token }" ] && [ ! -e "$R/minted/.tok-q.new" ] && ok "a pending record of the installed token: adopted" || fail "pending adopt"
printf 'example-app ghs_neverinstalledneverinstalled' > "$R/minted/.tok-q.new"; mint run >/dev/null 2>&1
[ ! -e "$R/minted/.tok-q.new" ] && grep -q '"revoke_unknown": "ghs_neverinstalledneverinstalled"' api.log && ok "a pending record of another token: revoked" || fail "pending revoke"
sed -i '/tok-q/d' "$E/mint.conf"; mint run >/dev/null 2>&1

# check: the installation (id, selection, permissions, installed repos) against the lines.
out="$(mint check 2>&1)"; rc=$?
[ "$rc" = 1 ] && [[ "$out" == *"app example-app: installation 678 on example-org, selected repositories, permissions contents=write, issues=write, metadata=read, pull_requests=read"* ]] \
  && [[ "$out" == *"installed repos: docs filed site tools wiki"* ]] \
  && [[ "$out" == *"error: line tok-api-rw asks for pull_requests=write, the App grants read"* ]] && [[ "$out" != *"tok-git-rw asks"* ]] \
  && [[ "$out" == *"app pass-app: key locked"* ]] \
  && ok "check: the installation, its repos, the line asking for more (rc 1)" || fail "check (rc $rc): $out"
python3 -I -c 'import json,sys; t={r.get("token") for r in map(json.loads, open(sys.argv[1])) if r.get("request") == {"permissions": {"metadata": "read"}}}; v={r.get("revoked") for r in map(json.loads, open(sys.argv[1]))}; sys.exit(0 if t and t <= v else 1)' api.log \
  && ok "check: its metadata-only token revoked once used" || fail "check's token not revoked"
printf 'tools\ndocs\n' > api.log.repos
printf '{"contents": "write", "issues": "write", "metadata": "read", "pull_requests": "write", "workflows": "write", "organization_secrets": "read", "actions": "write"}' > api.log.perms
out="$(mint check 2>&1)"; rc=$?
[ "$rc" = 1 ] && [[ "$out" == *"error: line tok-git-rw names site, which the App isn't installed on"* ]] && [[ "$out" != *"asks for pull_requests=write"* ]] \
  && [[ "$out" == *"warning: the App has workflows=write"* ]] && [[ "$out" == *"warning: the App has organization_secrets=read"* ]] && [[ "$out" == *"warning: the App has actions=write"* ]] \
  && ok "check: a repo it isn't installed on is an error; workflows, organization_*, actions=write warned" || fail "check 2 (rc $rc): $out"
printf 'tools\nsite\ndocs\nwiki\n' > api.log.repos; rm -f api.log.perms
grep -v 'pull_requests=write\|pass-app' "$E/mint.conf" > "$work/fits.conf"
out="$(mint check --conf "$work/fits.conf" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "check --conf: lines that fit, rc 0" || fail "check fits (rc $rc): $out"
grep 'pass-app' "$E/mint.conf" > "$work/locked.conf"
out="$(mint check --conf "$work/locked.conf" 2>&1)"; rc=$?
[ "$rc" = 3 ] && ok "check: a locked key: not checked, rc 3" || fail "check locked (rc $rc): $out"
printf 'token tok-o app example-app owner other-org repos tools perms contents=read format token\n' > "$work/owner.conf"
out="$(mint check --conf "$work/owner.conf" 2>&1)"; rc=$?
[ "$rc" = 1 ] && [[ "$out" == *"error: line tok-o names repos of other-org, the App is installed on example-org"* ]] && ok "check: a line of another owner is an error" || fail "check owner (rc $rc): $out"

# check's own token, when its revoke fails, is left recorded and revoked by the next run.
touch api.log.delfail; mint check --conf "$work/fits.conf" >/dev/null 2>&1; rm -f api.log.delfail
compgen -G "$R/minted/.check.*" >/dev/null && { mint run >/dev/null 2>&1; ! compgen -G "$R/minted/.check.*" >/dev/null; } \
  && ok "check's token, not revoked at once, is recorded and revoked by the next run" || fail "check's record"
# An unknown installation account: not checked (rc 3), not an error.
touch api.log.noaccount; mint check --conf "$work/fits.conf" >/dev/null 2>&1; rc=$?; rm -f api.log.noaccount
[ "$rc" = 3 ] && ok "check: no account in GitHub's answer: rc 3" || fail "unknown login rc $rc"
# A file key gone: its token retired and revoked.
printf 'token tok-fk app org-app owner example-org repos tools perms contents=read format token\n' >> "$E/mint.conf"; mint run >/dev/null 2>&1; fk="$(val tok-fk)"
mv "$E/apps/org-app.pem" "$work/org-app.pem"; mint run >/dev/null 2>&1; sleep 3; mint run >/dev/null 2>&1; mv "$work/org-app.pem" "$E/apps/org-app.pem"
grep -q "\"revoked\": \"${fk#token }\"" api.log && ok "a file key gone: its line's token retired and revoked" || fail "no key file: not revoked"
sed -i '/tok-fk/d' "$E/mint.conf"; mint run >/dev/null 2>&1

# GitHub's answer is read strictly: a token of odd characters is no token (the line stays as it was).
printf 'token tok-odd app example-app owner example-org repos tools perms contents=read format token\n' >> "$E/mint.conf"
touch api.log.badtoken; mint run >/dev/null 2>&1; rm -f api.log.badtoken
[ "$(val tok-odd)" = "airlock-envoy-unavailable example-app" ] && ! grep -q 'x\\"' "$R/tokens/tok-odd.yaml" && ok "a token of odd characters in GitHub's answer is refused" || fail "odd token: $(val tok-odd)"
sed -i '/tok-odd/d' "$E/mint.conf"

# No token in an argv: curl reads headers and body from stdin.
! grep -q 'Authorization: \$\|-H "Authorization' "$repo/install/airlock-envoy-mint" && grep -q -- '-K -' "$repo/install/airlock-envoy-mint" \
  && ok "curl takes the Authorization from stdin (-K -), never from its argv" || fail "argv"

echo "failures: $fails"
exit "$fails"
