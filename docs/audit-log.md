# The audit log

Envoy writes JSON lines to `/var/log/airlock-envoy/access.jsonl` (`run/access.jsonl` in the
spike harness). Lines are flushed every second and kept when Envoy stops.

**Nothing rotates or ships the log yet.** A box that keeps getting refused can grow it without
bound (planned with the audit pipeline).

The web Envoy logs to `/var/log/airlock-envoy/web.jsonl`: profile, server name, chain and
upstream address.

## The HTTP listener (one per box socket)

- One line per refused request, with its route (`deny-connect`, `deny-http`).
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
