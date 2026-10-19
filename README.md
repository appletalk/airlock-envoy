# airlock-envoy

Envoy as the one egress and credential proxy for [claude-airlock](https://github.com/appletalk/claude-airlock)
boxes. A box runs with `--network none` and reaches the outside only through Unix sockets that
airlock mounts in. Envoy listens on those sockets on the host, decides what passes, and logs every
decision.

Two modes, both on sockets, neither decrypting TLS:

- **CONNECT tunnel with a hostname allowlist, one per socket.** For clients that must talk TLS end
  to end, such as Claude Code (`HTTPS_PROXY`), whose login and Remote Control need the real
  Anthropic API. The proxy sees host, TLS server name, bytes and timing, never content, and holds
  no secret. The built-in `anthropic` socket allows Claude only; a host's site file adds more
  sockets, each a whole access profile (see [Site listeners](#site-listeners)).
- **Plain HTTP with an injected credential.** For clients that can be pointed at a plain-HTTP
  URL (`gh`, `git`, `curl`): Envoy checks method and path against a preset, adds the
  credential, and opens TLS upstream itself, so the box never holds the token (see
  [Plain HTTP and credentials](#plain-http-and-credentials)). Not yet: per-repo scoping,
  branch-only pushes and minted per-repo tokens (an `ext_authz` decision service).

Status: **spike**, with an install path tested on Ubuntu 22.04, 24.04 and 26.04, Debian 13 and
Arch (systemd-booted containers), and run as a service on an Arch workstation.

## Install (Ubuntu, Debian, Arch, any systemd + glibc Linux)

Envoy's apt repository is unmaintained, so this installs Envoy's official release binary on
every distribution, after checking it against the Envoy maintainers' release key (pinned
fingerprint `0AFC E836 BA4D 1D35 763C 8523 D8CD C375 0181 F31F`, the key behind every release
from v1.25.0 in January 2023 to v1.39.4). Nothing comes from the AUR or a third-party repo.

Prerequisites:

```
sudo apt install curl gpg acl                 # Ubuntu / Debian
sudo pacman -S --needed curl gnupg acl        # Arch
```

As root, from a clean clone that **no airlock box mounts** (both scripts run as root and
install code, the release key and the egress allowlist from it; check `git status` first):

```
sudo install/install-envoy.sh 1.39.4          # binary -> /usr/local/libexec/airlock-envoy/envoy-1.39.4
sudo install/install-service.sh "$USER"       # system account, units, airlock-envoy-apply, config
```

- `install-envoy.sh` downloads the binary and the signed checksum list, verifies the
  signature against the pinned key and the binary against the list, and switches
  `/usr/local/bin/envoy` to the new version atomically. It refuses a changed binary, a broken
  signature and any other key (tested). **Updating** is the same command with a newer
  version, then `sudo systemctl restart airlock-envoy`; older versions stay in
  `/usr/local/libexec/airlock-envoy/` for rollback (`ln -sfn` the old one back).
- `install-service.sh <user>` creates the `airlock-envoy` system account (sysusers; it refuses
  an existing login account of that name), installs the units and
  `/usr/local/sbin/airlock-envoy-apply`, and runs it: that renders the config,
  `/etc/airlock-envoy/envoy.yaml` (root:airlock-envoy 0640), from the built-in `anthropic`
  listener plus `/etc/airlock-envoy/site.conf` if there is one, and starts Envoy and a box
  socket per listener. `<user>` is the account whose boxes may connect: each box socket gets an
  ACL for its numeric uid (rootless containers drop supplementary groups, so a group would not
  work). Running it again, say to change the user or to update the built-in list, keeps the
  sockets that running boxes hold. An install from before site files is upgraded in place
  (its `tunnel-anthropic.yaml` goes; the socket stays).
- **Two layers of sockets.** Envoy cannot take a listening socket from systemd, so systemd
  creates each box socket (`airlock-envoy-proxy@<listener>.socket`) in the root-owned
  `/run/airlock-envoy/`, and `systemd-socket-proxyd` relays each connection to Envoy's own
  socket in `/run/airlock-envoy-internal/` (0700). Only root can rename anything where the box
  socket lives, so neither Envoy nor anything running as you can swap it for something else
  (claude-airlock requires exactly that, and its own check accepts the socket; the install
  test runs it). The box socket also outlives Envoy: restarts, updates and crashes drop open
  connections, never the socket a running box holds. The relay only `Wants=` Envoy and
  connects to it afresh for each box connection, so while Envoy is down box connections are
  closed, and once it is back the same socket works again, with no relaunch (tested with a
  burst of connections over systemd's socket trigger limit while Envoy is down). A box
  connection to an idle socket starts the relay, and the relay starts Envoy if it is stopped.
  Envoy itself is restarted after failures with no start limit, backing off from 2 s to a
  minute between tries, so after a crash loop it comes back by itself once the cause is gone;
  an apply also restarts it at once.
- **Cutting egress (the kill switch):** `sudo airlock-envoy-apply --stop` stops Envoy and every
  box socket and writes `/etc/airlock-envoy/stopped`; while that exists the units do not start
  (not at boot, not by a box connection, not by `systemctl start`), and an apply or
  `install-service.sh` updates the config without starting anything. `sudo airlock-envoy-apply
  --start` lifts it. Starting makes new socket files, so boxes need a relaunch afterwards.
  Stopping units by hand also cuts egress, but only until the next apply, which treats a
  stopped or failed Envoy or box socket as something to recover (a crash looks the same).
- Envoy and the relay run as `airlock-envoy` with no capabilities and systemd's sandboxing
  (read-only system, no home, private /tmp and devices, a syscall allowlist, no core dumps,
  no swap; the relay also has no network at all). Envoy's allocator needs `mincore`, the one
  syscall added to `@system-service`.
- The relay has no start-rate limit, so however often it stops it is started again by the next
  box connection (tested: eight Envoy restarts in a row with a relay running keep the socket
  working).

What it sets up:

| Path | Owner, mode | What |
|---|---|---|
| `/run/airlock-envoy/<listener>.sock` | airlock-envoy, ACL: owner and `<user>` rw | the socket a box gets, one per listener |
| `/run/airlock-envoy/` | root, 0755 | created by systemd for the box sockets |
| `/etc/airlock-envoy/site.conf` | yours to write; root:airlock-envoy 0640 when installed by apply | this host's listeners |
| `/etc/airlock-envoy/envoy.yaml`, `allowed` | root:airlock-envoy, 0640 | rendered config; what was last applied |
| `/run/airlock-envoy-internal/` | airlock-envoy, 0700 | Envoy's own sockets, incl. admin; never given to anyone |
| `/var/log/airlock-envoy/access.jsonl` | airlock-envoy, 0600 (dir 0750) | the audit log |
| `/etc/airlock-envoy/credentials/<name>.yaml` | root:airlock-envoy, 0640 (dir 0750) | credentials for plain-HTTP destinations, written by `airlock-envoy-cred` |
| `/usr/local/sbin/airlock-envoy-cred`, `/usr/local/share/airlock-envoy/github-graphql.lua` | root | the credential helper; the GitHub GraphQL write check |
| `/etc/airlock-envoy/envoy-web.yaml` | root:airlock-envoy, 0640 | the web Envoy's config, while a listener lists `web` |
| `/etc/systemd/system/airlock-envoy-web.service.d/site.conf` | root, 0644 | web's kernel filter: the site's `internal-net`, the resolvers allowed |
| `/run/airlock-envoy-web/<listener>.sock` | airlock-envoy (dir 0700) | the web Envoy's socket for each web profile (only the main Envoy connects) |
| `/var/log/airlock-envoy/web.jsonl` | airlock-envoy, 0600 | the web Envoy's log: profile, server name, chain, upstream address |

Put a project's box behind a socket with `airlock egress proxy /run/airlock-envoy/<listener>.sock`
(claude-airlock's proxy posture: no network of its own, every connection through that socket).

`test/install-test.sh ubuntu[-22.04|-24.04|-26.04]|debian|arch` runs the whole install in a
systemd-booted container and checks the result: owners, modes and the ACL, the client's
tunnel and refusals, that other users cannot reach either socket, that the log is private,
that the box socket survives Envoy restarts (eight in a row too) and a reinstall, and (with
`AIRLOCK_REPO=<claude-airlock checkout>`) that claude-airlock's own socket check accepts it.
Then site listeners: one added gets its socket and ACL and reaches exactly its list while the
`anthropic` socket is untouched; an unchanged apply does not restart Envoy; a bad site file
changes nothing; a file from elsewhere needs a confirmation; a removed listener loses its
socket; and a config Envoy will not start with is rolled back. With `OLD_REPO=<earlier
checkout>` it installs that first and checks the upgrade keeps the socket.
`install-envoy.sh` runs in the test image's build, so the download repeats only when the
script, the release key or the version changes. The test runs inside one `podman unshare` and
enters the container with `nsenter` (about 2 ms a command, against about 160 ms for
`podman exec`); about 20 s a distribution.

**All the tests at once:** `test/run-all.sh [distro...]` runs the install test on Arch, Debian
13 and Ubuntu 26.04 (the default; name others to change it) in parallel, and alongside them the
parser, t2 and the site checks, then prints each suite's result and time (about 20 s in all on
a 20-thread workstation, from about 115 s). `OLD_REPO` and `AIRLOCK_REPO` pass through.

## Site listeners

A box has one `HTTPS_PROXY`, so it uses one socket, and a socket is one allowlist. So each
listener is a whole access profile: `anthropic` (built in) for Claude alone, and whatever a
host adds, say Claude plus the hosts one project's work needs. Keeping profiles apart is the
point: a box that can read internal data should not also reach the open web.

`/etc/airlock-envoy/site.conf` (see `configs/site.conf.example`):

```
infra  @anthropic metrics.example.net:443 logs.example.net:443
infra  10.0.0.10:6443
```

- `host:port`: CONNECT to exactly this host and port; only TLS whose server name (SNI) is that
  host passes, so another site on the same address is out of reach, as for `anthropic`.
- `IPv4:port`: CONNECT to exactly this address and port; only TLS that sends *no* server name
  passes (clients send none for an address: checked for curl, Python and Go, which kubectl
  uses). A kubeconfig with `tls-server-name` set does send one and is refused. Meant for hosts
  you run, such as a Kubernetes API server addressed by IP: on a shared edge, the HTTP `Host`
  inside TLS could still pick another site. Loopback, `0.0.0.0/8`, link-local and multicast
  addresses are refused; a host name is not checked for what it resolves to, so a name that
  resolves to the host itself or its LAN reaches it.
- `@name`: everything listener `name` allows, defined above (so no cycles; a listener cannot
  be extended once included). Repeat a name to continue it on another line.
- `web`: the public internet, any host name on port 443 (see *How web decides*). A listener's
  exact entries still win, so `infra metrics.example.net:443 web` with `internal-name
  example.net` reaches metrics and the public web, but no other `example.net` name.
- `internal-name <domain>...` and `internal-net <CIDR>...` (site-wide lines, not listeners):
  what web treats as internal beyond the built-ins. Names: `localhost`, `local`, `localdomain`,
  `internal`, `lan`, `home.arpa` and their subdomains. Addresses: everything not public (in
  `airlock-envoy-web.service`). Use `internal-net` for internal ranges that are publicly
  routable (a company's own blocks) and for **your own public addresses**, which lead back in
  to your services. CIDRs are checked strictly: systemd skips an entry it can't parse, and a
  skipped deny would fail open.
- Strict syntax: lowercase names, explicit ports, no wildcards, URLs, IPv6 or Windows line
  endings; `admin` and `anthropic` are reserved. A bad line stops the apply with its line number.

`sudo airlock-envoy-apply` renders the config, checks it with `envoy --mode validate` (as the
service account), prints the change in allowed destinations against the last apply, swaps the
config in atomically and restarts Envoy (only if the config changed or Envoy is down; with the
kill switch on, nothing is started). Then it starts a socket
for each new listener and removes the socket of each listener that is gone, so a box set to it
no longer launches. If Envoy does not start with the new config, the previous one goes back.
`--check` does all the checking and shows the change without applying; `--list` and
`--render` work as any user. `--status` shows Envoy, the kill switch and each box socket with
its state and who may connect (any user; as root also whether the running config is the site
file's, which it is not after a failed apply). Any site file named on the command line other than the literal
`/etc/airlock-envoy/site.conf` counts as from elsewhere, symlinks into `/etc` included.

Keep the site file in version control. Two ways to land it:

- **A config repo that deploys `/etc`** (rsync, Ansible, a deploy script): put it at
  `etc/airlock-envoy/site.conf`, run `airlock-envoy-apply --check <repo file>` before
  deploying, so a bad file never lands, and `airlock-envoy-apply` after it changes.
- **A file kept elsewhere** (a dotfiles repo): `sudo airlock-envoy-apply ~/dotfiles/site.conf`
  shows the change and asks before installing it as `/etc/airlock-envoy/site.conf`, since
  anything running as you can edit that file. `--yes` skips the question. Do not symlink it
  into place instead: `/etc/airlock-envoy/site.conf` is applied without asking, so apply
  refuses it unless it is a regular file owned and writable only by root (and so is the
  directory).

The built-in `anthropic` list lives in `airlock-envoy-apply`, so updating it is this repo's job:
rerun `install-service.sh` from an updated clean clone.

## Plain HTTP and credentials

For a service the box needs credentials for, or that sits on a shared front end, the box
speaks **plain HTTP** to Envoy and Envoy is the TLS client: it checks the request against a
preset (methods and paths), fixes the `Host` and server name (so no other site on the same
address is reachable), adds the credential, and verifies the service's certificate. The box
never holds the credential, and the plain-HTTP leg is a Unix socket, never a wire.

```
http  api.github.com      rules github-api  credential github-api
http  github.com          rules git         credential github-git
http  metrics.example.net rules victoria-metrics
dev   @anthropic web http://api.github.com http://github.com
```

- `http <host>[:port] rules <preset> [credential <name>]` (site-wide, above its use) defines
  the destination; a listener lists it as `http://<host>`.
- **Variants**: `http <host>@<variant> ...` is another definition of the same host, with its
  own rules, credential and projects (a second identity, or narrower rules for one profile);
  a listener lists it as `http://<host>@<variant>`. A listener uses one definition per host.
  ```
  http api.github.com       rules github-api    credential gh-dev
  http api.github.com@agent  rules github-issues credential agent-app projects PVT_kwDOAB12cd
  dev   @anthropic http://api.github.com
  agent  @anthropic http://api.github.com@agent
  ```
- **Projects (v2)**: on the GitHub presets, `projects <id>[,<id>...]` (project node IDs,
  `PVT_...`) lets four item writes through (`updateProjectV2ItemFieldValue`,
  `clearProjectV2ItemFieldValue`, `addProjectV2ItemById`, `archiveProjectV2Item`), and only
  when the mutation's `input.projectId` is one of them: a plain string in the query, or a
  variable in the body's `variables` (an operation's default value is not read). Anything
  the check can't resolve for certain is refused; `deleteProjectV2Item` too (removing an
  item); project, field and view settings stay refused. Without `projects`, all Projects
  writes are refused. Limits:
  - That an item, field or value ID belongs to the named project is GitHub's check, not this
    one (verify it live before relying on the pin).
  - `addProjectV2ItemById` takes any content ID, so a box can put any issue it can read
    (another repo's, a private one's) on the pinned board.
  - GitHub adds items to boards by itself: org auto-add workflows, and an issue template with
    `projects:` (createIssue with an `issueTemplate`) can add items to boards the box never
    names.
  `http` is a reserved word (no listener of that name). That exact name gets no CONNECT route in
  the listener, `web` included, so the credentialed path can't be tunnelled around. Other
  names on the same front end (`www.`, aliases) are still ordinary `web` hosts: without the
  credential that matters only for a preset without one on a public name.
- **Presets** (default deny, in `airlock-envoy-apply`): `victoria-metrics`, `victoria-logs`
  (the query paths), `git-read` (fetch only), `git` (fetch **and push, to any branch the token
  can write**: force-push, branch deletion and a push to `main` included, so a merge without
  any GraphQL check; protect branches on the server, rulesets or branch protection, or use
  `git-read`),
  `github-issues` (reads; issue create, edit, close, reopen, comments, labels, assignees,
  reactions; no PR writes), `github-api` (the same plus PR create, edit including the base
  branch, close, reopen, draft state, reviewers; refused in both: merge, approve, auto-merge,
  settings, hooks, keys, deletes, Projects, anything else), `any` (every method but TRACE).
  REST numbers PRs as issues, and GraphQL comment, label and assignee writes take any node ID,
  so `github-issues` also reaches a PR's comments, labels, assignees, title, body and state
  (not its base, reviewers or code).
- **GitHub writes go through `POST /graphql`**, so both GitHub presets run a check on that
  route (`install/github-graphql.lua`): queries pass; a mutation passes only if every top-level
  field is on the preset's allowlist (as gh 2.102 sends them: `replaceActorsForAssignable` for
  assignees, `requestReviewsByLogin` for reviewers) and its `input` is readable and names no
  project except as null (`projectIds`, `projectV2Ids` would skip the `projects` pin; gh
  sends `projectIds: null` on every issue create with labels or assignees); `mergePullRequest`, review approval, ref
  and branch-protection changes are refused, and so is any body it can't read for certain, a
  query string, a Content-Type other than JSON, a compressed body, and any error while
  checking. Every other `/graphql` form (any method, case or suffix) is refused. LuaJIT's
  compiler is off (the unit's `MemoryDenyWriteExecute` would make it panic Envoy).
- **What one box can cost the others**: the check runs on Envoy's worker threads, which every
  listener shares, so it is bounded per listener: 10 GraphQL requests a second over all its
  GitHub hosts (bursts of 20, then 429), bodies up to 64 KiB (then 413), 8192 GraphQL tokens
  and 50 mutation fields. A worst-case body costs about 20 ms of CPU in Envoy, so one listener can keep about
  a fifth of one worker busy. Every plain-HTTP stream but git's ends after 5 minutes, so a
  body sent slowly can't hold a connection.
- Paths are normalized before the rules see them (dot segments, merged slashes) and an escaped
  slash is refused. Headers a box sends that steer Envoy or claim a client or method are
  removed before anything else: `x-envoy-*`, `x-forwarded-*`, `forwarded`, `x-real-ip`,
  `x-client-ip`, `x-original-url`, `x-rewrite-url`, `x-request-id` and the method overrides
  (`x-http-method(-override)`, `x-method-override`). A header name with an underscore is
  refused outright (400): Rack and CGI servers read `x_http_method_override` as the dashed
  name. Envoy adds no headers of its own.
- **Credentials**: `printf %s "$TOKEN" | sudo airlock-envoy-cred set github-api` (or from a
  prompt; `--format bearer|token|raw|basic:<user>`; for GitHub git, `basic:x-access-token`).
  Envoy uses a new value from the next request, no restart. `revoke` writes a value that grants
  nothing (deleting the file would not: Envoy keeps the last good value). `list` shows names
  and dates, never values. Apply refuses a listener whose credential isn't set.
- **Never logged**: Envoy's access log sees request headers *after* the credential is added, so
  no rendered log format names a request header (a test checks it), and Envoy runs at `warn`.
- **A credential is only as secret as the upstream keeps it.** An upstream that echoes request
  headers (an echo service, a debug endpoint, a misconfigured app) hands the injected value
  back to the box. Use `any` only for upstreams you trust not to reflect headers.
- **What the presets don't bound** (the site's job): no repo scoping, so a box can read any repo
  the token can and write issues and comments in any of them, e.g. copy a private repo into
  another repo's issue (only the token's or App installation's repo list bounds it); and label
  and comment writes also land on PRs, where org automation (an auto-merge label, a
  comment-triggered workflow) can turn them into merges or deploys. Assignment can start an
  agent: where an org has the Copilot coding agent on, assigning an issue to Copilot
  (`replaceActorsForAssignable`, REST assignees) has GitHub write code and open a PR, from an
  issues-only box. The presets do not refuse it: turn the agent off where the token reaches.
  The admin config dump shows secrets as `[redacted]`.
- **Clients in the box**: curl and anything that honours `http_proxy` use `http://<host>/`
  URLs. git keeps its ssh remotes on the host: in the box only, a config rewrites them, e.g.
  `url.http://github.com/.insteadOf git@github.com:`. gh: `http_unix_socket
  /run/airlock-envoy/<listener>.sock` in a box gh config, and any placeholder `GH_TOKEN`
  (Envoy replaces it). claude-airlock sets both up at launch from the client manifest.
- **Client manifest**: apply writes `/run/airlock-envoy/<listener>.clients` next to each box
  socket (root, 0644; `--clients <listener>` prints it): one line per plain-HTTP host,
  `<host> <upstream port> <rules> <credential: yes|no>`, and nothing secret (no credential
  names or values). A box launcher reads it, since the site file is root's. The socket unit
  copies it from `/etc/airlock-envoy/clients/` when the socket starts (at boot too) and removes
  it when the socket stops; a listener without plain-HTTP hosts gets one with comments only.

## How a tunnel decides

The config `airlock-envoy-apply` renders (`--render` prints it):

1. The HTTP listener on each socket accepts `CONNECT <host>:<port>` only for an exact entry
   of its own list (for `anthropic`: `api.anthropic.com` and `platform.claude.com`, on
   443). Any other host, port, IP address or spelling, another listener's entries, and any
   other request are refused: 403 from a deny route, or a 4xx from the HTTP parser for a
   malformed one (`OPTIONS *` gets 404).
2. An allowed tunnel goes to an internal listener for that destination. It reads the TLS
   server name (SNI) from the client's handshake without decrypting, and passes the connection
   on only if the SNI equals the CONNECT host (for an address entry: only if there is no SNI).
   Otherwise, or without TLS, it closes the connection.
3. The upstream is fixed per destination, resolved by Envoy or a fixed address. The client
   never chooses an address.

Step 2 matters because the allowed names share their address with many other sites (other
Anthropic properties on the same CDN edge). Without it, `CONNECT api.anthropic.com:443` with
another SNI reached those sites.

Limits: 128 connections from boxes at once per listener, so a profile at its cap does not
starve another (refusals over the cap show only in Envoy's stats,
`connection_limit.<listener>.limited_connections`, not in the access log; `site-checks.sh`
tests it), 10 s to send request headers,
and a tunnel is cut after 1 h without bytes. In practice the CDN closes an idle TLS connection
much sooner (about 15 s without a request).

## How web decides

1. On the box's listener, after its exact entries: a CONNECT authority that is an internal name
   (built in or `internal-name`, any case) gets 403. Anything else that is a host name with an
   alphabetic top-level label on port 443 goes, as raw TLS, to the web Envoy
   (`airlock-envoy-web`, its own unit). IP literals, single labels and other ports never match
   and get 403.
2. Each web profile has its own listener in the web Envoy, so its own DNS cache (one profile
   filling it doesn't stall another) and its own name in the web log. The filter chain is
   picked from the TLS server name **before any filter runs**: an internal name, no name, an
   IP literal or a name without a dot gets no chain that has an upstream, so nothing is
   dialled. The CONNECT host and the server name may differ; each side checks its own.
3. Envoy resolves the server name itself, **IPv4 only** (A records), without resolv.conf
   search domains, and dials what DNS returns under the unit's kernel filter: `IPAddressDeny`
   for every non-public range (built in) plus the site's `internal-net`, and `IPAddressAllow`
   for the resolvers in `/etc/resolv.conf` by exact address. That filter is the boundary;
   `internal-name` is policy on top of it (a CNAME, `/etc/hosts` or a name you didn't list
   still resolves). A resolver that strips private answers (Unbound `private-address`) adds a
   layer in front.
4. **No filter, no web.** systemd accepts `IPAddressDeny` and silently enforces nothing where
   cgroup BPF is missing (some containers, old kernels), so the unit's start fails unless a
   connect to a denied address gets `EPERM`; `apply` then reports it and leaves web off. Only
   a root-written drop-in setting `AIRLOCK_ENVOY_WEB_FILTER_CHECK=skip` overrides that, and the
   start logs the skip.

**Why IPv4 only.** "Public" by address range includes a site's own public addresses. Over IPv6
those are the site's global prefix, which rotates with a dynamic delegation, and some never
cross a router (the host's own addresses, hosts on its link), so neither a fixed list nor the
router can keep web off them. Over IPv4 the internal space is RFC 1918, fixed and denied, and
a site's own public address is its router's WAN address: add it to `internal-net` if it's
fixed, and check whether the router reflects port forwards back inside (NAT reflection). The
web Envoy's sockets are also out of reach of the main Envoy's (`InaccessiblePaths`), so a
compromised web Envoy can't use the main one's listeners to get around its filter.

The unit already proves enforcement at every start. To check by hand, as root, this runs a
throwaway unit with the web unit's exact filter:

```
sudo systemd-run --wait --pipe --quiet \
  -p "IPAddressDeny=$(systemctl show -P IPAddressDeny airlock-envoy-web)" \
  -p "IPAddressAllow=$(systemctl show -P IPAddressAllow airlock-envoy-web)" \
  sh -c 'curl -s -m 5 -o /dev/null https://1.1.1.1/ && echo "public: reachable (want this)";
         curl -s -m 5 -o /dev/null https://10.0.0.1/ || echo "10.0.0.1: refused (want this)"'
```

## What this does not stop

- **Data sent to Anthropic itself.** The box holds a Claude login and can talk to
  `api.anthropic.com`, so it can put data into requests there, including with an API key for
  someone else's account, or by asking server-side tools such as web fetch to reach a URL.
  Without decrypting TLS, the proxy cannot see or stop this.
- **The login in the box.** The tunnel carries the box's own credential; it does not hold or
  inject one.
- **Data sent anywhere public, through web.** A listener with `web` can reach any public
  host; the web log names each one. Narrow a profile to exact entries when that matters.
- **The resolver, through web.** It is allowed by address, on every port, and a hostile public
  name can point at it. Harmless for a loopback resolver that strips private answers (Unbound
  `private-address`); a resolver on a LAN address (a home router) exposes whatever that host
  serves on 443 to web.
- **A NAT64 prefix of your own.** The well-known `64:ff9b::/96` is denied, but web is IPv4
  only anyway; if IPv6 comes back, add a network-specific NAT64 prefix to `internal-net`.
- **A different site inside a matched TLS session.** Once the SNI matches, the HTTP `Host` is
  encrypted. Asking `api.anthropic.com` for another Anthropic site's `Host` is refused today by
  the CDN (403), which is its policy, not this proxy's.

## The audit log

Envoy writes JSON lines to `/var/log/airlock-envoy/access.jsonl` (`run/access.jsonl` in the
spike), flushed every second and kept when Envoy stops. Nothing rotates or ships it yet, so a
box that keeps getting refused can grow it without bound (planned with the audit pipeline):

- the HTTP listener: one line per refused request with its route (`deny-connect`, `deny-http`),
  and two per allowed tunnel (`DownstreamTunnelSuccessfullyEstablished`, then `DownstreamEnd`
  with bytes and duration). A request the HTTP parser rejects is logged with status and
  details, without a route. Long tunnels also log every 60 s while open.
- the SNI listeners: one line per tunnel with the SNI the client sent, `sni-match` and the
  upstream, or flag `NR` and no upstream when the SNI does not match. A tunnel that never
  sends a TLS handshake (nothing within 15 s, or closed first, or not TLS) logs no SNI and no
  route. For an address entry the route is `tls-no-sni`, and a tunnel that sent an SNI is
  refused with `details` `rbac_access_denied_matched_policy[server-name-sent]` (flag `-`).
- `listener` in HTTP lines is the box socket's listener, so each line says which profile it
  came through.
- Every SNI line carries the `connection` ID of the HTTP line that allowed its CONNECT, so a
  refused SNI joins to its tunnel exactly, also with many tunnels open at once (the ID is part
  of the internal connection's pool key; a 40-tunnel test checks it). On the HTTP side such a
  tunnel still reads as allowed (route `allow-…`, status 200): the SNI line holds the refusal.
  `connection` is a number in HTTP lines and a string in SNI lines.

## Spike results

Envoy v1.39.4 (official image, pinned by digest), rootless podman.

**Test 1, capture** (`configs/tunnel-capture.yaml`): a log-only tunnel on loopback, any host on
443. Claude Code with Remote Control, run with `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`,
`DISABLE_AUTOUPDATER` and `ENABLE_CLAUDEAI_MCP_SERVERS=false`, needed only `api.anthropic.com`.
Remote Control works with telemetry disabled (Claude Code 2.1.283 or later).

**Test 2, enforced, in the box's shape** (`test/t2-checks.sh`): the client is the airlock image
plus `socat`, run with `--network none`, only the socket mounted. Each check expects one exact
result and the script exits non-zero on any mismatch; a deliberately weakened allowlist
(prefix match, case-insensitive) fails two of them. It also opens 40 wrong-SNI tunnels at
once and checks that each log line names its own tunnel, and it reads only log lines from
its own run.

| Check | Result |
|---|---|
| CONNECT to each allowed host on 443, by `-x` and by `HTTPS_PROXY` | tunnel, TLS end to end |
| CONNECT to another host, another port, an IP address, `[::1]`, an uppercase name | 403 `deny-connect` |
| plain HTTP through the proxy | 403 `deny-http` |
| CONNECT to an allowed host with another SNI (`www.anthropic.com`, `console.anthropic.com`) | closed during the TLS handshake, logged `NR` with the SNI and joined to its CONNECT |
| direct connection to an IP, DNS | fail: the client has only `lo` |
| `/login`, a session, Remote Control from a phone, `/logout` | worked (run by hand, before the SNI check was added) |

Claude Code also tried `raw.githubusercontent.com` (release notes), `downloads.claude.ai`
(update checks) and `github.com` (plugin marketplace). All were refused and logged, and nothing
broke. `claude.ai` was never used, so it is not in the allowlist: the browser half of `/login`
runs on the host, and the code exchange goes to `platform.claude.com`.

## Running the spike

Needs the `claude-airlock:dev` image locally (the test client builds on it).

```
./test/run-envoy.sh                      # the built-in anthropic listener only
podman build -t localhost/airlock-envoy-spike-client:test test/client
./test/t2-checks.sh
jq . run/access.jsonl
podman stop airlock-envoy-spike

./test/run-envoy.sh test/site.conf       # plus two test listeners, public endpoints only
./test/site-checks.sh                    # each listener reaches exactly its own list
podman stop airlock-envoy-spike

./test/apply-parse.sh                    # the site file parser, no Envoy needed
```

`site-checks.sh` covers: the include, a host entry, an address entry and a host on another
port pass; a listed host on an unlisted port, an unlisted address and the other listener's
host are refused; a wrong SNI or no SNI on a host entry (to a server that would accept a
handshake without one), any SNI on an address entry, and plain HTTP inside an allowed tunnel
are closed and logged, each joined to its CONNECT; one listener at its connection cap does not
starve another; and `anthropic` and
the second listener each refuse the other's hosts. Weakening the renderer (no SNI rule on
address entries, no TLS requirement, one shared route list, a no-SNI chain on host entries,
a global-only connection cap) fails it.

Against the installed service instead:

```
SOCK=/run/airlock-envoy/anthropic.sock SOCK_MOUNT_OPTS= LOG="sudo cat /var/log/airlock-envoy/access.jsonl" ./test/t2-checks.sh
```

`run/` holds the sockets, the access log (mode 0600; it appends across runs) and the admin
socket. The admin socket (mode 0600) is never mounted into a box, but any process running as
you can use it, including to stop Envoy. The capture config runs with the host network, so
its loopback listener is reachable; the others run on podman's default network.

## Licence

AGPL-3.0-or-later.
