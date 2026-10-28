#!/bin/bash
# Every test, as fast as this machine allows: the install test on each distribution at once,
# and alongside them shellcheck, the site-details checks, the parser, t2 and the site checks
# (in turn: they share one test Envoy).
# Prints each suite's result and time; exits non-zero if any failed. Logs stay in a temp dir.
# Usage: test/run-all.sh [distro...]     default: arch debian ubuntu-26.04
#   OLD_REPO=<earlier checkout> and AIRLOCK_REPO=<claude-airlock checkout> reach install-test.sh.
#   SHELLCHECK=<path> if shellcheck is not on PATH (skipped, and said so, if not found).
set -u
cd "$(dirname "$0")/.." || exit
distros=("$@")
[ ${#distros[@]} -gt 0 ] || distros=(arch debian ubuntu-26.04)
logs="$(mktemp -d /tmp/airlock-envoy-tests.XXXXXX)"
t0=$EPOCHREALTIME
secs() { awk -v a="$1" -v b="$EPOCHREALTIME" 'BEGIN { printf "%.1f", b - a }'; }
run() {  # run <name> <cmd...>: output to <name>.log; rc and seconds to <name>.result
  local name=$1 s=$EPOCHREALTIME rc; shift
  "$@" > "$logs/$name.log" 2>&1; rc=$?
  echo "$rc $(secs "$s")" > "$logs/$name.result"
}
with_envoy() {  # with_envoy <name> <site file or ""> <checks script>
  if test/run-envoy.sh ${2:+"$2"} > "$logs/$1.log" 2>&1; then run "$1" "$3"
  else echo "1 0" > "$logs/$1.result"; fi
  podman stop --ignore airlock-envoy-spike airlock-envoy-web-spike >/dev/null 2>&1 || true
}
order=()
for d in "${distros[@]}"; do run "install-$d" test/install-test.sh "$d" & order+=("install-$d"); done
# shellcheck disable=SC2329  # run via run()
lint() {
  local sc="${SHELLCHECK:-$(command -v shellcheck)}"
  [ -n "$sc" ] || { echo "skipped: no shellcheck (set SHELLCHECK=)"; return 3; }
  "$sc" install/*.sh install/airlock-envoy-apply install/airlock-envoy-cred test/*.sh test/client/entry.sh \
    scripts/private-names-check hooks/* && echo "ok   shellcheck"
}
# shellcheck disable=SC2329  # run via run()
names() {  # no site details in the tracked files (this repo is public; the patterns are private)
  local rc=0; scripts/private-names-check --tree HEAD || rc=$?
  [ "$rc" = 2 ] && { echo "skipped: no private pattern list (scripts/private-names-check)"; return 3; }
  [ "$rc" = 0 ] && echo "ok   no site details in the tree"
  return "$rc"
}
# shellcheck disable=SC2329  # run via run()
graphql() {  # the GitHub GraphQL write check, under LuaJIT as in Envoy
  command -v luajit >/dev/null || { echo "skipped: no luajit"; return 3; }
  luajit test/graphql-check.lua
}
# shellcheck disable=SC2329  # run via run()
protect() {  # the push check of protected branches: its parser under LuaJIT, then end to end
  command -v luajit >/dev/null || { echo "skipped: no luajit"; return 3; }
  luajit test/git-protect-check.lua && test/protect-e2e.sh
}
{ run shellcheck lint
  run private-names names
  run private-names-check test/private-names-check-test.sh
  run apply-parse test/apply-parse.sh
  run graphql graphql
  run protect protect
  run cred-backends test/cred-backends.sh
  run cred-e2e test/cred-e2e.sh
  with_envoy t2 test/t2.conf test/t2-checks.sh
  with_envoy site-checks test/site.conf test/site-checks.sh
} &
order=(shellcheck private-names private-names-check apply-parse graphql protect cred-backends cred-e2e t2 site-checks "${order[@]}")
wait
failed=0
for name in "${order[@]}"; do
  read -r rc s < "$logs/$name.result" || { rc=1 s='?'; }
  case "$rc" in 0) st=ok ;; 3) st=skip ;; *) st=FAIL; failed=1 ;; esac   # 3: a tool missing, skipped
  printf '%-4s %-24s %6s s  %s\n' "$st" "$name" "$s" "$(grep -c '^ok' "$logs/$name.log") checks ok"
  case "$rc" in 0|3) ;; *) grep -E '^FAIL' "$logs/$name.log" | sed 's/^/       /' ;; esac
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || grep -q '^FAIL' "$logs/$name.log" || tail -3 "$logs/$name.log" | sed 's/^/       /'
done
echo "total $(secs "$t0") s; logs: $logs"
exit "$failed"
