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
- **Plain-HTTP injection** (planned). For clients that can be pointed at a plain-HTTP URL (`gh`,
  `git`, `kubectl`, `curl`): Envoy applies policy, adds the credential, and opens TLS upstream
  itself. Service-specific policy (for GitHub, per-repo tokens, no approvals, branch-only pushes)
  comes from an `ext_authz` decision service.

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
  test runs it). The box socket also outlives Envoy: restarts and updates drop open
  connections, never the socket a running box holds.
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
- The relay restarts with Envoy and has no start-rate limit: with systemd's default, a few
  Envoy restarts in a row failed the relay and with it the box socket, leaving running boxes a
  dead socket (tested: eight restarts in a row keep the socket working).

What it sets up:

| Path | Owner, mode | What |
|---|---|---|
| `/run/airlock-envoy/<listener>.sock` | airlock-envoy, ACL: owner and `<user>` rw | the socket a box gets, one per listener |
| `/run/airlock-envoy/` | root, 0755 | created by systemd for the box sockets |
| `/etc/airlock-envoy/site.conf` | yours to write; root:airlock-envoy 0640 when installed by apply | this host's listeners |
| `/etc/airlock-envoy/envoy.yaml`, `allowed` | root:airlock-envoy, 0640 | rendered config; what was last applied |
| `/run/airlock-envoy-internal/` | airlock-envoy, 0700 | Envoy's own sockets, incl. admin; never given to anyone |
| `/var/log/airlock-envoy/access.jsonl` | airlock-envoy, 0600 (dir 0750) | the audit log |

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
- Strict syntax: lowercase names, explicit ports, no wildcards, URLs, IPv6 or Windows line
  endings; `admin` and `anthropic` are reserved. A bad line stops the apply with its line number.

`sudo airlock-envoy-apply` renders the config, checks it with `envoy --mode validate` (as the
service account), prints the change in allowed destinations against the last apply, swaps the
config in atomically and restarts Envoy (only if the config changed, or Envoy is down while box
sockets are up; with the kill switch on, nothing is started). Then it starts a socket
for each new listener and removes the socket of each listener that is gone, so a box set to it
no longer launches. If Envoy does not start with the new config, the previous one goes back.
`--check` does all the checking and shows the change without applying; `--list` and
`--render` work as any user. Any site file named on the command line other than the literal
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

## How a tunnel decides

The config `airlock-envoy-apply` renders (`--render` prints it):

1. The HTTP listener on each socket accepts `CONNECT <host>:<port>` only for an exact entry
   of its own list (for `anthropic`: `api.anthropic.com`, `platform.claude.com`, `claude.ai`, on
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

## What this does not stop

- **Data sent to Anthropic itself.** The box holds a Claude login and can talk to
  `api.anthropic.com`, so it can put data into requests there, including with an API key for
  someone else's account, or by asking server-side tools such as web fetch to reach a URL.
  Without decrypting TLS, the proxy cannot see or stop this.
- **The login in the box.** The tunnel carries the box's own credential; it does not hold or
  inject one.
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
broke. `claude.ai` was never used: the browser half of `/login` runs on the host, and the code
exchange goes to `platform.claude.com`.

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
