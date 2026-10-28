#!/bin/bash
# airlock-envoy-cred's backends: pass credentials, unlock, lock, expiry, migrate. Runs as any
# user, no root: a copy of the tool with its paths moved under a scratch directory and its
# ownership changes dropped, and stubs on PATH for id (root or the operator), sudo (runs the
# command as root), pass (a store of files, logging what was read), systemctl (logging; can
# fail) and the clocks. Exits non-zero if any check fails.
# Checks read "<condition> && ok ... || fail ...": ok always succeeds.
# shellcheck disable=SC2015
set -u
cd "$(dirname "$0")/.." || exit
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails+1)); }

E=$work/etc R=$work/run
mkdir -p "$E/credentials" "$E/ca" "$work/bin" "$work/store" "$work/clock"
# shellcheck disable=SC2016  # the $ in the patterns is the tool's own text
sed -e "s#^DIR=/etc/airlock-envoy/credentials#DIR=$E/credentials#" -e "s#^CA_DIR=/etc/airlock-envoy/ca#CA_DIR=$E/ca#" \
    -e "s#^PASS_DIR=/etc/airlock-envoy/pass#PASS_DIR=$E/pass#" -e "s#^UNLOCK_CONF=/etc/airlock-envoy/unlock.conf#UNLOCK_CONF=$E/unlock.conf#" \
    -e "s#^ENVOY_YAML=/etc/airlock-envoy/envoy.yaml#ENVOY_YAML=$E/envoy.yaml#" -e "s#^RUN=/run/airlock-envoy-cred#RUN=$R#" \
    -e 's#chown "root:$grp" "$tmp"; ##' -e 's# -o root -g root##g' -e 's# -o root -g "$grp"##g' \
    -e "s#^now() { date +%s; }#now() { cat $work/clock/now 2>/dev/null || date +%s; }#" \
    -e "s#^boot_secs() { cut -d. -f1 /proc/uptime; }#boot_secs() { cat $work/clock/boot 2>/dev/null || cut -d. -f1 /proc/uptime; }#" \
    install/airlock-envoy-cred > "$work/bin/airlock-envoy-cred"
chmod +x "$work/bin/airlock-envoy-cred"
# Each rewrite above must have taken: a missed one would test the real paths or owners.
for pat in "DIR=$E/credentials" "PASS_DIR=$E/pass" "RUN=$R" "ENVOY_YAML=$E/envoy.yaml" "cat $work/clock/now" "cat $work/clock/boot"; do
  grep -qF "$pat" "$work/bin/airlock-envoy-cred" || { echo "FAIL the test copy lacks $pat"; exit 1; }
done
! grep -q 'chown "root\|-o root' "$work/bin/airlock-envoy-cred" || { echo "FAIL the test copy still changes owners"; exit 1; }

