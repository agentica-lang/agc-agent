"""End-to-end tests: the TUI client under a pseudo-terminal, against a core server against a fake model API.

The fake model streams the recorded fixtures of core (core/tests/fixtures/openai_chat). Most tests let the client
start the server itself (the command after --) in a fresh state folder; the stream tests put a proxy between the
client and a server they start, to cut the event stream or answer it with `resync`. Standard library only. AGENTICA
names the binary.
"""

import fcntl
import http.client
import http.server
import json
import os
import queue
import re
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import threading
import time
import unicodedata
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CLIENT = ROOT / "tui_client" / "main.agc"
CORE = ROOT / "core" / "main.agc"
FIXTURES = ROOT / "core" / "tests" / "fixtures" / "openai_chat"
AGENTICA = os.environ.get("AGENTICA", "agentica")
TIMEOUT = 20.0
ROWS, COLS = 24, 80
ANSWER = "Hello! It's a pleasure to meet you."

ENTER_SCREEN = b"\x1b[?1049h"
LEAVE_SCREEN = b"\x1b[?1049l"
ESCAPE = re.compile(r"\x1b(\[[0-?]*[ -/]*[@-~]|[()][0-9A-Za-z]|.)")


def screen_rows(output: bytes) -> list[str]:
    """The text a terminal shows after `output`: cursor moves `ESC [ row ; col H`, clears and characters (a wide one
    takes two columns)."""
    grid = [[" "] * COLS for _ in range(ROWS)]
    row = col = 0
    text = output.decode(errors="replace")
    at = 0
    while at < len(text):
        match = ESCAPE.match(text, at)
        if match:
            sequence = match.group(1)
            if sequence.startswith("[") and sequence.endswith("H"):
                parts = (sequence[1:-1] or "1;1").split(";")
                row, col = int(parts[0]) - 1, int(parts[1]) - 1
            elif sequence == "[2J":
                grid = [[" "] * COLS for _ in range(ROWS)]
            at = match.end()
            continue
        char = text[at]
        if char >= " " and row < ROWS and col < COLS:
            grid[row][col] = char
            col += 1
            if unicodedata.east_asian_width(char) in "WF" and col < COLS:
                grid[row][col] = ""
                col += 1
        at += 1
    return ["".join(line).rstrip() for line in grid]


def env_for(base: Path, model: "FakeModel") -> dict[str, str]:
    return dict(
        os.environ,
        TERM="xterm",
        FINN_BASE_URL=model.url,
        FINN_MODEL="test-model",
        FINN_DATA_DIR=str(base / "data"),
        FINN_CONTEXT_WINDOW="100000",
    )


class Reply:
    """One answer of the fake model: a fixture streamed one event at a time. After `hold` events it waits until
    `release` is set (or the test ends, when it never is)."""

    def __init__(self, fixture: str, hold: int | None = None, pause: float = 0.02) -> None:
        events = (FIXTURES / fixture).read_text().split("\n\n")
        self.events = [event + "\n\n" for event in events if event.strip()]
        self.hold = hold
        self.pause = pause
        self.release = threading.Event()


class FakeModel:
    """An OpenAI chat completions API on 127.0.0.1, port 0, that answers each request with the next reply."""

    def __init__(self, replies: list[Reply]) -> None:
        self.replies: queue.Queue[Reply] = queue.Queue()
        for reply in replies:
            self.replies.put(reply)
        self.requests: queue.Queue[dict] = queue.Queue()
        self.done = threading.Event()
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args) -> None:
                pass

            def do_POST(self) -> None:
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                fake.requests.put(json.loads(body or b"{}"))
                try:
                    reply = fake.replies.get_nowait()
                except queue.Empty:
                    self.send_error(500, "no reply left")
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                try:
                    for index, event in enumerate(reply.events):
                        if index == reply.hold:
                            reply.release.wait(TIMEOUT)
                            if fake.done.is_set():
                                return
                        self.chunk(event.encode())
                        time.sleep(reply.pause)
                    self.chunk(b"")
                except OSError:
                    pass

            def chunk(self, data: bytes) -> None:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                self.wfile.flush()

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/v1"

    def close(self) -> None:
        self.done.set()
        while not self.replies.empty():
            self.replies.get_nowait().release.set()
        self.server.shutdown()
        self.server.server_close()


