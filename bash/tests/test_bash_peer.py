"""The commands that the bash package finds in a line against those that real bash runs: for random lines of
unknown commands joined by `;`, `&&`, `|`, `|&`, `&` and line ends, inside subshells, groups, `if`, `while`, `for`,
`case`, functions and substitutions, with redirections (and words after them), backticks and here-documents, every
command bash runs (its `command_not_found_handle` gets the words) is one the package gives, with the same words.
The package may give more (a function's name, `break`, an assignment); a line it marks unclear or with a syntax
error is not compared.

Python standard library only: the cases come from a seeded random generator instead of Hypothesis.
"""

import json
import os
import random
import re
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
OPERATORS = [" ; ", "; ", " && ", " | ", "|", " |& ", " & ", "\n"]
REDIRECTIONS = ["2>/dev/null", ">/dev/null", "</dev/null", "2>&1"]


def plain(rng):
    return "".join(rng.choice(PLAIN) for _ in range(rng.randint(1, 4)))


def argument(rng, depth):
    choice = rng.randint(0, 14)
    if choice == 0:
        return "'" + plain(rng) + " " + plain(rng) + "'"
    if choice == 1:
        return '"' + plain(rng) + " " + plain(rng) + '"'
    if choice == 2 and depth < 2:
        return "$( " + line(rng, depth + 1) + " )"
    if choice == 3 and depth < 2:
        return "`" + simple(rng, 2) + "`"
    if choice == 4 and depth < 2:
        return "<(" + simple(rng, depth + 1) + ")"
    if choice == 5 and depth < 2:
        return '"$(' + simple(rng, 2) + ')"'
    return plain(rng)


def simple(rng, depth):
    """A simple command: maybe an assignment first, maybe a redirection, with words after it too."""
    words = [rng.choice(NAMES)] + [argument(rng, depth) for _ in range(rng.randint(0, 3))]
    if rng.random() < 0.25:
        words.insert(rng.randint(1, len(words)), rng.choice(REDIRECTIONS))
    prefix = "V=1 " if rng.random() < 0.15 else ""
    return prefix + " ".join(words)


def item(rng, depth):
    choice = rng.randint(0, 16) if depth < 2 else 16
    if choice == 0:
        return "( " + line(rng, depth + 1) + " )"
    if choice == 1:
        return "{ " + line(rng, depth + 1) + "; }"
    if choice == 2:
        return "if " + simple(rng, depth) + "; then " + line(rng, depth + 1) + "; fi"
    if choice == 3:
        return "while " + simple(rng, depth) + "; do " + line(rng, depth + 1) + "; break; done"
    if choice == 4:
        return "for v in 1; do " + line(rng, depth + 1) + "; done"
    if choice == 5:
        return "case k in k) " + line(rng, depth + 1) + ";; esac"
    if choice == 6:
        return "fn" + str(depth) + "() { " + line(rng, depth + 1) + "; }; fn" + str(depth)
    if choice == 7:
        return "[[ -n $(" + simple(rng, 2) + ") || 1 ]]"
    if choice == 8:
        return "! " + simple(rng, depth)
    if choice == 9:
        return simple(rng, depth) + ' <<< "$(' + simple(rng, 2) + ')"'
    return simple(rng, depth)


def line(rng, depth=0):
    text = item(rng, depth)
    for _ in range(rng.randint(0, 3)):
        text += rng.choice(OPERATORS) + item(rng, depth)
    if depth == 0 and rng.random() < 0.3:
        start = rng.choice(["<<EOF", "<<'EOF'", "<<EOF " + plain(rng) + " " + plain(rng)])
        body = rng.choice(["x $(" + simple(rng, 2) + ") y", "plain text", "`" + simple(rng, 2) + "`"])
        text += "\n" + simple(rng, 1) + " " + start + "\n" + body + "\nEOF"
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
    write, so the commands of a pipeline do not mix and a command substitution expands to nothing. A process
    substitution is `<PS>`."""
    script = "exec 9>&1; command_not_found_handle() { printf '%s\\0' \"$@\" $'\\1' >&9; return 0; }\n" + text + "\nwait\n"
    with tempfile.TemporaryDirectory() as folder:
        out = subprocess.run(
            [BASH, "-c", script],
            capture_output=True,
            cwd=folder,
            env={"PATH": "/nonexistent-peer-path", "HOME": folder},
            timeout=20,
        )
    records = out.stdout.decode("utf-8", "surrogateescape").split("\1\0")[:-1]
    return {tuple("<PS>" if re.fullmatch(r"/dev/fd/\d+", w) else w for w in r.split("\0")[:-1]) for r in records}


def as_bash_passes(word):
    kind, text = word
    if kind == "string" and text.startswith('"$('):
        return ""
    if kind in ("string", "raw_string"):
        return text[1:-1]
    if kind == "process_substitution":
        return "<PS>"
    return text


def package_commands(result):
    """The words of each command the package gives, as bash passes them: quotes taken off, a substitution, which
    expands to nothing here, left out, and a quoted one empty."""
    return {tuple(as_bash_passes(w) for w in c if w[0] != "command_substitution") for c in result["commands"]}


class BashPeerTest(unittest.TestCase):
    def test_the_commands_bash_runs_are_among_those_of_the_line(self):
        rng = random.Random(int(os.environ.get("BASH_PEER_SEED", "215")))
        lines = [line(rng) for _ in range(CASES)]
        results = parsed(lines)
        self.assertEqual(len(results), len(lines))
        skipped = 0
        for text, result in zip(lines, results):
            self.assertIsNotNone(result, text)
            if result["unclear"] or result["error"]:
                skipped += 1
                continue
            self.assertEqual(bash_commands(text) - package_commands(result), set(), text)
        print(f"{skipped} of {CASES} lines unclear or with a syntax error")
        self.assertLess(skipped, CASES // 3)

    def test_the_known_misreads_are_unclear(self):
        lines = [
            "zqa `zqb` `zqc`",
            "zqa <<EOF\n`zqb`\nEOF",
            "zqa - 2>/dev/null",
            "zqa | zqb | zqc x\nzq-d <<EOF\nbody\nEOF",
            "zqa a\\\nb",
        ]
        self.assertEqual([r["unclear"] for r in parsed(lines)], [True] * len(lines))


if __name__ == "__main__":
    unittest.main()
