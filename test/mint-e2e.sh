#!/bin/bash
# GitHub App credentials end to end: a rendered config in a real Envoy; test/fake-github-app.py as
# both GitHub's App API and the upstream (it echoes the Authorization it gets and whether that
# token is live); airlock-envoy-apply, -cred and -mint as copies with their paths under a scratch
# directory, and stubs for id, sudo, pass and systemctl (whose "start airlock-envoy-mint.service"
# runs the mint copy, as systemd would). Runs as any user, no podman or root.
# Needs envoy, python3, openssl, curl. Exits non-zero if any check fails.
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
UP=18743 PX=18201
cd "$work" || exit

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.pem -days 2 -subj /CN=test-ca 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout srv.key -out srv.csr -subj /CN=api.example.com 2>/dev/null
printf 'subjectAltName=DNS:api.example.com,IP:127.0.0.1\n' > san.ext
openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out srv.pem -days 2 -extfile san.ext 2>/dev/null
openssl genrsa -out app.pem 2048 2>/dev/null; openssl rsa -in app.pem -pubout -out app.pub 2>/dev/null
python3 -I "$repo/test/fake-github-app.py" "$UP" srv.pem srv.key app.pub 12345 678 "$work/api.log" 2> api.err & pids+=($!)

# The three tools, their paths here (see cred-backends.sh and mint.sh).
E=$work/etc R=$work/run
mkdir -p "$E/credentials" "$E/ca" "$E/mint/apps" "$R/mint/tokens" "$R/mint/keys" "$R/mint/minted" "$R/mint/installations" bin store/work
: > "$R/mint/.lock"   # the layout tmpfiles.d makes
# shellcheck disable=SC2016  # the $ in the patterns is the tools' own text
sed -e "s#^DIR=/etc/airlock-envoy/credentials#DIR=$E/credentials#" -e "s#^PASS_DIR=/etc/airlock-envoy/pass#PASS_DIR=$E/pass#" \
    -e "s#^ENVOY_YAML=/etc/airlock-envoy/envoy.yaml#ENVOY_YAML=$work/rendered.yaml#" -e "s#^RUN=/run/airlock-envoy-cred#RUN=$R/cred#" \
    -e "s#^APPS=/etc/airlock-envoy-mint/apps#APPS=$E/mint/apps#" -e "s#^MINT_CONF=/etc/airlock-envoy-mint/mint.conf#MINT_CONF=$E/mint/mint.conf#" \
    -e "s#^MRUN=/run/airlock-envoy-mint#MRUN=$R/mint#" \
    -e 's#chown "root:$grp" "$tmp"; ##' -e 's# -o root -g root##g' -e 's# -o root -g "$grp"##g' \
    -e 's# -o "$MINT_USER" -g "$MINT_USER"##g' -e 's# -o "$MINT_USER" -g "$grp"##g' -e 's# -o root -g "$MINT_USER"##g' \
    -e 's#chown "$MINT_USER:$grp" "$tmp"; ##' -e 's#chown "$MINT_USER:$MINT_USER" "$tmp"; ##' -e 's#chown "root:$MINT_USER" "\([^"]*\)"; ##' \
    "$repo/install/airlock-envoy-cred" > bin/airlock-envoy-cred
sed -e "s#^CONF=/etc/airlock-envoy-mint/mint.conf#CONF=$E/mint/mint.conf#" -e "s#^APPS=/etc/airlock-envoy-mint/apps#APPS=$E/mint/apps#" \
    -e "s#^RUN=/run/airlock-envoy-mint#RUN=$R/mint#" "$repo/install/airlock-envoy-mint" > bin/airlock-envoy-mint
sed -e "s#^MINT_APPS=/etc/airlock-envoy-mint/apps#MINT_APPS=$E/mint/apps#" -e "s#^PASS_DIR=/etc/airlock-envoy/pass#PASS_DIR=$E/pass#" \
    "$repo/install/airlock-envoy-apply" > bin/airlock-envoy-apply
