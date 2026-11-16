"""Runs the tests of test_pty.py at once, one process each (they use their own folders and port 0), and fails when
one fails or none ran. JOBS sets how many run together. Standard library only."""

import concurrent.futures
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODULE = "tui_client.tests.test_pty"


def test_ids() -> list[str]:
    suite = unittest.defaultTestLoader.loadTestsFromName(MODULE)
    ids = []
    stack = [suite]
    while stack:
        item = stack.pop()
        if isinstance(item, unittest.TestSuite):
            stack.extend(reversed(list(item)))
        else:
            ids.append(item.id())
    return ids


def run(test_id: str) -> tuple[str, bool, float, str]:
    started = time.monotonic()
    done = subprocess.run(
        [sys.executable, "-m", "unittest", test_id], cwd=ROOT, capture_output=True, text=True, timeout=300
    )
    return test_id, done.returncode == 0, time.monotonic() - started, done.stderr


def main() -> int:
    sys.path.insert(0, str(ROOT))
    ids = test_ids()
    from tui_client.tests import test_pty

    build = tempfile.mkdtemp(prefix="agc-tui-build-")
    os.environ["PTY_BUILD"] = build
    compiled = time.monotonic()
    test_pty.compile_programs(build)
    print(f"compiled in {time.monotonic() - compiled:.1f}s", flush=True)
    jobs = int(os.environ.get("JOBS", "4"))
    failed = []
    started = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        for test_id, passed, took, errors in pool.map(run, ids):
            print(f"{'ok' if passed else 'FAIL'} {took:5.1f}s {test_id.rsplit('.', 1)[-1]}", flush=True)
            if not passed:
                failed.append(test_id)
                print(errors, file=sys.stderr)
    shutil.rmtree(build, True)
    print(f"{len(ids) - len(failed)} passed, {len(failed)} failed in {time.monotonic() - started:.1f}s")
    return 1 if failed or not ids else 0


if __name__ == "__main__":
    sys.exit(main())
