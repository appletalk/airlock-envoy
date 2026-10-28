# A stand-in MCP server (Streamable HTTP) for test/mcp-e2e.sh: TLS, HTTP/1.1, endpoints
# /alpha/mcp, /beta/mcp and /mcp. Logs every request it gets, one JSON line each, to
# upstream.log in the working directory. Usage: python3 -I mcp-up.py <port> <cert> <key>
#   POST  initialize answers with an Mcp-Session-Id; every later request must carry it (400
#         if not). Notifications and responses: 202. tools/list, tools/call (echo, slow) and
#         batches answer as JSON, or as an event stream when the call's arguments ask for it
#         (sse: true) and the client accepts one. slow streams a progress notification every
#         `every` seconds for `seconds`, then the result.
#   GET   /alpha/mcp: an event stream that sends one event (naming the Last-Event-ID it got)
#         and then nothing for two minutes. /beta/mcp and /mcp: 405.
#   DELETE  ends the session: 200.
#   Any other path or method: 200 "upstream reached", so a refusal from Envoy stands out.
import http.server, json, ssl, sys, threading, time

SESSION = "sess-0123456789"
ENDPOINTS = ("/alpha/mcp", "/beta/mcp", "/mcp")
lock = threading.Lock()


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_request_line(self, body=b""):
        h = {k.lower(): v for k, v in self.headers.items()}
        rec = {"method": self.command, "path": self.path, "headers": h, "body": body[:300].decode("utf-8", "replace")}
        with lock, open("upstream.log", "a") as f:
            f.write(json.dumps(rec) + "\n")

    def send(self, status, body=b"", ctype="application/json", extra=None):
        self.send_response(status)
        if body or status != 202:
            self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def chunk(self, data):
        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()

    def start_stream(self, extra=None):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("transfer-encoding", "chunked")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()

    def other(self, body=b""):
        self.log_request_line(body)
        self.send(200, b"upstream reached\n", "text/plain")

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n) if n else b""
        if self.headers.get("transfer-encoding", "").lower() == "chunked":
            body = b""
            while True:
                size = int(self.rfile.readline().strip() or b"0", 16)
                if not size:
                    self.rfile.readline()
                    break
                body += self.rfile.read(size)
                self.rfile.readline()
        if self.path not in ENDPOINTS:
            return self.other(body)
        self.log_request_line(body)
        try:
            msg = json.loads(body)
        except ValueError:
            return self.send(400, b'{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}')
        msgs = msg if isinstance(msg, list) else [msg]
        if not (len(msgs) == 1 and msgs[0].get("method") == "initialize"):
            if self.headers.get("mcp-session-id") != SESSION:
                return self.send(400, b'{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"no or wrong session"}}')
        reqs = [m for m in msgs if "method" in m and "id" in m]
        if not reqs:
            return self.send(202)
        if len(msgs) == 1 and msgs[0]["method"] == "tools/call":
            p = msgs[0].get("params", {})
            a = p.get("arguments", {})
            if p.get("name") == "slow" or (a.get("sse") and "text/event-stream" in self.headers.get("accept", "")):
                return self.stream_call(msgs[0], a)
        out = [self.answer(m) for m in reqs]
        extra = {"mcp-session-id": SESSION} if msgs[0].get("method") == "initialize" else {}
        self.send(200, json.dumps(out if isinstance(msg, list) else out[0]).encode(), extra=extra)

    def answer(self, m):
        meth = m["method"]
        if meth == "initialize":
            r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "stand-in", "version": "1"}}
        elif meth == "tools/list":
            r = {"tools": [{"name": n, "inputSchema": {"type": "object"}} for n in ("echo", "slow", "write_thing", "read_a")]}
        elif meth == "tools/call":
            r = {"content": [{"type": "text", "text": "called " + m["params"]["name"]}], "isError": False}
        else:
            r = {}
        return {"jsonrpc": "2.0", "id": m["id"], "result": r}

    def stream_call(self, m, a):
        self.start_stream()
        try:
            secs, every = float(a.get("seconds", 0)), float(a.get("every", 1))
            t0 = time.time()
            k = 0
            while time.time() - t0 < secs:
                time.sleep(min(every, max(0.0, secs - (time.time() - t0))))
                k += 1
                note = {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": 1, "progress": k}}
                self.chunk(b"data: " + json.dumps(note).encode() + b"\n\n")
            self.chunk(b"id: 7\ndata: " + json.dumps(self.answer(m)).encode() + b"\n\n")
            self.chunk(b"")
        except OSError:
            pass

    def do_GET(self):
        if self.path not in ENDPOINTS:
            return self.other()
        self.log_request_line()
        if self.path != "/alpha/mcp":
            return self.send(405, b"", "text/plain", {"allow": "POST, DELETE"})
        if self.headers.get("mcp-session-id") != SESSION:
            return self.send(400, b"no session\n", "text/plain")
        self.start_stream()
        try:
            last = self.headers.get("last-event-id", "")
            note = {"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "data": "last-event-id=" + last}}
            self.chunk(b"id: 1\ndata: " + json.dumps(note).encode() + b"\n\n")
            time.sleep(120)   # then nothing, until Envoy or the client closes
            self.chunk(b": still here\n\n")
        except OSError:
            pass

    def do_DELETE(self):
        if self.path not in ENDPOINTS:
            return self.other()
        self.log_request_line()
        self.send(200 if self.headers.get("mcp-session-id") == SESSION else 404, b"", "text/plain")

    def do_PUT(self): self.other()
    def do_PATCH(self): self.other()
    def do_OPTIONS(self): self.other()
    def do_HEAD(self): self.other()

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H)
srv.daemon_threads = True
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[2], sys.argv[3])
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