cp "$repo/install/git-protect.lua" "$repo/install/github-graphql.lua" bin/
# shellcheck disable=SC2016  # scripts' text
{
printf '#!/bin/sh\n[ "$1" = -u ] && { echo "${FAKE_UID:-1000}"; exit 0; }\n[ "$1" = airlock-envoy-mint ] && exit 0\nexec /usr/bin/id "$@"\n' > bin/id
printf '#!/bin/sh\n[ "$1" = -- ] && shift\nFAKE_UID=0 exec "$@"\n' > bin/sudo
printf '#!/bin/sh\n[ "$1" = show ] && [ "$2" = -- ] || exit 2\ncat "%s/store/$3"\n' "$work" > bin/pass
# systemctl: a start of the mint service runs it, as systemd would; --no-block only queues it
# (run_queued below runs it), so what happens before that run can be seen.
printf '#!/bin/sh\necho "$*" >> %s/systemctl.log\ncase "$*" in *--no-block*airlock-envoy-mint.service*) touch %s/mint.queued ;; *airlock-envoy-mint.service*) FAKE_UID=1001 %s/bin/airlock-envoy-mint run 2>> %s/mint.log ;; esac\nexit 0\n' "$work" "$work" "$work" "$work" > bin/systemctl
printf '#!/bin/sh\nwhile [ "$1" != -- ]; do shift; done; shift\nFAKE_UID=1001 exec "$@"\n' > bin/setpriv   # the mint account
}
chmod +x bin/*
for f in airlock-envoy-cred airlock-envoy-mint airlock-envoy-apply; do ! grep -q '^\(DIR\|CONF\|APPS\|MINT_APPS\|RUN\|MRUN\)=/etc\|^\(RUN\|MRUN\)=/run' "bin/$f" || { echo "FAIL $f: a path not moved"; exit 1; }; done
export PATH="$work/bin:$PATH"
run_queued() { [ ! -e "$work/mint.queued" ] || { rm -f "$work/mint.queued"; FAKE_UID=1001 airlock-envoy-mint run 2>> "$work/mint.log"; }; }
cred() { airlock-envoy-cred "$@"; }
root() { FAKE_UID=0 airlock-envoy-cred "$@"; }

cp app.pem store/work/app-key
FAKE_UID=0 airlock-envoy-cred add-app example-app --app-id 12345 --org example-org --key pass:work/app-key --api "https://127.0.0.1:$UP" >/dev/null \
  || { echo "FAIL add-app"; exit 1; }
FAKE_UID=0 airlock-envoy-cred add-app file-app --app-id 12345 --installation-id 678 --key file --api "https://127.0.0.1:$UP" < app.pem >/dev/null \
  || { echo "FAIL add-app file"; exit 1; }
# The test's CA (add-app takes one under /etc or /usr only, where the unit's sandbox reads it).
printf 'ca %s\n' "$work/ca.pem" | tee -a "$E/mint/apps/example-app" >> "$E/mint/apps/file-app"
cat > site <<EOF
http api.example.com:$UP@ex rules github-api ca test credential example-app repos example-org/tools repos-read example-org/docs
http api.example.com:$UP@f rules github-api ca test credential file-app repos example-org/filed
b http://api.example.com@ex http://api.example.com@f
client b t
EOF
airlock-envoy-apply --render-mint site > "$E/mint/mint.conf" && airlock-envoy-apply --render site > rendered.yaml || { echo "FAIL render"; exit 1; }
[ "$(grep -c '^token ' "$E/mint/mint.conf")" = 3 ] && ok "mint.conf: a write and a read token for example-app's line, one for file-app's" || fail "mint.conf: $(cat "$E/mint/mint.conf")"
root boot; run_queued   # each token's file before Envoy reads the config (locked, unavailable), then a mint run
sed -e "s#/run/airlock-envoy-internal/#$work/#" -e "s#/etc/airlock-envoy/ca/test.pem#$work/ca.pem#" \
    -e "s#/run/airlock-envoy-mint/tokens#$R/mint/tokens#g" \
    -e "s#address: \"api.example.com\", port_value#address: \"127.0.0.1\", port_value#" \
    -e "s#path: /var/log/airlock-envoy/access.jsonl#path: $work/access.jsonl#" rendered.yaml > envoy.yaml
# Envoy as the units run it: under MemoryDenyWriteExecute (test/mdwe-exec.py), so a Lua filter
# that lets LuaJIT compile panics here as on a host; one worker, so a few hundred requests make
# its code hot.
# REQUIRE_MDWE=1 (CI) makes a kernel without it a failure, not a skip.
mdwe=(python3 -I "$repo/test/mdwe-exec.py") under="under MemoryDenyWriteExecute"
"${mdwe[@]}" true 2>/dev/null; rc=$?
if [ "$rc" = 3 ] && [ "${REQUIRE_MDWE:-}" != 1 ]; then
  echo "skip MemoryDenyWriteExecute: the kernel lacks PR_SET_MDWE (Linux 6.3+); Envoy runs without it"; mdwe=() under="WITHOUT MemoryDenyWriteExecute"
elif [ "$rc" != 0 ]; then echo "FAIL test/mdwe-exec.py true: exit $rc"; exit 1; fi
"${mdwe[@]}" envoy -c envoy.yaml --concurrency 1 --disable-hot-restart -l warn --base-id-path "$work/base-id" > envoy.log 2>&1 & pids+=($!)
envoy_pid=$!
for _ in $(seq 50); do [ -S b.sock ] && break; sleep 0.1; done
[ -S b.sock ] || { echo "FAIL envoy did not start"; cat envoy.log; exit 1; }
socat TCP-LISTEN:$PX,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:b.sock 2>/dev/null & pids+=($!)
sleep 0.3
get() { curl -s -i --max-time 5 -x "http://127.0.0.1:$PX" "http://api.example.com/repos/example-org/$1"; }
auth_of() { sed -n 's/.*"authorization": "\([^"]*\)".*/\1/p' <<< "$1"; }
settle() { sleep 1.5; }

