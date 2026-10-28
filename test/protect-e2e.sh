#!/bin/bash
# protect, end to end with real git: a rendered config run by a real Envoy, a git smart-HTTP
# upstream over TLS (git-http-backend behind a small Python server, its own CA), and git
# pushing through the box listener. Runs as any user, no podman or root: the rendered paths
# (sockets, CA, log) are moved under a scratch directory. Needs envoy, git, python3, openssl,
# socat. Exits non-zero if any check fails.
# Checks read "<condition> && ok ... || fail ...": ok always succeeds, so fail runs only when the
# condition doesn't hold.
# shellcheck disable=SC2015
set -u
cd "$(dirname "$0")/.." || exit
repo=$PWD
for t in envoy git python3 openssl socat; do command -v "$t" >/dev/null || { echo "skipped: no $t"; exit 3; }; done
work="$(mktemp -d)"
pids=()
# shellcheck disable=SC2329  # run by the trap
cleanup() { kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "kept $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails+1)); }
UP=18443 PX=18001

# The upstream: a CA, a certificate for git.example.com, bare repos, git-http-backend as CGI.
# The site names git.example.com (apply refuses loopback); the rendered cluster is then
# pointed at 127.0.0.1, with the name kept for SNI and the certificate check.
cd "$work" || exit
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.pem -days 2 -subj /CN=test-ca 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout srv.key -out srv.csr -subj /CN=git.example.com 2>/dev/null
printf 'subjectAltName=DNS:git.example.com\n' > san.ext
openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out srv.pem -days 2 -extfile san.ext 2>/dev/null
mkdir -p srv/alice
for r in tools open; do git init -q --bare -b main "srv/alice/$r.git"; git -C "srv/alice/$r.git" config http.receivepack true; done
cat > up.py <<'PY'
import http.server, os, ssl, subprocess, sys
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def run(self):
        body = b""
        if self.headers.get("transfer-encoding", "").lower() == "chunked":
            parts = []
            while True:
                n = int(self.rfile.readline().split(b";")[0].strip(), 16)
                if n == 0:
                    self.rfile.readline(); break
                parts.append(self.rfile.read(n)); self.rfile.readline()
            body = b"".join(parts)
        elif self.headers.get("content-length"):
            body = self.rfile.read(int(self.headers["content-length"]))
        with open(os.path.join(root, "..", "requests.log"), "a") as f:
            f.write(f"{self.command} {self.path} {len(body)}\n")
        path, _, query = self.path.partition("?")
        env = {"GIT_PROJECT_ROOT": root, "GIT_HTTP_EXPORT_ALL": "1", "PATH_INFO": path, "QUERY_STRING": query,
               "REQUEST_METHOD": self.command, "CONTENT_TYPE": self.headers.get("content-type", ""),
               "CONTENT_LENGTH": str(len(body)), "PATH": os.environ["PATH"], "REMOTE_USER": "box", "REMOTE_ADDR": "127.0.0.1"}
        out = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True).stdout
        head, _, rest = out.partition(b"\r\n\r\n")
        status = 200
        hdrs = []
        for line in head.split(b"\r\n"):
            k, _, v = line.decode().partition(":")
            if k.lower() == "status": status = int(v.strip().split()[0])
            elif k: hdrs.append((k, v.strip()))
        self.send_response(status)
        for k, v in hdrs: self.send_header(k, v)
        self.send_header("content-length", str(len(rest))); self.end_headers(); self.wfile.write(rest)
    do_GET = do_POST = run
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(sys.argv[3], sys.argv[4])
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
python3 up.py "$work/srv" "$UP" srv.pem srv.key 2>up.err & pids+=($!)

