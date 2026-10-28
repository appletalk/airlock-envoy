#!/usr/bin/env python3
"""A stand-in for GitHub's App API (and, on other paths, an upstream that echoes the
Authorization it gets), over TLS, for the airlock-envoy-mint tests. No packages: openssl
checks each JWT's RS256 signature against the App's public key.

  fake-github-app.py <port> <cert> <key> <app public key> <app id> <installation id> <log>

Writes one JSON line per request to <log>. A file <log>.fail makes token minting answer 422,
<log>.delay (seconds) makes it wait first, <log>.delfail makes revoking answer 502;
<log>.perms (JSON) replaces the installation's permissions; <log>.repos (a name a line) its
installed repos. GET /orgs/<org>/installation answers for any org named in <log>.orgs (one a
line; default "example-org").
"""
import base64, datetime, http.server, json, os, secrets, ssl, subprocess, sys, tempfile, time

port, cert, key, pub, app_id, inst_id, log = sys.argv[1:8]
issued = set()


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def jwt_ok(auth):
    """None if the Authorization is a valid JWT for the App, else why not."""
    if not auth.startswith("Bearer "):
        return "not a Bearer JWT"
    parts = auth[7:].split(".")
    if len(parts) != 3:
        return "not three parts"
    head, body = json.loads(b64d(parts[0])), json.loads(b64d(parts[1]))
    if head != {"alg": "RS256", "typ": "JWT"}:
        return "header %r" % head
    with tempfile.NamedTemporaryFile() as sig, tempfile.NamedTemporaryFile() as data:
        sig.write(b64d(parts[2])); sig.flush()
        data.write((parts[0] + "." + parts[1]).encode()); data.flush()
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", sig.name, data.name], capture_output=True)
    if r.returncode != 0:
        return "bad signature"
    now = time.time()
    if str(body.get("iss")) != app_id:
        return "iss %r" % body.get("iss")
    if not (body["iat"] <= now and body["exp"] > now and body["exp"] - body["iat"] <= 660):
        return "iat/exp %r" % body
    return None


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, code, obj=None, extra=None):
        b = b"" if obj is None else (json.dumps(obj) + "\n").encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
        rec = {"method": self.command, "path": self.path, "status": code}
        rec.update(extra or {})
        with open(log, "a") as f:
            f.write(json.dumps(rec) + "\n")

    def body(self):
        n = int(self.headers.get("content-length") or 0)
        return json.loads(self.rfile.read(n) or b"null")

    def do_POST(self):
        if self.path == "/app/installations/%s/access_tokens" % inst_id:
            why = jwt_ok(self.headers.get("authorization", ""))
            req = self.body()
            if why:
                return self.reply(401, {"message": why}, {"jwt": why})
            if os.path.exists(log + ".delay"):
                time.sleep(float(open(log + ".delay").read()))
            if os.path.exists(log + ".fail"):
                return self.reply(422, {"message": "permission not granted"}, {"request": req})
            tok = "ghs_" + secrets.token_hex(18)
            if os.path.exists(log + ".badtoken"):
                tok = "ghs_aaaaaaaaaaaaaaaaaaaaaaaa \\x"
            issued.add(tok)
            exp = datetime.datetime.fromtimestamp(time.time() + 3600, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            return self.reply(201, {"token": tok, "expires_at": exp, "permissions": req.get("permissions"),
                                    "repositories": [{"name": r} for r in req.get("repositories", [])]},
                              {"request": req, "token": tok})
        self.reply(404, {"message": "Not Found"})

    def do_DELETE(self):
        if self.path == "/installation/token" and os.path.exists(log + ".delfail"):
            return self.reply(502, {"message": "unavailable"})
        if self.path == "/installation/token":
            auth = self.headers.get("authorization", "")
            tok = auth[6:] if auth.startswith("token ") else ""
            if tok in issued:
                issued.discard(tok)
                return self.reply(204, None, {"revoked": tok})
            return self.reply(401, {"message": "Bad credentials"}, {"revoke_unknown": tok})
        self.reply(404, {"message": "Not Found"})

    def perms(self):
        if os.path.exists(log + ".perms"):
            return json.load(open(log + ".perms"))
        return {"contents": "write", "issues": "write", "metadata": "read", "pull_requests": "read"}

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/app/installations/%s" % inst_id or path.startswith("/orgs/") and path.endswith("/installation"):
            why = jwt_ok(self.headers.get("authorization", ""))
            if why:
                return self.reply(401, {"message": why}, {"jwt": why})
            if path.startswith("/orgs/"):
                orgs = open(log + ".orgs").read().split() if os.path.exists(log + ".orgs") else ["example-org"]
                if path.split("/")[2] not in orgs:
                    return self.reply(404, {"message": "Not Found"})
            acct = {} if os.path.exists(log + ".noaccount") else {"login": "example-org", "id": 999}
            return self.reply(200, {"id": int(inst_id), "account": acct,
                                    "repository_selection": "selected", "permissions": self.perms()})
        if path == "/installation/repositories":
            auth = self.headers.get("authorization", "")
            if not (auth.startswith("token ") and auth[6:] in issued):
                return self.reply(401, {"message": "Bad credentials"})
            names = open(log + ".repos").read().split() if os.path.exists(log + ".repos") else ["tools", "site", "docs", "wiki", "filed"]
            page = int(dict(p.split("=") for p in query.split("&") if "=" in p).get("page", "1"))
            chunk = names[(page - 1) * 100:page * 100]
            return self.reply(200, {"total_count": len(names), "repositories": [{"name": n, "full_name": "example-org/" + n} for n in chunk]})
        # Anything else: an upstream echoing what it was sent, with whether the token is live.
        auth = self.headers.get("authorization", "")
        tok = auth.split(":", 1)[-1] if auth.startswith("Basic ") else auth[6:] if auth.startswith("token ") else ""
        if auth.startswith("Basic "):
            tok = base64.b64decode(auth[6:]).decode().split(":", 1)[-1]
        self.reply(200, {"authorization": auth, "live": tok in issued})

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer((os.environ.get("FAKE_BIND", "127.0.0.1"), int(port)), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
