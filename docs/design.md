# How it works

## Two layers of sockets

Envoy cannot take a listening socket from systemd, so there are two layers:

1. **The box socket.** systemd creates it (`airlock-envoy-proxy@<listener>.socket`) in its user's
   directory under the root-owned `/run/airlock-envoy/`. The listener's drop-in says where, and
   for whom.
2. **The relay.** `systemd-socket-proxyd` (`airlock-envoy-proxy@<listener>.service`) relays each
   connection to Envoy's own socket in `/run/airlock-envoy-internal/` (0700).

What this buys:

- **Nobody can swap the box socket.** Only root can rename anything where the box socket lives,
  so neither Envoy nor anything running as you can replace it with something else.
  claude-airlock requires exactly that, and its own check accepts the socket (the install test
  runs it).
- **The box socket outlives Envoy.** Restarts, updates and crashes drop open connections, never
  the socket a running box holds.
- **Recovery without a relaunch.** The relay only `Wants=` Envoy and connects to it afresh for
  each box connection. While Envoy is down, box connections are closed; once it is back, the
  same socket works again (tested with a burst of connections over systemd's socket trigger
  limit while Envoy is down).
- **Start on demand.** A box connection to an idle socket starts the relay, and the relay starts
  Envoy if it is stopped (unless the kill switch is on).
- **No start-rate limit on the relay.** However often it stops, the next box connection starts
  it again (tested: eight Envoy restarts in a row with a relay running keep the socket working).

Envoy itself restarts after failures with no start limit, backing off from 2 s to a minute
between tries, so after a crash loop it comes back by itself once the cause is gone. (The
back-off needs systemd 254 or later; older versions retry every 2 s.) An apply also restarts it
at once.

## Sandboxing

Envoy and the relay run as the `airlock-envoy` system account with no capabilities, under
systemd's sandboxing:

- read-only system, no home, private `/tmp` and devices;
- a syscall allowlist (`@system-service`; the Envoy units add `mincore`, which Envoy's allocator
  needs);
- no core dumps; the Envoy and mint units also no swap;
- the relay also has no network at all.

The other units:

- `airlock-envoy-cred boot` runs before Envoy starts, as root outside Envoy's sandbox (`+`): it
  makes the locked pass credential and App token files Envoy's config reads.
