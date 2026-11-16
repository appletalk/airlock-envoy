#!/bin/bash
# install/install-all.sh (make install), with stubs for sudo, Envoy, airlock-envoy-apply and the
# two installers it calls: the steps in order, a current Envoy skipped, YES=1, no terminal refused.
# Usage: test/install-all.sh
# shellcheck disable=SC2016,SC2034  # checks and stubs are single-quoted on purpose
set -u
cd "$(dirname "$0")/.." || exit
t="$(mktemp -d /tmp/install-all-test.XXXXXX)"; trap 'rm -rf "$t"' EXIT
fails=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
mkdir -p "$t/repo/install" "$t/bin"
cp install/install-all.sh "$t/repo/install/"; echo 1.40.2 > "$t/repo/ENVOY_VERSION"
export CALLS="$t/calls"
printf '#!/bin/bash\necho "install-envoy.sh $*" >> "$CALLS"\n' > "$t/repo/install/install-envoy.sh"
printf '#!/bin/bash\necho "install-service.sh $*" >> "$CALLS"\n' > "$t/repo/install/install-service.sh"
printf '#!/bin/bash\necho "sudo $*" >> "$CALLS"\nexec "$@"\n' > "$t/bin/sudo"
printf '#!/bin/bash\necho "envoy  version: abc/${HAVE:-1.40.2}/Clean/RELEASE/BoringSSL"\n' > "$t/bin/envoy"
printf '#!/bin/bash\necho "apply $*" >> "$CALLS"\n' > "$t/bin/apply"
chmod +x "$t"/repo/install/* "$t"/bin/*
export PATH="$t/bin:$PATH" AIRLOCK_ENVOY_BIN="$t/bin/envoy" AIRLOCK_ENVOY_APPLY="$t/bin/apply"
s="$t/repo/install/install-all.sh"

: > "$CALLS"; out="$(YES=1 bash "$s" </dev/null 2>&1)"; rc=$?
ck "Envoy at the pin: skipped, said so; the service installed; the status shown" \
   '[ "$rc" = 0 ] && [[ "$out" == *"Envoy 1.40.2: already installed"* ]] && [ "$(cat "$CALLS")" = "$(printf "sudo bash %s\ninstall-service.sh \napply --status" "$t/repo/install/install-service.sh")" ]'
: > "$CALLS"; out="$(HAVE=1.39.0 YES=1 bash "$s" </dev/null 2>&1)"; rc=$?
ck "an older Envoy: install-envoy.sh with the pinned version, before the service" \
   '[ "$rc" = 0 ] && [ "$(head -2 "$CALLS")" = "$(printf "sudo bash %s 1.40.2\ninstall-envoy.sh 1.40.2" "$t/repo/install/install-envoy.sh")" ] && grep -q "^install-service.sh" "$CALLS"'
: > "$CALLS"; out="$(HAVE=1.39.0 setsid -w bash "$s" </dev/null 2>&1)"; rc=$?
ck "no terminal and no YES: refused before anything runs" '[ "$rc" != 0 ] && [[ "$out" == *"YES=1"* ]] && [ ! -s "$CALLS" ]'
echo "x.y" > "$t/repo/ENVOY_VERSION"; out="$(YES=1 bash "$s" </dev/null 2>&1)"; rc=$?
ck "a malformed ENVOY_VERSION is refused" '[ "$rc" != 0 ] && [[ "$out" == *"must look like"* ]]'
echo 1.40.2 > "$t/repo/ENVOY_VERSION"
ck "make install runs it, passing YES" 'grep -A1 "^install:" Makefile | grep -q "YES=\"\$(YES)\" bash install/install-all.sh"'
ck "ENVOY_VERSION is a version, the same CI installs" 'grep -qxE "[0-9]+\.[0-9]+\.[0-9]+" ENVOY_VERSION && grep -qx "  ENVOY_VERSION: $(cat ENVOY_VERSION)" .github/workflows/ci.yml'
# A terminal: n skips a step, q stops (script(1) gives it one; answers on stdin).
if command -v script >/dev/null; then
  : > "$CALLS"; out="$(HAVE=1.39.0 script -qec "bash $s" /dev/null <<< $'n\nq\n' 2>&1)"; rc=$?
  ck "asks before each step: n skips the Envoy step, q stops before the service" \
     '[ "$rc" = 0 ] && [[ "$out" == *"stopped; rerun make install"* ]] && [ ! -s "$CALLS" ]'
  : > "$CALLS"; out="$(HAVE=1.39.0 script -qec "bash $s" /dev/null <<< $'y\nn\n' 2>&1)"; rc=$?
  ck "y runs the Envoy step, n skips the service" \
     'grep -q "^install-envoy.sh 1.40.2" "$CALLS" && ! grep -q "^install-service.sh" "$CALLS"'
fi
# A clone with local changes stops before the first sudo.
git -C "$t/repo" init -q && git -C "$t/repo" add -A && git -C "$t/repo" -c user.email=t@example.org -c user.name=t commit -qm x
echo "# edited" >> "$t/repo/install/install-service.sh"
: > "$CALLS"; out="$(YES=1 bash "$s" </dev/null 2>&1)"; rc=$?
ck "a clone with local changes stops before the first root step" \
   '[ "$rc" != 0 ] && [[ "$out" == *"has local changes"* ]] && ! grep -q "^sudo" "$CALLS"'
git -C "$t/repo" checkout -q install/install-service.sh
ck "refuses to run as root (the check is first)" 'grep -q "run it as yourself" install/install-all.sh'
[ "$fails" = 0 ] && echo "ok   install-all: all checks passed"
exit $(( fails > 0 ))
