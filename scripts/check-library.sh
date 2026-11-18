#!/bin/sh
# Fails when a prebuilt library of bash's native module needs more than it may: it is loaded on machines that have no
# compiler and nothing of ours beside it. Usage: check-library.sh FILE (.so, .dylib or .dll).
# Linux: no GLIBC symbol newer than the 2.28 of the build, and only the libraries of glibc itself. macOS: only
# libSystem. Windows: only the system's DLLs, never libwinpthread (the loader does not find it beside the file).
set -eu

file=$1
max_glibc=2.28

# Prints each name and fails when one is not matched by the pattern of the allowlist.
allow() {
  bad=$(grep -Evi "$1" || true)
  if [ -n "$bad" ]; then
    echo "check-library: $file needs what it may not:" >&2
    echo "$bad" >&2
    exit 1
  fi
}

case $file in
  *.so)
    needed=$(objdump -p "$file" | awk '$1 == "NEEDED" { print $2 }')
    echo "$needed"
    echo "$needed" | allow '^(libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|ld-linux[-a-z0-9.]*\.so\.[0-9]|$)'
    newest=$(objdump -T "$file" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/^GLIBC_//' | sort -Vu | tail -n 1)
    echo "newest glibc symbol: ${newest:-none}"
    if [ -n "$newest" ] && [ "$(printf '%s\n%s\n' "$newest" "$max_glibc" | sort -V | tail -n 1)" != "$max_glibc" ]; then
      echo "check-library: $file uses GLIBC_$newest, newer than $max_glibc" >&2
      exit 1
    fi
    ;;
  *.dylib)
    needed=$(otool -L "$file" | tail -n +2 | awk '{ print $1 }')
    echo "$needed"
    echo "$needed" | allow '^(/usr/lib/libSystem\.B\.dylib|$)'
    ;;
  *.dll)
    needed=$(objdump -p "$file" | awk '/DLL Name:/ { print $3 }')
    echo "$needed"
    echo "$needed" | allow '^(kernel32\.dll|msvcrt\.dll|ucrtbase\.dll|api-ms-win-crt-[a-z0-9-]+\.dll|$)'
    ;;
  *)
    echo "check-library: $file is not a .so, .dylib or .dll" >&2
    exit 2
    ;;
esac
echo "check-library: $file ok"
