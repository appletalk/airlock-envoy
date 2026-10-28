# airlock-envoy

An egress and credential proxy for [claude-airlock](https://github.com/appletalk/claude-airlock)
boxes, built on Envoy.

A box runs with `--network none`. Its only way out is a Unix socket that airlock mounts in.
Envoy listens on that socket on the host, decides what may pass, and logs every decision.

Each socket belongs to one user and carries one allowlist. Envoy never decrypts TLS. It offers
two modes:

| Mode | For | What the proxy does |
|---|---|---|
| **CONNECT tunnel** | Clients that need TLS end to end, such as Claude Code (`HTTPS_PROXY`), whose login and Remote Control need the real Anthropic API | Allows exact hosts only, checks the TLS server name, sees host, bytes and timing but never content, holds no secret |
| **Plain HTTP with an injected credential** | Clients you can point at a plain-HTTP URL (`gh`, `git`, `tea`, `curl`, `kubectl`) | Checks method and path against a preset, adds the credential, opens TLS upstream itself. The box never holds the token |

Per-repo scoping is the `repos` option of the `http` line, read-only repos its `repos-read`,
protected branches its `protect`; a GitHub App credential gets each line its own minted token.

## Contents

- [Install](#install)
- [The site file](#the-site-file)
- [Plain HTTP and credentials](#plain-http-and-credentials)
- [Presets](#presets)
- [Operating it](#operating-it)
- [What this does not stop](#what-this-does-not-stop)
- [Reference](#reference)

More detail lives in `docs/`:

- [docs/site-file.md](docs/site-file.md): every site-file rule, apply behaviour, upgrading
- [docs/presets.md](docs/presets.md): each preset's routes, the GitHub GraphQL check, limits
- [docs/design.md](docs/design.md): sockets and sandboxing, how a tunnel and web decide, why IPv4 only
- [docs/unlock.md](docs/unlock.md): pass credentials: unlock, lock, the expiry, the boundary
- [docs/github-app.md](docs/github-app.md): GitHub App credentials: setup, minting, revoking
- [docs/audit-log.md](docs/audit-log.md): what each log line holds
- [docs/testing.md](docs/testing.md): the test suites and the spike harness
- [docs/spike-results.md](docs/spike-results.md): what the first spike found

## Install

Works on Ubuntu, Debian, Arch and any other systemd + glibc Linux, on x86_64 or aarch64.

Envoy's apt repository is unmaintained, so every distribution gets Envoy's official release
binary. It is checked against the Envoy maintainers' release key, pinned by fingerprint
`0AFC E836 BA4D 1D35 763C 8523 D8CD C375 0181 F31F` (the key behind every release from v1.25.0,
January 2023, to v1.40.2). Nothing comes from the AUR or a third-party repository.

### 1. Prerequisites

```
sudo apt install curl gpg acl logrotate                 # Ubuntu / Debian
sudo pacman -S --needed curl gnupg acl logrotate        # Arch
```

GitHub App credentials also need `python3` and `openssl`; `airlock-envoy-cred ca` needs `openssl`.

### 2. Install Envoy and the service

Run these from a **clean clone that no airlock box mounts**. Both run as root and install code,
the release key and the built-in allowlist from the clone, so check `git status` first.

```
sudo install/install-envoy.sh 1.40.2          # binary -> /usr/local/libexec/airlock-envoy/envoy-1.40.2
sudo install/install-service.sh               # system account, units, airlock-envoy-apply, config
```

`install-envoy.sh`:

- downloads the binary and the signed checksum list;
- verifies the signature against the pinned key, and the binary against the list;
- refuses a changed binary, a broken signature or any other key;
- switches `/usr/local/bin/envoy` to the new version atomically.

`install-service.sh`:

- creates the `airlock-envoy` and `airlock-envoy-mint` system accounts (sysusers); it refuses if
  a login account of either name already exists;
- installs the units, `airlock-envoy-apply`, `airlock-envoy-cred` and `airlock-envoy-mint` in
  `/usr/local/sbin`, the GraphQL and push checks, and the mint's tmpfiles.d entry;
- enables the log rotation timer;
- runs `airlock-envoy-apply`, which renders `/etc/airlock-envoy/envoy.yaml` from
  `/etc/airlock-envoy/site.conf` and starts Envoy and one box socket per listener.

Without a site file there are no box sockets yet; the script says so. `install-service.sh
--site FILE [--yes]` installs FILE as the site file in the same step (see
[docs/site-file.md](docs/site-file.md#upgrading-from-one-global-client)).

Running `install-service.sh` again (to pick up a new built-in list, say) keeps the sockets that
running boxes hold.

### 3. Write the site file and apply it

Write `/etc/airlock-envoy/site.conf` (see [The site file](#the-site-file)). The smallest useful
one gives you a listener for Claude alone:

```
me  @anthropic
client me alice
```

Then:

```
sudo airlock-envoy-apply
```

### 4. Point a box at its socket

In the project, as the listener's user:

```
airlock egress proxy /run/airlock-envoy/<user>/<listener>.sock
```

This is claude-airlock's proxy posture: the box has no network of its own and every connection
goes through that socket.

### Updating Envoy

Run `install-envoy.sh` with the newer version, then `sudo systemctl restart airlock-envoy`.
Older versions stay in `/usr/local/libexec/airlock-envoy/` for rollback: `ln -sfn` the old one
back to `/usr/local/bin/envoy`. Restarts drop open connections, never the box sockets.

## The site file

`/etc/airlock-envoy/site.conf` defines **listeners**. Each listener is one box socket for one
user, and a box uses one socket, so each listener is a whole access profile. Examples: Claude
alone (`@anthropic`, the built-in list), or Claude plus the hosts one project needs. Keeping
profiles apart is the point: a box that can read internal data should not also reach the open
web.

Every socket has exactly one user, so no socket is shared between users. With an agent running
as its own user next to you, its listeners and credentials stay its own, and yours stay yours.

```
infra  @anthropic metrics.example.net:443 logs.example.net:443
infra  10.0.0.10:6443
client infra alice
```

That gives alice a socket at `/run/airlock-envoy/alice/infra.sock`. A fuller example is in
`configs/site.conf.example`.

| Entry | Meaning |
|---|---|
| `<listener> <destination>...` | A listener and what it may reach. Repeat the name to continue on another line. `#` starts a comment. |
| `host:port` | CONNECT to exactly this host and port. Only TLS whose server name (SNI) is that host passes, so other sites on the same address are out of reach. |
| `IPv4:port` | CONNECT to exactly this address and port. Only TLS with *no* server name passes. For hosts you run, not shared edges. |
| `@name` | Everything listener `name` allows. It must be defined above. Built in: `anthropic` (`api.anthropic.com:443`, `platform.claude.com:443`). |
| `web` | The public internet: any host name on port 443, through a separate Envoy whose kernel filter refuses every non-public address. Exact entries still win. |
| `http://<host>` | A plain-HTTP destination defined by an `http` line above (see [Plain HTTP](#plain-http-and-credentials)). |
| `client <listener> <user>` | The one user whose boxes may connect. Its own line, anywhere in the file. |
| `internal-name <domain>...` | Site-wide: names (and subdomains) `web` treats as internal, beyond the built-ins. |
| `internal-net <CIDR>...` | Site-wide: IPv4 or IPv6 ranges `web` refuses, beyond the built-ins. |
| `http <host> rules <preset> ...` | Site-wide: defines a plain-HTTP destination. |

Rules that matter most (full list in [docs/site-file.md](docs/site-file.md)):

- **One user per listener.** Each listener with a socket needs exactly one `client` line. A
  listener that another one includes may have none; it is then a definition only, with no
  socket (like the built-in `anthropic`). A listener that nothing includes must have a client.
- **The client must be a login account** (uid in the `UID_MIN`..`UID_MAX` range), not root or
  nobody, and outside every other user's `/etc/subuid` ranges. Make it a local account (in
  `/etc/passwd`): box sockets start at boot, before a directory service answers.
- **A credential belongs to one user.** If listeners of two users would reach the same
  credential, apply refuses. Give the second user a variant (`http <host>@<variant> ...`).
- **Name listeners after their user** (`alice-infra`, `agent-infra`) so the name in a box's
  config says whose it is.
- **Strict syntax.** Lowercase names, explicit ports, no wildcards, URLs or Windows line
  endings, and no IPv6 destinations. `admin`, `client`, `http`, `internal-name`, `internal-net` and `anthropic` are reserved as
  listener names, and `web` is a destination. A bad line stops the apply with its line number.

### Applying

| Command | Who | What |
|---|---|---|
| `sudo airlock-envoy-apply` | root | Check, render, validate and apply `/etc/airlock-envoy/site.conf` |
| `sudo airlock-envoy-apply [--yes] FILE` | root | Show FILE's change, ask (`--yes` skips), install it as the site file, apply |
| `airlock-envoy-apply --check [FILE]` | root (any user: without the credential and ca checks) | Check everything and show the change, without applying |
| `airlock-envoy-apply --list [FILE]` | any user who can read FILE | Print each listener's destinations |
| `airlock-envoy-apply --render [FILE]` | any user who can read FILE | Print the Envoy config |
| `airlock-envoy-apply --clients NAME [FILE]` | any user who can read FILE | Print listener NAME's client manifest |
| `airlock-envoy-apply --render-mint [FILE]` | any user who can read FILE | Print the GitHub App tokens apply would mint (`mint.conf`) |

An apply validates the new config with `envoy --mode validate` (as the service account), prints
the change in allowed destinations, swaps the config in atomically and restarts Envoy only if
the config changed or Envoy is down. If Envoy will not start with the new config, the previous
one goes back. Details, including what happens to sockets when listeners are added, moved or
removed: [docs/site-file.md](docs/site-file.md#what-an-apply-does).

**Keep the site file in version control.** Two ways to land it:

- **A config repo that deploys `/etc`** (rsync, Ansible, a deploy script): keep it at
  `etc/airlock-envoy/site.conf`. Run `airlock-envoy-apply --check <repo file>` before
  deploying, so a bad file never lands, and `airlock-envoy-apply` after it changes.
- **A file kept elsewhere** (a dotfiles repo): `sudo airlock-envoy-apply ~/dotfiles/site.conf`.
  It shows the change and asks before installing it, since anything running as you can edit
  that file. Do not symlink it into place: `/etc/airlock-envoy/site.conf` is applied without
  asking, so apply refuses it unless it is a regular file owned and writable only by root (and
  so is its directory).

The built-in `anthropic` list lives in `airlock-envoy-apply`. To update it, rerun
`install-service.sh` from an updated clean clone.

## Plain HTTP and credentials

For a service that needs a credential, or that sits on a shared front end, the box speaks
**plain HTTP** to Envoy and Envoy is the TLS client. Envoy:

1. checks method and path against a preset;
2. fixes the `Host` and server name, so no other site on the same address is reachable;
3. adds the credential;
4. verifies the service's certificate.

The box never holds the credential, and the plain-HTTP leg is a Unix socket, never a wire.

```
http  api.github.com      rules github-api  credential github-api
http  github.com          rules git         credential github-git
http  metrics.example.net rules victoria-metrics
dev   @anthropic web http://api.github.com http://github.com
client dev alice
```

### The `http` line

```
http <host>[:port][@variant] rules <preset> [credential <name>] [ca <name>] [projects <id>[,<id>...]]
     [repos <owner>/<repo>[,<owner>/<repo>...]] [repos-read <owner>/<repo>[,<owner>/<repo>...]]
     [protect <branch>[,<branch>...]]
```

It is site-wide and must come above any listener that uses it. A listener lists it as
`http://<host>` (or `http://<host>@<variant>`). The port defaults to 443.

- **An IPv4 host** (a Kubernetes API server named by address, as kubeconfigs do): Envoy sends
  no server name, and the certificate must name that address (an IP SAN). A listener cannot
  list an address both as `http://` and as a CONNECT entry.
- **`ca <name>`**: check the host's certificate against `/etc/airlock-envoy/ca/<name>.pem`
  alone instead of the system CAs, for a service with its own CA (a cluster's). Apply refuses
  a listener whose ca isn't set. The ca is the whole trust anchor: anything it signs for that
  address passes. (A k3s server CA also signs the node's kubelet certificate; Envoy never dials
  that, being pinned to the API port.)
- **Variants**: `http <host>@<variant> ...` is a second definition of the same host, with its
  own rules, credential and projects (a second identity, or narrower rules for one profile). A
  listener uses one definition per host, or several with `repos` or `repos-read` (below).
  ```
  http api.github.com        rules github-api    credential gh-dev
  http api.github.com@agent  rules github-issues credential agent-app projects PVT_kwDOAB12cd
  dev    @anthropic http://api.github.com
  agent  @anthropic http://api.github.com@agent
  ```
- **`projects`** (GitHub presets only): lets Projects v2 item writes through for those project
  IDs. See [docs/presets.md](docs/presets.md#projects-v2).
- **`repos`** (the `git`, `git-read`, `forgejo` and GitHub presets): the box's requests may name only those
  repos (`<owner>/*` for all of an owner's) to read, clone or write; on GitHub, GraphQL is
  refused, so `gh` works through `gh api` (REST). A listed repo's fork network stays readable
  through it. See [docs/presets.md](docs/presets.md#repo-scoping-repos).
  ```
  http github.com      rules git        credential github-git repos example-org/*,alice/tools
  http api.github.com  rules github-api credential github-api repos example-org/*,alice/tools
  ```
- **`repos-read`** (the same presets but `git-read`, which is read only already): repos the box
  may only read, on the same line as `repos` or alone. Their reads (GET and HEAD) and git fetch
  pass with the line's credential; a push, or an API write under the repo's path, gets 403
  "this repo is read only" (other writes, the generic refusal). So one token that may write some
  repos serves a box that should only read others. A repo is in one of the two lists
  (`<owner>/*` takes every repo of that owner). A writable repo can still act on a read-only
  one by reference (closing keywords, mentions). See
  [docs/presets.md](docs/presets.md#read-only-repos-repos-read).
  ```
  http api.github.com  rules github-api credential gh-api repos example-org/app repos-read alice/tools
  ```
- **`protect`** (the `git` and `forgejo` presets): branches a push may not create, update,
  force or delete (`<name>`, or `<prefix>/*` for every branch under it; any case). Envoy reads
  the push's ref updates before anything goes upstream and refuses the whole push if one names a
  protected branch; git shows the reason and `! [remote rejected]`. Opt-in per line, and per
  repo through two definitions of the host (one with `protect`, one without). Defense in depth:
  the server's own branch protection stays the main guard where it has one. See
  [docs/presets.md](docs/presets.md#protected-branches-protect).
  ```
  http github.com@deploy rules git credential gh-git repos example-org/config protect main,release/*
  http github.com@work   rules git credential gh-git repos example-org/app
  ```
- **A credential per repo**: a listener may list several definitions of one host if each has
  `repos` (or `repos-read`) and no repo is in two of them. Each repo's requests carry its own definition's
  credential (say an organisation's App for its repos and a personal token for your own).
  See [docs/presets.md](docs/presets.md#several-credentials-on-one-host).
  ```
  http api.github.com@org  rules github-api    credential org-app  repos example-org/*
  http api.github.com@me   rules github-issues credential alice-pat repos alice/tools
  agent  @anthropic http://api.github.com@org http://api.github.com@me
  ```
- **No tunnelling around it.** A host defined by an `http` line gets no CONNECT route in the
  listener, `web` included. Other names on the same front end (`www.`, aliases) are still
  ordinary `web` hosts; without the credential, that matters only for a preset without one on
  a public name.

### Credentials and CAs

All as root. Secrets come from stdin or a prompt, never the command line.

```
printf %s "$TOKEN" | sudo airlock-envoy-cred set github-api      # or omit the pipe for a prompt
sudo airlock-envoy-cred set github-git --format basic:x-access-token
sudo airlock-envoy-cred revoke github-api
sudo airlock-envoy-cred list
sudo airlock-envoy-cred ca cluster < ca.pem
```

- `set <name> [--format bearer|token|raw|basic:<user>]`: the default is `bearer`. For GitHub
  git use `basic:x-access-token`. Envoy uses the new value from the next request, no restart.
  `--file` turns a pass credential back into a file one, applied in one step
  ([docs/unlock.md](docs/unlock.md)).
- `remove <name>`: forgets a pass credential (locked first), or removes a GitHub App no line
  uses once nothing minted with it is left to revoke ([docs/github-app.md](docs/github-app.md)).
- `revoke <name>`: writes a value that grants nothing. Deleting the file would not work:
  Envoy keeps the last good value. Revoke it at the issuer too.
- `list`: file credentials (name, format, date), pass credentials (name, pass entry, format)
  and the CAs, never values. GitHub Apps are in `sudo airlock-envoy-cred status`.
- `ca <name>`: CA certificates only. It prints each one's SHA-256 fingerprint to compare with
  the source. Envoy reads CA files when it starts, so changing a ca already in use needs
  `sudo systemctl restart airlock-envoy`.

Apply refuses a listener whose credential isn't set.

**Pass credentials (unlocked for the working day).** A credential can instead live in the
operator's `pass` store, so it is not on disk in usable form and Envoy holds it only while
unlocked:

```
sudo airlock-envoy-cred add github-api --pass work/github-token   # locked until unlocked
airlock-envoy-cred migrate github-git --pass work/github-git      # a file credential -> pass (applies)
airlock-envoy-cred unlock [--for 2h]   # as yourself, on the host: pass show, then sudo
airlock-envoy-cred lock                # every pass credential, now
airlock-envoy-cred status
```

`unlock` reads only the entries of the pass credentials the applied config uses, and hands them
to Envoy (a tmpfs, root:airlock-envoy 0640) until `max_lifetime` (default 10h, at most 24h),
the next `expire_at` (both in `/etc/airlock-envoy/unlock.conf`) or `--for`, whichever is first.
Locked, a request using one gets **423 Locked** from Envoy itself (`x-airlock-envoy: locked`,
"credential <name> is locked on this host: ... do not retry"); nothing goes upstream. A box can
never unlock: see [docs/unlock.md](docs/unlock.md) for the boundary, the expiry and the limits.
File credentials work as before; the backend is per credential.

**GitHub App credentials (minted per line).** A credential can be a GitHub App installation:
each site-file line that uses it gets its own short-lived installation token, minted for that
line's repos with that line's permissions (and a read-only one for its `repos-read`), renewed
before it expires, revoked when replaced or locked. A separate service account
(`airlock-envoy-mint`) holds the App's key; Envoy only ever reads the tokens.

```
sudo airlock-envoy-cred add-app work-app --app-id 123 --org example-org --key pass:work/app.pem
sudo airlock-envoy-cred add-app work-app --app-id 123 --org example-org --key file < app.pem
http api.github.com@w rules github-api credential work-app repos example-org/app repos-read example-org/docs
http github.com@w     rules git        credential work-app repos example-org/app protect main
sudo -u airlock-envoy-mint /usr/local/sbin/airlock-envoy-mint check   # the installation's permissions vs what the lines ask
```

A pass key unlocks with the other pass credentials. Lines name their repos (no `<owner>/*`),
one owner each. See [docs/github-app.md](docs/github-app.md).

**Credentials are never logged.** Envoy's access log sees request headers *after* the credential
is added, so no rendered log format names a request header (a test checks this), and Envoy runs
at log level `warn`. The admin config dump shows secrets as `[redacted]`.

**A credential is only as secret as the upstream keeps it.** An upstream that echoes request
headers (an echo service, a debug endpoint, a misconfigured app) hands the injected value back
to the box. Use the `any` preset only for upstreams you trust not to reflect headers.

### Clients in the box

claude-airlock sets these up at launch from the client manifest:

| Client | Setup in the box |
|---|---|
| curl, anything that honours `http_proxy` | `http://<host>/` URLs |
| git | Keep ssh remotes on the host; in the box only, rewrite them, e.g. `url.http://github.com/.insteadOf git@github.com:` |
| gh | `http_unix_socket /run/airlock-envoy/<user>/<listener>.sock` in a box gh config, and any placeholder `GH_TOKEN` (Envoy replaces it) |
| kubectl | A box kubeconfig with `server: http://<host>` and no user (kubectl takes `http_proxy`; Envoy adds the token) |

**The client manifest.** Apply writes `/run/airlock-envoy/<user>/<listener>.clients` next to each
box socket (root, 0644, in the directory only that user may enter). It has one line per
plain-HTTP host, `<host> <upstream port> <rules> <credential: yes|no>`, and nothing secret (no
credential names or values). A box launcher reads it because the site file is root's. The socket
unit copies it from `/etc/airlock-envoy/clients/` when the socket starts (at boot too) and
removes it when the socket stops. A listener without plain-HTTP hosts gets one with comments
only. `airlock-envoy-apply --clients <listener>` prints it.

## Presets

Every preset is default deny: its routes, then 403. Full routes, the GitHub GraphQL check, the
headers Envoy strips from box requests, and the limits are in [docs/presets.md](docs/presets.md).

| Preset | Allows | Refuses (main points) |
|---|---|---|
| `victoria-metrics` | The query paths | Everything else |
| `victoria-logs` | The LogsQL query paths | Everything else |
| `git-read` | git fetch | Push |
| `git` | git fetch **and push to any branch the token can write**, including force-push, branch deletion and a push to `main` (so a merge, with no GraphQL check), but the branches of `protect` | Everything but smart HTTP |
| `forgejo` | Forgejo or Gitea for a bot account: git fetch and push, API reads, PR create and edit (including base and state), comments, labels, reviewers | Merge, reviews and approval, files written through the API, branch and tag API, releases, settings, hooks, keys, tokens, deletes, admin, the web UI, wiki git, token query parameters and form bodies |
| `kubernetes-read` | A Kubernetes API server, read only, plus `kubectl auth can-i` and `whoami` | Every write, protocol upgrades, escaped paths, exec, attach, port-forward, `proxy` subresources |
| `github-issues` | Reads; issue create, edit, close, reopen; comments, labels, assignees, reactions. GitHub numbers PRs as issues, so these also reach a PR's title, body, state, comments, labels and assignees | PR create, base, reviewers and code; merge, approve, auto-merge, settings, hooks, keys, deletes, Projects (unless `projects`) |
| `github-api` | The same, plus PR create, edit (including base branch), close, reopen, draft state, reviewers | Merge, approve, auto-merge, settings, hooks, keys, deletes, Projects (unless `projects`) |
| `any` | Every method but TRACE | TRACE |

With `git`, protect branches on the server (rulesets or branch protection), add `protect`, or
use `git-read`.
With `forgejo`, which branches and tags a push may touch is the server's protection. Both
GitHub presets check every `POST /graphql` write against an allowlist.

**What the presets don't bound** (the site's job):

- **Repo scoping is opt-in.** Without `repos`, a box can read any repo the token can (a GitHub
  token also reads every public repo), and write issues and comments in any it may write: it
  could copy a private repo into another repo's issue. Only the token's (or App installation's)
  repo list bounds this. With `repos` (or `repos-read`), GraphQL is refused, and a listed repo still reads its
  fork network (parent and forks) and can reach other repos by reference
  ([docs/presets.md](docs/presets.md#repo-scoping-repos)).
- **Label and comment writes also land on PRs**, where org automation (an auto-merge label, a
  comment-triggered workflow) can turn them into merges or deploys.
- **Assignment can start an agent.** Where an org has the Copilot coding agent on, assigning an
  issue to Copilot (`replaceActorsForAssignable`, REST assignees) makes GitHub write code and
  open a PR, even from an issues-only box. The presets do not refuse this: turn the agent off
  where the token reaches.
- **`kubernetes-read` reads whatever the token's RBAC allows**, Secrets included if it may.
- **`forgejo`**: a push may create, force-push or delete any branch or tag the server doesn't
  protect; edits reach other people's issues, PRs and comments; set `DISABLE_QUERY_AUTH_TOKEN`
  on the server too.

## Operating it

### Status

```
airlock-envoy-apply --status
```

Shows Envoy, the kill switch, and each box socket with its state, its user and who may connect.
Any user may run it, and sees the files of their own directory only. As root it also says
whether the running config and socket drop-ins are the site file's; they are not after a failed
apply ("Applied: NO").

### The kill switch

```
sudo airlock-envoy-apply --stop       # cut all box egress, and keep it cut
sudo airlock-envoy-apply --start      # lift it, apply, start everything
```

`--stop` stops Envoy and every box socket and writes `/etc/airlock-envoy/stopped`. While that
file exists, the units do not start: not at boot, not on a box connection, not by `systemctl
start`. An apply or `install-service.sh` still updates the config but starts nothing.

`--start` makes new socket files, so boxes need a relaunch afterwards.

`--stop` cuts egress only. Unlocked pass credentials stay unlocked until their expiry, and
`airlock-envoy-mint.timer` keeps renewing GitHub App tokens; with Envoy down nothing can use them.
To drop them as well, `airlock-envoy-cred lock` (a pass-key App's tokens are revoked too).

Stopping units by hand also cuts egress, but only until the next apply, which treats a stopped
or failed Envoy or box socket as something to recover (a crash looks the same).

### Recovery

- Box sockets outlive Envoy. Restarts, updates and crashes drop open connections, never the
  socket a running box holds. While Envoy is down, box connections are closed; once it is back,
  the same socket works again, with no relaunch.
- Envoy restarts after failures with no start limit, backing off from 2 s to a minute between
  tries, so after a crash loop it comes back by itself once the cause is gone. An apply also
  restarts it at once.

How the two socket layers make this work: [docs/design.md](docs/design.md#two-layers-of-sockets).

### Logs

| Log | What |
|---|---|
| `/var/log/airlock-envoy/access.jsonl` | The audit log: every allowed and refused request and tunnel, with the listener and user |
| `/var/log/airlock-envoy/web.jsonl` | The web Envoy: profile, server name, chain, upstream address |

Both are JSON lines, readable by root and the service account only. logrotate rotates each at
100 MiB or once a day (checked every 15 minutes, so a flood can still outgrow that between
checks) and removes rotated files by age only, at a rotation once they are older than 30 days;
nothing ships them anywhere yet.
Field-by-field detail: [docs/audit-log.md](docs/audit-log.md).

A refusal tells the box why: the 403's body names the listener and what would change it (a
host not in its list, a host that isn't one of its plain-HTTP destinations, or a method and
path its rules don't allow), so boxed Claude can report the cause instead of guessing.

## What this does not stop

- **Data sent to Anthropic itself.** The box holds a Claude login and can talk to
  `api.anthropic.com`, so it can put data into requests there, including with an API key for
  someone else's account, or by asking server-side tools such as web fetch to reach a URL.
  Without decrypting TLS, the proxy cannot see or stop this.
- **The login in the box.** The tunnel carries the box's own credential; it does not hold or
  inject one.
- **Data sent anywhere public, through `web`.** A listener with `web` can reach any public host;
  the web log names each one. Narrow a profile to exact entries when that matters.
- **The resolver, through `web`.** It is allowed by address, on every port, and a hostile public
  name can point at it. Harmless for a loopback resolver that strips private answers (Unbound
  `private-address`). A resolver on a LAN address (a home router) exposes whatever that host
  serves on 443 to `web`.
- **A NAT64 prefix of your own.** The well-known `64:ff9b::/96` is denied, but `web` is IPv4 only
  anyway. If IPv6 comes back, add a network-specific NAT64 prefix to `internal-net`.
- **A different site inside a matched TLS session.** Once the SNI matches, the HTTP `Host` is
  encrypted. Asking `api.anthropic.com` for another Anthropic site's `Host` is refused today by
  the CDN (403), which is its policy, not this proxy's.
- **A host name that resolves to the host itself or its LAN.** CONNECT entries are not checked
  for what they resolve to.
- **What the presets don't bound**: see [Presets](#presets) and
  [docs/presets.md](docs/presets.md#limits).

## Reference

### What the install sets up

| Path | Owner, mode | What |
|---|---|---|
| `/run/airlock-envoy/<user>/<listener>.sock` | airlock-envoy, ACL: owner and `<user>` rw | The socket a box gets, one per listener |
| `/run/airlock-envoy/<user>/<listener>.clients` | root, 0644 | The listener's client manifest |
| `/run/airlock-envoy/<user>/` | root, 0700, ACL: `<user>` r-x | That user's sockets and manifests; no other user may enter or list it |
| `/run/airlock-envoy/` | root, 0755 | Made by each socket's start, for the users' directories |
| `/etc/systemd/system/airlock-envoy-proxy@<listener>.socket.d/client.conf` | root, 0644 | The listener's socket path and its user's uid, from the site file |
| `/etc/airlock-envoy/site.conf` | yours to write; root:airlock-envoy 0640 when installed by apply | This host's listeners |
| `/etc/airlock-envoy/envoy.yaml`, `allowed` | root:airlock-envoy, 0640 | Rendered config; what was last applied |
| `/etc/airlock-envoy/stopped` | root, 0644 | The kill switch, while it exists |
| `/run/airlock-envoy-internal/` | airlock-envoy, 0700 | Envoy's own sockets, including admin; never given to anyone |
| `/var/log/airlock-envoy/access.jsonl` | airlock-envoy, 0600 (dir 0750) | The audit log (rotated: `access.jsonl-<time>`, then `.gz`) |
| `/etc/airlock-envoy/credentials/<name>.yaml` | root:airlock-envoy, 0640 (dir 0750) | Credentials for plain-HTTP destinations, written by `airlock-envoy-cred` |
| `/etc/airlock-envoy/ca/<name>.pem` | root, 0644 (dir root:airlock-envoy 0750) | CAs for plain-HTTP hosts with `ca <name>` |
| `/etc/airlock-envoy/clients/` | root:airlock-envoy, 0750 | Each listener's client manifest, copied into its user's directory when its socket starts |
| `/etc/airlock-envoy/site.conf.prev` | as `site.conf` | The site file a `--site` install replaced |
| `/etc/airlock-envoy/pass/<name>` | root, 0600 (dir 0700) | A pass credential: its pass entry and format, no secret |
| `/etc/airlock-envoy/unlock.conf` | yours to write (optional) | `max_lifetime`, `expire_at` for unlocks |
| `/run/airlock-envoy-cred/secrets/<name>.yaml` | root:airlock-envoy, 0640 (dir 0750; a tmpfs) | Each pass credential, unlocked or the locked marker |
| `/run/airlock-envoy-cred/state`, `.lock` | root, 0644 / 0600 | Locked or unlocked, until when; one verb at a time |
| `/etc/airlock-envoy-mint/`, `apps/` | root:airlock-envoy-mint, 0750 | GitHub Apps (`apps/<name>`, a file key `apps/<name>.pem`, 0640) and `mint.conf` (0640, written by apply) |
| `/run/airlock-envoy-mint/` | root, 0755 (tmpfiles.d) | `keys/` (root:airlock-envoy-mint 0750, unlocked keys 0440) and `.lock` are root's; `tokens/` (airlock-envoy-mint:airlock-envoy 2750, tokens 0640), `minted/` and `installations/` (0700) the mint account's |
| `/usr/local/sbin/airlock-envoy-apply`, `airlock-envoy-cred`, `airlock-envoy-mint` | root, 0755 | The apply tool, the credential helper, the minter |
| `/etc/airlock-envoy/logrotate.conf` | root, 0644 | Log rotation, run by its own timer (not `/etc/logrotate.d`) |
| `/usr/local/share/airlock-envoy/github-graphql.lua`, `git-protect.lua` | root, 0644 | The GitHub GraphQL write check; the push check of `protect` |
| `/var/lib/airlock-envoy/logrotate.status` | root | Log rotation's state |
| `/etc/airlock-envoy/envoy-web.yaml` | root:airlock-envoy, 0640 | The web Envoy's config, while a listener lists `web` |
| `/etc/systemd/system/airlock-envoy-web.service.d/site.conf` | root, 0644 | Web's kernel filter: the site's `internal-net`, the resolvers allowed |
| `/run/airlock-envoy-web/<listener>.sock` | airlock-envoy (dir 0700) | The web Envoy's socket for each web profile (only the main Envoy connects) |
| `/var/log/airlock-envoy/web.jsonl` | airlock-envoy, 0600 | The web Envoy's log |

### Units

| Unit | Role |
|---|---|
| `airlock-envoy.service` | The main Envoy; `airlock-envoy-cred boot` runs as root before it starts (locked pass credentials, App token files) |
| `airlock-envoy-proxy@<listener>.socket` | A box socket, in its user's directory |
| `airlock-envoy-proxy@<listener>.service` | `systemd-socket-proxyd`, relaying box connections to Envoy |
| `airlock-envoy-web.service` | The web Envoy, enabled only while a listener lists `web` |
| `airlock-envoy-logrotate.timer`, `.service` | Every 15 minutes, logrotate with `/etc/airlock-envoy/logrotate.conf` and its own state (`/var/lib/airlock-envoy/`) |
| `airlock-envoy-cred-expire.timer`, `.service` | Every 30 s while unlocked: locks at the deadline. Started by `unlock`, stopped by `lock` |
| `airlock-envoy-mint.timer`, `.service` | Every 5 minutes, as `airlock-envoy-mint`: mints, renews and revokes App tokens. Enabled by apply while a line uses an App, and until every token is revoked after the last goes |

### Limits at a glance

| Limit | Value |
|---|---|
| Box connections at once, per listener | 128 |
| Time to send request headers | 10 s |
| Idle connection with no request open | closed after about a minute |
| Idle CONNECT tunnel | cut after 1 h without bytes |
| Plain-HTTP stream | 5 minutes, except git and Kubernetes reads (see [docs/presets.md](docs/presets.md#limits)) |
| GitHub GraphQL, per listener | 10 requests/s (bursts of 20), 64 KiB bodies, 8192 tokens, 50 mutation fields |

### Tests

`test/run-all.sh` runs every suite. See [docs/testing.md](docs/testing.md).

This repository is public. Keep site details out of it, commit messages included: names of
people and hosts, domains, addresses, anything from one site's config; use stand-ins (`alice`,
`example.org`, `10.0.0.10`). `scripts/private-names-check` checks against your own list of
patterns, kept outside the repo (one regex per line in `~/.config/claude-airlock/private-names`,
or the file `AIRLOCK_PRIVATE_NAMES` or `git config airlock.privateNames` names). The hooks in
`hooks/` run it on each commit (`git config core.hooksPath hooks`); before publishing, run it
over what you're about to push: `scripts/private-names-check --range origin/main..main`.

## Licence

AGPL-3.0-or-later.
