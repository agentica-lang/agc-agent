#!/bin/sh
# Makes sure that the submodule vendor/tree-sitter-bash holds the parser that bash/native/grammar/parser.c names by its
# sha256 (that line is part of the source key of bash's native module, and a build of another parser would stay in the
# native cache under that key). Fetches the submodule when it is missing or at another commit; never moves one that has
# local changes or commits. Run from the root of a git clone (make native-source).
set -eu

sub=vendor/tree-sitter-bash
parser=$sub/src/parser.c
stub=bash/native/grammar/parser.c

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d ' ' -f 1
}

parser_ok() {
  [ -f "$parser" ] && grep -qx "// sha256 $(sha256 "$parser")" "$stub"
}

fail() {
  echo "native-source: $*" >&2
  exit 1
}

[ -e .git ] || fail 'bash needs the tree-sitter-bash submodule: use a git clone and "make install"'

if ! parser_ok; then
  if [ -e "$sub/.git" ]; then
    wanted=$(git ls-files -s "$sub" | awk '{ print $2 }')
    head=$(git -C "$sub" rev-parse HEAD)
    if [ "$head" != "$wanted" ]; then
      ancestor=0
      git -C "$sub" merge-base --is-ancestor "$head" "$wanted" 2>/dev/null || ancestor=$?
      if [ -n "$(git -C "$sub" status --porcelain)" ] || [ "$ancestor" -eq 1 ]; then
        fail "$sub is at $head, not at $wanted, and has local changes or commits: commit them (and update the sha256 line of $stub), or run git -C $sub checkout $wanted"
      fi
    fi
  fi
  git submodule update --init "$sub"
fi

parser_ok || fail "$parser is not the parser that $stub names (sha256): the submodule has local edits, or its commit was bumped without updating the sha256 line of the stub"
