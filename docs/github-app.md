# GitHub App credentials: a token minted per line

A static token (a PAT) has one set of permissions for every repo it covers, and it lasts until
someone revokes it. A GitHub App installation can mint short-lived tokens narrowed to some of its
repos and some of its permissions. airlock-envoy uses that: each site-file line that names an App
credential gets its own token, for exactly that line's repos and what that line's rules may do.

## Setting it up

On the host, as its operator (not in a box):

1. Install or update airlock-envoy (`sudo install/install-service.sh`): it adds the
   `airlock-envoy-mint` account, its units and `/etc/tmpfiles.d/airlock-envoy-mint.conf`. Hosts using
   an App need `python3`.
2. Register the App, installed on your organisation (no organisation admin rights needed):
   ```
   sudo airlock-envoy-cred add-app work-app --app-id 123456 --org example-org --key pass:work/app.pem
   # or, a key file:  ... --key file < app.pem       (an unencrypted RSA key, as GitHub issues)
   # a private GitHub (GHES):  --api https://github.example.org/api/v3 --ca /etc/ssl/example-ca.pem
   ```
3. Use it on the site file's GitHub lines, repos named, one owner per line:
   ```
   http api.github.com@w rules github-api credential work-app repos example-org/app repos-read example-org/docs
   http github.com@w     rules git        credential work-app repos example-org/app protect main
   ```
4. `sudo airlock-envoy-apply`. It prints the installation's check (its permissions and installed
   repos against your lines) and refuses a line that asks for more than the App grants or names a
   repo it isn't installed on. `airlock-envoy-apply --render-mint` shows the tokens it will mint.
5. A pass key: `airlock-envoy-cred unlock` (as yourself, in a host shell), daily. `airlock-envoy-cred
   lock` locks it early; `sudo airlock-envoy-cred status` shows each App, its tokens, and the check.

In a box, a request on such a line just works (Envoy adds the token). **423 Locked** means the key
is locked: stop and ask the operator to unlock. **503** naming the App means minting failed: tell the
operator (`journalctl -u airlock-envoy-mint`). Neither clears by retrying.

## Three layers, each narrower

1. **The App installation** (set by the organisation's admins): the repos and permissions the
   App may have at all. The outer bound.
2. **The minted token**, one per line (per access, below): `POST
   /app/installations/<id>/access_tokens` with the line's repos and permissions, a subset of the
   installation's. The site file is the one list: there is no second repo list to keep in step.
3. **Envoy's routes**, as for any credential: `repos`, `repos-read`, `protect`, GraphQL refused
   under `repos`.

So a bug in one layer is still bounded by the next: a route Envoy wrongly let through can't
write a repo the line's token wasn't minted for, and can't write at all with a read token.

## Tokens per line

A line gets a **write token** for its `repos` and, if it has `repos-read`, a separate **read
token** for those: each route injects the one for its repo, so read-only holds at GitHub too.

| Rules | Write token (`repos`) | Read token (`repos-read`) | Injected as |
|---|---|---|---|
| `git` | `contents: write` | `contents: read` | `Basic x-access-token:<token>` |
| `git-read` | `contents: read` | `contents: read` | `Basic x-access-token:<token>` |
| `github-api` | `contents: read`, `issues: write`, `pull_requests: write` | `contents: read`, `issues: read`, `pull_requests: read` | `token <token>` |
| `github-issues` | `contents: read`, `issues: write` | `contents: read`, `issues: read` | `token <token>` |

GitHub adds `metadata: read` itself. No token is minted with `workflows`, so a push that touches
`.github/workflows/` is refused by GitHub. The routes outside a repo (`/user`, `/rate_limit`)
use the line's write token, or its read token if it has only `repos-read`.

Apply refuses an App credential on other rules (`forgejo`, `any`, `kubernetes-read`), on a line
without `repos` or `repos-read`, with `<owner>/*` (GitHub mints tokens for named repos only), or
with repos of more than one owner on one line (the token takes repo names under the
installation's account). Several lines may use one App: each gets its own tokens.

`airlock-envoy-apply --render-mint` prints what would be minted (`mint.conf`).

## The App describes itself

`add-app` takes the App's id and the organisation it's installed on (`--org`); the installation
is looked up with the App's own key (`GET /orgs/<org>/installation`) and its id kept in
`/run/airlock-envoy-mint/installations/`, so setting up needs no organisation admin rights
(`--installation-id` names it instead, if known).

`airlock-envoy-mint check` (run by apply, by `airlock-envoy-cred status`, or as root) shows each
App's installation: its id, repository selection, granted permissions, and installed repos (read
with a token minted for `metadata: read` alone, revoked once used). It checks the lines against
it:

- **error** (apply refuses): a line naming a repo the App isn't installed on, or asking for more
  than the App grants;
- **warning**: the App holds `workflows`, `administration`, `secrets`, `actions: write`,
  `environments`, `members` or any `organization_*` permission at all (no line asks for them, but
  the installation is wider than it needs to be).

It exits 0 when the lines fit, 1 on an error, 3 when it couldn't check (a pass key locked, the
API unreachable), 2 when it didn't run: apply refuses on 1, otherwise says so and goes on;
minting reports any refusal.

