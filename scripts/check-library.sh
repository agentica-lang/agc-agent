#!/bin/sh
# Fails when a prebuilt library of bash's native module needs more than it may: it is loaded on machines that have no
# compiler and nothing of ours beside it. Usage: check-library.sh FILE (.so, .dylib or .dll).
# Linux: no GLIBC symbol newer than the 2.28 of the build, and only the libraries of glibc itself. macOS: only
# libSystem, and a deployment target of 12.0 at most (the second line of otool -L is the library's own id). Windows:
# only the system's DLLs, never libwinpthread (the loader does not find it beside the file).
# It fails closed: a missing tool is exit 2, and so is a list that it cannot read (empty). The tools run on their own,
# never in a pipeline, so a failure of one is the failure of the script.
set -eu

file=$1
max_glibc=2.28
max_macos=12.0

fail() {
  echo "check-library: $file: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "check-library: $1 is not on PATH" >&2; exit 2; }
}

# Whether $1 is at most $2, as versions.
at_most() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$2" ]
}

# Fails unless every line of $1 matches the pattern $2 (an allowlist); $1 is not empty.
only() {
  [ -n "$1" ] || fail "no library listed (the tool printed nothing it can read)"
  bad=$(echo "$1" | grep -Evi "$2" || true)
  [ -z "$bad" ] || fail "needs what it may not: $bad"
}

case $file in
  *.so)
    need objdump
    dynamic=$(objdump -p "$file")
    needed=$(echo "$dynamic" | awk '$1 == "NEEDED" { print $2 }')
    echo "$needed"
    only "$needed" '^(libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|ld-linux[-a-z0-9.]*\.so\.[0-9])$'
    symbols=$(objdump -T "$file")
    newest=$(echo "$symbols" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/^GLIBC_//' | sort -Vu | tail -n 1 || true)
    [ -n "$newest" ] || fail "no GLIBC symbol version found"
    echo "newest glibc symbol: $newest"
    at_most "$newest" "$max_glibc" || fail "uses GLIBC_$newest, newer than $max_glibc"
    ;;
  *.dylib)
    need otool
    listed=$(otool -L "$file")
    needed=$(echo "$listed" | tail -n +3 | awk '{ print $1 }')
    echo "$needed"
    only "$needed" '^/usr/lib/libSystem\.B\.dylib$'
    commands=$(otool -l "$file")
    minos=$(echo "$commands" | awk '$1 == "minos" { print $2; exit }')
    [ -n "$minos" ] || minos=$(echo "$commands" | awk '/LC_VERSION_MIN_MACOSX/ { found = 1 } found && $1 == "version" { print $2; exit }')
    [ -n "$minos" ] || fail "no deployment target found"
    echo "deployment target: $minos"
    at_most "$minos" "$max_macos" || fail "deployment target $minos is newer than $max_macos"
    ;;
  *.dll)
    need objdump
    dynamic=$(objdump -p "$file")
    needed=$(echo "$dynamic" | awk '/DLL Name:/ { print $3 }')
    echo "$needed"
    only "$needed" '^(kernel32\.dll|msvcrt\.dll|ucrtbase\.dll|api-ms-win-crt-[a-z0-9-]+\.dll)$'
    ;;
  *)
    echo "check-library: $file is not a .so, .dylib or .dll" >&2
    exit 2
    ;;
esac
echo "check-library: $file ok"
