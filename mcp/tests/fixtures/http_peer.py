"""An MCP server on streamable HTTP (revision 2025-06-18) for the tests, standard library only.

Usage: python3 http_peer.py LOG. It listens on 127.0.0.1, port 0, prints its port and serves until its stdin
closes. Each request goes to LOG as a JSON line. With PEER_TOKEN set, a request without `Authorization: Bearer
TOKEN` gets 401.

`initialize` gets JSON and a new session id; every later request needs that id (400 without one, 404 for an unknown
one) and the protocol version. `tools/list` gets an SSE stream: a notification, a `ping` request of the server, then
the answer. The tools: `echo` (JSON), `cut` (an SSE stream that closes after one event, resumed by a GET with
`Last-Event-ID`), `big` (an SSE event of 100000 bytes), `hang` (no answer), `expire` (answers, then ends the
session) and `once` (ends the session, then sends one event with an id and closes the stream: its resume gets 404).
A GET without `Last-Event-ID` gets 405, and DELETE ends the session. `X-Peer-Version` on `initialize` is the
protocol version it answers.
`X-Peer-Init-Delay: N:SECONDS` delays the Nth initialize by that many seconds.
"""

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "2025-06-18"
TOOLS = ["echo", "cut", "big", "hang", "expire", "once"]
LOCK = threading.Lock()
SESSIONS = set()
PENDING = {}
COUNTER = [0]


def answer(message, result):
    return {"jsonrpc": "2.0", "id": message["id"], "result": result}


def text_result(text):
    return {"content": [{"type": "text", "text": text}], "isError": False}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        message = json.loads(self.rfile.read(length))
        self.record(message)
        if not self.authorized():
            return self.empty(401)
        accept = self.headers.get("Accept", "")
        if "application/json" not in accept or "text/event-stream" not in accept:
            return self.empty(406)
        method = message.get("method")
        if method == "initialize":
            return self.initialize(message)
        session = self.session()
        if session is None:
            return None
        if "id" not in message or method is None:
            return self.empty(202)
        if method == "tools/list":
            tools = [{"name": name, "inputSchema": {"type": "object"}} for name in TOOLS]
            progress = {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progress": 1}}
            ping = {"jsonrpc": "2.0", "id": "srv-1", "method": "ping"}
            return self.events([("", progress), ("", ping), ("", answer(message, {"tools": tools}))])
        if method == "tools/call":
            return self.call(message, session)
        return self.json({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": method}})

    def do_GET(self):
        self.record(None)
        if not self.authorized():
            return self.empty(401)
        last = self.headers.get("Last-Event-ID")
        if last is None or "text/event-stream" not in self.headers.get("Accept", ""):
            return self.empty(405)
        if self.session() is None:
            return None
        with LOCK:
            pending = PENDING.pop(last, None)
        if pending is None:
            return self.empty(404)
        return self.events([pending])

    def do_DELETE(self):
        self.record(None)
        with LOCK:
            SESSIONS.discard(self.headers.get("Mcp-Session-Id"))
        return self.empty(200)

    def initialize(self, message):
        with LOCK:
            COUNTER[0] += 1
            number = COUNTER[0]
            session = f"session-{number}"
            SESSIONS.add(session)
        delay = self.headers.get("X-Peer-Init-Delay")
        if delay:
            nth, seconds = delay.split(":")
            if number == int(nth):
                time.sleep(float(seconds))
        result = {
            "protocolVersion": self.headers.get("X-Peer-Version", VERSION),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "peer", "version": "1"},
        }
        try:
            return self.json(answer(message, result), {"Mcp-Session-Id": session})
        except (BrokenPipeError, ConnectionResetError):
            # A client with a shorter deadline may already have closed the connection.
            return None

    def call(self, message, session):
        params = message.get("params", {})
        name = params.get("name")
        arguments = params.get("arguments", {})
        if name == "echo":
            return self.json(answer(message, text_result(arguments.get("text", ""))))
        if name == "cut":
            progress = {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progress": 1}}
            with LOCK:
                PENDING[f"{session}-cut-1"] = (f"{session}-cut-2", answer(message, text_result("resumed")))
            return self.events([(f"{session}-cut-1", progress)])
        if name == "big":
            return self.events([("", answer(message, text_result("x" * 100000)))])
        if name == "hang":
            time.sleep(30)
            return self.empty(500)
        if name == "expire":
            with LOCK:
                SESSIONS.discard(session)
            return self.json(answer(message, text_result("expired")))
        if name == "once":
            with LOCK:
                SESSIONS.discard(session)
            progress = {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progress": 1}}
            return self.events([(f"{session}-once-1", progress)])
        return self.json({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32602, "message": "no tool"}})

    def authorized(self):
        token = os.environ.get("PEER_TOKEN", "")
        return not token or self.headers.get("Authorization") == f"Bearer {token}"

    def session(self):
        session = self.headers.get("Mcp-Session-Id")
        with LOCK:
            known = session in SESSIONS
        if session is None:
            self.empty(400)
            return None
        if not known:
            self.empty(404)
            return None
        if self.headers.get("MCP-Protocol-Version") != VERSION:
            self.empty(400)
            return None
        return session

    def record(self, message):
        seen = {
            "verb": self.command,
            "session": self.headers.get("Mcp-Session-Id"),
            "version": self.headers.get("MCP-Protocol-Version"),
            "last_event_id": self.headers.get("Last-Event-ID"),
            "body": message,
        }
        with LOCK, open(sys.argv[1], "a", encoding="utf-8") as log:
            log.write(json.dumps(seen) + "\n")

    def empty(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def json(self, message, headers=None):
        body = json.dumps(message).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    # The stream ends with the connection: it has no length.
    def events(self, events):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        for event_id, message in events:
            head = f"id: {event_id}\n" if event_id else ""
            self.wfile.write(f": comment\n{head}data: {json.dumps(message)}\n\n".encode())
            self.wfile.flush()
        self.close_connection = True


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(server.server_address[1], flush=True)
    sys.stdin.read()
    server.shutdown()


if __name__ == "__main__":
    main()
