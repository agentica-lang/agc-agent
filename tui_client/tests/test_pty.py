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
OWN_FIXTURES = ROOT / "tui_client" / "tests" / "fixtures"
AGENTICA = os.environ.get("AGENTICA", "agentica")
# The client and the core are compiled once, and every process of a test runs the bytecode: `agentica main.agc` loads
# the whole front end again each time. PTY_BUILD names a folder that `run_pty.py` already filled.
BUILD = os.environ.get("PTY_BUILD", "")
TIMEOUT = 20.0
ROWS, COLS = 24, 80
ANSWER = "Hello! It's a pleasure to meet you."

ENTER_SCREEN = b"\x1b[?1049h"
LEAVE_SCREEN = b"\x1b[?1049l"
ESCAPE = re.compile(r"\x1b(\[[0-?]*[ -/]*[@-~]|[()][0-9A-Za-z]|.)")


def program(source: Path) -> list[str]:
    """The words that run the program of `source`."""
    return [AGENTICA, "run", "--", f"{BUILD}/{source.parent.name}.agcb"]


def compile_programs(folder: str) -> None:
    for source in (CLIENT, CORE):
        subprocess.run(
            [AGENTICA, "compile", str(source), "-o", f"{folder}/{source.parent.name}.agcb"],
            check=True,
            capture_output=True,
        )


def setUpModule() -> None:  # noqa: N802
    global BUILD
    if not BUILD:
        BUILD = tempfile.mkdtemp(prefix="agc-tui-build-")
        compile_programs(BUILD)


def tearDownModule() -> None:  # noqa: N802
    if not os.environ.get("PTY_BUILD"):
        shutil.rmtree(BUILD, True)


def screen_rows(output: bytes, rows: int = ROWS, cols: int = COLS) -> list[str]:
    """The text a terminal shows after `output`: cursor moves `ESC [ row ; col H`, clears and characters (a wide one
    takes two columns)."""
    ROWS, COLS = rows, cols  # noqa: N806
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


# FINN_TEST_RUN marks the servers of this test run, which `make leftovers` looks for after it.
KEPT_ENV = ("PATH", "LANG", "TMPDIR", "AGENTICA", "FINN_TEST_RUN")


def env_for(base: Path, model: "FakeModel") -> dict[str, str]:
    """Only what the programs need from the host, so that no FINN_*, ANTHROPIC_* or other variable of the developer
    reaches them: a test never calls a real API or reads a real config."""
    kept = {key: value for key, value in os.environ.items() if key in KEPT_ENV or key.startswith("LC_")}
    return dict(
        kept,
        TERM="xterm",
        FINN_BASE_URL=model.url,
        FINN_MODEL="test-model",
        FINN_DATA_DIR=str(base / "data"),
        # The user's own settings, skills and model list never reach the server: home is the test folder, and the
        # model catalog is not fetched.
        HOME=str(base / "home"),
        XDG_CONFIG_HOME=str(base / "home" / ".config"),
        XDG_DATA_HOME=str(base / "home" / ".local" / "share"),
        XDG_STATE_HOME=str(base / "home" / ".local" / "state"),
        XDG_CACHE_HOME=str(base / "home" / ".cache"),
        FINN_MODELS_URL="off",
        FINN_CONTEXT_WINDOW="100000",
        # The panels under test need the approvals, which are off by default.
        FINN_APPROVALS="1",
    )


def transcript(rows: list[str]) -> str:
    """The rows above the editor, from the session line to the note of a turn cut at the output limit."""
    text = text_of(rows)
    start = text.index(" session ")
    end = text.index("\n", text.index("output limit", start))
    return text[start:end]


