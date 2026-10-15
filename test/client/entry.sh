#!/bin/sh
# Bridge a loopback port to the mounted proxy socket; Claude Code needs an http:// proxy URL.
# Waits until both the proxy socket and the bridge answer.
# socat's messages go to a file: on the terminal they draw over Claude's interface.
set -eu
socat -lf /tmp/socat.log TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:/run/proxy/anthropic.sock &
i=0
until socat -u /dev/null UNIX-CONNECT:/run/proxy/anthropic.sock 2>/dev/null && socat -u /dev/null TCP:127.0.0.1:3128 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 50 ] || { echo "spike-entry: proxy socket or socat bridge not reachable, see /tmp/socat.log" >&2; exit 1; }
  sleep 0.1
done
export HTTPS_PROXY=http://127.0.0.1:3128
export DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 DISABLE_AUTOUPDATER=1 ENABLE_CLAUDEAI_MCP_SERVERS=false
export CLAUDE_CONFIG_DIR=/tmp/claude-spike
exec "$@"
