# The audit log

Envoy writes JSON lines to `/var/log/airlock-envoy/access.jsonl` (`run/access.jsonl` in the
spike harness). Lines are flushed every second and kept when Envoy stops.

**Rotation** is logrotate's (`/etc/airlock-envoy/logrotate.conf`), run every 15 minutes by
`airlock-envoy-logrotate.timer` with its own state file, apart from the distribution's daily run.
A log rotates once it passes 100 MiB or once a day (an empty one never) to
`access.jsonl-<YYYYmmddTHHMMSSZ>` (UTC), and the Envoy that writes it is asked to reopen its files
(admin `POST /reopen_logs`). The newest rotated file stays uncompressed until the next rotation
(Envoy flushes once a second, so a few lines can still land in it); older ones are `.gz`.

- **Retention is by age only:** a rotated file is removed at that log's next rotation once it
  is older than 30 days (by its modification time), never to make room. A flood of refused
  requests rotates more often but can't push earlier evidence out; it costs disk instead (100
  MiB is checked every 15 minutes, so a flood can outgrow it between checks). A separate
  filesystem for `/var/log/airlock-envoy`, or a disk-space alert, keeps a flood from filling
  `/var`.
- **Reopen:** each run first asks both Envoys to reopen their logs, so a reopen that failed
  once (Envoy still writing the rotated file) heals at the next run. A failed run shows in
  `systemctl status airlock-envoy-logrotate`.
- **Force a rotation:** `sudo env TZ=UTC logrotate -f --state
  /var/lib/airlock-envoy/logrotate.status /etc/airlock-envoy/logrotate.conf` (TZ as the unit
  sets it, so the name's time is UTC). `sudo systemctl start airlock-envoy-logrotate` rotates
  only what is due.
- A reinstall enables the timer again.

Nothing ships the logs anywhere yet.

The web Envoy logs to `/var/log/airlock-envoy/web.jsonl`: profile, server name, chain and
upstream address.

## The HTTP listener (one per box socket)

- One line per refused request, with its route: `deny-connect`, `deny-http`,
  `deny-connect-http-<host>` (a CONNECT to a host served by plain HTTP), `deny-web-internal-<name>`
  and `deny-web-internal-sub-<name>` (an internal name asked of web).
- One line per plain-HTTP request, allowed or refused, with the route of the host's rules:
  `<host>-<route>`, as `api.github.com-read` or `github.com-refused`.
- A credential locked or with no token is answered by Envoy itself, nothing upstream: status 423
  or 503 (`x-airlock-envoy: locked` or `unavailable`).
- Two lines per allowed tunnel: `DownstreamTunnelSuccessfullyEstablished`, then `DownstreamEnd`
  with bytes and duration. Long tunnels also log every 60 s while open.
- A request the HTTP parser rejects is logged with status and details, without a route.
- `listener` is the box socket's listener and `user` its client, so each line says which profile
  and whose box it came through (also in the web log).

## The SNI listeners (one per destination)

- One line per tunnel, with the SNI the client sent, `sni-match` and the upstream. When the SNI
  does not match: flag `NR` and no upstream.
- A tunnel that never sends a TLS handshake (nothing within 15 s, closed first, or not TLS) logs
  no SNI and no route.
- For an address entry, the route is `tls-no-sni`. A tunnel that sent an SNI is refused with
  `details` `rbac_access_denied_matched_policy[server-name-sent]` (flag `-`).

## Joining the two

Every SNI line carries the `connection` ID of the HTTP line that allowed its CONNECT. So a
refused SNI joins to its tunnel exactly, also with many tunnels open at once (the ID is part of
the internal connection's pool key; a 40-tunnel test checks it).

On the HTTP side, such a tunnel still reads as allowed (route `allow-...`, status 200): the SNI
line holds the refusal.

`connection` is a number in HTTP lines and a string in SNI lines.

## What is never logged

No rendered log format names a request header, because Envoy's access log sees headers *after*
the credential is added (a test checks this). Envoy runs at log level `warn`.

`path` is the whole request path, query string included: a secret a client puts in a query
parameter is logged. GitHub App minting logs to its unit's journal (`journalctl -u
airlock-envoy-mint`), not here.