## The key, and who holds it

`airlock-envoy-cred add-app <name> --app-id <n> --org <org> --key ...` (or `add-github-app`):

- **`--key file`** (the PEM on stdin): kept in `/etc/airlock-envoy-mint/apps/<name>.pem`,
  root:airlock-envoy-mint 0640. Always usable, like a file credential.
- **`--key pass:<entry>`**: the whole pass entry is the key. It is unlocked with the other pass
  credentials (`airlock-envoy-cred unlock`, [docs/unlock.md](unlock.md): the same boundary,
  expiry and 423), checked by root with openssl, and held in `/run/airlock-envoy-mint/keys/`
  (a tmpfs; root:airlock-envoy-mint 0440: the mint account reads it, nobody else) until the lock. Unlock mints once before it says
  unlocked; if a line gets no token, everything is locked again.

Minting runs as its own system account, `airlock-envoy-mint`, in `airlock-envoy-mint.service`
(sandboxed: no capabilities, a read-only system but the three directories it writes, no swap,
no core dumps). It alone reads the key; it writes only the tokens,
`/run/airlock-envoy-mint/tokens/<token>.yaml` (group airlock-envoy, 0640), which Envoy reads like
any credential. A compromised Envoy can't mint, and a compromised minter can't reach Envoy's
sockets.

