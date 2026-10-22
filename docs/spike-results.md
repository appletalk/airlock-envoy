# Spike results

History: what the first spike found. Envoy v1.40.0 (official image, pinned by digest), rootless
podman. How to run the harness: [testing.md](testing.md#the-spike-harness).

## Test 1: capture

`configs/tunnel-capture.yaml`: a log-only tunnel on loopback, any host on 443.

Claude Code with Remote Control, run with `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`,
`DISABLE_AUTOUPDATER` and `ENABLE_CLAUDEAI_MCP_SERVERS=false`, needed only `api.anthropic.com`.
Remote Control works with telemetry disabled (Claude Code 2.1.283 or later).

## Test 2: enforced, in the box's shape

`test/t2-checks.sh` (described in [testing.md](testing.md#t2-checkssh)).

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
broke.

`claude.ai` was never used, so it is not in the allowlist: the browser half of `/login` runs on
the host, and the code exchange goes to `platform.claude.com`.
