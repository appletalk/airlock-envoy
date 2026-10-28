# Pass credentials: unlocked for the working day

Sit down at the workstation, unlock once, work. A pass credential is not on disk in usable
form, and Envoy holds it no longer than the working day. Unlocking uses the password the
operator already types (the gpg passphrase for `pass`), so there is no new password.

A file credential (`airlock-envoy-cred set`, the default) is usable at rest: anyone who can
read `/etc/airlock-envoy/credentials` has it, at any time. A pass credential's only copy
outside the operator's password store is in a tmpfs that Envoy reads, from `unlock` until the
deadline, `lock`, or a reboot. Which to use is per credential and per host: where root and the
filesystem are a good boundary, file credentials are fine; where they are weaker (a Linux VM
whose disk an unprivileged user of the host can read), pass credentials keep the secret out of
the disk.

## The boundary

A box can never unlock. This is not a rule the agent follows: no path leads from a box to an
unlocked credential, and any path found is a defect.

### Assumption

The box cannot run code on the host as the operator. If it can, this boundary and every other
one the sandbox draws are gone: code running as the operator can read `pass` while gpg-agent
has the passphrase cached, or run `unlock` itself. Channels from a box to host code execution
(a shared directory the host later runs code from: git hooks, `core.fsmonitor`; an unboxed agent
session on the same host) are the sandbox's to close.

### What unlocking needs

| Needed to unlock | Why a box cannot reach it |
|---|---|
| The secret | In `pass`, encrypted to the operator's gpg key. The box sandbox refuses to mount `~/.password-store` and `~/.gnupg`, with no override. |
| The gpg agent | A socket owned by the operator, refused by the sandbox whatever the path. |
| The gpg key | Useless without `~/.gnupg`, which never reaches a box. |
| Root, to hand the secret to Envoy | `sudo`. A box has no sudo: no setuid binary works under its no-new-privileges, and the sandbox gives it no sudo configuration. There is no socket or port to reach instead: unlocking is `pass show` as the operator, then `sudo airlock-envoy-cred receive` reading stdin. |

Envoy's sockets (the boxes' listeners) carry requests only: no path on them reads or changes a
credential. The tmpfs that holds the secrets is root:airlock-envoy 0750, outside anything a box
is given.

### Inside `airlock-envoy-cred`

- **No secretless verb.** Unlock needs every secret again: there is no "extend" or "renew".
  Unlocking again restarts the clock, and needs the secrets, so it is not a way around the
  lifetime. `lock` needs no secret: anyone who could run it could only lock.
- **Root names the entries.** `unlock` asks root (`sudo airlock-envoy-cred entries`) which
  `pass` entries the pass credentials in the *applied* config use, and reads only those. It
  checks each name again before `pass show` (letters, digits and `._@+-` in `/`-separated
  parts, none starting with `.` or `-`, no `..`), so a damaged answer can't point `pass` at
  something else.
- **All or nothing.** `receive` refuses a credential that isn't a pass credential, isn't in
  use, or whose value isn't plain printable ASCII, and installs nothing unless every pass
  credential in use has its secret.
- **The deadline first.** The deadline is written and the expiry timer started before any
  secret is installed; if the deadline can't be worked out or the timer can't start, nothing is
  unlocked.
- **One verb at a time.** receive (and receive-migrate), lock, the expiry, boot, add, add-app,
  remove, migrate and `set --file` take a lock (migrate, `set --file` and `remove` release it
  around their apply or mint run)
  (`/run/airlock-envoy-cred/.lock`), so a lock or an expiry can't interleave with an unlock and
  leave secrets without their timer. (The expiry waits a minute for it; if it can't have it, it
  still locks every secret, and leaves the state and the timer to the next expiry. Unlock releases
  it while a GitHub App mints.) Secrets are read before it is taken (pass may be waiting
  at its prompt), and migrate releases it before its apply (Envoy's restart runs boot, which
  takes it).
- **Unreadable means locked.** The expiry locks on a state it can't read (missing, damaged, a
  deadline that isn't a number), and `lock` locks every file in the tmpfs, including one whose
  metadata is gone.

## Operator flow

```
$ airlock-envoy-cred unlock
==> unlocked github-api github-git until 2026-10-27T18:00:00+0000 (540 minutes): Envoy uses them from the next request
```

1. `unlock` (as the operator, in a host shell; it refuses to run as root) asks root which
   entries to read. Run the installed one (`/usr/local/sbin/airlock-envoy-cred`): it runs itself
   again under sudo, so a copy somewhere a box can write would run as root.
2. It runs `pass show <entry>` for each and takes the first line. gpg-agent prompts once and
   caches the passphrase.
3. It sends `<name> <secret>` lines on stdin to `sudo airlock-envoy-cred receive`. The secrets
   are in the operator's process and the pipe only; nothing here writes them to disk (but see
   sudo's I/O logging under Limits).
4. Root writes each one, as the Authorization value of the credential's format, to
   `/run/airlock-envoy-cred/secrets/<name>.yaml`. Envoy takes it within a second, without a
   restart; box sockets and tunnels stay up.

`airlock-envoy-cred lock` locks every pass credential at once. `unlock --for 2h` unlocks for
less than the lifetime, never more. `status` shows the state and the deadline (with its UTC
offset and as epoch seconds: a box usually runs in UTC while `expire_at` is the host's local
time); as root, each credential's backend and whether it is locked.

