"""End-to-end tests: the TUI client under a pseudo-terminal, against a core server against a fake model API.

The fake model streams the recorded fixtures of core (core/tests/fixtures/openai_chat); the client starts the server
itself (the command after --) in a fresh state folder. Standard library only. AGENTICA names the binary.
"""

import fcntl
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
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CLIENT = ROOT / "tui_client" / "main.agc"
CORE = ROOT / "core" / "main.agc"
FIXTURES = ROOT / "core" / "tests" / "fixtures" / "openai_chat"
AGENTICA = os.environ.get("AGENTICA", "agentica")
TIMEOUT = 20.0
ROWS, COLS = 24, 80

ENTER_SCREEN = b"\x1b[?1049h"
ESCAPE = re.compile(r"\x1b(\[[0-?]*[ -/]*[@-~]|[()][0-9A-Za-z]|.)")


def screen_rows(output: bytes) -> list[str]:
    """The text a terminal shows after `output`: cursor moves `ESC [ row ; col H`, clears and characters."""
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
        at += 1
    return ["".join(line).rstrip() for line in grid]


class Reply:
    """One answer of the fake model: a fixture streamed one event at a time; `hold` stops after that many events and
    keeps the connection open until the client leaves or the test ends."""

    def __init__(self, fixture: str, hold: int | None = None, pause: float = 0.02) -> None:
        events = (FIXTURES / fixture).read_text().split("\n\n")
        self.events = [event + "\n\n" for event in events if event.strip()]
        self.hold = hold
        self.pause = pause


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
                events = reply.events if reply.hold is None else reply.events[: reply.hold]
                try:
                    for event in events:
                        self.chunk(event.encode())
                        time.sleep(reply.pause)
                    if reply.hold is not None:
                        fake.done.wait(TIMEOUT)
                        return
                    self.chunk(b"")
                except OSError:
                    pass

            def chunk(self, data: bytes) -> None:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                self.wfile.flush()

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/v1"

    def close(self) -> None:
        self.done.set()
        self.server.shutdown()
        self.server.server_close()


class Terminal:
    """The client on a new pty of 80x24 with TERM=xterm."""

    def __init__(self, base: Path, model: FakeModel, args: list[str]) -> None:
        self.base = base
        self.master, self.slave = os.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        self.output = b""
        env = dict(
            os.environ,
            TERM="xterm",
            FINN_BASE_URL=model.url,
            FINN_MODEL="test-model",
            FINN_DATA_DIR=str(base / "data"),
            FINN_CONTEXT_WINDOW="100000",
        )
        command = [AGENTICA, str(CLIENT), "--state-dir", str(base / "state"), "--cwd", str(base / "work"), *args]
        self.process = subprocess.Popen(
            [*command, "--", AGENTICA, str(CORE), "serve"],
            cwd=base / "work",
            stdin=self.slave,
            stdout=self.slave,
            stderr=self.slave,
            env=env,
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
        stop_server(self.base / "state")

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


class PtyTest(unittest.TestCase):
    def start(self, replies: list[Reply], args: list[str] | None = None) -> Terminal:
        base = Path(tempfile.mkdtemp(prefix="agc-tui-"))
        self.addCleanup(shutil.rmtree, base, True)
        (base / "work").mkdir()
        model = FakeModel(replies)
        self.addCleanup(model.close)
        terminal = Terminal(base, model, args or [])
        self.addCleanup(terminal.close)
        self.model = model
        terminal.wait_for("ready")
        return terminal

    def test_a_message_streams_its_answer_into_the_transcript(self) -> None:
        term = self.start([Reply("text.sse", pause=0.2)])
        term.type("hello there")
        term.wait_for("> hello there")
        term.type("\r")
        term.wait_for("working")
        rows = term.wait_for("Hello!")
        self.assertFalse(any("meet you." in row for row in rows), "the answer came whole, not in deltas")
        term.wait_for("It's a pleasure to meet you.")
        rows = term.wait_for("ready")
        self.assertIn("> hello there", rows)
        request = self.model.requests.get(timeout=1)
        self.assertEqual(request["messages"][-1]["content"], "hello there")
        term.type("\x03")
        self.assertEqual(term.finish(), 0)

    def test_ctrl_j_adds_a_line_to_the_prompt(self) -> None:
        term = self.start([Reply("text.sse")])
        term.type("one\ntwo")
        rows = term.wait_for("  two")
        self.assertEqual(rows[rows.index("  two") - 1], "> one")
        term.type("\r")
        term.wait_for("It's a pleasure to meet you.")
        request = self.model.requests.get(timeout=1)
        self.assertEqual(request["messages"][-1]["content"], "one\ntwo")

    def test_escape_stops_the_turn(self) -> None:
        term = self.start([Reply("text.sse", hold=3), Reply("text.sse")])
        term.type("hi\r")
        term.wait_for("Hello!")
        term.wait_for("working")
        term.type("\x1b")
        term.wait_for("· stopped")
        term.wait_for("ready")
        term.type("again\r")
        term.wait_for("It's a pleasure to meet you.")


if __name__ == "__main__":
    unittest.main()
