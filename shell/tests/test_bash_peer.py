"""The parser of the shell package against real bash: for commands made of random pieces of bash syntax, the words it
gives are the ones bash passes to a program (printf '%s\\0'), a word bash expands to file names is marked as a
glob, and whatever else bash would expand does not parse.

Python standard library only: the cases come from a seeded random generator instead of Hypothesis.
"""

import json
import os
import random
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HELPER = os.path.join(ROOT, "shell", "tests", "support", "argv.agc")
AGENTICA = os.environ.get("AGENTICA", "agentica")
CASES = 600

PLAIN = "abcxyzABC019_./:=,+@%-^]"
PIECES_IN_QUOTES = "ab $`\\\"'!*?~{}|;&<>()#\t"


def unquoted(rng):
    choices = [
        lambda: "".join(rng.choice(PLAIN) for _ in range(rng.randint(1, 4))),
        lambda: "\\" + rng.choice(PLAIN + PIECES_IN_QUOTES),
        lambda: rng.choice(["*", "?", "[ab]", "~", "~/x", "$x", "${x}", "$(echo hi)", "`echo hi`", "{a,b}", "!", "#c"]),
        lambda: rng.choice(["a=~", "b:~", "HEAD~1", "x~y"]),
    ]
    return rng.choice(choices)()


def single(rng):
    return "'" + "".join(rng.choice(PIECES_IN_QUOTES.replace("'", "")) for _ in range(rng.randint(0, 4))) + "'"


def double(rng):
    body = ""
    for _ in range(rng.randint(0, 4)):
        body += rng.choice(["a", " ", "\\\\", '\\"', "\\$", "\\`", "\\x", "*", "'", "~", "$x", "`id`", "!", "|", ";"])
    return '"' + body + '"'


def word(rng):
    return "".join(rng.choice([unquoted, unquoted, single, double])(rng) for _ in range(rng.randint(1, 3)))


REDIRECTIONS = ["2>/dev/null", ">/dev/null", ">out", ">>log", "2>&1", "</dev/null", "3>x", "2>>err", "> out", "< /dev/null"]
OPERATORS = [" ; ", " && ", " || ", " | ", ";", "&&", "|"]


def segment(rng):
    parts = [word(rng) for _ in range(rng.randint(1, 4))]
    for _ in range(rng.randint(0, 2)):
        parts.insert(rng.randint(1, len(parts)), rng.choice(REDIRECTIONS))
    return " ".join(parts)


def command(rng):
    """A list of simple commands joined by operators: the text and its segments."""
    segments = [segment(rng) for _ in range(rng.randint(1, 3))]
    text = segments[0]
    for seg in segments[1:]:
        text += rng.choice(OPERATORS) + seg
    return text, segments


def parsed(texts):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(texts, f)
    try:
        out = subprocess.run([AGENTICA, HELPER, f.name], capture_output=True, text=True, check=True, timeout=120)
    finally:
        os.unlink(f.name)
    return json.loads(out.stdout)


def bash_words(text, names):
    """The words bash passes to a function for one simple command, its redirections applied and left out, in a fresh
    folder with the files `names`."""
    with tempfile.TemporaryDirectory() as folder:
        for name in names:
            open(os.path.join(folder, name), "w").close()
        return run_bash(text, folder)


def run_bash(text, folder):
    env = {"PATH": "/usr/bin:/bin", "HOME": "/home-of-the-peer", "x": "EXPANDED"}
    script = "exec 9>&1; f() { printf '%s\\0' \"$@\" >&9; }; f " + text
    out = subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        cwd=folder,
        env=env,
        timeout=10,
    )
    if out.returncode != 0:
        return None
    return out.stdout.decode("utf-8", "surrogateescape").split("\0")[:-1]


class BashPeerTest(unittest.TestCase):
    def test_words_match_bash_and_expansions_do_not_parse(self):
        rng = random.Random(int(os.environ.get("SHELL_PEER_SEED", "94")))
        cases = [command(rng) for _ in range(CASES)]
        results = parsed([text for text, _ in cases])
        compared = 0
        for (text, segments), result in zip(cases, results):
            if result is None:
                continue
            self.assertEqual(len(result), len(segments), text)
            compared += 1
            for seg, got in zip(segments, result):
                words = [w[0] for w in got]
                self.assertEqual(bash_words(seg, []), words, text)
                if bash_words(seg, ["ab", "a", "b", "-x"]) != words:
                    self.assertTrue(any(w[1] for w in got), "a glob not marked: " + text)
        self.assertGreater(compared, CASES // 10)


if __name__ == "__main__":
    unittest.main()