class Proxy:
    """Forwards the client's requests to a server. Each event stream takes the next step of `plan`: None passes it
    on, ("cut", n) passes n events then drops the connection, "resync" answers with a `resync` event."""

    def __init__(self, port: int, plan: list) -> None:
        self.plan: queue.Queue = queue.Queue()
        for step in plan:
            self.plan.put(step)
        self.paths: list[str] = []
        proxy = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args) -> None:
                pass

            def do_GET(self) -> None:
                self.forward()

            def do_POST(self) -> None:
                self.forward()

            def do_DELETE(self) -> None:
                self.forward()

            def forward(self) -> None:
                proxy.paths.append(f"{self.command} {self.path}")
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                upstream = http.client.HTTPConnection("127.0.0.1", port, timeout=TIMEOUT)
                upstream.request(self.command, self.path, body, dict(self.headers.items()))
                response = upstream.getresponse()
                if self.path.endswith("/events") and response.status == 200:
                    self.stream(response)
                else:
                    data = response.read()
                    self.send_response(response.status)
                    self.send_header("Content-Type", response.getheader("Content-Type", "application/json"))
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                upstream.close()

            def stream(self, response: http.client.HTTPResponse) -> None:
                step = None if proxy.plan.empty() else proxy.plan.get_nowait()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                if step == "resync":
                    self.chunk(b"event: resync\ndata: {}\n\n")
                    self.chunk(b"")
                    return
                left = step[1] if step else None
                buffer = b""
                try:
                    while left != 0:
                        piece = response.read1(65536)
                        if not piece:
                            self.chunk(b"")
                            return
                        buffer += piece
                        while b"\n\n" in buffer and left != 0:
                            event, buffer = buffer.split(b"\n\n", 1)
                            self.chunk(event + b"\n\n")
                            if left is not None:
                                left -= 1
                except (OSError, http.client.HTTPException):
                    return
                self.close_connection = True

            def chunk(self, data: bytes) -> None:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                self.wfile.flush()

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.port = self.server.server_address[1]

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


class Terminal:
    """The client on a new pty of 80x24 with TERM=xterm."""

    def __init__(self, base: Path, model: FakeModel, args: list[str]) -> None:
        self.base = base
        self.master, self.slave = os.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        self.modes_before = termios.tcgetattr(self.slave)
        self.output = b""
        self.process = subprocess.Popen(
            [AGENTICA, str(CLIENT), "--cwd", str(base / "work"), *args],
            cwd=base / "work",
            stdin=self.slave,
            stdout=self.slave,
            stderr=self.slave,
            env=env_for(base, model),
            preexec_fn=self._own_terminal,
        )

    @staticmethod
    def _own_terminal() -> None:
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    def screen(self) -> list[str]:
        return screen_rows(self.output[self.output.rfind(ENTER_SCREEN) :])

    def wait_for(self, text: str) -> list[str]:
        """Reads until some row of the screen holds `text`; gives the screen."""
        deadline = time.monotonic() + TIMEOUT
        while True:
            rows = self.screen()
            if any(text in row for row in rows):
                return rows
            if time.monotonic() > deadline:
                shown = "\n".join(rows)
                raise AssertionError(f"no {text!r} on the screen:\n{shown}")
            self._read(0.05)

    def settle(self, seconds: float = 0.5) -> list[str]:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self._read(0.05)
        return self.screen()

    def type(self, text: str) -> None:
        os.write(self.master, text.encode())

    def finish(self) -> int:
        code = self.process.wait(TIMEOUT)
        while self._read(0.1):
            pass
        return code

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        os.close(self.master)
        os.close(self.slave)

    def _read(self, wait: float) -> bool:
        ready, _, _ = select.select([self.master], [], [], wait)
        if not ready:
            return False
        try:
            chunk = os.read(self.master, 65536)
        except OSError:
            return False
        self.output += chunk
        return bool(chunk)


def stop_server(state: Path) -> None:
    try:
        pid = json.loads((state / "server.json").read_text())["pid"]
    except (OSError, ValueError, KeyError):
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass


def text_of(rows: list[str]) -> str:
    return "\n".join(rows)


