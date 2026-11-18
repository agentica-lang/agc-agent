#!/bin/sh
# Fails when a page of docs/content has no `description: TEXT` inside the front matter (the first --- block): the skill
# finn and `finn docs` list every page of that folder (not _index.md, not a folder) by it.
set -eu

status=0
for page in docs/content/*.md; do
  case $(basename "$page") in _*) continue ;; esac
  if ! awk 'NR == 1 { if ($0 != "---") exit 1; next } $0 == "---" { exit !found } /^description:[ \t]*[^ \t]/ { found = 1 }' "$page"; then
    echo "check-docs: $page has no description in its front matter" >&2
    status=1
  fi
done
exit $status
