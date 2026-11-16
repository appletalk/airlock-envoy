#!/usr/bin/env bash
# make install: everything airlock-envoy puts on this host, in order, as the user who works here
# (sudo for each step). Safe to rerun: a step with nothing to do says so.
#
#   make install          says what each step does and asks [Y/n/q] before it (n skips it,
#                         q stops); a step already current skips itself
#   make install YES=1    every step, no questions
#
# The steps:
#   1. Envoy at the pinned version (ENVOY_VERSION)  (sudo install/install-envoy.sh <version>)
#   2. the service and its units, then an apply     (sudo install/install-service.sh: re-applies
#                                                     /etc/airlock-envoy/site.conf and restarts
#                                                     Envoy: open tunnels drop, box sockets stay)
#   3. the result                                   (airlock-envoy-apply --status)
# Then claude-airlock's make install, if this host runs it.
#
# The root steps install code, the release key and the built-in allowlist from this clone: run it
# from a clone no airlock box mounts. Before the first sudo it checks the clone has no local
# changes and stops if it has.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVOY_BIN="${AIRLOCK_ENVOY_BIN:-/usr/local/bin/envoy}"   # test hook: a stub Envoy
APPLY="${AIRLOCK_ENVOY_APPLY:-/usr/local/sbin/airlock-envoy-apply}"   # test hook
YES="${YES:-}"
[ "$(id -u)" != 0 ] || { echo "make install: run it as yourself (it uses sudo where it must)" >&2; exit 1; }
ver="$(tr -d '[:space:]' < "$REPO_DIR/ENVOY_VERSION")"
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "make install: ENVOY_VERSION must look like 1.40.2, not '$ver'" >&2; exit 1; }

n=0
# ask <what>: 0 to run the step, 1 to skip it; q stops everything.
ask() {
    n=$((n + 1))
    printf '\n==> %d. %s\n' "$n" "$1"
    [ "$YES" != 1 ] || return 0
    { exec 3</dev/tty; } 2>/dev/null || { echo "make install: no terminal to ask on; rerun with YES=1 to answer yes to every step" >&2; exit 1; }
    local a
    read -r -u 3 -p "    run it? [Y/n/q] " a || a=q
    exec 3<&-
    case "$a" in ''|[yY]*) return 0 ;; [qQ]*) echo "stopped; rerun make install to go on"; exit 0 ;; *) echo "    skipped"; return 1 ;; esac
}

# Before the first root step: no local changes in the clone (they would be what root installs).
checked=0
clean_checkout() {
    [ "$checked" = 0 ] || return 0
    checked=1
    echo "    (root installs from $REPO_DIR: use a clone no airlock box mounts)"
    if ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        echo "    (not a git checkout: local changes can't be checked)"; return 0
    fi
    local dirty; dirty="$(git -C "$REPO_DIR" status --porcelain --untracked-files=all 2>/dev/null)" || dirty="(git status failed)"
    if [ -n "$dirty" ]; then
        echo "make install: $REPO_DIR has local changes; the root steps would install them. Commit, stash or check them out first:" >&2
        printf '%s\n' "$dirty" | head -n 10 >&2
        exit 1
    fi
}

have="$("$ENVOY_BIN" --version 2>/dev/null | grep -oE '/[0-9]+\.[0-9]+\.[0-9]+/' | tr -d / || true)"
if [ "$have" = "$ver" ]; then
    n=$((n + 1)); printf '\n==> %d. Envoy %s: already installed\n' "$n" "$ver"
elif ask "Envoy ${have:-(none)} -> $ver, the pinned version (sudo install/install-envoy.sh $ver)"; then
    clean_checkout
    sudo bash "$REPO_DIR/install/install-envoy.sh" "$ver"
fi

if ask "the service and its units, then an apply (sudo install/install-service.sh; restarts Envoy: open tunnels drop, box sockets stay)"; then
    clean_checkout
    sudo bash "$REPO_DIR/install/install-service.sh"
fi

if [ -x "$APPLY" ]; then
    n=$((n + 1)); printf '\n==> %d. the result\n' "$n"
    "$APPLY" --status || true
fi
echo; echo "==> make install: done (next, on a host with claude-airlock: make install there)"