cat > "$work/bin/id" <<EOF
#!/bin/sh
[ "\$1" = -u ] && { echo "\${FAKE_UID:-1000}"; exit 0; }
exec /usr/bin/id "\$@"
EOF
cat > "$work/bin/sudo" <<EOF
#!/bin/sh
[ "\$1" = -- ] && shift
echo "\$*" >> "$work/sudo.log"
FAKE_UID=0 exec "\$@"
EOF
cat > "$work/bin/pass" <<EOF
#!/bin/sh
[ "\$1" = show ] && [ "\$2" = -- ] || exit 2
echo "\$3" >> "$work/pass.log"
[ -z "\${SLOW_PASS:-}" ] || sleep "\$SLOW_PASS"
[ "\${FAKE_UID:-1000}" != 0 ] || { echo "pass run as root" >> "$work/pass.log"; exit 3; }
cat "$work/store/\$3" 2>/dev/null || exit 1
EOF
cat > "$work/bin/systemctl" <<EOF
#!/bin/sh
[ "\$1" != stop ] || [ -z "\${SLOW_STOP:-}" ] || sleep "\$SLOW_STOP"
echo "\$*" >> "$work/systemctl.log"
if [ "\$1" = start ]; then
  # The deadline first: no secret may be in place when the timer is started.
  for f in "$R"/secrets/*.yaml; do grep -q 'inline_string: "airlock-envoy-locked ' "\$f" 2>/dev/null || { [ -e "\$f" ] && echo "SECRET BEFORE TIMER \$f" >> "$work/systemctl.log"; }; done
  # The timer firing while an unlock runs: the expiry starts now, alongside.
  [ -z "\${RACE_EXPIRE:-}" ] || { FAKE_UID=0 RACE_EXPIRE= "$work/bin/airlock-envoy-cred" expire & echo \$! > "$work/race.pid"; }
  [ -n "\${FAIL_SYSTEMCTL:-}" ] && exit 1
fi
exit 0
EOF
cat > "$work/bin/airlock-envoy-apply" <<EOF
#!/bin/sh
echo "apply \$(ls "$E/credentials" | tr '\n' ' ')" >> "$work/apply.log"
[ -z "\${FAIL_APPLY:-}" ] || exit 1
# Envoy restarted by the apply runs boot first (ExecStartPre): it must not wait on migrate.
FAKE_UID=0 timeout 5 "$work/bin/airlock-envoy-cred" boot || { echo "boot from apply failed rc=\$?" >> "$work/apply.log"; exit 1; }
exit 0
EOF
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
mkdir -p "$work/brokenbin"; printf '#!/bin/sh\ncase "$*" in *18:00*|*19:00*) exit 1 ;; esac\nexec /bin/date "$@"\n' > "$work/brokenbin/date"; chmod +x "$work/brokenbin/date"
cred() { airlock-envoy-cred "$@"; }
root() { FAKE_UID=0 airlock-envoy-cred "$@"; }
secret_of() { sed -n 's/^  generic_secret: { secret: { inline_string: "\(.*\)" } }$/\1/p' "$1"; }
# The applied config uses a credential when it reads it from $R/secrets.
uses() { for n in "$@"; do printf '                    sds_config: { path_config_source: { path: "%s/secrets/%s.yaml" } }\n' "$R" "$n"; done > "$E/envoy.yaml"; }
mkdir -p "$work/store/work"
printf 'S3CRET-ONE\nsecond line ignored\n' > "$work/store/work/gh"
printf 'S3CRET-TWO\n' > "$work/store/work/kube"
printf 'NOT-NAMED\n' > "$work/store/work/other"

# add: a pass credential, locked until unlocked.
out="$(root add gh --pass work/gh 2>&1)"
[ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && grep -q '^locked' "$R/state" && [[ "$out" == *"locked"* ]] \
  && ok "add: a pass credential starts locked" || fail "add: $out"
root add kube --pass work/kube --format token >/dev/null
for e in ../x -x .hidden a//b /abs a/ "a b" "a;b" a/-b; do
  ! root add bad --pass "$e" >/dev/null 2>&1 || fail "add accepted the entry '$e'"
done; ok "add: bad entries refused (.., -opt, dot-files, //, absolute, spaces)"
printf 'FILE-SECRET\n' | root set filecred >/dev/null
! root add filecred --pass work/gh >/dev/null 2>&1 && ok "add: a file credential's name refused (migrate it instead)" || fail "add over a file credential"
! printf 'X\n' | root set gh >/dev/null 2>&1 && ok "set: a pass credential's name refused" || fail "set over a pass credential"
! root revoke gh >/dev/null 2>&1 && ok "revoke: a pass credential refused (lock it)" || fail "revoke of a pass credential"
[[ "$(root list)" == *"gh  pass:work/gh  bearer"* && "$(root list)" == *"filecred  bearer  "* ]] && ! root list | grep -q S3CRET \
  && ok "list: file and pass credentials, no secret" || fail "list: $(root list)"

# entries: only the pass credentials the applied config uses.
uses gh
[ "$(root entries)" = "gh work/gh" ] && ok "entries: only those in use" || fail "entries: $(root entries)"
! cred entries >/dev/null 2>&1 && ok "entries: root only" || fail "entries ran as the operator"

# unlock: as the operator; reads only the named entries; installs; starts the expiry timer.
out="$(root unlock 2>&1)"; [[ "$out" == *"run unlock as yourself"* ]] && ok "unlock: refused as root" || fail "unlock as root: $out"
: > "$work/pass.log"; : > "$work/systemctl.log"
echo 1000000 > "$work/clock/now"; echo 500 > "$work/clock/boot"
out="$(cred unlock 2>&1)"
[ "$(secret_of "$R/secrets/gh.yaml")" = "Bearer S3CRET-ONE" ] && [ "$(cat "$work/pass.log")" = "work/gh" ] \
  && grep -q "start airlock-envoy-cred-expire.timer" "$work/systemctl.log" && grep -q '^unlocked until' "$R/state" \
  && ok "unlock: reads only the entry in use, installs it, starts the expiry" || fail "unlock: $out / $(cat "$work/pass.log")"
[ "$(secret_of "$R/secrets/kube.yaml")" = "airlock-envoy-locked kube" ] && ok "unlock: a pass credential not in use stays locked" || fail "kube unlocked"
[ "$(sed -n 's/^deadline //p' "$R/state")" = $((1000000 + 36000)) ] && [ "$(sed -n 's/^boot_deadline //p' "$R/state")" = $((500 + 36000)) ] \
  && ok "unlock: 10h by default, on the wall and the boot clock" || fail "deadline: $(cat "$R/state")"
! grep -rq S3CRET "$work/etc" "$R/state" && [[ "$out" != *S3CRET* ]] && ! cred status | grep -q S3CRET \
  && ok "the secret is only in the tmpfs file (not in /etc, the state, any output)" || fail "the secret leaked"
[ "$(stat -c %a "$R/secrets/gh.yaml")" = 640 ] && [ "$(stat -c %a "$R/state")" = 644 ] && ok "modes: secret 0640, state 0644" || fail "modes"
cred unlock --for 2h >/dev/null
[ "$(sed -n 's/^deadline //p' "$R/state")" = $((1000000 + 7200)) ] && ok "unlock --for shortens" || fail "--for 2h"
cred unlock --for 30h >/dev/null
[ "$(sed -n 's/^deadline //p' "$R/state")" = $((1000000 + 36000)) ] && ok "unlock --for can't lengthen past max_lifetime" || fail "--for 30h"
! cred unlock --for 0h >/dev/null 2>&1 && ! cred unlock --for 2d >/dev/null 2>&1 && ok "unlock --for: bad durations refused" || fail "bad --for"

# unlock.conf: max_lifetime (at most 24h), expire_at (next one strictly after now, local time).
printf 'max_lifetime 4h\n' > "$E/unlock.conf"; cred unlock >/dev/null
[ "$(sed -n 's/^deadline //p' "$R/state")" = $((1000000 + 14400)) ] && ok "unlock.conf max_lifetime" || fail "max_lifetime 4h"
printf 'max_lifetime 25h\n' > "$E/unlock.conf"
! cred unlock >/dev/null 2>&1 && ok "unlock.conf: max_lifetime over 24h refused" || fail "25h accepted"
printf 'max_lifetime 10h\nexpire_at 18:00\n' > "$E/unlock.conf"
date -d "2026-10-27 17:00" +%s > "$work/clock/now"; cred unlock >/dev/null
[ "$(sed -n 's/^deadline //p' "$R/state")" = "$(date -d '2026-10-27 18:00' +%s)" ] && ok "expire_at: 17:00 unlock ends at 18:00" || fail "expire_at 17:00"
date -d "2026-10-27 19:00" +%s > "$work/clock/now"; cred unlock >/dev/null
[ "$(sed -n 's/^deadline //p' "$R/state")" = "$(date -d '2026-10-28 05:00' +%s)" ] && ok "expire_at: 19:00 unlock ends 10h later (the next 18:00 is further)" || fail "expire_at 19:00"
date -d "2026-10-27 18:00" +%s > "$work/clock/now"; printf 'max_lifetime 24h\nexpire_at 18:00\n' > "$E/unlock.conf"; cred unlock >/dev/null
[ "$(sed -n 's/^deadline //p' "$R/state")" = "$(date -d '2026-10-28 18:00' +%s)" ] && ok "expire_at: an unlock at 18:00 rolls to the next day" || fail "expire_at 18:00"
printf 'expire_at 25:00\n' > "$E/unlock.conf"; ! cred unlock >/dev/null 2>&1 && ok "unlock.conf: bad expire_at refused" || fail "25:00"
printf 'idle 2h\n' > "$E/unlock.conf"; ! cred unlock >/dev/null 2>&1 && ok "unlock.conf: unknown settings refused" || fail "idle accepted"
rm -f "$E/unlock.conf"

# The expiry: locks at the deadline on either clock; nothing before.
echo 1000000 > "$work/clock/now"; echo 500 > "$work/clock/boot"; cred unlock >/dev/null
echo $((1000000 + 35000)) > "$work/clock/now"; echo $((500 + 35000)) > "$work/clock/boot"; : > "$work/systemctl.log"
root expire
[ "$(secret_of "$R/secrets/gh.yaml")" = "Bearer S3CRET-ONE" ] && ok "expire: before the deadline, nothing" || fail "expire locked early"
echo $((1000000 + 36000)) > "$work/clock/now"; root expire
[ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && grep -q '^locked' "$R/state" && grep -q "stop airlock-envoy-cred-expire.timer" "$work/systemctl.log" \
  && ok "expire: at the wall-clock deadline, locked and the timer stopped" || fail "expire at deadline"
echo 1000000 > "$work/clock/now"; echo 500 > "$work/clock/boot"; cred unlock >/dev/null
echo 900000 > "$work/clock/now"; echo $((500 + 36000)) > "$work/clock/boot"; root expire
[ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && ok "expire: the wall clock set back can't extend it (the boot clock locks)" || fail "boot clock"
echo 1000000 > "$work/clock/now"; echo 500 > "$work/clock/boot"; cred unlock >/dev/null
sed -i '/^boot_deadline /d' "$R/state"; root expire
[ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && ok "expire: a state without its deadlines locks" || fail "damaged state"

# A failed timer start unlocks nothing.
root lock >/dev/null
! FAIL_SYSTEMCTL=1 cred unlock >/dev/null 2>&1 && [ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && grep -q '^locked' "$R/state" \
  && ok "unlock: no expiry timer, nothing unlocked" || fail "unlocked without a timer"

# lock: as the operator through sudo, or as root; every pass credential.
cred unlock >/dev/null; : > "$work/sudo.log"
out="$(cred lock 2>&1)"
[ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && grep -q "lock" "$work/sudo.log" && [[ "$out" == *423* ]] \
  && ok "lock: from the operator, through sudo" || fail "lock: $out"

# receive (what sudo runs for unlock): all or nothing, only in-use pass credentials.
uses gh kube
! printf 'gh A\n' | root receive >/dev/null 2>&1 && [ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] \
  && ok "receive: one in-use credential missing, nothing unlocked" || fail "partial unlock"
! printf 'gh A\nkube B\nfilecred C\n' | root receive >/dev/null 2>&1 && ok "receive: a file credential refused" || fail "receive filecred"
! printf 'gh A\nkube B\nnope C\n' | root receive >/dev/null 2>&1 && ok "receive: an unknown credential refused" || fail "receive nope"
! printf 'gh A"x\nkube B\n' | root receive >/dev/null 2>&1 && ! printf 'gh A\\\\x\nkube B\n' | root receive >/dev/null 2>&1 \
  && ! printf 'gh A B\nkube B\n' | root receive >/dev/null 2>&1 && ok "receive: quotes, backslashes, spaces refused" || fail "receive bad secret"
uses gh
! printf 'gh A\nkube B\n' | root receive >/dev/null 2>&1 && ok "receive: a credential not in use refused" || fail "receive not in use"
[ "$(cred unlock 2>&1 >/dev/null; secret_of "$R/secrets/kube.yaml")" = "airlock-envoy-locked kube" ] && ok "unlock: kube (token format) untouched while not in use" || fail "kube"
uses gh kube; cred unlock >/dev/null
[ "$(secret_of "$R/secrets/kube.yaml")" = "token S3CRET-TWO" ] && ok "unlock: the format (token) applies" || fail "token format"

# A bad first line in the store stops the unlock, before anything goes to root.
root lock >/dev/null; printf 'has space\n' > "$work/store/work/kube"; : > "$work/sudo.log"
! cred unlock >/dev/null 2>&1 && ! grep -q receive "$work/sudo.log" && [ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] \
  && ok "unlock: a bad pass entry stops it before root gets anything" || fail "bad entry unlock"
printf 'S3CRET-TWO\n' > "$work/store/work/kube"
# An entry name from root is checked again before pass sees it.
printf 'entry ../../etc/shadow\nformat bearer\n' > "$E/pass/gh"; : > "$work/pass.log"
! cred unlock >/dev/null 2>&1 && ! grep -q shadow "$work/pass.log" && ok "unlock: re-checks entry names before pass show" || fail "entry re-check"
printf 'entry work/gh\nformat bearer\n' > "$E/pass/gh"

# migrate: file -> pass, only if the entry gives the same value; the file goes last.
printf 'FILE-SECRET\n' > "$work/store/work/filecred"
printf 'OTHER\n' > "$work/store/work/wrong"
! cred migrate filecred --pass work/wrong >/dev/null 2>&1 && [ -f "$E/credentials/filecred.yaml" ] && [ ! -f "$E/pass/filecred" ] \
  && ok "migrate: a different value refused, nothing changed" || fail "migrate wrong"
out="$(root migrate filecred --pass work/filecred 2>&1)"; [[ "$out" == *"run migrate as yourself"* ]] && ok "migrate: refused as root" || fail "migrate as root: $out"
! FAIL_APPLY=1 cred migrate filecred --pass work/filecred >/dev/null 2>&1 && [ -f "$E/credentials/filecred.yaml" ] && [ ! -f "$E/pass/filecred" ] \
  && ok "migrate: an apply that fails leaves it a file credential" || fail "migrate with a failing apply"
: > "$work/apply.log"
out="$(cred migrate filecred --pass work/filecred 2>&1)"
[ ! -f "$E/credentials/filecred.yaml" ] && [ "$(sed -n 's/^entry //p' "$E/pass/filecred")" = work/filecred ] \
  && [ "$(secret_of "$R/secrets/filecred.yaml")" = "airlock-envoy-locked filecred" ] && [[ "$out" == *"applied and locked"* ]] \
  && grep -q "filecred.yaml" "$work/apply.log" \
  && ok "migrate: same value; applied while the file was still there, then the file removed" || fail "migrate: $out / $(cat "$work/apply.log")"
printf 'X\n' | root set basicc --format basic:x-access-token >/dev/null; printf 'X\n' > "$work/store/work/basicc"
cred migrate basicc --pass work/basicc >/dev/null && [ "$(sed -n 's/^format //p' "$E/pass/basicc")" = basic:x-access-token ] \
  && ok "migrate: the format comes along (basic:<user>)" || fail "migrate basic"

# boot: makes each missing file locked, leaves an existing one.
rm -f "$R/secrets/kube.yaml"; uses gh kube; cred unlock >/dev/null; rm -f "$R/secrets/kube.yaml"
root boot
[ "$(secret_of "$R/secrets/kube.yaml")" = "airlock-envoy-locked kube" ] && [ "$(secret_of "$R/secrets/gh.yaml")" = "Bearer S3CRET-ONE" ] \
  && ok "boot: a missing file made locked, an unlocked one kept" || fail "boot"

# status: the operator reads the state; root sees each credential's backend.
[[ "$(cred status)" == "unlocked until"* ]] && [[ "$(root status)" == *"credential gh pass work/gh (unlocked)"* ]] \
  && [[ "$(root status)" == *"credential filecred pass work/filecred (locked)"* ]] && ok "status: operator and root views" || fail "status"

# Root reads what it is sent before taking the lock: a slow sender holds nothing up.
uses gh; cred unlock >/dev/null; echo $((1000000 + 40000)) > "$work/clock/now"
( sleep 3; printf 'gh S3CRET-ONE\n' ) | FAKE_UID=0 airlock-envoy-cred receive >/dev/null 2>&1 & slow=$!; sleep 0.5
t=$(date +%s%N); root expire; t=$(( ($(date +%s%N) - t) / 1000000 )); wait "$slow" 2>/dev/null
[ "$t" -lt 1500 ] && ok "a slow sender to receive holds no lock (${t} ms)" || fail "expire waited on a slow receive (${t} ms)"
echo 1000000 > "$work/clock/now"
# Input over 60000 bytes is refused, not cut; a NUL is refused; an empty stdin is said.
root lock >/dev/null; uses gh
big="$(head -c 70000 /dev/zero | tr '\0' A)"
! printf 'gh %s\n' "$big" | root receive >/dev/null 2>&1 && [ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] \
  && ok "receive: over 60000 bytes refused, nothing unlocked" || fail "a cut secret was installed"
! printf 'gh AB\000CD\n' | root receive >/dev/null 2>&1 && [ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] \
  && ok "receive: a NUL refused" || fail "a NUL passed"
out="$(: | root receive 2>&1)"; [[ "$out" == *"nothing on stdin"* ]] && ok "receive: an empty stdin said so" || fail "empty stdin: $out"
out="$(printf 'S3CRET-AS-NAME\n' | root receive 2>&1)"; [[ "$out" == *"line 1 on stdin"* && "$out" != *S3CRET* ]] \
  && ok "receive: a bad line named by its number, not its text" || fail "bad line echoed: $out"
# A re-unlock whose deadline can't be worked out locks the live unlock too (fail closed).
cred unlock >/dev/null; printf 'expire_at 18:00\n' > "$E/unlock.conf"
! PATH="$work/brokenbin:$PATH" cred unlock >/dev/null 2>&1 && [ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] \
  && ok "a failed re-unlock locks the live one" || fail "a failed re-unlock left the old one live"
rm -f "$E/unlock.conf"

# The deadline first: no secret in place when the timer starts (the stub checks).
uses gh; root lock >/dev/null; : > "$work/systemctl.log"; cred unlock >/dev/null
! grep -q "SECRET BEFORE TIMER" "$work/systemctl.log" && [ "$(secret_of "$R/secrets/gh.yaml")" = "Bearer S3CRET-ONE" ] \
  && ok "unlock: the deadline and the timer before any secret" || fail "a secret was in place before the timer: $(cat "$work/systemctl.log")"
# The timer firing during an unlock (here: at its start) waits for it, and leaves it unlocked.
root lock >/dev/null; : > "$work/systemctl.log"
RACE_EXPIRE=1 cred unlock >/dev/null; wait "$(cat "$work/race.pid")" 2>/dev/null; sleep 0.3
[ "$(secret_of "$R/secrets/gh.yaml")" = "Bearer S3CRET-ONE" ] && grep -q '^unlocked' "$R/state" && [ "$(tail -n 1 "$work/systemctl.log")" = "start airlock-envoy-cred-expire.timer" ] \
  && ok "an expiry during an unlock: no stop after the start, still unlocked with its timer" || fail "race: $(cat "$work/systemctl.log") / $(head -1 "$R/state")"
# unlock.conf's last line without a newline counts.
printf 'max_lifetime 2h' > "$E/unlock.conf"; echo 1000000 > "$work/clock/now"; cred unlock >/dev/null
[ "$(sed -n 's/^deadline //p' "$R/state")" = $((1000000 + 7200)) ] && ok "unlock.conf: a last line without a newline counts" || fail "no-newline conf: $(sed -n 's/^deadline //p' "$R/state")"
rm -f "$E/unlock.conf"
# expire_at in a DST gap (America/New_York springs forward 2026-03-08 02:00 -> 03:00): an hour later.
printf 'expire_at 02:30
' > "$E/unlock.conf"
TZ=America/New_York date -d "2026-03-08 01:00" +%s > "$work/clock/now"; TZ=America/New_York cred unlock >/dev/null
[ "$(sed -n 's/^deadline //p' "$R/state")" = "$(TZ=America/New_York date -d '2026-03-08 03:30' +%s)" ] && ok "expire_at in a DST gap, the same day: an hour later" || fail "DST same day: $(head -1 "$R/state")"
TZ=America/New_York date -d "2026-03-07 23:00" +%s > "$work/clock/now"; TZ=America/New_York cred unlock >/dev/null
[ "$(sed -n 's/^deadline //p' "$R/state")" = "$(TZ=America/New_York date -d '2026-03-08 03:30' +%s)" ] && ok "expire_at in a DST gap, the next day: an hour later" || fail "DST next day: $(head -1 "$R/state")"
rm -f "$E/unlock.conf"; echo 1000000 > "$work/clock/now"
# A deadline that can't be worked out unlocks nothing (expire_at 23:30 on a day without it can't occur;
# a broken date stands in for it).
root lock >/dev/null
printf 'expire_at 18:00\n' > "$E/unlock.conf"
! PATH="$work/brokenbin:$PATH" cred unlock >/dev/null 2>&1 && [ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && grep -q '^locked' "$R/state" \
  && ok "unlock: a deadline that can't be worked out unlocks nothing" || fail "bad deadline unlocked: $(head -1 "$R/state")"
rm -f "$E/unlock.conf"
# A damaged deadline locks at the next expiry.
cred unlock >/dev/null; sed -i 's/^deadline .*/deadline soon/' "$R/state"; root expire
[ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && ok "expire: a deadline that isn't a number locks" || fail "garbled deadline"
cred unlock >/dev/null; rm -f "$R/state"; root expire
[ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && ok "expire: no state at all locks" || fail "no state"
# lock reaches a file whose metadata went; remove locks and forgets.
cred unlock >/dev/null; mv "$E/pass/gh" "$work/gh.meta"; root lock >/dev/null; mv "$work/gh.meta" "$E/pass/gh"
[ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && ok "lock: also a file whose metadata is gone" || fail "lock missed an orphan"
root add tmpc --pass work/gh >/dev/null; uses gh tmpc; cred unlock >/dev/null
[ "$(secret_of "$R/secrets/tmpc.yaml")" = "Bearer S3CRET-ONE" ] || fail "tmpc not unlocked for the remove test"
root remove tmpc >/dev/null; uses gh
[ ! -f "$E/pass/tmpc" ] && [ "$(secret_of "$R/secrets/tmpc.yaml")" = "airlock-envoy-locked tmpc" ] && ok "remove: an unlocked one locked and forgotten" || fail "remove"
# migrate waits for pass (its prompt) without holding the lock: an expiry meanwhile isn't held up.
uses gh; cred unlock >/dev/null
printf 'X\n' | root set slowc >/dev/null; printf 'X\n' > "$work/store/work/slowc"
SLOW_PASS=3 cred migrate slowc --pass work/slowc >/dev/null 2>&1 & mig=$!; sleep 0.5
echo $((1000000 + 40000)) > "$work/clock/now"
t=$(date +%s%N); root expire; t=$(( ($(date +%s%N) - t) / 1000000 )); wait "$mig"
[ "$t" -lt 1500 ] && [ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && ok "migrate at pass's prompt holds no lock: the expiry ran at once (${t} ms)" || fail "expire waited on migrate (${t} ms)"
echo 1000000 > "$work/clock/now"
grep -q "boot from apply failed" "$work/apply.log" && fail "migrate's apply could not run boot (the lock)" || ok "migrate's apply runs boot (as Envoy's restart would) without waiting on migrate"
# A lock interleaving with an unlock: whichever is last, the state and the timer agree.
root lock >/dev/null; : > "$work/systemctl.log"
SLOW_STOP=1.5 root lock >/dev/null & lk=$!; sleep 0.3
cred unlock >/dev/null; wait "$lk"
if grep -q '^unlocked' "$R/state"; then
  [ "$(tail -n 1 "$work/systemctl.log")" = "start airlock-envoy-cred-expire.timer" ] && ok "lock then unlock: unlocked with the timer started last" || fail "interleave: unlocked but the timer stopped last: $(cat "$work/systemctl.log")"
else
  [ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && ok "lock then unlock: locked, and so are the secrets" || fail "interleave: state locked, secret live"
fi

# boot: an unlock past its deadline (Envoy restarted late) locks; a valid one keeps its timer.
cred unlock >/dev/null; : > "$work/systemctl.log"; root boot
[ "$(secret_of "$R/secrets/gh.yaml")" = "Bearer S3CRET-ONE" ] && grep -q "start airlock-envoy-cred-expire.timer" "$work/systemctl.log" \
  && ok "boot: a valid unlock stays, its timer started again" || fail "boot valid"
echo $((1000000 + 40000)) > "$work/clock/now"; root boot
[ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && ok "boot: an unlock past its deadline locks" || fail "boot expired"
echo 1000000 > "$work/clock/now"; echo 500 > "$work/clock/boot"; cred unlock >/dev/null
echo 900000 > "$work/clock/now"; echo $((500 + 40000)) > "$work/clock/boot"; root boot
[ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && ok "boot: past the boot-clock deadline (wall clock set back) locks" || fail "boot boot-clock"
echo 1000000 > "$work/clock/now"; echo 500 > "$work/clock/boot"
# A reboot: the tmpfs gone; boot makes every file locked and the state locked.
cred unlock >/dev/null; rm -rf "$R"; root boot
[ "$(secret_of "$R/secrets/gh.yaml")" = "airlock-envoy-locked gh" ] && grep -q '^locked' "$R/state" && ok "boot after a reboot: locked" || fail "boot after reboot"
# status: minutes left now, not at unlock.
cred unlock >/dev/null; echo $((1000000 + 600)) > "$work/clock/now"
[[ "$(cred status | head -1)" == *"; 590 minutes left" ]] && ok "status: minutes left now" || fail "status minutes: $(cred status | head -1)"
echo 1000000 > "$work/clock/now"
# The mutating verbs take a lock: one held elsewhere makes them wait.
( exec 9> "$R/.lock"; flock 9; sleep 1.5 ) & holder=$!; sleep 0.3
t=$(date +%s%N); root lock >/dev/null; t=$(( ($(date +%s%N) - t) / 1000000 )); wait "$holder"
[ "$t" -ge 900 ] && ok "lock waits for another verb's lock (${t} ms)" || fail "lock didn't wait (${t} ms)"

# The root-only verbs refuse the operator.
for v in "receive" "receive-migrate x y" "expire" "boot" "add x --pass a/b" "set x" "remove x"; do
  # shellcheck disable=SC2086
  ! echo | cred $v >/dev/null 2>&1 || fail "$v ran as the operator"
done; ok "receive, expire, boot, add, set: root only"

echo "failures: $fails"
exit "$fails"
