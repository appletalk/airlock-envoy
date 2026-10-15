# airlock-envoy

Envoy as the one egress and credential proxy for [claude-airlock](https://github.com/appletalk/claude-airlock)
boxes. A box runs with `--network none` and reaches the outside only through Unix sockets that
airlock mounts in. Envoy listens on those sockets on the host, decides what passes, and logs every
decision.

Two modes, both on sockets, neither decrypting TLS:

- **CONNECT tunnel with a hostname allowlist.** For clients that must talk TLS end to end, such as
  Claude Code (`HTTPS_PROXY`), whose login and Remote Control need the real Anthropic API. The proxy
  sees host, TLS server name, bytes and timing, never content, and holds no secret.
- **Plain-HTTP injection** (planned). For clients that can be pointed at a plain-HTTP URL (`gh`,
  `git`, `kubectl`, `curl`): Envoy applies policy, adds the credential, and opens TLS upstream
  itself. Service-specific policy (for GitHub, per-repo tokens, no approvals, branch-only pushes)
  comes from an `ext_authz` decision service.

Status: **spike**. Nothing here is ready to deploy.

## How the Anthropic tunnel decides

`configs/tunnel-anthropic.yaml`:

1. The HTTP listener on the socket accepts `CONNECT <host>:443` only for an exact, allowed
   host (`api.anthropic.com`, `platform.claude.com`, `claude.ai`). Any other host, port, IP
   address or spelling, and any other request, is refused: 403 from a deny route, or a 4xx
   from the HTTP parser for a malformed one (`OPTIONS *` gets 404).
2. An allowed tunnel goes to an internal listener for that host. It reads the TLS server name
   (SNI) from the client's handshake without decrypting, and passes the connection on only if
   the SNI equals the CONNECT host. Otherwise it closes the connection.
3. The upstream is a fixed cluster per host, resolved by Envoy. The client never chooses an
   address.

Step 2 matters because the allowed names share their address with many other sites (other
Anthropic properties on the same CDN edge). Without it, `CONNECT api.anthropic.com:443` with
another SNI reached those sites.

Limits: 256 connections from boxes at once (refusals over the limit show only in Envoy's
stats, `downstream_global_cx_overflow`, not in the access log), 10 s to send request headers,
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

Envoy writes JSON lines to `run/access.jsonl` (flushed every second, kept when Envoy stops):

- the HTTP listener: one line per refused request with its route (`deny-connect`, `deny-http`),
  and two per allowed tunnel (`DownstreamTunnelSuccessfullyEstablished`, then `DownstreamEnd`
  with bytes and duration). A request the HTTP parser rejects is logged with status and
  details, without a route. Long tunnels also log every 60 s while open.
- the SNI listeners: one line per tunnel with the SNI the client sent, `sni-match` and the
  upstream, or flag `NR` and no upstream when the SNI does not match. A tunnel that never
  sends a TLS handshake (nothing within 15 s, or closed first) logs no SNI and no route.
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
./test/run-envoy.sh tunnel-anthropic.yaml
podman build -t localhost/airlock-envoy-spike-client:test test/client
./test/t2-checks.sh
jq . run/access.jsonl
podman stop airlock-envoy-spike
```

`run/` holds the sockets, the access log (mode 0600; it appends across runs) and the admin
socket. The admin socket (mode 0600) is never mounted into a box, but any process running as
you can use it, including to stop Envoy. The capture config runs with the host network, so
its loopback listener is reachable; the others run on podman's default network.

## Licence

AGPL-3.0-or-later.
