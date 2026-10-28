#!/bin/bash
# Lint every shell script in the repo with shellcheck.
# Usage: test/lint.sh     SHELLCHECK=<path> if shellcheck is not on PATH (exits 3, skipped, if not found)
set -u
cd "$(dirname "$0")/.." || exit
sc="${SHELLCHECK:-$(command -v shellcheck)}"
[ -n "$sc" ] || { echo "skipped: no shellcheck (set SHELLCHECK=)"; exit 3; }
"$sc" install/*.sh install/airlock-envoy-apply install/airlock-envoy-cred install/airlock-envoy-mint test/*.sh test/client/entry.sh \
  scripts/private-names-check hooks/* && echo "ok   shellcheck"
