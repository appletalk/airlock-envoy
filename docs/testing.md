# Testing

Every suite runs as your own user with rootless podman, except `apply-parse.sh`, shellcheck
and the GraphQL check, which need no podman.

| Command | What |
|---|---|
| `test/run-all.sh [distro...]` | Everything at once (below) |
| `test/install-test.sh <distro> [envoy version]` | The whole install in a systemd-booted container |
| `test/apply-parse.sh` | The site file parser, no Envoy needed |
| `test/run-envoy.sh test/t2.conf` then `test/t2-checks.sh` | The CONNECT tunnel, from a box-shaped client |
| `luajit test/graphql-check.lua` | The GitHub GraphQL write check (skipped without luajit) |
| `test/run-envoy.sh test/site.conf` then `test/site-checks.sh` | Site listeners, each reaching exactly its own list |

## All the tests at once

```
test/run-all.sh [distro...]
```

Runs the install test on Arch, Debian 13 and Ubuntu 26.04 (the default; name others to change
it) in parallel. Alongside them it runs shellcheck, the parser, the GraphQL check, t2 and the
site checks, then prints each suite's result and time. About 20 s in all on a 20-thread
workstation.

- `OLD_REPO` and `AIRLOCK_REPO` pass through to the install test.
- `SHELLCHECK=<path>` if shellcheck is not on `PATH` (skipped, and said so, if not found).

## The install test

```
test/install-test.sh ubuntu[-22.04|-24.04|-26.04]|debian|arch
```

Plain `ubuntu` is 24.04. It runs the whole install in a systemd-booted container and checks:

**One user:**

- owners, modes and ACLs;
- the client's tunnel and refusals;
- that other users cannot reach either socket, and that the log is private;
- that the box socket survives Envoy restarts (eight in a row too) and a reinstall;
- with `AIRLOCK_REPO=<claude-airlock checkout>`: that claude-airlock's own socket check accepts
  it.

**Site listeners:**

- a listener added gets its socket and ACL and reaches exactly its list, while the first socket
  is untouched;
- an unchanged apply does not restart Envoy;
- a bad site file changes nothing;
- a file from elsewhere needs a confirmation;
- a removed listener loses its socket;
- a config Envoy will not start with is rolled back.

**Two users:**

- each reaches only its own sockets (the other's directory refuses listing, `stat` and connect,
  both ways);
- each request carries its own user's credential, and the log names the user;
- `--status` shows each socket's user;
- the kill switch and a boot (no `/run/airlock-envoy`) bring both back;
- two clients for a listener, an unknown user, or one credential for two users are refused with
  nothing changed;
- a listener given to another user moves its socket there.

**Upgrade**, with `OLD_REPO=<earlier checkout>`: it installs that first, then checks that a site
file without client lines is refused before anything changes, and that the old flat sockets go.

`install-envoy.sh` runs in the test image's build, so the download repeats only when the script,
the release key or the version changes. The test runs inside one `podman unshare` and enters the
container with `nsenter` (about 2 ms a command, against about 160 ms for `podman exec`). About
20 s a distribution.

## The spike harness

Runs Envoy in a container (the official image, pinned by digest) against a test client. Needs the
`claude-airlock:dev` image locally; the test client builds on it.

```
./test/run-envoy.sh test/t2.conf         # one listener (the built-in has no socket of its own)
podman build -t localhost/airlock-envoy-spike-client:test test/client
./test/t2-checks.sh
jq . run/access.jsonl
podman stop airlock-envoy-spike

./test/run-envoy.sh test/site.conf       # the test listeners, public endpoints only
./test/site-checks.sh                    # each listener reaches exactly its own list
podman stop airlock-envoy-spike

./test/apply-parse.sh                    # the site file parser, no Envoy needed
```

`run/` holds the sockets, the access log (mode 0600; it appends across runs) and the admin socket.
The admin socket (mode 0600) is never mounted into a box, but any process running as you can use
it, including to stop Envoy.

### t2-checks.sh

The client is the airlock image plus `socat`, run with `--network none` and only the socket
mounted. Each check expects one exact result, and the script exits non-zero on any mismatch. A
deliberately weakened allowlist (prefix match, case-insensitive) fails two of them. It also opens
40 wrong-SNI tunnels at once and checks that each log line names its own tunnel. It reads only
log lines from its own run. The checks are listed in [spike-results.md](spike-results.md).

To run it against the installed service instead:

```
SOCK=/run/airlock-envoy/$USER/<listener>.sock LISTENER=<listener> SOCK_MOUNT_OPTS= LOG="sudo cat /var/log/airlock-envoy/access.jsonl" ./test/t2-checks.sh
```

### site-checks.sh

Covers:

- the include, a host entry, an address entry and a host on another port pass;
- a listed host on an unlisted port, an unlisted address and the other listener's host are
  refused;
- these are closed and logged, each joined to its CONNECT: a wrong SNI or no SNI on a host entry
  (to a server that would accept a handshake without one), any SNI on an address entry, and
  plain HTTP inside an allowed tunnel;
- one listener at its connection cap does not starve another;
- `t-anthropic` (Claude only) and the second listener each refuse the other's hosts.

Weakening the renderer fails it: no SNI rule on address entries, no TLS requirement, one shared
route list, a no-SNI chain on host entries, or a global-only connection cap.

### The capture config

`configs/tunnel-capture.yaml` is a log-only tunnel on loopback, any host on 443, used to find
which hosts Claude Code needs. It runs with the host network, so its loopback listener is
reachable; the other configs run on podman's default network. Run it with
`test/run-envoy.sh capture`.
