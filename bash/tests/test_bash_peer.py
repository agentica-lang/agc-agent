"""The commands that the bash package finds in a line against those that real bash runs: for random lines of
unknown commands joined by `;`, `&&`, `|` and line ends, inside subshells, groups and command substitutions, every
command bash runs (its `command_not_found_handle` gets the words) is one the package gives, with the same words.

Python standard library only: the cases come from a seeded random generator instead of Hypothesis.
"""

import json
import os
import random
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HELPER = os.path.join(ROOT, "bash", "tests", "support", "commands.agc")
AGENTICA = os.environ.get("AGENTICA", "agentica")
BASH = shutil.which("bash")
CASES = 150

NAMES = ["zqa", "zqb", "zqc", "zq-d", "zq.e"]
PLAIN = "abcxyz019_./:,+@%-"
OPERATORS = [" ; ", "; ", " && ", "&&", " | ", "|", "\n"]


def plain(rng):
    return "".join(rng.choice(PLAIN) for _ in range(rng.randint(1, 4)))


def argument(rng, depth):
    choice = rng.randint(0, 9)
    if choice == 0:
        return "'" + plain(rng) + " " + plain(rng) + "'"
    if choice == 1:
        return '"' + plain(rng) + " " + plain(rng) + '"'
    if choice == 2 and depth < 2:
        return "$( " + line(rng, depth + 1) + " )"
    return plain(rng)


def command(rng, depth):
    words = [rng.choice(NAMES)] + [argument(rng, depth) for _ in range(rng.randint(0, 3))]
    return " ".join(words)


def item(rng, depth):
    choice = rng.randint(0, 7)
    if choice == 0 and depth < 2:
        return "( " + line(rng, depth + 1) + " )"
    if choice == 1 and depth < 2:
        return "{ " + line(rng, depth + 1) + "; }"
    return command(rng, depth)


def line(rng, depth=0):
    text = item(rng, depth)
    for _ in range(rng.randint(0, 3)):
        text += rng.choice(OPERATORS) + item(rng, depth)
    return text


def parsed(lines):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(lines, f)
    try:
        out = subprocess.run([AGENTICA, HELPER, f.name], capture_output=True, text=True, check=True, timeout=300)
    finally:
        os.unlink(f.name)
    return json.loads(out.stdout)


def bash_commands(text):
    """The words of each command that bash runs: the handler of unknown commands writes them to descriptor 9 in one
    write, so the commands of a pipeline do not mix and a command substitution expands to nothing."""
    script = "exec 9>&1; command_not_found_handle() { printf '%s\\0' \"$@\" $'\\1' >&9; return 0; }\n" + text
    with tempfile.TemporaryDirectory() as folder:
        out = subprocess.run(
            [BASH, "-c", script],
            capture_output=True,
            cwd=folder,
            env={"PATH": "/nonexistent-peer-path", "HOME": folder},
            timeout=10,
        )
    records = out.stdout.decode("utf-8", "surrogateescape").split("\1\0")[:-1]
    return sorted([record.split("\0")[:-1] for record in records])


def unquoted(word):
    kind, text = word
    if kind in ("string", "raw_string"):
        return text[1:-1]
    return text


def package_commands(result):
    """The words of each command the package gives, as bash passes them: quotes taken off, and a substitution, which
    expands to nothing here, left out."""
    return sorted([[unquoted(w) for w in c if w[0] != "command_substitution"] for c in result["commands"]])


class BashPeerTest(unittest.TestCase):
    def test_the_commands_of_a_line_are_those_bash_runs(self):
        rng = random.Random(int(os.environ.get("BASH_PEER_SEED", "215")))
        lines = [line(rng) for _ in range(CASES)]
        results = parsed(lines)
        self.assertEqual(len(results), len(lines))
        for text, result in zip(lines, results):
            self.assertIsNotNone(result, text)
            self.assertFalse(result["error"], text)
            self.assertEqual(package_commands(result), bash_commands(text), text)


if __name__ == "__main__":
    unittest.main()