- `airlock-envoy-mint.service` runs as its own account (`airlock-envoy-mint`), no capabilities,
  a read-only system but for its three directories under `/run/airlock-envoy-mint`
  ([github-app.md](github-app.md#the-key-and-who-holds-it)).
- `airlock-envoy-cred-expire.service` and `airlock-envoy-logrotate.service` run as root with a
  bounded capability set (file ownership and access, and `SETUID`/`SETGID`, for what they run
  as other accounts), no network (`PrivateNetwork`, Unix sockets only), and a read-only system
  but for their own paths (the expiry: `/run/airlock-envoy-cred` and `/run/airlock-envoy-mint`;
  logrotate: `/var/log/airlock-envoy` and its state in `/var/lib/airlock-envoy`).

The web Envoy cannot reach the main Envoy's sockets (`InaccessiblePaths`), so a compromised web
Envoy can't use the main one's listeners to get around its filter.

## How a tunnel decides

The config `airlock-envoy-apply` renders (`--render` prints it):

1. **The CONNECT request.** The HTTP listener on each socket accepts `CONNECT <host>:<port>` only
   for an exact entry of its own list (for `anthropic`: `api.anthropic.com` and
   `platform.claude.com`, on 443). Refused with 403 from a deny route: any other host, port, IP
   address or spelling, another listener's entries, and any other request. A malformed request
   gets a 4xx from the HTTP parser (`OPTIONS *` gets 404).
2. **The TLS server name.** An allowed tunnel goes to an internal listener for that destination.
   It reads the SNI from the client's handshake without decrypting, and passes the connection on
   only if the SNI equals the CONNECT host (for an address entry: only if there is no SNI).
   Otherwise, or without TLS, it closes the connection.
3. **The upstream** is fixed per destination: resolved by Envoy, or a fixed address. The client
   never chooses an address.

Step 2 matters because the allowed names share their address with many other sites (other
Anthropic properties on the same CDN edge). Without it, `CONNECT api.anthropic.com:443` with
another SNI reached those sites.

**Limits:**

| Limit | Value |
|---|---|
| Connections from boxes at once, per listener | 128, so a profile at its cap does not starve another |
| Time to send request headers | 10 s |
| A connection with no request open | closed about a minute after its last one, so idle keep-alives can't hold the cap |
| A tunnel without bytes | cut after 1 h |

Refusals over the connection cap show only in Envoy's stats
(`connection_limit.<listener>.limited_connections`), not in the access log; `site-checks.sh`
tests it. In practice the CDN closes an idle TLS connection much sooner than 1 h (about 15 s
without a request).

## How web decides

1. **On the box's listener**, after its exact entries: a CONNECT authority that is an internal
   name (built in or `internal-name`, any case) gets 403. Anything else that is a host name with
   an alphabetic top-level label, on port 443, goes as raw TLS to the web Envoy
   (`airlock-envoy-web`, its own unit). IP literals, single labels and other ports never match,
   and get 403.
2. **In the web Envoy**, each web profile has its own listener, so its own DNS cache (one profile
   filling it doesn't stall another) and its own name in the web log. The filter chain is picked
   from the TLS server name **before any filter runs**: an internal name, no name, an IP literal
   or a name without a dot gets no chain that has an upstream, so nothing is dialled. The CONNECT
   host and the server name may differ; each side checks its own.
3. **Resolving and dialling.** Envoy resolves the server name itself, **IPv4 only** (A records),
   without resolv.conf search domains. It dials what DNS returns under the unit's kernel filter:
   - `IPAddressDeny` for every non-public range (built in) plus the site's `internal-net`;
   - `IPAddressAllow` for the resolvers in `/etc/resolv.conf`, by exact address.

   That filter is the boundary. `internal-name` is policy on top of it: a CNAME, `/etc/hosts` or
   a name you didn't list still resolves. A resolver that strips private answers (Unbound
   `private-address`) adds a layer in front.
4. **No filter, no web.** systemd accepts `IPAddressDeny` and silently enforces nothing where
   cgroup BPF is missing (some containers, old kernels). So the unit's start fails unless a
   connect to a denied address gets `EPERM`; `apply` then reports it and leaves web off. Only a
   root-written drop-in setting `AIRLOCK_ENVOY_WEB_FILTER_CHECK=skip` overrides that, and the
   start logs the skip.

### Why IPv4 only

"Public" by address range includes a site's own public addresses.

- Over IPv6, those are the site's global prefix, which rotates with a dynamic delegation. Some
  never cross a router (the host's own addresses, hosts on its link). So neither a fixed list nor
  the router can keep web off them.
- Over IPv4, the internal space is RFC 1918, fixed and denied. A site's own public address is its
  router's WAN address: add it to `internal-net` if it's fixed, and check whether the router
  reflects port forwards back inside (NAT reflection).

### Checking the filter by hand

The unit already proves enforcement at every start. To check by hand, as root, this runs a
throwaway unit with the web unit's exact filter:

```
sudo systemd-run --wait --pipe --quiet \
  -p "IPAddressDeny=$(systemctl show -P IPAddressDeny airlock-envoy-web)" \
  -p "IPAddressAllow=$(systemctl show -P IPAddressAllow airlock-envoy-web)" \
  sh -c 'curl -s -m 5 -o /dev/null https://1.1.1.1/ && echo "public: reachable (want this)";
         curl -s -m 5 -o /dev/null https://10.0.0.1/ || echo "10.0.0.1: refused (want this)"'
```