`migrate <name> --pass <entry>` moves a file credential to pass. Root checks that the entry
gives exactly the value the file held, then applies the config (Envoy reads the credential from
the tmpfs, locked, from then on), and only then removes the file: there is no window with
neither, and none where Envoy keeps the old value with no expiry. If the apply fails, it stays
a file credential (if the apply got as far as Envoy, the config reads the locked tmpfs file:
apply again once the apply works). Then unlock. `remove <name>` (as root) locks a pass credential
and forgets it; take it out of the site file and apply. (A reboot before that apply is fine: boot
makes a locked file for every tmpfs path the applied config reads.)

`set <name> --file` (as root) goes the other way, a pass credential back to a file one: it reads
the secret as `set` does (the pass credential's format unless `--format`), writes the file,
applies (Envoy reads the file from then on), and only then forgets the pass credential and locks
its tmpfs copy. If the apply fails or is interrupted, it stays a pass credential: the file goes,
or, if the applied config already reads it, stays locked (Envoy keeps the last value of a
deleted file); apply again. A second signal can't cut that rollback short. A `set --file` killed
outright is noticed by the next `set` of that name: if its apply got through (the config reads
the file) the move is finished, else it is a pass credential again; not while an apply runs. A
reboot in between leaves Envoy a locked placeholder where the config still reads the tmpfs, and
`boot` and `status` name the `set` to run. One `set --file` runs at a time, and not during an
apply. Without `--file`, `set` refuses a pass credential,
since the secret then lives on disk, never locked.

## Expiry

`/etc/airlock-envoy/unlock.conf` (optional):

```
max_lifetime 10h    # the default; at most 24h
expire_at 18:00     # optional; local time
```

An unlock ends at whichever comes first: unlock time plus `max_lifetime` (or `--for`), or the
next `expire_at` strictly after the unlock. An unlock at 19:00 with `expire_at 18:00` ends ten
hours later, at 05:00, because the next 18:00 is further away; one at exactly 18:00 rolls to
the next day's. An `expire_at` that a day skips (the hour DST springs forward) is an hour later
that day.

The deadline is kept on two clocks. A timer (`airlock-envoy-cred-expire.timer`, every 30 s,
started by `unlock` and stopped by `lock`) locks when either the wall clock reaches the deadline
or the boot clock (`CLOCK_BOOTTIME`, which runs through suspend and never steps back) reaches its
own: setting the wall clock back cannot extend an unlock. A reboot always starts locked: the
secrets were in a tmpfs, and before Envoy starts, `airlock-envoy-cred boot` writes each pass
credential's file locked. Envoy restarted within an unlock keeps it (boot starts its timer
again); restarted past the deadline, boot locks. A `systemctl soft-reboot` keeps `/run` and the
boot clock, so it counts as a restart within the unlock, not a reboot.

## When a credential is locked

Every request that uses it gets **HTTP 423 Locked** from Envoy itself, with the header
`x-airlock-envoy: locked` and the body
`airlock-envoy: credential <name> is locked on this host: stop, and ask the operator to unlock
it on the host (airlock-envoy-cred unlock); do not retry`. Nothing goes upstream. Upstream's own
`x-airlock-envoy` header is removed from its responses, so an upstream can't fake the marker
(it can still answer 423 itself, which only stops the agent). A
locked credential's file holds `airlock-envoy-locked <name>`, which the injector adds as usual
and a check after it answers; that value grants nothing anywhere.

What the agent does on 423 (agent behaviour, recorded here so the proxy matches what an agent
needs):

- Stop the workflow at the step that got 423. Do not retry: a lock does not clear by itself.
- Report which steps completed, the one that failed, and where to resume. Name a half-done
  operation as such.
- Never try to unlock. There is no way to from a box; asking the operator is the only path.

git shows the body as `remote:` lines on a fetch; on a push it may show only
`RPC failed; HTTP 423`, so an agent keys on the status as well as the text.

## Limits

- **tmpfs can be swapped.** `/run` is a tmpfs, and the kernel may write its pages to swap.
  Envoy itself runs with `MemorySwapMax=0`, but the files are not covered. On a host where that
  matters, run without swap or with encrypted swap.
- **sudo's I/O logging.** If the host's sudoers enables `log_input` (I/O logging), sudo records
  the stdin of `receive` and `receive-migrate`, the secrets, under its log directory. Leave it
  off for this command.
- **Up to 30 s after a suspend.** A laptop that wakes past the deadline locks within 30 s of
  waking, not before the first request.
- **No idle lock** ("lock after 2h without use") yet.
- **Values are printable ASCII without spaces, quotes or backslashes**, as for file
  credentials: tokens are. What unlock sends root is at most 60000 bytes; more is refused.
- A request that started before a lock finishes with the credential it had.

## Tests

- `test/cred-backends.sh` (no root, no podman): add, entries, unlock, lock, the deadline rules
  (default, `--for`, `max_lifetime`, `expire_at` including the 18:00 and 19:00 cases and a DST
  gap), the deadline and timer before any secret, an expiry during an unlock, the verb lock, the
  expiry on each clock and on a damaged state, all-or-nothing receive, migrate (applied before
  the file goes), `set --file` (the reverse, applied before the pass credential goes; a failed
  or interrupted apply rolling back, the file locked if Envoy reads it; one killed outright,
  resumed; one at a time), remove, boot (a reboot, Envoy restarted within and past an unlock), status,
  and that each root-only verb refuses the operator and `unlock`/`migrate` refuse root.
- `test/cred-e2e.sh` (no root, no podman): a rendered config in a real Envoy: 423 while locked
  with nothing upstream, the token used after unlock and the 423 after lock without a restart,
  upstream's marker removed.
- `test/install-test.sh` (podman): the units under systemd: the boot step, the timer started by
  unlock and firing by itself, the expiry service locking under its sandbox, a reboot (the tmpfs
  gone) starting locked with the timer stopped.