settle
out="$(get tools)"
[[ "$out" == "HTTP/1.1 423"* ]] && [[ "$out" == *"credential example-app is locked on this host"* ]] && ok "pass-key App locked: 423 naming the App, nothing upstream" || fail "locked: $out"
out="$(get filed)"
[[ "$out" == "HTTP/1.1 200"* ]] && [[ "$(auth_of "$out")" == "token ghs_"* ]] && [[ "$out" == *'"live": true'* ]] \
  && ok "file-key App: minted at boot's run, its line's token reaches upstream, live" || fail "file app: $out"

# unlock: the key from pass (the whole entry), a mint run, then each route its own token.
out="$(cred unlock 2>&1)"
[[ "$out" == *"unlocked"*"example-app"* ]] && ok "unlock: the App key from pass, minted before it says unlocked" || fail "unlock: $out"
settle
t1="$(get tools)"; t2="$(get docs)"
[[ "$t1" == "HTTP/1.1 200"* && "$t1" == *'"live": true'* ]] && [[ "$t2" == "HTTP/1.1 200"* && "$t2" == *'"live": true'* ]] \
  && [ "$(auth_of "$t1")" != "$(auth_of "$t2")" ] && ok "unlocked: repos and repos-read routes each carry their own live token" || fail "unlocked: $t1 / $t2"
ro="$(auth_of "$t2")"
python3 -I - "$work/api.log" "${ro#token }" <<'PY' && ok "the read-only route's token was minted for docs alone, read permissions only" || fail "the ro token's request"
import json, sys
for r in map(json.loads, open(sys.argv[1])):
    if r.get("token") == sys.argv[2]:
        ok = r["request"] == {"repositories": ["docs"], "permissions": {"contents": "read", "issues": "read", "pull_requests": "read"}}
        sys.exit(0 if ok else 1)
sys.exit(1)
PY
# (file-app's key is the file in /etc by design.)
! grep -rl "BEGIN" "$E" "$R/cred" 2>/dev/null | grep -qv "/apps/file-app.pem$" && [ -f "$R/mint/keys/example-app.pem" ] \
  && ok "the unlocked key only in the mint account's tmpfs" || fail "the key elsewhere: $(grep -rl BEGIN "$E" "$R/cred" 2>/dev/null)"

# lock: 423 at once (before any mint run), the key gone; then the run revokes the tokens.
cred lock >/dev/null; settle
out="$(get tools)"
[[ "$out" == "HTTP/1.1 423"* ]] && [ ! -f "$R/mint/keys/example-app.pem" ] && [ -e "$work/mint.queued" ] \
  && ok "lock: 423 from the next request, before any mint run; the key gone" || fail "lock: $out"
run_queued
python3 -I - "$work/api.log" "$(auth_of "$t1")" "$ro" <<'PY' && ok "lock: both of the line's tokens revoked at GitHub" || fail "revocation"
import json, sys
rev = {r.get("revoked") for r in map(json.loads, open(sys.argv[1]))}
sys.exit(0 if {sys.argv[2][6:], sys.argv[3][6:]} <= rev else 1)
PY
[[ "$(get filed)" == *'"live": true'* ]] && ok "lock leaves a file-key App's token alone" || fail "lock touched the file app"

# GitHub refusing the first mint of a line: Envoy says the credential is unavailable (503).
touch api.log.fail
printf 'token tok-000000000000-rw app file-app owner example-org repos other perms contents=read format token\n' >> "$E/mint/mint.conf"
airlock-envoy-mint run 2>/dev/null
grep -q 'inline_string: "airlock-envoy-unavailable file-app"' "$R/mint/tokens/tok-000000000000-rw.yaml" && ok "a line never minted: unavailable (the 503's value)" || fail "unavailable"
rm -f api.log.fail
grep -q 'airlock-envoy-unavailable' rendered.yaml && ok "Envoy's check answers unavailable with 503" || fail "no unavailable branch in the render"

kill -0 "$envoy_pid" 2>/dev/null && ! grep -q 'PANIC\|runtime code generation failed' envoy.log \
  && ok "Envoy still running, no Lua panic ($under)" || fail "Envoy died or panicked: $(grep -m2 'PANIC\|code generation' envoy.log)"
echo "failures: $fails"
exit "$fails"