`/run/airlock-envoy-mint` is laid out by `tmpfiles.d` at boot: root owns the directory, `keys/`
(an unlocked pass key, root:airlock-envoy-mint 0440: the minter reads it, can't change it) and the
run lock; the minter owns only `tokens/`, `minted/` (the tokens it must still revoke) and
`installations/` (looked-up ids). Root never writes in those: to lock or prepare a token it runs
the minter's own `mark` as the minter's account, and `check` runs as that account too. So nothing
a compromised minter plants there (a link, a file) can make root write, change or remove anything
elsewhere.

Apps have a `kind` (`github-app` today); another issuer of short-lived credentials would be
another kind, minted by the same account. The minter talks to the GitHub API directly
(HTTPS, the system CAs or the App's own `--ca`), not through Envoy. curl gets the JWT and the
tokens on stdin, never in its argv; GitHub's JSON is read by python3 (needed on hosts using an
App) and every value checked (a token of GitHub's characters, an expiry within a day). Runs are
one at a time (a lock), so two can't revoke each other's fresh tokens.

## Minting, renewing, revoking

- The JWT: RS256 with the App's key, `iat` a minute back (clock skew), `exp` nine minutes on.
- A token is minted when its line is new or changed, or within 15 minutes (plus up to 2 of
  jitter) of its expiry; tokens last an hour. `airlock-envoy-mint.timer` runs every 5 minutes,
  apply runs it after each apply, unlock runs it, and so does Envoy's start.
- The new token is recorded, then installed; only then is the one it replaces retired: queued
  and revoked at GitHub (`DELETE /installation/token`) a minute later by the next run, so
  requests already sent with it finish, and kept to retry until GitHub confirms. A new token that
  can't be installed is revoked at once; a run stopped half way leaves a record the next run
  settles (adopted if it is the installed token, revoked if not).
- A failed mint keeps a token that still works for that very line; a line that changed (other
  repos, permissions, or its App's definition) gets no token rather than its old one, which is
  retired.
- A line gone from `mint.conf` has its tokens revoked and its files removed. When no line uses an
  App any more, apply runs a last sweep, and keeps the timer (with an empty `mint.conf`) until every
  token is revoked.
- Runs are one at a time, and `lock` waits (up to 30 s) for a run in flight; a run that mints
  as the key is locked revokes what it got. Envoy's start doesn't wait on a run, and unlock
  doesn't hold the credential lock while it mints. Root's own lock files are closed before it runs
  anything as the mint account, and root never reads the mint account's files: it asks the account
  (`airlock-envoy-mint state`, under a timeout). Failures are logged
  (`journalctl -u airlock-envoy-mint`).
- The owner: a line's repos must be the App's organisation's (an App set up by `--org`), and
  `check` compares them with the installation's account.
- The timer is enabled only while a line uses an App, and kept after the last one goes until
  every token is revoked; the next apply after that stops it and removes `mint.conf`.

## What a box sees

| State | Envoy's answer (nothing upstream) |
|---|---|
| A pass key locked, or the unlock expired | **423 Locked**: `credential <app> is locked on this host: stop, and ask the operator to unlock it` (as for pass credentials) |
| A line never minted (GitHub refused, the API unreachable, a file key missing) | **503**: `credential <app> has no token on this host (GitHub App minting failed: journalctl -u airlock-envoy-mint): stop, and tell the operator; do not retry` |

Both are marked `x-airlock-envoy: locked` or `unavailable`; upstream's own header of that name
is removed. Locking drops the key, locks the App's tokens at once, and starts a mint run that
revokes them at GitHub.

## Limits

- **Revoked with the App as it is now.** A record is revoked against its App's current
  definition: an App re-added with another `--api` sends older revokes to the new server. A
  record whose App was removed is kept (logged each run) and can't be revoked; remove it by hand
  once its hour is over (`/run/airlock-envoy-mint/minted/`).
- **Revocation is best effort.** A token whose revoke failed (GitHub unreachable at the time)
  stays valid at GitHub for up to its hour; Envoy stops using it at the lock regardless, and the
  next run retries the revoke while it still has the token recorded.
- **The key** is an unencrypted RSA key (a GitHub App's); `--ca` must be a world-readable file
  under `/etc` or `/usr`, where the unit's sandbox can read it.
- **Repo names, one owner, per line.** An organisation's repos and a user's go on separate lines.
- **A renamed repo** must be renamed in the site file too: GitHub mints for the current name.
- **The installation's own bounds** are the organisation's: `check` reports them; it can't
  change them.

## Tests

- `test/mint.sh`: the minter against `test/fake-github-app.py` (a stand-in App API over TLS that
  checks each JWT's RS256 signature with the App's public key, and records each token's request):
  each line's repos and permissions, the formats, renewal near expiry with the old token revoked,
  a changed line, a refused mint keeping a working token, a never-minted line unavailable, a pass
  key locked and revoked, another key's JWT refused, bad lines, `check`, no token in an argv.
- `test/mint-e2e.sh`: a real Envoy with the three tools: 423 while the pass key is locked, unlock
  minting, each route its own live token (the read route's minted read-only for its repo alone),
  lock revoking both, a file-key App untouched by the lock.
- `test/apply-parse.sh`: the refusals, `mint.conf`, which token each route injects.
- `test/cred-backends.sh`: `add-app`'s checks, unlock reading the key whole, a key openssl can't
  read, an unlock whose mint gives no token locking everything.
- `test/install-test.sh` (podman): the account and units under systemd, minting under the
  unit's sandbox against the stand-in, a pass key unlocked and locked with its token revoked, the
  timer enabled and disabled by apply.