class PtyTest(unittest.TestCase):
    def folder(self) -> Path:
        base = Path(tempfile.mkdtemp(prefix="agc-tui-"))
        self.addCleanup(shutil.rmtree, base, True)
        (base / "work").mkdir()
        return base

    def model(self, replies: list[Reply]) -> FakeModel:
        model = FakeModel(replies)
        self.addCleanup(model.close)
        self.fake = model
        return model

    def start(self, replies: list[Reply]) -> Terminal:
        """The client, which starts its own server."""
        base = self.folder()
        model = self.model(replies)
        self.addCleanup(stop_server, base / "state")
        args = ["--state-dir", str(base / "state"), "--", AGENTICA, str(CORE), "serve"]
        terminal = Terminal(base, model, args)
        self.addCleanup(terminal.close)
        terminal.wait_for("ready")
        return terminal

    def start_proxied(self, replies: list[Reply], plan: list) -> Terminal:
        """A server the test starts, and the client reaching it through a proxy."""
        base = self.folder()
        model = self.model(replies)
        server_dir = base / "server"
        server_dir.mkdir(mode=0o700)
        server = subprocess.Popen(
            [AGENTICA, str(CORE), "serve"],
            env=dict(env_for(base, model), FINN_STATE_DIR=str(server_dir)),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(server.wait)
        self.addCleanup(server.terminate)
        deadline = time.monotonic() + TIMEOUT
        while not (server_dir / "server.json").exists() or not (server_dir / "server.json").read_text():
            if time.monotonic() > deadline:
                raise AssertionError("the server wrote no server.json")
            time.sleep(0.05)
        time.sleep(0.1)
        info = json.loads((server_dir / "server.json").read_text())
        proxy = Proxy(info["port"], plan)
        self.addCleanup(proxy.close)
        self.proxy = proxy
        client_dir = base / "client"
        client_dir.mkdir(mode=0o700)
        info_file = client_dir / "server.json"
        info_file.write_text(json.dumps(dict(info, port=proxy.port)))
        info_file.chmod(0o600)
        terminal = Terminal(base, model, ["--state-dir", str(client_dir)])
        self.addCleanup(terminal.close)
        terminal.wait_for("ready")
        return terminal

    def test_a_message_streams_its_answer_into_the_transcript(self) -> None:
        reply = Reply("text.sse", hold=4)
        term = self.start([reply])
        term.type("hello there")
        term.wait_for("> hello there")
        term.type("\r")
        rows = term.wait_for("Hello!")
        self.assertIn("working", text_of(rows))
        self.assertNotIn("meet you", text_of(rows))
        reply.release.set()
        term.wait_for(ANSWER)
        rows = term.wait_for("ready")
        self.assertIn("> hello there", rows)
        request = self.fake.requests.get(timeout=1)
        self.assertEqual(request["messages"][-1]["content"], "hello there")
        term.type("\x03")
        self.assertEqual(term.finish(), 0)

    def test_ctrl_j_adds_a_line_to_the_prompt(self) -> None:
        term = self.start([Reply("text.sse")])
        term.type("one\ntwo")
        rows = term.wait_for("  two")
        self.assertEqual(rows[rows.index("  two") - 1], "> one")
        term.type("\r")
        term.wait_for(ANSWER)
        request = self.fake.requests.get(timeout=1)
        self.assertEqual(request["messages"][-1]["content"], "one\ntwo")

    def test_wide_characters_wrap_by_their_width(self) -> None:
        term = self.start([])
        text = "日本" * 25
        term.type(text)
        # 50 wide characters are 100 columns: 39 fit after the lead, the other 11 go on the next row.
        rows = term.wait_for("  " + text[39:])
        self.assertEqual(rows[-1], "  " + text[39:])
        self.assertEqual(rows[-2], "> " + text[:39])

    def test_escape_stops_the_turn(self) -> None:
        term = self.start([Reply("text.sse", hold=3), Reply("text.sse")])
        term.type("hi\r")
        term.wait_for("Hello!")
        term.wait_for("working")
        term.type("\x1b")
        term.wait_for("· stopped")
        term.wait_for("ready")
        term.type("again\r")
        term.wait_for(ANSWER)

    def test_an_approval_request_is_noted(self) -> None:
        term = self.start([Reply("write_file.sse")])
        term.type("write it\r")
        term.wait_for("waiting (write_file): answer it with finn")

    def test_term_and_hup_restore_the_terminal(self) -> None:
        for sig, code in [(signal.SIGTERM, 143), (signal.SIGHUP, 129)]:
            with self.subTest(signal=sig.name):
                term = self.start([])
                term.process.send_signal(sig)
                self.assertEqual(term.finish(), code)
                self.assertIn(LEAVE_SCREEN, term.output[term.output.rindex(ENTER_SCREEN) :])
                self.assertEqual(termios.tcgetattr(term.slave), term.modes_before)

    def test_escape_while_idle_sends_no_stop(self) -> None:
        term = self.start_proxied([], [])
        term.type("\x1b")
        term.type("x")
        rows = term.wait_for("> x")
        self.assertNotIn("stopping", text_of(term.settle()))
        self.assertIn("ready", text_of(rows))
        self.assertFalse(any(path.endswith("/stop") for path in self.proxy.paths), self.proxy.paths)

    def test_a_cut_stream_is_read_again_from_the_last_event(self) -> None:
        term = self.start_proxied([Reply("text.sse", pause=0.1)], [("cut", 3)])
        term.type("hi\r")
        term.wait_for(ANSWER)
        rows = term.wait_for("ready")
        self.assertEqual(text_of(rows).count("Hello!"), 1, text_of(rows))
        streams = [path for path in self.proxy.paths if path.endswith("/events")]
        self.assertEqual(len(streams), 2, self.proxy.paths)

    def test_a_resync_reads_the_session_again(self) -> None:
        term = self.start_proxied([Reply("text.sse", pause=0.1)], [("cut", 3), "resync"])
        term.type("hi\r")
        term.wait_for(ANSWER)
        rows = term.wait_for("ready")
        self.assertEqual(text_of(rows).count("Hello!"), 1, text_of(rows))
        self.assertEqual(text_of(rows).count("> hi"), 1, text_of(rows))
        reads = [path for path in self.proxy.paths if path.startswith("GET") and not path.endswith("/events")]
        self.assertTrue(any("/sessions/" in path for path in reads), self.proxy.paths)

    def test_resyncs_in_a_row_end_the_client(self) -> None:
        term = self.start_proxied([], ["resync", "resync", "resync", "resync"])
        self.assertEqual(term.finish(), 1)
        after = term.output[term.output.rindex(LEAVE_SCREEN) :]
        self.assertIn(b"keeps asking to read the session again", after)


if __name__ == "__main__":
    unittest.main()