class Reply:
    """One answer of the fake model: a fixture streamed one event at a time. After `hold` events it waits until
    `release` is set (or the test ends, when it never is)."""

    def __init__(self, fixture: str, hold: int | None = None, pause: float = 0.02) -> None:
        path = OWN_FIXTURES / fixture if (OWN_FIXTURES / fixture).exists() else FIXTURES / fixture
        events = path.read_text().split("\n\n")
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

            def do_GET(self) -> None:
                """`GET /models`, where a login checks a key: any key passes."""
                if not self.path.endswith("/models"):
                    self.send_error(404)
                    return
                data = json.dumps({"object": "list", "data": [{"id": "test-model"}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

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
    on, ("cut", n) passes n events then drops the connection, "resync" answers with a `resync` event. Each answer of an
    approval takes the next of `approvals`: "fail" answers 500 and sends nothing on, "late_fail" sends it on, then
    answers 500 a second later; none left passes it on."""

    def __init__(self, port: int, plan: list, approvals: list[str] = []) -> None:
        self.plan: queue.Queue = queue.Queue()
        for step in plan:
            self.plan.put(step)
        self.approvals = list(approvals)
        self.paths: list[str] = []
        # The Last-Event-ID of each event stream, and the ids each one passed on.
        self.asked: list[int] = []
        self.passed: list[list[int]] = []
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
                if self.path.endswith("/events"):
                    proxy.asked.append(int(self.headers.get("Last-Event-ID", "-1")))
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                approval = "/approvals/" in self.path and self.command == "POST" and proxy.approvals
                mode = proxy.approvals.pop(0) if approval else None
                if mode == "fail":
                    self.fail()
                    return
                upstream = http.client.HTTPConnection("127.0.0.1", port, timeout=TIMEOUT)
                upstream.request(self.command, self.path, body, dict(self.headers.items()))
                response = upstream.getresponse()
                if mode == "late_fail":
                    response.read()
                    upstream.close()
                    time.sleep(1)
                    self.fail()
                    return
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
                passed: list[int] = []
                proxy.passed.append(passed)
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
                            passed.extend(int(line[3:]) for line in event.split(b"\n") if line.startswith(b"id:"))
                            if left is not None:
                                left -= 1
                except (OSError, http.client.HTTPException):
                    return
                self.close_connection = True

            def fail(self) -> None:
                data = json.dumps({"kind": "proxy.failed", "message": "the proxy failed it"}).encode()
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

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

    def __init__(
        self, base: Path, model: FakeModel, args: list[str], rows: int = ROWS, cols: int = COLS, env: dict[str, str] = {}
    ) -> None:
        self.base = base
        self.master, self.slave = os.openpty()
        self.rows, self.cols = rows, cols
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.modes_before = termios.tcgetattr(self.slave)
        self.output = b""
        self.process = subprocess.Popen(
            [*program(CLIENT), "--cwd", str(base / "work"), *args],
            cwd=base / "work",
            stdin=self.slave,
            stdout=self.slave,
            stderr=self.slave,
            env=dict(env_for(base, model), **env),
            preexec_fn=self._own_terminal,
        )

    @staticmethod
    def _own_terminal() -> None:
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    def screen(self) -> list[str]:
        return screen_rows(self.output[self.output.rfind(ENTER_SCREEN) :], self.rows, self.cols)

    def resize(self, rows: int, cols: int) -> None:
        """The kernel sends SIGWINCH to the client, which owns the terminal."""
        self.output += b"\x1b[2J"
        self.rows, self.cols = rows, cols
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

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

    def wait_for_output(self, data: bytes, start: int) -> int:
        """Reads until `data` comes after offset `start` of the output; gives the offset after it."""
        deadline = time.monotonic() + TIMEOUT
        while data not in self.output[start:]:
            if time.monotonic() > deadline:
                raise AssertionError(f"no {data!r} in {self.output[start:]!r}")
            self._read(0.05)
        return self.output.index(data, start) + len(data)

    def wait_until(self, check, what: str) -> list[str]:
        """Reads until `check` holds for the screen rows; gives the screen."""
        deadline = time.monotonic() + TIMEOUT
        while True:
            rows = self.screen()
            if check(rows):
                return rows
            if time.monotonic() > deadline:
                shown = "\n".join(rows)
                raise AssertionError(f"no {what} on the screen:\n{shown}")
            self._read(0.05)

    def settle(self, seconds: float = 0.5) -> list[str]:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self._read(0.05)
        return self.screen()

    def type(self, text: str) -> None:
        os.write(self.master, text.encode())

    def click(self, row: int, col: int) -> None:
        """A left click at a cell (from 0), as an SGR mouse report: press, then release."""
        self.type(f"\x1b[<0;{col + 1};{row + 1}M\x1b[<0;{col + 1};{row + 1}m")

    def find(self, text: str) -> tuple[int, int]:
        rows = self.wait_for(text)
        row = next(i for i, line in enumerate(rows) if text in line)
        return row, rows[row].index(text)

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
        (base / "home").mkdir()
        return base

    def model(self, replies: list[Reply]) -> FakeModel:
        model = FakeModel(replies)
        self.addCleanup(model.close)
        self.fake = model
        return model

    def start(
        self, replies: list[Reply], rows: int = ROWS, cols: int = COLS, extra: list[str] = [], env: dict[str, str] = {}
    ) -> Terminal:
        """The client, which starts its own server."""
        base = self.folder()
        model = self.model(replies)
        self.addCleanup(stop_server, base / "state")
        args = [*extra, "--state-dir", str(base / "state"), "--", *program(CORE), "serve"]
        terminal = Terminal(base, model, args, rows, cols, env)
        self.addCleanup(terminal.close)
        terminal.wait_for("ready")
        return terminal

    def test_a_first_start_login_moves_the_session_to_the_new_provider(self) -> None:
        """A first start with no provider set up offers a login. A key for a provider of the config file offers its
        models in the picker, and the pick moves the session from the local fallback, where no server answers, to that
        provider: the footer names it and the next turn goes to it."""
        base = self.folder()
        model = self.model([Reply("text.sse")])
        config = base / "home" / ".config" / "finn"
        config.mkdir(parents=True)
        box = {"name": "box", "base_url": model.url, "key_env": "BOX_API_KEY", "models": ["test-model"]}
        (config / "config.json").write_text(json.dumps({"providers": [box]}))
        self.addCleanup(stop_server, base / "state")
        args = ["--state-dir", str(base / "state"), "--", *program(CORE), "serve"]
        terminal = Terminal(base, model, args, env={"FINN_BASE_URL": ""})
        self.addCleanup(terminal.close)
        terminal.wait_for("no provider is set up")
        terminal.type("box")
        terminal.wait_for("box")
        terminal.type("\r")
        terminal.wait_for("the key of box")
        terminal.type("sk-test\r")
        terminal.wait_for("pick a model of box")
        terminal.type("\r")
        rows = terminal.wait_for("box/test-model from the next turn")
        self.assertTrue(any("(box) test-model" in row for row in rows), text_of(rows))
        terminal.type("hello\r")
        terminal.wait_for(ANSWER)
        self.assertEqual(model.requests.get(timeout=TIMEOUT)["model"], "test-model")

    def test_a_pick_in_a_list_or_a_picker_is_the_one_applied(self) -> None:
        """Enter on the list of a command's argument runs the command with the row moved to, from the session's model or
        level, and no picker opens after it; `/model` alone opens one picker, whose pick closes it. Each pick is the
        one applied."""
        base = self.folder()
        model = self.model([])
        config = base / "home" / ".config" / "finn"
        config.mkdir(parents=True)
        box = {"name": "box", "base_url": model.url, "key_env": "BOX_API_KEY", "models": ["m1", "m2"]}
        (config / "config.json").write_text(json.dumps({"providers": [box]}))
        self.addCleanup(stop_server, base / "state")
        args = ["--state-dir", str(base / "state"), "--", *program(CORE), "serve"]
        terminal = Terminal(base, model, args, env={"BOX_API_KEY": "sk-test"})
        self.addCleanup(terminal.close)
        terminal.wait_for("ready")
        down = "\x1b[B"
        up = "\x1b[A"
        for typed, listed, keys, applied, footer in [
            ("/mo\r", "box/m2", up * 20 + down, "model box/m2 from the next turn", "(box) m2"),
            ("/model\r", "pick a model", "m1", "model box/m1 from the next turn", "(box) m1"),
            ("/thinking ", "medium", up, "thinking high from the next turn", "(box) m1 · high"),
        ]:
            terminal.type(typed)
            terminal.wait_for(listed)
            terminal.type(keys)
            terminal.settle(0.3)
            terminal.type("\r")
            terminal.wait_for(applied)
            rows = terminal.settle(0.5)
            self.assertFalse(any("pick a" in row or row.strip() == "box/m1" for row in rows), text_of(rows))
            self.assertTrue(rows[-1].endswith(footer), text_of(rows))

    def start_proxied(
        self, replies: list[Reply], plan: list, approvals: list[str] = [], extra: list[str] = []
    ) -> Terminal:
        """A server the test starts, and the client reaching it through a proxy."""
        base = self.folder()
        model = self.model(replies)
        server_dir = base / "server"
        server_dir.mkdir(mode=0o700)
        server = subprocess.Popen(
            [*program(CORE), "serve"],
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
        proxy = Proxy(info["port"], plan, approvals)
        self.addCleanup(proxy.close)
        self.proxy = proxy
        client_dir = base / "client"
        client_dir.mkdir(mode=0o700)
        info_file = client_dir / "server.json"
        info_file.write_text(json.dumps(dict(info, port=proxy.port)))
        info_file.chmod(0o600)
        terminal = Terminal(base, model, [*extra, "--state-dir", str(client_dir)])
        self.addCleanup(terminal.close)
        terminal.wait_for("ready")
        return terminal

    def test_a_message_streams_its_answer_into_the_transcript(self) -> None:
        reply = Reply("text.sse", hold=4)
        term = self.start([reply])
        term.type("hello there")
        term.wait_for(" hello there")
        term.type("\r")
        rows = term.wait_for("Hello!")
        self.assertIn("Working", text_of(rows))
        self.assertNotIn("meet you", text_of(rows))
        reply.release.set()
        term.wait_for(ANSWER)
        rows = term.wait_for("ready")
        self.assertIn(" hello there", rows)
        request = self.fake.requests.get(timeout=1)
        self.assertEqual(request["messages"][-1]["content"], "hello there")
        term.type("\x03")
        self.assertEqual(term.finish(), 0)

    def test_ctrl_j_adds_a_line_to_the_prompt(self) -> None:
        term = self.start([Reply("text.sse")])
        term.type("one\ntwo")
        rows = term.wait_for(" two")
        self.assertEqual(rows[rows.index(" two") - 1], " one")
        term.type("\r")
        term.wait_for(ANSWER)
        request = self.fake.requests.get(timeout=1)
        self.assertEqual(request["messages"][-1]["content"], "one\ntwo")

    def test_editing_keys_cut_by_word_and_line_and_ctrl_d_quits(self) -> None:
        term = self.start([Reply("text.sse")])
        term.type("one two three")
        term.wait_for(" one two three")
        # Ctrl+Left, Alt+B, Alt+Backspace, Ctrl+Right, Alt+F, Ctrl+W, Ctrl+A, Delete.
        for key in ["\x1b[1;5D", "\x1bb", "\x1b\x7f", "\x1b[1;5C", "\x1bf", "\x17", "\x01", "\x1b[3~"]:
            term.type(key)
        term.wait_until(lambda rows: " wo" in rows, "the edited prompt")
        term.type("\r")
        term.wait_for(ANSWER)
        self.assertEqual(self.fake.requests.get(timeout=5)["messages"][-1]["content"], "wo")
        term.wait_for("ready")
        term.type("\x04")
        self.assertEqual(term.finish(), 0)

    def test_ctrl_g_edits_the_prompt_in_the_editor_and_ctrl_c_there_keeps_the_client(self) -> None:
        editor = self.folder() / "editor"
        # The editor reads two lines from the terminal and adds the second to the prompt, with whether the first held the
        # Ctrl+C byte: with the signal keys on, the terminal would turn it into a signal and drop the line.
        editor.write_text(
            "printf 'editor> '\nread first\nread line\nmark=none\n"
            "case \"$first\" in *\"$(printf '\\003')\"*) mark=ctrl-c;; esac\n"
            "printf '\\n%s %s\\n' \"$line\" \"$mark\" >> \"$1\"\n"
        )
        term = self.start([Reply("text.sse")], env={"VISUAL": f"sh {editor}"})
        term.type("draft")
        term.wait_for(" draft")
        start = len(term.output)
        term.type("\x07")
        term.wait_for_output(b"editor> ", start)
        term.type("\x03\r")
        term.type("more\r")
        term.wait_for(" more ctrl-c")
        term.type("\r")
        term.wait_for(ANSWER)
        self.assertEqual(self.fake.requests.get(timeout=5)["messages"][-1]["content"], "draft\nmore ctrl-c")
        term.wait_for("ready")
        term.type("\x04")
        self.assertEqual(term.finish(), 0)
        self.assertEqual(termios.tcgetattr(term.slave), term.modes_before)
        self.assertEqual(list((term.base / "state" / "edits").iterdir()), [])

    def test_the_model_argument_is_listed_from_the_server_and_tab_completes_it(self) -> None:
        term = self.start([Reply("text.sse")])
        term.type("/model ")
        rows = term.wait_until(lambda rows: any(row.endswith("/test-model") for row in rows), "the models listed")
        pair = next(row for row in rows if row.endswith("/test-model")).split()[-1]
        term.type("\t")
        term.wait_for(f" /model {pair}")
        term.type("\r")
        term.wait_for(f" model {pair} from the next turn")

    def test_escape_stops_the_turn(self) -> None:
        term = self.start([Reply("text.sse", hold=3), Reply("text.sse")])
        term.type("hi\r")
        term.wait_for("Hello!")
        term.wait_for("Working")
        term.type("\x1b")
        term.wait_for(" stopped")
        term.wait_for("ready")
        term.type("again\r")
        term.wait_for(ANSWER)

    def test_bang_lines_run_commands_and_only_one_bang_reaches_the_model(self) -> None:
        term = self.start([Reply("text.sse")])
        term.type("!echo hi\r")
        term.wait_for("$ echo hi")
        term.wait_until(lambda rows: "hi" in [row.strip() for row in rows] and "ready" in text_of(rows), "echo's output")
        term.type("!!echo secret\r")
        term.wait_for("not sent to the model")
        term.type("!sleep 30\r")
        term.wait_for("$ sleep 30")
        term.wait_for("Working")
        term.type("\x1b")
        term.wait_for("stopping the command")
        term.wait_until(lambda rows: text_of(rows).count("not sent to the model") == 2, "the stopped command")
        term.wait_for("ready")
        term.type("hello\r")
        term.wait_for(ANSWER)
        content = self.fake.requests.get(timeout=5)["messages"][-1]["content"]
        self.assertIn("hi", content)
        self.assertNotIn("secret", content)
        self.assertNotIn("sleep", content)
        self.assertTrue(content.endswith("\n\nhello"), content)

    def test_ctrl_t_shows_and_hides_the_thinking(self) -> None:
        term = self.start([Reply("thinking.sse")])
        term.type("hi\r")
        term.wait_for("Hi there.")
        term.wait_for("ready")
        self.assertNotIn("greets", text_of(term.settle()))
        term.type("\x14")
        rows = term.wait_for("The user greets me. I greet back.")
        self.assertLess(text_of(rows).index("greets"), text_of(rows).index("Hi there."))
        term.type("\x14")
        deadline = time.monotonic() + TIMEOUT
        while "greets" in text_of(term.settle(0.2)):
            self.assertLess(time.monotonic(), deadline, "the thinking stayed")

    def test_a_resumed_session_shows_what_its_turns_did(self) -> None:
        """A session resumed from another one shows its turn as it was drawn live: the session line first, then the
        thinking, the tool call, the answer and how the turn ended. Quitting it says how to come back."""
        term = self.start([Reply("think_read.sse"), Reply("text_length.sse")])
        first = re.search(r" session (\S+)", text_of(term.screen())).group(1)
        term.type("Read missing.txt.\r")
        term.wait_for("output limit")
        live = transcript(term.wait_for("ready"))
        self.assertIn("read missing.txt", live)
        term.type("/new\r")
        term.wait_until(lambda rows: "Read missing" not in text_of(rows), "the new session")
        term.type("/resume\r")
        term.wait_for("resume a session (1 of 1)")
        term.type("\r")
        replayed = transcript(term.wait_for("output limit"))
        self.assertEqual(replayed, live)
        self.assertTrue(replayed.startswith(f" session {first}"), replayed)
        term.type("\x14")
        term.wait_for("The user wants the file.")
        term.type("/quit\r")
        term.wait_for(f"to come back: finn --session {first}")

    def test_a_session_attached_mid_turn_shows_each_item_once(self) -> None:
        """A second client that opens a session while its turn waits for an approval shows the history up to the turn,
        then the turn from the replay: each thinking block and tool call once, as the first client does."""
        term = self.start([Reply("think_read.sse"), Reply("write_file.sse"), Reply("text.sse")])
        first = re.search(r" session (\S+)", text_of(term.screen())).group(1)
        term.type("Read missing.txt.\r")
        term.wait_for("Tab to answer")
        args = ["--session", first, "--state-dir", str(term.base / "state"), "--", *program(CORE), "serve"]
        other = Terminal(term.base, self.fake, args, ROWS, COLS, {})
        self.addCleanup(other.close)
        other.wait_for("Tab to answer")
        rows = other.settle()
        text = text_of(rows[: next(i for i, row in enumerate(rows) if row.startswith("──"))])
        for once in ["Read missing.txt.", "▸ thinking", "read missing.txt", "write hello.txt"]:
            self.assertEqual(text.count(once), 1, f"{once!r} in:\n{text}")

    def test_quitting_an_empty_session_says_nothing_of_it(self) -> None:
        term = self.start([])
        term.wait_for("ready")
        term.type("\x03")
        self.assertEqual(term.finish(), 0)
        self.assertNotIn("to come back", text_of(term.screen()))

    def test_session_commands(self) -> None:
        term = self.start([Reply("text.sse"), Reply("text.sse"), Reply("summary.sse")])
        first = re.search(r" session (\S+)", text_of(term.screen())).group(1)
        term.type("hi\r")
        term.wait_for(ANSWER)
        term.wait_for("ready")
        term.type("/model other-model\r")
        term.wait_for(" model other-model from the next turn")
        term.type("again\r")
        # The turn has finished once its answer is drawn twice and the status is back to ready, not before.
        term.wait_until(lambda rows: text_of(rows).count(ANSWER) == 2 and "ready" in rows[-1], "the second answer")
        self.fake.requests.get(timeout=1)
        self.assertEqual(self.fake.requests.get(timeout=5)["model"], "other-model")
        term.type("/compact\r")
        term.wait_for(" compacted")
        self.fake.requests.get(timeout=1)
        term.type("/new\r")
        rows = term.wait_for("ready")
        deadline = time.monotonic() + TIMEOUT
        while ANSWER in text_of(rows):
            self.assertLess(time.monotonic(), deadline, "the old session stayed on the screen")
            rows = term.settle(0.2)
        self.assertNotIn(first, text_of(rows))
        # The new session, empty and the one in use, is not in the list.
        term.type("/resume\r")
        term.wait_for("resume a session (1 of 1)")
        term.type("\x1b")
        rows = term.settle()
        self.assertNotIn("resume a session", text_of(rows))
        term.type("/resume\r")
        term.wait_for("resume a session (1 of 1)")
        term.type(first[:8])
        rows = term.wait_for(f"resume a session (1 of 1) · filter: {first[:8]}")
        row = next(row for row in rows if first in row)
        self.assertTrue(row.startswith("› "), row)
        self.assertIn("other-model", row)
        self.assertIn("  hi", row)
        term.type("\r")
        rows = term.wait_for(" again")
        self.assertIn(f" session {first}", text_of(rows))
        self.assertNotIn("resume a session", text_of(rows))
        term.type("/help\r")
        term.wait_for("leave")
        term.type("/quit\r")
        self.assertEqual(term.finish(), 0)

    def test_a_bracketed_paste_goes_to_the_prompt_and_answers_nothing(self) -> None:
        term = self.start([Reply("write_file.sse"), Reply("text.sse")])
        term.type("write it\r")
        term.wait_for("Tab to answer")
        term.type("\t")
        term.wait_for("y allow · n deny")
        term.settle(0.4)
        # The raw bytes of a paste, with control bytes and a CRLF: the terminal decodes them end to end.
        term.type("\x1b[200~y\x01a\x19n\r\nnext\x1b[201~")
        rows = term.wait_for(" next")
        self.assertIn(" yan", rows)
        self.assertIn("y allow · n deny", text_of(term.settle()))
        self.assertFalse((term.base / "work" / "hello.txt").exists())

    def test_clicks_answer_toggle_and_move_the_cursor(self) -> None:
        term = self.start([Reply("write_file.sse"), Reply("thinking.sse")])
        term.type("write it\r")
        term.find("^Y allow")
        term.settle(0.4)
        term.click(*term.find("^Y allow"))
        term.wait_for(": allow (client)")
        term.wait_for("ready")
        self.assertEqual((term.base / "work" / "hello.txt").read_text(), "hi\n")
        term.type("helo")
        row, col = term.find(" helo")
        term.click(row, col + 5)
        term.type("l")
        term.wait_for(" hello")
        term.type("\r")
        term.click(*term.find("▸ thinking"))
        term.wait_for("The user greets me. I greet back.")
        term.click(*term.find("The user greets me."))
        rows = term.wait_for("▸ thinking")
        self.assertNotIn("greets", text_of(rows))

    def test_yolo_allows_the_calls_of_its_run_but_asks_the_inherited_ones(self) -> None:
        term = self.start([Reply("write_file.sse"), Reply("text.sse"), Reply("write_file.sse"), Reply("text.sse")])
        term.type("write it\r")
        term.wait_for("Tab to answer")
        term.type("\x03")
        self.assertEqual(term.finish(), 0)
        info = json.loads((term.base / "state" / "server.json").read_text())
        server = http.client.HTTPConnection("127.0.0.1", info["port"], timeout=TIMEOUT)
        server.request("GET", "/v1/sessions", headers={"Authorization": f"Bearer {info['token']}"})
        session_id = json.loads(server.getresponse().read())["sessions"][0]["id"]
        server.close()
        args = ["--yolo", "--state-dir", str(term.base / "state"), "--session", session_id]
        again = Terminal(term.base, self.fake, args)
        self.addCleanup(again.close)
        rows = again.wait_for("Tab to answer")
        self.assertIn("YOLO · ", rows[-1])
        self.assertIn(" --yolo: the tool calls of the turns this client starts run without asking", text_of(rows))
        self.assertFalse((term.base / "work" / "hello.txt").exists())
        again.settle(0.4)
        again.type("\x0e")
        again.wait_for(": deny (client)")
        again.wait_until(lambda rows: "ready" in rows[-1], "the end of the turn")
        (term.base / "work" / "hello.txt").unlink(missing_ok=True)
        again.type("write it again\r")
        rows = again.wait_for(" --yolo allows write_file:")
        again.wait_until(lambda rows: text_of(rows).count(ANSWER) == 2 and "ready" in rows[-1], "the answer")
        self.assertNotIn("Tab to answer", text_of(again.screen()))
        self.assertEqual((term.base / "work" / "hello.txt").read_text(), "hi\n")

    def test_yolo_asks_the_calls_of_a_turn_another_client_started(self) -> None:
        term = self.start([Reply("write_file.sse"), Reply("text.sse")], extra=["--yolo"])
        session_id = re.search(r" session (\S+)", text_of(term.screen())).group(1)
        info = json.loads((term.base / "state" / "server.json").read_text())
        server = http.client.HTTPConnection("127.0.0.1", info["port"], timeout=TIMEOUT)
        headers = {"Authorization": f"Bearer {info['token']}", "Content-Type": "application/json"}
        server.request("POST", f"/v1/sessions/{session_id}/messages", json.dumps({"text": "write it"}), headers)
        self.assertEqual(server.getresponse().status, 202)
        server.close()
        term.wait_for("Tab to answer")
        self.assertNotIn("--yolo allows", text_of(term.settle(0.6)))
        self.assertFalse((term.base / "work" / "hello.txt").exists())

    def test_yolo_asks_the_calls_another_client_steers_into_its_turn(self) -> None:
        held = Reply("text.sse", hold=2)
        term = self.start([held, Reply("write_file.sse"), Reply("text.sse")], extra=["--yolo"])
        session_id = re.search(r" session (\S+)", text_of(term.screen())).group(1)
        term.type("say hi\r")
        deadline = time.monotonic() + TIMEOUT
        while self.fake.requests.empty():
            self.assertLess(time.monotonic(), deadline, "the turn called no model")
            term.settle(0.05)
        info = json.loads((term.base / "state" / "server.json").read_text())
        server = http.client.HTTPConnection("127.0.0.1", info["port"], timeout=TIMEOUT)
        headers = {"Authorization": f"Bearer {info['token']}", "Content-Type": "application/json"}
        server.request("POST", f"/v1/sessions/{session_id}/messages", json.dumps({"text": "write it"}), headers)
        self.assertEqual(server.getresponse().status, 202)
        server.close()
        term.wait_for("queued: write it")
        held.release.set()
        term.wait_for("Tab to answer")
        self.assertNotIn("--yolo allows", text_of(term.settle(0.6)))
        self.assertFalse((term.base / "work" / "hello.txt").exists())

    def test_yolo_asks_an_allow_that_was_not_sent(self) -> None:
        term = self.start_proxied([Reply("write_file.sse"), Reply("text.sse")], [], ["fail"], ["--yolo"])
        term.type("write it\r")
        rows = term.wait_for("Tab to answer")
        self.assertIn(" --yolo allows write_file:", text_of(rows))
        term.wait_for("error: the answer was not sent")
        self.assertFalse((term.base / "work" / "hello.txt").exists())

    def test_yolo_drops_a_failed_allow_the_server_resolved_first(self) -> None:
        term = self.start_proxied([Reply("write_file.sse"), Reply("text.sse")], [], ["late_fail"], ["--yolo"])
        term.type("write it\r")
        term.wait_for(": allow (client)")
        term.wait_for("error: the answer was not sent")
        rows = term.wait_until(lambda rows: ANSWER in text_of(rows) and "ready" in rows[-1], "the answer")
        self.assertNotIn("Tab to answer", text_of(term.settle()))
        self.assertNotIn("approval waiting", text_of(rows))
        self.assertEqual((term.base / "work" / "hello.txt").read_text(), "hi\n")

    def test_a_tool_is_approved_and_its_notices_shown(self) -> None:
        term = self.start([Reply("write_file.sse"), Reply("text.sse")])
        term.type("write it\r")
        rows = term.wait_for("^Y allow · ^N deny")
        self.assertIn("Tab to answer (a: allow write_file on this exact target for the session)", rows)
        self.assertIn("approval waiting", text_of(rows))
        self.assertIn(" write_file:", text_of(rows))
        self.assertIn("  hi", rows)
        term.type("\t")
        term.wait_for("y allow · n deny · a allow write_file")
        term.settle(0.4)
        term.type("y")
        term.wait_for(ANSWER)
        rows = term.wait_for("ready")
        shown = text_of(rows)
        self.assertIn(": allow (client)", shown)
        self.assertIn(" write hello.txt\n   + 1 hi\n", shown)
        self.assertIn("   Took ", shown)
        self.assertNotIn("Tab to answer", shown)
        self.assertEqual((term.base / "work" / "hello.txt").read_text(), "hi\n")

    def test_a_denied_tool_writes_nothing(self) -> None:
        term = self.start([Reply("write_file.sse"), Reply("text.sse")])
        term.type("write it\r")
        term.wait_for("Tab to answer")
        term.settle(0.4)
        term.type("\x0e")
        rows = term.wait_for("ready")
        self.assertIn(": deny (client)", text_of(rows))
        self.assertFalse((term.base / "work" / "hello.txt").exists())

    def test_a_client_that_attaches_asks_the_pending_approval(self) -> None:
        term = self.start([Reply("write_file.sse"), Reply("text.sse")])
        term.type("write it\r")
        rows = term.wait_for("Tab to answer")
        approval_id = re.search(r"approval (\S+) · write_file", text_of(rows)).group(1)
        term.type("\x03")
        self.assertEqual(term.finish(), 0)
        info = json.loads((term.base / "state" / "server.json").read_text())
        server = http.client.HTTPConnection("127.0.0.1", info["port"], timeout=TIMEOUT)
        server.request("GET", "/v1/sessions", headers={"Authorization": f"Bearer {info['token']}"})
        session_id = json.loads(server.getresponse().read())["sessions"][0]["id"]
        server.close()
        args = ["--state-dir", str(term.base / "state"), "--session", session_id]
        again = Terminal(term.base, self.fake, args)
        self.addCleanup(again.close)
        rows = again.wait_for("Tab to answer")
        self.assertIn(f"approval {approval_id} · write_file", text_of(rows))
        again.settle(0.4)
        again.type("\x19")
        again.wait_for(ANSWER)
        self.assertEqual((term.base / "work" / "hello.txt").read_text(), "hi\n")

    def test_an_approval_answered_by_another_client_closes_the_panel(self) -> None:
        term = self.start([Reply("write_file.sse"), Reply("text.sse")])
        term.type("write it\r")
        rows = term.wait_for("Tab to answer")
        approval_id = re.search(r"approval (\S+) · write_file", text_of(rows)).group(1)
        info = json.loads((term.base / "state" / "server.json").read_text())
        headers = {"Authorization": f"Bearer {info['token']}", "Content-Type": "application/json"}
        server = http.client.HTTPConnection("127.0.0.1", info["port"], timeout=TIMEOUT)
        server.request("GET", "/v1/sessions", headers=headers)
        session_id = json.loads(server.getresponse().read())["sessions"][0]["id"]
        body = json.dumps({"decision": "deny"})
        server.request("POST", f"/v1/sessions/{session_id}/approvals/{approval_id}", body, headers)
        self.assertEqual(server.getresponse().status, 200)
        server.close()
        rows = term.wait_for(": deny (client)")
        rows = term.wait_for("ready")
        self.assertNotIn("Tab to answer", text_of(rows))
        term.type("\t")
        term.type("y")
        rows = term.wait_for(" y")
        self.assertFalse((term.base / "work" / "hello.txt").exists())

    def test_term_hup_and_int_restore_the_terminal(self) -> None:
        for sig, code in [(signal.SIGTERM, 143), (signal.SIGHUP, 129), (signal.SIGINT, 130)]:
            with self.subTest(signal=sig.name):
                term = self.start([])
                term.process.send_signal(sig)
                self.assertEqual(term.finish(), code)
                self.assertIn(LEAVE_SCREEN, term.output[term.output.rindex(ENTER_SCREEN) :])
                self.assertEqual(termios.tcgetattr(term.slave), term.modes_before)

    def test_a_cut_stream_is_read_again_from_the_last_event(self) -> None:
        term = self.start_proxied([Reply("text.sse", pause=0.1)], [("cut", 3)])
        term.type("hi\r")
        term.wait_for(ANSWER)
        rows = term.wait_for("ready")
        self.assertEqual(text_of(rows).count("Hello!"), 1, text_of(rows))
        self.assertEqual(len(self.proxy.asked), 2, self.proxy.paths)
        self.assertEqual(self.proxy.asked[1], self.proxy.passed[0][-1])

    def test_a_resync_reads_the_session_again(self) -> None:
        term = self.start_proxied([Reply("text.sse", pause=0.1)], [("cut", 3), "resync"])
        term.type("hi\r")
        term.wait_for(ANSWER)
        rows = term.wait_for("ready")
        self.assertEqual(text_of(rows).count("Hello!"), 1, text_of(rows))
        self.assertEqual(rows.count(" hi"), 1, text_of(rows))
        reads = [path for path in self.proxy.paths if path.startswith("GET") and not path.endswith("/events")]
        self.assertTrue(any("/sessions/" in path for path in reads), self.proxy.paths)

    def test_resyncs_in_a_row_end_the_client(self) -> None:
        term = self.start_proxied([Reply("text.sse", hold=4)], [("cut", 3), "resync", "resync", "resync"])
        term.type("hi\r")
        self.assertEqual(term.finish(), 1)
        after = term.output[term.output.rindex(LEAVE_SCREEN) :]
        self.assertIn(b"keeps asking to read the session again", after)


class FinnCommandTest(unittest.TestCase):
    """`bin/finn` picks the client: the full screen with no command or options alone, the line client for `chat` and
    its own forms, and a refusal when the full screen would have no terminal. A fake AGENTICA writes the arguments it
    got."""

    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="agc-finn-"))
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.args = self.dir / "args"
        fake = self.dir / "agentica"
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$FINN_ARGS"\n')
        fake.chmod(0o755)
        kept = {key: value for key, value in os.environ.items() if key in KEPT_ENV}
        self.env = dict(kept, AGENTICA=str(fake), FINN_ARGS=str(self.args))
        self.tui = str(ROOT / "tui_client" / "main.agc")
        self.cli = str(ROOT / "cli" / "main.agc")

    def finn(self, args: list[str], tty_in: bool = True, tty_out: bool = True) -> tuple[int, list[str]]:
        """Runs bin/finn with a terminal on stdin and stdout as asked (a pipe otherwise): its exit code, and the
        arguments the fake got (none when it did not run)."""
        self.args.unlink(missing_ok=True)
        master, slave = os.openpty()
        stdin = slave if tty_in else subprocess.DEVNULL
        stdout = slave if tty_out else subprocess.PIPE
        process = subprocess.Popen(
            [str(ROOT / "bin" / "finn"), *args], stdin=stdin, stdout=stdout, stderr=subprocess.PIPE, env=self.env
        )
        os.close(slave)
        deadline = time.monotonic() + TIMEOUT
        try:
            while process.poll() is None:
                self.assertLess(time.monotonic(), deadline, f"finn {args} did not end")
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        os.read(master, 4096)
                    except OSError:
                        break
            process.communicate(timeout=TIMEOUT)
        finally:
            os.close(master)
        got = self.args.read_text().splitlines() if self.args.exists() else []
        return process.returncode, got

    def test_no_command_and_options_alone_open_the_full_screen(self) -> None:
        forms = [
            [],
            ["--yolo", "--model", "m"],
            ["tui", "--yolo"],
            ["--", "my-server", "-p", "8080"],
            ["--cwd", "server"],
            ["--model", "-p"],
        ]
        for args in forms:
            words = args[1:] if args[:1] == ["tui"] else args
            self.assertEqual(self.finn(args), (0, [self.tui, *words]), args)

    def test_chat_and_the_forms_of_the_line_client_go_to_it(self) -> None:
        self.assertEqual(self.finn(["chat", "--yolo"]), (0, [self.cli, "--yolo"]))
        self.assertEqual(self.finn(["-p", "fix it"]), (0, [self.cli, "-p", "fix it"]))
        forms = [
            ["--yolo", "-p", "fix it"],
            ["-pfix"],
            ["--prompt=x"],
            ["--delete", "s1"],
            ["--logout=groq"],
            ["--server-command", "core serve"],
            ["server", "status"],
            ["--state-dir", "d", "server", "status"],
        ]
        for args in forms:
            self.assertEqual(self.finn(args, tty_in=False, tty_out=False), (0, [self.cli, *args]), args)

    def test_the_full_screen_without_a_terminal_refuses(self) -> None:
        for tty_in, tty_out in [(False, False), (True, False), (False, True)]:
            for args in [[], ["--yolo"], ["--", "my-server", "-p", "8080"]]:
                self.assertEqual(self.finn(args, tty_in, tty_out), (2, []), (args, tty_in, tty_out))

    def test_help_and_version_need_no_terminal(self) -> None:
        for args in [["--model", "x", "--help"], ["--yolo", "-h"], ["--yolo", "--version"]]:
            self.assertEqual(self.finn(args, tty_in=False, tty_out=False), (0, [self.tui, *args]), args)


if __name__ == "__main__":
    unittest.main()