# The site: alice/tools with main and release/* protected, alice/open (another definition of
# the same host, the same credential) without: the per-repo exception.
cat > site <<EOF
http git.example.com:$UP@prot rules git ca test repos alice/tools protect main,release/*
http git.example.com:$UP@open rules git ca test repos alice/open
b http://git.example.com@prot http://git.example.com@open
client b t
EOF
"$repo/install/airlock-envoy-apply" --render site > rendered.yaml || { echo "FAIL render"; exit 1; }
sed -e "s#/run/airlock-envoy-internal/#$work/#" -e "s#address: \"git.example.com\", port_value#address: \"127.0.0.1\", port_value#" -e "s#/etc/airlock-envoy/ca/test.pem#$work/ca.pem#" \
    -e 's#path: /var/log/airlock-envoy/access.jsonl#path: '"$work"'/access.jsonl#' rendered.yaml > envoy.yaml
# Envoy as the units run it: under MemoryDenyWriteExecute (test/mdwe-exec.py), so a Lua filter
# that lets LuaJIT compile panics here as on a host; one worker, so a few hundred requests make
# its code hot.
# REQUIRE_MDWE=1 (CI) makes a kernel without it a failure, not a skip.
mdwe=(python3 -I "$repo/test/mdwe-exec.py") under="under MemoryDenyWriteExecute"
"${mdwe[@]}" true 2>/dev/null; rc=$?
if [ "$rc" = 3 ] && [ -z "${REQUIRE_MDWE:-}" ]; then
  echo "skip MemoryDenyWriteExecute: the kernel lacks PR_SET_MDWE (Linux 6.3+); Envoy runs without it"; mdwe=() under="WITHOUT MemoryDenyWriteExecute"
elif [ "$rc" != 0 ]; then echo "FAIL test/mdwe-exec.py true: exit $rc"; exit 1; fi
"${mdwe[@]}" envoy -c envoy.yaml --concurrency 1 --disable-hot-restart -l warn --base-id-path "$work/base-id" > envoy.log 2>&1 & pids+=($!)
envoy_pid=$!
for _ in $(seq 50); do [ -S b.sock ] && break; sleep 0.1; done
[ -S b.sock ] || { echo "FAIL envoy did not start"; cat envoy.log; exit 1; }
socat TCP-LISTEN:$PX,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:b.sock & pids+=($!)
sleep 0.3

export http_proxy=http://127.0.0.1:$PX GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 HOME=$work
git config --global user.email t@example.org; git config --global user.name t; git config --global init.defaultBranch main
remote() { git -C "srv/alice/$1.git" rev-parse -q --verify "refs/heads/$2" 2>/dev/null || echo none; }
push() { git -C w push "$@" 2>&1; }
rejected() { [[ "$1" == *"[remote rejected]"*"(protected branch (airlock-envoy protect))"* ]]; }   # refused by the check, not by chance

git init -q w && git -C w commit -q --allow-empty -m one
git -C w remote add origin http://git.example.com/alice/tools.git
git -C w remote add open http://git.example.com/alice/open.git

out="$(push origin HEAD:refs/heads/feature)"
[ "$(remote tools feature)" = "$(git -C w rev-parse HEAD)" ] && ok "push to a feature branch passes" || fail "push to a feature branch: $out"
out="$(push origin HEAD:main)"
[ "$(remote tools main)" = none ] && [[ "$out" == *"remote: airlock-envoy: refused by the git rules (listener b): push to protected branch refs/heads/main on git.example.com (protect): push another branch and open a PR"* ]] \
  && [[ "$out" == *"! [remote rejected] HEAD -> main (protected branch (airlock-envoy protect))"* ]] \
  && ok "push creating main refused; git shows the reason and [remote rejected]" || fail "create main: $out"
out="$(push origin HEAD:refs/heads/MAIN)"
[ "$(remote tools MAIN)" = none ] && rejected "$out" && [[ "$out" == *"refs/heads/MAIN"* ]] && ok "MAIN (another case) refused" || fail "MAIN: $out"
out="$(push origin HEAD:refs/heads/release/1.0)"
[ "$(remote tools release/1.0)" = none ] && rejected "$out" && ok "release/1.0 (release/*) refused" || fail "release/1.0: $out"
out="$(push origin HEAD:refs/heads/releases/1.0)"
[ "$(remote tools releases/1.0)" != none ] && ok "releases/1.0 (not under release/) passes" || fail "releases/1.0: $out"
out="$(push origin HEAD:refs/heads/f2 HEAD:main)"
[ "$(remote tools f2)" = none ] && [ "$(remote tools main)" = none ] && rejected "$out" \
  && [[ "$out" == *"f2 (refused with a protected branch in the same push)"* ]] && ok "a mixed push (feature + main) refused whole" || fail "mixed push: $out"
out="$(git -C w -c http.extraHeader='x-airlock-protect: nothing' push origin HEAD:main 2>&1)"
[ "$(remote tools main)" = none ] && rejected "$out" && ok "a box's own x-airlock-protect header changes nothing" || fail "forged header: $out"

# Main exists upstream (put there behind Envoy's back): update, force and delete refused.
git -C w push -q "$work/srv/alice/tools.git" HEAD:main
base="$(remote tools main)"
git -C w commit -q --allow-empty -m two
out="$(push origin HEAD:main)"
[ "$(remote tools main)" = "$base" ] && rejected "$out" && ok "update of main refused" || fail "update main: $out"
git -C w commit -q --amend --allow-empty -m three
out="$(push -f origin HEAD:main)"
[ "$(remote tools main)" = "$base" ] && rejected "$out" && ok "force push to main refused" || fail "force main: $out"
out="$(push origin :main)"
[ "$(remote tools main)" = "$base" ] && rejected "$out" && ok "delete of main refused" || fail "delete main: $out"

# The other definition (no protect): main passes. The exception is per repo.
out="$(push open HEAD:main)"
[ "$(remote open main)" = "$(git -C w rev-parse HEAD)" ] && ok "main of the unprotected repo (another definition) passes" || fail "open main: $out"

# A large push streams (past the 64 KiB the check reads, and past git's 1 MiB post buffer, so
# git probes and then sends chunked); the same pack to main is refused after 64 KiB.
head -c 30000000 /dev/urandom > w/big && git -C w add big && git -C w commit -q -m big
out="$(push origin HEAD:refs/heads/big)"
[ "$(remote tools big)" = "$(git -C w rev-parse HEAD)" ] && ok "a 30 MB push to a feature branch passes" || fail "big push: $out"
git -C w commit -q --amend -m big2
out="$(push origin HEAD:main)"
# git prints the reason; curl, still uploading when the refusal came, then resends the rest on
# a new connection, which the check refuses as unreadable (git adds "HTTP 400").
[ "$(remote tools main)" = "$base" ] && [[ "$out" == *"remote: airlock-envoy: refused by the git rules (listener b): push to protected branch refs/heads/main"* ]] \
  && ok "a 30 MB push to main refused, the reason shown" || fail "big main: $out"

# Hand-made bodies: gzip and a signed push are refused; nothing of either reaches upstream.
Z=0000000000000000000000000000000000000000 A=1111111111111111111111111111111111111111
before="$(grep -c 'POST /alice/tools.git/git-receive-pack' requests.log)"
code="$(printf '%04x%s0000' $((4 + 83 + 16)) "$Z $A refs/heads/feature9" | gzip | curl -s -o /dev/null -w '%{http_code}' -x "$http_proxy" -H 'Content-Encoding: gzip' -H 'Content-Type: application/x-git-receive-pack-request' --data-binary @- http://git.example.com/alice/tools.git/git-receive-pack)"
[ "$code" = 400 ] && ok "a gzip push body refused (400)" || fail "gzip: $code"
cert="push-cert"$'\0'"report-status"$'\n'
code="$(printf '%04x%s0000' $((4 + ${#cert})) "$cert" | curl -s -o /dev/null -w '%{http_code}' -x "$http_proxy" -H 'Content-Type: application/x-git-receive-pack-request' --data-binary @- http://git.example.com/alice/tools.git/git-receive-pack)"
[ "$code" = 400 ] && ok "a signed push (push-cert) refused (400)" || fail "push-cert: $code"
after="$(grep -c 'POST /alice/tools.git/git-receive-pack' requests.log)"
[ "$before" = "$after" ] && ok "refused pushes never reached the upstream" || fail "a refused push reached the upstream ($before -> $after)"

# Of every push to alice/tools through Envoy, only the three allowed reached the upstream
# (feature, releases/1.0, big), besides the empty probes git sends before a large pack ("0000":
# no ref update, nothing to protect).
n="$(grep 'POST /alice/tools.git/git-receive-pack' requests.log | grep -vc ' 4$')"
[ "$n" = 3 ] && ok "the upstream got the three allowed pushes and no other" || fail "the upstream got $n pushes (want 3)"

# Fetch is untouched.
rm -rf c && git clone -q http://git.example.com/alice/tools.git c 2>/dev/null && [ -n "$(git -C c branch -r)" ] && ok "clone passes" || fail "clone"

grep -q 'protect refused' envoy.log && ok "Envoy logs each refusal" || fail "no refusal in the Envoy log"

# The check's ref-name rules against git's own (git check-ref-format): never more permissive.
# Names from every one- and two-part combination of tricky pieces, as bytes (printf, not echo).
python3 -I - > refnames <<'PY'
import itertools
atoms = ["main", "a", "x.y", "/", "//", ".", "..", ".lock", ".LOCK", "@", "@{", "{", "}", "-", "+", "~", "^",
         ":", "?", "*", "[", "]", "\\", " ", "\t", "é", "main.lock", "a.", "@{x}", "/.", "./", "..."]
for n in (1, 2):
    for c in itertools.product(atoms, repeat=n):
        print("refs/heads/" + "".join(c))
PY
while IFS= read -r n; do
  if git check-ref-format "$n" 2>/dev/null; then printf '1 %s\n' "$n"; else printf '0 %s\n' "$n"; fi
done < refnames > refnames.git
cat > refcmp.lua <<'LUA'
local src = io.open(arg[1]):read("*a")
local plain_ref = loadstring(src:match("(local function plain_ref%(r%)\n.-\nend)") .. "\nreturn plain_ref")()
local more = 0
for line in io.lines(arg[2]) do
  local g, n = line:match("^(%d) (.*)$")
  if plain_ref(n) and g == "0" then more = more + 1; print("allowed, git refuses: " .. n) end
end
os.exit(more == 0 and 0 or 1)
LUA
if ! command -v luajit >/dev/null; then echo "skip ref names against git: no luajit"
elif luajit refcmp.lua "$repo/install/git-protect.lua" refnames.git; then ok "ref names: the check is never more permissive than git check-ref-format ($(wc -l < refnames) names)"
else fail "ref names the check allows and git refuses"; fi
kill -0 "$envoy_pid" 2>/dev/null && ! grep -q 'PANIC\|runtime code generation failed' envoy.log \
  && ok "Envoy still running, no Lua panic ($under)" || fail "Envoy died or panicked: $(grep -m2 'PANIC\|code generation' envoy.log)"
echo "failures: $fails"
exit "$fails"
